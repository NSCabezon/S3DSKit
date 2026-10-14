/// Monotonic counters sampled for ``S3DSStats``.
struct StatsInput: Sendable {
    var sender = SenderCounters()
    /// Audio frames (per channel, before resampling) passed to `submitAudio`, connected or not.
    var audioFramesSubmitted = 0
    /// Audio frames lost in the ring before encoding.
    var audioFramesDropped = 0
    var encoderIsHardware: Bool?
    var multiSlicePicturesDropped = 0
}

/// Turns periodic counter snapshots into ``S3DSStats``. Pure (the clock is passed in), so tests
/// can drive it with synthetic time.
struct StatsSampler {
    /// Window for the audio rates: long enough to smooth 10 ms callback granularity and
    /// once-per-second sampling.
    static let audioWindow: Double = 2

    private var history: [(time: Double, input: StatsInput)]

    init(now: Double, input: StatsInput = StatsInput()) {
        history = [(now, input)]
    }

    mutating func update(_ input: StatsInput, now: Double) -> S3DSStats {
        let last = history[history.count - 1]
        history.append((now, input))
        // Keep the newest sample that is at least `audioWindow` old as the window start.
        while history.count > 2, now - history[1].time >= Self.audioWindow { history.removeFirst() }
        let oldest = history[0]

        let c = input.sender
        let dt = max(0.001, now - last.time)
        let window = max(0.001, now - oldest.time)
        var s = S3DSStats()
        s.framesPerSecond = Double(c.framesSent - last.input.sender.framesSent) / dt
        s.kilobitsPerSecond = Double(c.bytesSent - last.input.sender.bytesSent) * 8 / 1000 / dt
        s.framesSent = c.framesSent
        s.framesDropped = c.framesDropped
        s.backpressureFramesDropped = c.backpressureDropped
        s.awaitingKeyframeFramesDropped = c.awaitingKeyframeDropped
        s.oversizeFramesDropped = c.oversizeDropped
        s.keyframesSent = c.keyframesSent
        s.audioPacketsSent = c.audioPacketsSent
        s.audioInputFramesPerSecond =
            Double(input.audioFramesSubmitted - oldest.input.audioFramesSubmitted) / window
        s.audioPacketsPerSecond =
            Double(c.audioPacketsSent - oldest.input.sender.audioPacketsSent) / window
        s.audioDroppedInputFrames = input.audioFramesDropped
        s.encoderIsHardware = input.encoderIsHardware
        s.multiSlicePicturesDropped = input.multiSlicePicturesDropped
        return s
    }
}
