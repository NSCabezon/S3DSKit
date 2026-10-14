import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Metal
import QuartzCore
import Synchronization
import os

/// The thread-safe core behind ``S3DSStreamer``: throttle → congestion gate → rotate/stack (GPU)
/// → H.264 → TCP.
///
/// Congestion is handled per stereo pair, before any work: when a pair is due but the oldest
/// unsent video AU is older than `CongestionPolicy.skipLatency`, the pair is skipped (never
/// rotated nor encoded), so the H.264 reference chain stays intact. Skips also drive the
/// adaptive bitrate (`CongestionController`).
///
/// Every mutable field lives in a `Mutex`/`Atomic`; the Metal/VT objects are immutable references
/// whose APIs are thread-safe, hence `@unchecked Sendable`.
final class StreamEngine: @unchecked Sendable {
    enum Event: Sendable {
        case state(S3DSConnectionState)
        case preview(UncheckedBox<CGImage>)
    }

    private struct Throttle {
        var limiter: FrameThrottle
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
    private let throttle: Mutex<Throttle>
    private let audioFramesSubmitted = Atomic<Int>(0)
    private let congestion: Mutex<CongestionController>
    /// Opus bitrate when audio is on (0 otherwise); part of the rate the backlog drains at.
    private let audioBitrate: Int
    private let congestionSkips = Atomic<Int>(0)
    /// Alternating pixel-buffer input: the last left frame was accepted, so its right may follow.
    private let rightExpected = Atomic<Bool>(false)
    private let options: Mutex<S3DSFrameOptions>
    private let previewEnabled = Atomic<Bool>(false)
    private let lastPreview = Mutex<Double>(-.infinity)
    private let lastPTS = Mutex<CMTime>(.invalid)
    private struct SummarySnapshot {
        var time: Double
        var sender: SenderCounters
        var submitted: Int
        var encoded: Int
        var latencySum: Double
        var multiSlice: Int
        var skipped: Int
    }
    private let lastSummary = Mutex<SummarySnapshot?>(nil)
    private static let log = Logger(subsystem: "S3DSKit", category: "engine")

    /// Why GPU input is unavailable (nil when it works).
    let metalError: String?

    init(configuration: S3DSConfiguration, device: (any MTLDevice)?) {
        fps = configuration.framesPerSecond
        throttle = Mutex(Throttle(limiter: FrameThrottle(framesPerSecond: configuration.framesPerSecond)))
        layout = configuration.layout
        options = Mutex(configuration.frameOptions)
        var policy = configuration.congestion
        policy.adaptiveBitrate = configuration.adaptiveBitrate
        congestion = Mutex(CongestionController(
            policy: policy, bitrate: configuration.bitrate,
            framesPerSecond: configuration.framesPerSecond * configuration.layout.framesPerPair,
            audioBitrate: configuration.audioEnabled ? configuration.audioBitrate : 0))
        (events, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .bufferingNewest(16))

        let link = SenderLink()
        let encoder = H264Encoder(
            settings: .init(layout: configuration.layout, bitrate: configuration.bitrate,
                            fps: configuration.framesPerSecond, keyframeInterval: configuration.keyframeInterval,
                            encoder: configuration.encoder),
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
            policy: policy,
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
        audioBitrate = configuration.audioEnabled ? configuration.audioBitrate : 0
        sender.setDrainRate(configuration.bitrate + audioBitrate)
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
    func setBitrate(_ bitrate: Int) {
        congestion.withLock { $0.setTarget(bitrate) }
        encoder.setBitrate(bitrate)
        sender.setDrainRate(bitrate + audioBitrate)
    }
    /// Starts the bitrate adaptation at `bitrate` (clamped to the floor and the ceiling).
    func setStartBitrate(_ bitrate: Int) {
        let rate = congestion.withLock { c -> Int in c.setStart(bitrate); return c.bitrate }
        encoder.setBitrate(rate)
        sender.setDrainRate(rate + audioBitrate)
    }
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
        guard let audio, frames > 0, sampleRate > 0 else { return }
        audioFramesSubmitted.add(frames, ordering: .relaxed)   // lock-free: real-time safe
        guard isConnected else { return }
        audio.ring.write(frames: frames, sampleRate: sampleRate, endTime: endTime, sample: sample)
    }

    var audioEnabled: Bool { audio != nil }

    /// Counters behind ``S3DSStats`` (monotonic).
    var statsInput: StatsInput {
        StatsInput(sender: counters,
                   audioFramesSubmitted: audioFramesSubmitted.load(ordering: .relaxed),
                   audioFramesDropped: audio?.ring.droppedFrames ?? 0,
                   encoderIsHardware: encoder.isHardware,
                   multiSlicePicturesDropped: encoder.multiSlicePicturesDropped,
                   congestionPairsSkipped: congestionSkips.load(ordering: .relaxed),
                   videoBitrate: videoBitrate)
    }

    /// The bitrate the encoder runs at (configured, or lowered by the adaptation).
    var videoBitrate: Int { congestion.withLock { $0.bitrate } }
    /// Stereo pairs skipped before encoding because of congestion (monotonic).
    var congestionPairsSkipped: Int { congestionSkips.load(ordering: .relaxed) }
    /// Test hooks.
    var encoderCounters: (submitted: Int, encoded: Int, latencySum: Double) { encoder.encodeCounters }
    var encoderKeyframeTimes: [Double] { encoder.keyframeTimes }
    /// Estimated seconds of data queued ahead of a new pair (what the skip decision uses).
    var videoBacklog: Double { sender.backlogSeconds() }
    var socketBacklog: Int { sender.socketBacklog }

    /// Logs (info) a one-line sender summary, plus a drop-reason line when anything was dropped
    /// since the last call. Call about once per second; calls closer than 0.9 s are ignored.
    func logSummary(now: Double) {
        let c = counters
        let e = encoder.encodeCounters
        let multi = encoder.multiSlicePicturesDropped
        let skipped = congestionPairsSkipped
        let snap = SummarySnapshot(time: now, sender: c, submitted: e.submitted, encoded: e.encoded,
                                   latencySum: e.latencySum, multiSlice: multi, skipped: skipped)
        let previous: SummarySnapshot? = lastSummary.withLock { last in
            if let l = last, now - l.time < 0.9 { return nil }
            defer { last = snap }
            return last ?? SummarySnapshot(time: now - 1, sender: SenderCounters(), submitted: 0, encoded: 0,
                                           latencySum: 0, multiSlice: 0, skipped: 0)
        }
        guard let p = previous, isConnected else { return }
        let dt = max(0.001, now - p.time)
        let encoded = e.encoded - p.encoded
        let latencyMs = encoded > 0 ? (e.latencySum - p.latencySum) / Double(encoded) * 1000 : 0
        let hw = encoder.isHardware.map { $0 ? "hw" : "sw" } ?? "?"
        let skips = skipped - p.skipped
        Self.log.info("""
            video/s: submitted \(e.submitted - p.submitted) encoded \(encoded) sent \(c.framesSent - p.sender.framesSent) \
            keys \(c.keyframesSent - p.sender.keyframesSent) dropped \(c.framesDropped - p.sender.framesDropped) \
            pairs-skipped \(skips); \(Int(Double(c.bytesSent - p.sender.bytesSent) * 8 / 1000 / dt)) kbps \
            (bitrate \(self.videoBitrate / 1000) kbps); in-flight \(c.inFlight) \
            backlog \(Int(self.videoBacklog * 1000)) ms (socket \(self.socketBacklog / 1024) KiB); encode \(String(format: "%.1f", latencyMs)) ms avg (\(hw))
            """)
        let bp = c.backpressureDropped - p.sender.backpressureDropped
        let gate = c.awaitingKeyframeDropped - p.sender.awaitingKeyframeDropped
        let big = c.oversizeDropped - p.sender.oversizeDropped
        let ms = multi - p.multiSlice
        if bp + gate + big + ms + skips > 0 {
            Self.log.info("""
                drops/s: congestion-skipped pairs \(skips) backpressure \(bp) awaiting-keyframe \(gate) \
                oversize \(big) multi-slice \(ms) (totals \(skipped)/\(c.backpressureDropped)/\
                \(c.awaitingKeyframeDropped)/\(c.oversizeDropped)/\(multi); recovery IDRs \
                \(c.recoveryKeyframesRequested))
                """)
        }
    }

    /// Test hook: drain the audio ring synchronously.
    func drainAudioNow() { audio?.drainNow() }

    // MARK: - Throttle

    /// Reserves a capture slot if one is due at `now` (seconds, CACurrentMediaTime clock) and the
    /// link is not congested. A due slot refused for congestion still consumes the throttle's
    /// cadence: that pair is skipped, not delayed.
    func reserveCapture(at now: Double) -> Bool {
        guard wantsFrames else { return false }
        let due = throttle.withLock { t in
            guard t.inFlight < Self.maxGPUFramesInFlight else { return false }
            return t.limiter.accept(at: now)
        }
        return due && congestionAllowsPair()
    }

    // MARK: - Congestion

    /// Congestion gate for a new stereo pair (call once per pair, before any work on it). Records
    /// a skip when it refuses.
    private func congestionAllowsPair() -> Bool {
        guard isConnected else { return true }
        let backlog = sender.backlogSeconds()
        guard congestion.withLock({ $0.shouldSkip(backlog: backlog) }) else { return true }
        congestionSkips.add(1, ordering: .relaxed)
        recordPair(skipped: true, backlog: backlog)
        return false
    }

    /// Feeds one due pair (sent on, or skipped) and the backlog it saw to the bitrate adaptation.
    private func recordPair(skipped: Bool, backlog: Double? = nil) {
        let now = CACurrentMediaTime()
        let seen = backlog ?? sender.backlogSeconds()
        let link = sender.linkSample()
        guard let (old, rate) = congestion.withLock({ c -> (Int, Int)? in
            let old = c.bitrate
            return c.record(at: now, skipped: skipped, backlog: seen, link: link).map { (old, $0) }
        }) else { return }
        encoder.setBitrate(rate)
        sender.setDrainRate(rate + audioBitrate)
        Self.log.info("adaptive bitrate: \(rate / 1000) kbps (\(rate < old ? "congested" : "link clear"))")
    }

    // MARK: - Frame input

    func submit(left: any MTLTexture, right: (any MTLTexture)?,
                commandBuffer: (any MTLCommandBuffer)?, throttled: Bool) -> Bool {
        let now = CACurrentMediaTime()
        guard let rotator else { return false }
        if throttled {
            guard reserveCapture(at: now) else { return false }
        } else {
            guard wantsFrames, congestionAllowsPair() else { return false }
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
        if isConnected { recordPair(skipped: false) }
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
        // In the alternating layout the pair is decided on its left frame (throttle, congestion);
        // a right frame is accepted only right after an accepted left, so a skipped pair can
        // never leave a lone right frame.
        if alternating, eye == .right {
            guard rightExpected.exchange(false, ordering: .acquiringAndReleasing), wantsFrames else { return false }
        } else {
            let accepted = throttled ? reserveCapture(at: now) : (wantsFrames && congestionAllowsPair())
            if alternating { rightExpected.store(accepted, ordering: .releasing) }
            guard accepted else { return false }
            if isConnected { recordPair(skipped: false) }
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
