import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Metal
import QuartzCore
import Synchronization
import os

/// The thread-safe core behind ``S3DSStreamer``: throttle → rotate/stack (GPU) → H.264 → TCP.
///
/// Every mutable field lives in a `Mutex`/`Atomic`; the Metal/VT objects are immutable references
/// whose APIs are thread-safe, hence `@unchecked Sendable`.
final class StreamEngine: @unchecked Sendable {
    enum Event: Sendable {
        case state(S3DSConnectionState)
        case preview(UncheckedBox<CGImage>)
    }

    private struct Throttle {
        var lastCapture: Double = -.infinity
        var inFlight = 0
    }

    /// Strong link encoder → sender, set once after both exist (avoids a retain cycle: the sender
    /// only references the encoder weakly).
    private final class SenderLink: Sendable {
        let sender = Mutex<StreamSender?>(nil)
    }

    private final class Flag: Sendable {
        let value = Atomic<Bool>(false)
    }

    static let maxGPUFramesInFlight = 3
    static let previewInterval: Double = 0.25

    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    private let fps: Int
    let layout: S3DSLayout
    private let encoder: H264Encoder
    private let audio: AudioPipeline?
    private let sender: StreamSender
    private let rotator: FrameRotator?
    private let commandQueue: (any MTLCommandQueue)?
    private let connected = Flag()
    private let throttle = Mutex(Throttle())
    private let options: Mutex<S3DSFrameOptions>
    private let previewEnabled = Atomic<Bool>(false)
    private let lastPreview = Mutex<Double>(-.infinity)
    private let lastPTS = Mutex<CMTime>(.invalid)
    private static let log = Logger(subsystem: "S3DSKit", category: "engine")

    /// Why GPU input is unavailable (nil when it works).
    let metalError: String?

    init(configuration: S3DSConfiguration, device: (any MTLDevice)?) {
        fps = configuration.framesPerSecond
        layout = configuration.layout
        options = Mutex(configuration.frameOptions)
        (events, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .bufferingNewest(16))

        let link = SenderLink()
        let encoder = H264Encoder(
            settings: .init(layout: configuration.layout, bitrate: configuration.bitrate,
                            fps: configuration.framesPerSecond, keyframeInterval: configuration.keyframeInterval),
            output: { data, isKey, eye in
                link.sender.withLock { $0 }?.sendVideo(data, isKeyframe: isKey, eye: eye)
            })
        let audio = configuration.audioEnabled
            ? AudioPipeline(bitrate: configuration.audioBitrate, output: { packet, micros in
                link.sender.withLock { $0 }?.sendAudio(packet, timestampMicros: micros)
            })
            : nil
        let connected = self.connected
        let continuation = self.continuation
        let sender = StreamSender(
            senderName: configuration.senderName,
            maxInFlightFrames: configuration.maxInFlightFrames * configuration.layout.framesPerPair,
            callbacks: .init(
                stateChanged: { [weak encoder] state in
                    connected.value.store(state == .connected, ordering: .relaxed)
                    if state == .connected { audio?.start() } else { audio?.stop() }
                    if state == .connected { encoder?.forceKeyframe() }
                    continuation.yield(.state(state))
                },
                keyframeNeeded: { [weak encoder] in encoder?.forceKeyframe() }
            ))
        link.sender.withLock { $0 = sender }
        self.encoder = encoder
        self.audio = audio
        self.sender = sender

        let dev = device ?? MTLCreateSystemDefaultDevice()
        var rotator: FrameRotator?
        var metalError: String?
        if let dev {
            do { rotator = try FrameRotator(device: dev, layout: configuration.layout) } catch { metalError = "\(error)" }
        } else {
            metalError = "no Metal device"
        }
        self.rotator = rotator
        self.commandQueue = rotator?.device.makeCommandQueue()
        self.metalError = metalError
        if let metalError { Self.log.error("GPU input disabled: \(metalError)") }
    }

    deinit {
        sender.disconnect()
        continuation.finish()
    }

    var device: (any MTLDevice)? { rotator?.device }

    // MARK: - Control

    func connect(host: String, port: UInt16) { sender.connect(host: host, port: port) }
    func disconnect() { sender.disconnect() }
    func setBitrate(_ bitrate: Int) { encoder.setBitrate(bitrate) }
    func setFrameOptions(_ o: S3DSFrameOptions) { options.withLock { $0 = o } }
    func setPreviewEnabled(_ on: Bool) { previewEnabled.store(on, ordering: .relaxed) }
    func forceKeyframe() { encoder.forceKeyframe() }

    var isConnected: Bool { connected.value.load(ordering: .relaxed) }
    var counters: SenderCounters { sender.counterSnapshot }

    /// Whether anything consumes frames right now (connected, or preview on).
    var wantsFrames: Bool { isConnected || previewEnabled.load(ordering: .relaxed) }

    // MARK: - Audio

    /// Real-time safe: copies into the ring (short lock, no allocation) when connected.
    /// `sample(frame, channel)` for channel 0/1.
    func submitAudio(frames: Int, sampleRate: Double, endTime: Double, sample: (Int, Int) -> Float) {
        guard let audio, frames > 0, sampleRate > 0, isConnected else { return }
        audio.ring.write(frames: frames, sampleRate: sampleRate, endTime: endTime, sample: sample)
    }

    var audioEnabled: Bool { audio != nil }

    /// Test hook: drain the audio ring synchronously.
    func drainAudioNow() { audio?.drainNow() }

    // MARK: - Throttle

    /// Reserves a capture slot if one is due at `now` (seconds, CACurrentMediaTime clock).
    func reserveCapture(at now: Double) -> Bool {
        guard wantsFrames else { return false }
        let interval = 1.0 / Double(fps)
        return throttle.withLock { t in
            guard t.inFlight < Self.maxGPUFramesInFlight else { return false }
            let elapsed = now - t.lastCapture
            guard elapsed >= interval * 0.9 else { return false }
            // Stay on a regular cadence under display-rate jitter; resync after gaps.
            t.lastCapture = elapsed < 2 * interval ? t.lastCapture + interval : now
            return true
        }
    }

    // MARK: - Frame input

    func submit(left: any MTLTexture, right: (any MTLTexture)?,
                commandBuffer: (any MTLCommandBuffer)?, throttled: Bool) -> Bool {
        let now = CACurrentMediaTime()
        guard let rotator else { return false }
        if throttled {
            guard reserveCapture(at: now) else { return false }
        } else if !wantsFrames {
            return false
        }
        let opts = options.withLock { $0 }
        var l = left, r = right ?? left
        if opts.swapEyes, right != nil { swap(&l, &r) }

        let ownBuffer = commandBuffer == nil
        guard let cb = commandBuffer ?? commandQueue?.makeCommandBuffer() else { return false }
        guard let buffers = rotator.encode(left: l, right: r, fit: opts.fit, flipY: opts.flipY, into: cb)
        else {
            if ownBuffer { cb.commit() }
            return false
        }
        throttle.withLock { $0.inFlight += 1 }
        let box = UncheckedBox(buffers)
        cb.addCompletedHandler { [weak self] buffer in
            guard let self else { return }
            self.throttle.withLock { $0.inFlight -= 1 }
            if buffer.status == .completed {
                self.deliver(box.value, hostTime: now)
            } else if let error = buffer.error {
                Self.log.error("rotate/stack command buffer failed: \(error.localizedDescription)")
            }
        }
        if ownBuffer { cb.commit() }
        return true
    }

    func submit(pixelBuffer: CVPixelBuffer, eye: S3DSEye?, throttled: Bool) -> Bool {
        let now = CACurrentMediaTime()
        let alternating = layout == .alternating240x400
        guard CVPixelBufferGetWidth(pixelBuffer) == layout.frameWidth,
              CVPixelBufferGetHeight(pixelBuffer) == layout.frameHeight,
              !alternating || eye != nil else {
            Self.log.error("submit(pixelBuffer:): wrong size or missing eye for layout \(String(describing: self.layout))")
            return false
        }
        // In the alternating layout only left frames are throttled; the right one follows.
        if throttled, eye != .right {
            guard reserveCapture(at: now) else { return false }
        } else if !wantsFrames {
            return false
        }
        if alternating {
            encodeIfConnected(pixelBuffer, eye: eye, hostTime: now)
        } else {
            deliver([pixelBuffer], hostTime: now)
        }
        return true
    }

    private func encodeIfConnected(_ pixelBuffer: CVPixelBuffer, eye: S3DSEye?, hostTime: Double) {
        guard isConnected else { return }
        let pts = lastPTS.withLock { last -> CMTime in
            var t = CMTime(seconds: hostTime, preferredTimescale: 1_000_000)
            if last.isValid, t <= last { t = last + CMTime(value: 1, timescale: 1_000_000) }
            last = t
            return t
        }
        encoder.encode(pixelBuffer, presentationTime: pts, eye: eye)
    }

    /// Finished frames of one stereo pair (`[stacked]` or `[left, right]`): encode (if connected)
    /// and refresh the preview (if enabled).
    private func deliver(_ buffers: [CVPixelBuffer], hostTime: Double) {
        if isConnected {
            if buffers.count == 2 {
                // Right frame is presented half a pair interval after the left one.
                let half = 0.5 / Double(fps)
                encodeIfConnected(buffers[0], eye: .left, hostTime: hostTime)
                encodeIfConnected(buffers[1], eye: .right, hostTime: hostTime + half)
            } else if let stacked = buffers.first {
                encodeIfConnected(stacked, eye: nil, hostTime: hostTime)
            }
        }
        if previewEnabled.load(ordering: .relaxed) {
            let due = lastPreview.withLock { last -> Bool in
                guard hostTime - last >= Self.previewInterval else { return false }
                last = hostTime
                return true
            }
            if due, let image = buffers.count == 2
                ? SideBySidePreview.makeImage(left: buffers[0], right: buffers[1])
                : buffers.first.flatMap({ SideBySidePreview.makeImage(fromStacked: $0) }) {
                continuation.yield(.preview(UncheckedBox(image)))
            }
        }
    }
}
