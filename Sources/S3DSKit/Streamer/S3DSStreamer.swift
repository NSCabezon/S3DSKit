import CoreGraphics
import CoreVideo
import Foundation
import Metal
import Observation
import QuartzCore

/// Streams stereo frames to a New Nintendo 3DS running the 3DSStream receiver.
///
/// Create one per app, `connect(host:port:)` to the IP shown on the 3DS bottom screen, then feed
/// frames from your render loop with one of the `submit` methods:
///
/// 1. ``submit(left:right:commandBuffer:throttle:)`` — two eye textures of any size (or one for
///    mono); the library scales, rotates, stacks and encodes them. Most apps want this.
/// 2. ``StereoEyeRenderer`` + (1) — let the library own 400x240 eye targets and call your Metal
///    draw code once per eye from a ``StereoCamera`` (Compositor Services / Metal apps).
/// 3. ``submit(pixelBuffer:eye:throttle:)`` — already rotated BGRA frames in the configured layout.
///
/// Observable state (`connectionState`, `stats`, `previewImage`) lives on the main actor. The
/// `submit` methods and ``nextCaptureDue(at:)`` are `nonisolated` and thread-safe: call them from
/// any thread, every display frame if convenient — the built-in throttle limits work to
/// `configuration.framesPerSecond` and makes extra calls cheap no-ops. Nothing blocks the caller:
/// GPU work completes asynchronously and encoding/networking run on background queues.
@MainActor
@Observable
public final class S3DSStreamer {
    /// The configuration the streamer was created with (bitrate reflects later changes).
    public private(set) var configuration: S3DSConfiguration
    /// Current link state.
    public private(set) var connectionState: S3DSConnectionState = .disconnected
    /// Statistics, refreshed about once per second while the streamer is alive.
    public private(set) var stats = S3DSStats()
    /// An 800x240 side-by-side (left | right) preview of the stream, updated ≤ 4 times per
    /// second while ``isPreviewEnabled`` is true.
    public private(set) var previewImage: CGImage?

    /// True while connected to a receiver (frames are being encoded and sent).
    public var isStreaming: Bool { connectionState == .connected }

    /// Average bitrate in bits per second; applies to the running encoder immediately.
    public var bitrate: Int {
        get { configuration.bitrate }
        set {
            configuration.bitrate = newValue
            engine.setBitrate(newValue)
        }
    }

    /// Fit / swap / flip options for texture input; applies from the next frame.
    public var frameOptions: S3DSFrameOptions {
        get { configuration.frameOptions }
        set {
            configuration.frameOptions = newValue
            engine.setFrameOptions(newValue)
        }
    }

    /// Generate ``previewImage``. When enabled, frames are also processed while disconnected.
    public var isPreviewEnabled = false {
        didSet { engine.setPreviewEnabled(isPreviewEnabled) }
    }

    /// The Metal device used for texture input (pass textures created on this device), or nil if
    /// Metal setup failed (see ``metalError``).
    public nonisolated var device: (any MTLDevice)? { engine.device }

    /// Why texture input is unavailable, if it is.
    public nonisolated var metalError: String? { engine.metalError }

    @ObservationIgnored private nonisolated let engine: StreamEngine
    @ObservationIgnored private var lastCounters = SenderCounters()
    @ObservationIgnored private var lastCountersTime = CACurrentMediaTime()

    /// - Parameters:
    ///   - configuration: bitrate, frame rate, keyframe interval, frame options.
    ///   - device: the Metal device your textures live on (default: the system device).
    public init(configuration: S3DSConfiguration = S3DSConfiguration(), device: (any MTLDevice)? = nil) {
        self.configuration = configuration
        self.engine = StreamEngine(configuration: configuration, device: device)
        let events = engine.events
        Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.refreshStats()
            }
        }
    }

    // MARK: - Connection

    /// Connects to a 3DS receiver (replacing any current connection). Does not retry on its own:
    /// on failure `connectionState` becomes `.failed` and you may call `connect` again.
    public func connect(host: String, port: UInt16 = S3DSProtocol.defaultPort) {
        engine.connect(host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: port)
    }

    /// Closes the connection.
    public func disconnect() {
        engine.disconnect()
    }

    /// Asks the encoder for an IDR frame next.
    public nonisolated func requestKeyframe() {
        engine.forceKeyframe()
    }

    // MARK: - Frame input (thread-safe)

    /// Whether a frame is due at `time` (seconds on the `CACurrentMediaTime()` clock), reserving
    /// the slot if so. Use it to skip rendering eye images that would be dropped, then submit
    /// with `throttle: false`. Returns false while nothing consumes frames (not connected and
    /// preview off) or the GPU is behind.
    public nonisolated func nextCaptureDue(at time: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        engine.reserveCapture(at: time)
    }

    /// Submits a stereo (or mono) frame as eye textures.
    ///
    /// Textures may be any size (scaled per ``S3DSFrameOptions/fit`` with a cheap anti-aliased
    /// downsample) and must have `.shaderRead` usage. Formats: `rgba8Unorm`, `bgra8Unorm` (and other
    /// Unorm formats) are read as-is and should hold sRGB-encoded color; `*_srgb` and float formats
    /// are read as linear and encoded to sRGB.
    ///
    /// - Parameters:
    ///   - left: left eye image (or the mono image).
    ///   - right: right eye image; nil = mono (left is shown to both eyes).
    ///   - commandBuffer: if given, the GPU work is encoded into it (ordered after your rendering)
    ///     and **you must commit it** after this call; if nil the library uses its own queue.
    ///   - throttle: apply the frame-rate throttle (default). Pass false if you already called
    ///     ``nextCaptureDue(at:)``.
    /// - Returns: true if the frame was accepted, false if it was skipped (not due, nothing to send
    ///   to, GPU busy, or Metal unavailable).
    @discardableResult
    public nonisolated func submit(left: any MTLTexture, right: (any MTLTexture)? = nil,
                                   commandBuffer: (any MTLCommandBuffer)? = nil,
                                   throttle: Bool = true) -> Bool {
        engine.submit(left: left, right: right, commandBuffer: commandBuffer, throttled: throttle)
    }

    /// Submits the eye textures produced by a ``StereoEyeRenderer``.
    @discardableResult
    public nonisolated func submit(_ eyes: StereoEyeTextures, commandBuffer: (any MTLCommandBuffer)? = nil,
                                   throttle: Bool = true) -> Bool {
        submit(left: eyes.left, right: eyes.right, commandBuffer: commandBuffer, throttle: throttle)
    }

    /// Submits an already rotated frame in the configured layout: a `kCVPixelFormatType_32BGRA`
    /// buffer holding sRGB-encoded color (IOSurface-backed recommended), see `docs/ARCHITECTURE.md`.
    ///
    /// - `.stacked240x800`: one 240x800 buffer per stereo frame, `eye` nil.
    /// - `.alternating240x400`: one 240x400 buffer per eye; submit `.left` then `.right`. Only left
    ///   frames are throttled (a rejected left means: skip its right too).
    @discardableResult
    public nonisolated func submit(pixelBuffer: CVPixelBuffer, eye: S3DSEye? = nil, throttle: Bool = true) -> Bool {
        engine.submit(pixelBuffer: pixelBuffer, eye: eye, throttled: throttle)
    }

    // MARK: - Private

    private func handle(_ event: StreamEngine.Event) {
        switch event {
        case .state(let state):
            connectionState = state
        case .preview(let image):
            if isPreviewEnabled { previewImage = image.value }
        }
    }

    private func refreshStats() {
        let c = engine.counters
        let now = CACurrentMediaTime()
        let dt = max(0.001, now - lastCountersTime)
        var s = S3DSStats()
        s.framesPerSecond = Double(c.framesSent - lastCounters.framesSent) / dt
        s.kilobitsPerSecond = Double(c.bytesSent - lastCounters.bytesSent) * 8 / 1000 / dt
        s.framesSent = c.framesSent
        s.framesDropped = c.framesDropped
        s.keyframesSent = c.keyframesSent
        stats = s
        lastCounters = c
        lastCountersTime = now
    }
}
