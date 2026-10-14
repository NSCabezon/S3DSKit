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

/// Which VideoToolbox H.264 encoder to use.
public enum S3DSEncoderPreference: Sendable, Equatable {
    /// Software encoder (240x400 costs little CPU), because the Vision Pro's hardware encoder is
    /// suspected to ignore `NumberOfSlices = 1`. If a hardware session is ever in use (software
    /// unavailable) and emits a multi-slice picture, the session is rebuilt once on software.
    /// Default.
    case automatic
    /// Always ask for the software encoder; multi-slice pictures are dropped and logged.
    case software
    /// VideoToolbox's default choice (hardware on device); multi-slice pictures are dropped and
    /// logged, never switched.
    case hardware
}

/// Encoder and transport settings for an ``S3DSStreamer``.
public struct S3DSConfiguration: Sendable, Equatable {
    /// Stream layout (must match what the receiver expects).
    public var layout: S3DSLayout
    /// Average H.264 bitrate in bits per second, clamped to ``bitrateRange``. Default 1.2 Mbps; 1.5 Mbps was clean
    /// over the 3DS's Wi-Fi; above ~2 Mbps risks stalls (2.5 Mbps stalled on hardware).
    public var bitrate: Int {
        didSet { bitrate = Self.clampBitrate(bitrate) }
    }
    /// Default network budget for video in flight, in seconds.
    static let inFlightSeconds = 0.25
    /// Allowed video bitrate range (0.5–3 Mbps).
    public static let bitrateRange = 500_000...3_000_000
    static func clampBitrate(_ b: Int) -> Int { min(max(b, bitrateRange.lowerBound), bitrateRange.upperBound) }
    /// Target stereo frame rate (pairs per second). With `.alternating240x400` the encoder runs
    /// at twice this rate. Submissions arriving faster are dropped by the built-in throttle.
    public var framesPerSecond: Int
    /// Stereo frames (pairs) between scheduled keyframes. Default `2 * framesPerSecond` (2 s).
    public var keyframeInterval: Int
    /// Name sent in the HELLO message (≤ 64 UTF-8 bytes).
    public var senderName: String
    /// Stereo frames allowed in flight to the network (send not yet completed). Beyond it, video
    /// is dropped until the next *scheduled* keyframe (no extra IDR is forced). Default ≈ 250 ms
    /// at `framesPerSecond` (5 pairs = 10 AUs at 20 pairs/s).
    public var maxInFlightFrames: Int
    /// How source images are fitted, eye swapping, flipping.
    public var frameOptions: S3DSFrameOptions
    /// Stream audio submitted with `submitAudio` (Opus, 48 kHz stereo, 20 ms packets).
    public var audioEnabled: Bool
    /// Opus bitrate in bits per second.
    public var audioBitrate: Int
    /// Which H.264 encoder to use. Default `.automatic` (software).
    public var encoder: S3DSEncoderPreference

    public init(layout: S3DSLayout = .alternating240x400,
                bitrate: Int = 1_200_000,
                framesPerSecond: Int = 20,
                keyframeInterval: Int? = nil,
                senderName: String = "S3DSKit",
                maxInFlightFrames: Int? = nil,
                frameOptions: S3DSFrameOptions = S3DSFrameOptions(),
                audioEnabled: Bool = true,
                audioBitrate: Int = 96_000,
                encoder: S3DSEncoderPreference = .automatic) {
        self.layout = layout
        self.bitrate = Self.clampBitrate(bitrate)
        self.framesPerSecond = max(1, framesPerSecond)
        self.keyframeInterval = max(1, keyframeInterval ?? 2 * self.framesPerSecond)
        self.senderName = senderName
        self.maxInFlightFrames = max(1, maxInFlightFrames
            ?? Int((Self.inFlightSeconds * Double(self.framesPerSecond)).rounded(.up)))
        self.frameOptions = frameOptions
        self.audioEnabled = audioEnabled
        self.audioBitrate = audioBitrate
        self.encoder = encoder
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
    /// Total frames dropped by the sender (sum of the three reasons below).
    public var framesDropped: Int = 0
    /// Dropped because the network was backed up (in-flight budget exceeded).
    public var backpressureFramesDropped: Int = 0
    /// Dropped while waiting for the next keyframe after an earlier drop.
    public var awaitingKeyframeFramesDropped: Int = 0
    /// Dropped because an AU exceeded the 256 KiB payload limit.
    public var oversizeFramesDropped: Int = 0
    /// Total keyframes sent.
    public var keyframesSent: Int = 0
    /// Total Opus audio packets sent (50 per second while audio flows).
    public var audioPacketsSent: Int = 0
    /// Audio input rate actually measured: frames (per channel, before resampling) passed to
    /// `submitAudio` per second of wall-clock time, averaged over the last ~2 s. Counted whether
    /// or not a receiver is connected. It should match the `sampleRate` you declare (48000 for
    /// real-time 48 kHz audio); a higher value means the app produces audio faster than real time
    /// (e.g. an emulator running fast, or interleaved stereo submitted with `channels: 1`), and
    /// the 3DS will receive more audio than it can play.
    public var audioInputFramesPerSecond: Double = 0
    /// Opus packets sent per second, averaged over the last ~2 s (50 for real-time input).
    public var audioPacketsPerSecond: Double = 0
    /// Total audio input frames lost before encoding: overwritten in the input ring (~4 s at 48 kHz) because
    /// the encoder fell behind, or discarded when the input sample rate changed. Normally 0.
    public var audioDroppedInputFrames: Int = 0
    /// Whether the H.264 session runs on the hardware encoder (nil before the first frame, or
    /// when VideoToolbox does not say). `false` with the default `.automatic` encoder.
    public var encoderIsHardware: Bool?
    /// Total encoded pictures dropped because they had more than one slice (the 3DS decoder
    /// needs exactly one). Should stay 0.
    public var multiSlicePicturesDropped: Int = 0

    public init() {}
}
