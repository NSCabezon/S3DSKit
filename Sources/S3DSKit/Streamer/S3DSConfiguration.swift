/// How the two eyes are packed into the H.264 stream.
public enum S3DSLayout: Sendable, Equatable {
    /// Each H.264 frame is one eye, 240x400 (the eye's 400x240 image rotated 90° CW); frames
    /// alternate L, R, L, R at twice the stereo rate. Keyframes are always left frames.
    /// `VIDEO_AU` flags: bit1 = eye (0 left, 1 right), bit2 = 1. Default.
    case alternating240x400
    /// Each H.264 frame holds both eyes stacked, 240x800 (left rows 0..399, right 400..799).
    case stacked240x800

    /// Encoded frame size.
    public var frameWidth: Int { 240 }
    public var frameHeight: Int { self == .alternating240x400 ? 400 : 800 }
    /// Encoded frames per stereo pair.
    public var framesPerPair: Int { self == .alternating240x400 ? 2 : 1 }
}

/// Encoder and transport settings for an ``S3DSStreamer``.
public struct S3DSConfiguration: Sendable, Equatable {
    /// Stream layout (must match what the receiver expects).
    public var layout: S3DSLayout
    /// Average H.264 bitrate in bits per second, clamped to ``bitrateRange``. 1.5 Mbps is clean
    /// over the 3DS's Wi-Fi; above ~2 Mbps risks stalls (2.5 Mbps stalled on hardware).
    public var bitrate: Int {
        didSet { bitrate = Self.clampBitrate(bitrate) }
    }
    /// Allowed video bitrate range (0.5–3 Mbps).
    public static let bitrateRange = 500_000...3_000_000
    static func clampBitrate(_ b: Int) -> Int { min(max(b, bitrateRange.lowerBound), bitrateRange.upperBound) }
    /// Target stereo frame rate (pairs per second). With `.alternating240x400` the encoder runs
    /// at twice this rate. Submissions arriving faster are dropped by the built-in throttle.
    public var framesPerSecond: Int
    /// Maximum stereo frames (pairs) between keyframes (the contract asks for ≤ 1 s).
    public var keyframeInterval: Int
    /// Name sent in the HELLO message (≤ 64 UTF-8 bytes).
    public var senderName: String
    /// Stereo frames allowed in flight to the network (send not yet completed) before non-key
    /// frames are dropped and an IDR is forced on the next left frame. Default 6 = 12 AUs = 200 ms
    /// at 60 fps in the alternating layout (the receiver's burst budget).
    public var maxInFlightFrames: Int
    /// How source images are fitted, eye swapping, flipping.
    public var frameOptions: S3DSFrameOptions
    /// Stream audio submitted with `submitAudio` (Opus, 48 kHz stereo, 20 ms packets).
    public var audioEnabled: Bool
    /// Opus bitrate in bits per second.
    public var audioBitrate: Int

    public init(layout: S3DSLayout = .alternating240x400,
                bitrate: Int = 1_500_000,
                framesPerSecond: Int = 30,
                keyframeInterval: Int = 30,
                senderName: String = "S3DSKit",
                maxInFlightFrames: Int = 6,
                frameOptions: S3DSFrameOptions = S3DSFrameOptions(),
                audioEnabled: Bool = true,
                audioBitrate: Int = 96_000) {
        self.layout = layout
        self.bitrate = Self.clampBitrate(bitrate)
        self.framesPerSecond = max(1, framesPerSecond)
        self.keyframeInterval = max(1, keyframeInterval)
        self.senderName = senderName
        self.maxInFlightFrames = max(1, maxInFlightFrames)
        self.frameOptions = frameOptions
        self.audioEnabled = audioEnabled
        self.audioBitrate = audioBitrate
    }
}

/// Options applied when turning submitted eye textures into the 3DS frame.
public struct S3DSFrameOptions: Sendable, Equatable {
    /// Aspect-ratio handling for sources that are not 5:3.
    public var fit: S3DSFit
    /// Swap left and right images (stereo pairs only).
    public var swapEyes: Bool
    /// Flip source images vertically (for bottom-up sources).
    public var flipY: Bool

    public init(fit: S3DSFit = .letterbox, swapEyes: Bool = false, flipY: Bool = false) {
        self.fit = fit
        self.swapEyes = swapEyes
        self.flipY = flipY
    }
}

/// Streaming statistics, refreshed about once per second.
public struct S3DSStats: Sendable, Equatable {
    /// Video frames handed to the network per second.
    public var framesPerSecond: Double = 0
    /// Network throughput in kilobits per second (video + audio, including headers).
    public var kilobitsPerSecond: Double = 0
    /// Total frames sent since the streamer was created.
    public var framesSent: Int = 0
    /// Total frames dropped by backpressure / keyframe gating.
    public var framesDropped: Int = 0
    /// Total keyframes sent.
    public var keyframesSent: Int = 0
    /// Total Opus audio packets sent (50 per second while audio flows).
    public var audioPacketsSent: Int = 0

    public init() {}
}
