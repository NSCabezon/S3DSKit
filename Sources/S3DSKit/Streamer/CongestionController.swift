/// Thresholds of the congestion policy. Internal: tests shorten the windows.
///
/// The measure is the **estimated backlog in seconds** (`StreamSender.backlogSeconds`): the
/// larger of the age of the oldest video AU still queued in Network.framework, and the bytes
/// waiting (that queue plus the unacknowledged TCP send buffer) at the stream's own bitrate. It
/// stays near 0 while the link keeps up (an average AU at 1.2 Mbps / 40 fps is ~3.75 KB, ~25 ms)
/// and grows only when data is produced faster than the link drains it.
struct CongestionPolicy: Sendable, Equatable {
    /// Skip new stereo pairs, before they are rotated or encoded, while the backlog is at least
    /// this long. 150 ms is three pairs at 20 pairs/s and ~22 KB at 1.2 Mbps: more than a typical
    /// IDR plus its pair, so normal jitter does not skip, but half the receiver's ~300 ms audio
    /// budget, so audio queued behind video still arrives in time. A skipped pair is never
    /// encoded, so the H.264 reference chain stays intact and no keyframe is needed.
    var skipLatency: Double = 0.15
    /// Tests turn skipping off to exercise the last-resort drop alone.
    var skipPairs = true
    /// Last resort, after encoding: drop non-key left (or stacked) AUs when the backlog is at
    /// least this long (3× the skip threshold; only pairs already in the GPU/encoder pipeline
    /// when skipping started, or a huge IDR, can get here). Keyframes are dropped only at 2× this.
    /// After such a drop the sender waits for a keyframe and asks for one (forced-IDR rate limit,
    /// ≤ 1/s, left frame) as soon as the backlog drains below `skipLatency`.
    var dropLatency: Double = 0.45
    /// Lower the encoder bitrate while pairs keep being skipped, raise it back once they stop.
    var adaptiveBitrate = true
    /// Window over which the skip fraction is measured.
    var downWindow: Double = 2
    /// Step down when more than this fraction of the window's pairs was skipped.
    var downSkipFraction = 0.2
    /// Also step down when the backlog averaged over the window's pairs is at least this long. A
    /// link just below the bitrate keeps the backlog near the skip threshold while skipping only
    /// 5-15 % of the pairs (device run: 12 s at 1.2 Mbps, 100-140 ms backlog, 1-4 skips/s), so the
    /// skip fraction alone adapts too slowly. 100 ms is 2/3 of `skipLatency`: a clear link stays
    /// far below it (0-40 ms), and an IDR's brief spike averages out over the window.
    var downBacklog: Double = 0.1
    /// Fewer pairs than this in a window never trigger a step (app paused, link idle).
    var downMinPairs = 4
    var downFactor = 0.8
    /// Step up after this long without a skip (and at most once per period).
    var upQuietPeriod: Double = 5
    var upFactor = 1.1
    /// Floor of the adapted bitrate (the configuration's lower clamp).
    var minBitrate = S3DSConfiguration.bitrateRange.lowerBound
    /// On a congested window with link measurements, step straight to the bitrate that fits:
    /// this fraction of what the 3DS acknowledged over the window (the link was saturated), minus
    /// audio, divided by the encoder's measured overshoot. Device runs: the link carried
    /// ~850-950 kbps and the hardware encoder produced 20-50 % above its target, so ×0.8 steps
    /// from 1.5 Mbps took ~30 s to get there.
    var linkHeadroom = 0.85
}

/// Running totals from `StreamSender.linkSample()`: bytes acknowledged by the 3DS (video and
/// audio), and video bytes and AUs handed to the socket.
struct LinkSample: Sendable, Equatable {
    var delivered: Int
    var videoBytes: Int
    var videoFrames: Int
}

/// Per-pair congestion bookkeeping and bitrate adaptation. Pure (the clock is passed in), so
/// tests drive it with synthetic time; `StreamEngine` keeps it in a `Mutex`.
struct CongestionController: Sendable {
    let policy: CongestionPolicy
    /// The bitrate the app configured (ceiling of the adaptation).
    private(set) var targetBitrate: Int
    /// The bitrate the encoder currently runs at.
    private(set) var bitrate: Int
    private var windowStart: Double?
    private var windowPairs = 0
    private var windowSkips = 0
    private var windowBacklog = 0.0
    private var lastSkip = -Double.infinity
    private var lastChange = -Double.infinity
    /// Set by `setStart`: the next `record` stamps `lastChange`, so a start value is held for an
    /// `upQuietPeriod` before stepping up.
    private var holdStart = false
    private var windowLink: LinkSample?
    /// Encoded video frames per second when no pair is skipped (2 × pairs/s in the alternating
    /// layout) and the audio bitrate sharing the link; for the link-fit step.
    private let framesPerSecond: Double
    private let audioBitrate: Double

    init(policy: CongestionPolicy, bitrate: Int, framesPerSecond: Int = 40, audioBitrate: Int = 96_000) {
        self.policy = policy
        targetBitrate = bitrate
        self.bitrate = bitrate
        self.framesPerSecond = Double(max(1, framesPerSecond))
        self.audioBitrate = Double(max(0, audioBitrate))
    }

    /// Whether a new pair should be skipped given the estimated backlog in seconds
    /// (`StreamSender.backlogSeconds`).
    func shouldSkip(backlog: Double) -> Bool { policy.skipPairs && backlog >= policy.skipLatency }

    /// The app changed the bitrate: it becomes both the ceiling and the current value.
    mutating func setTarget(_ newBitrate: Int) {
        targetBitrate = newBitrate
        bitrate = newBitrate
        resetWindow()
    }

    /// Starts the adaptation at `startBitrate` (e.g. the rate that last worked with this receiver)
    /// instead of the ceiling, clamped to `minBitrate...targetBitrate`. The ceiling is unchanged;
    /// the value is held for an `upQuietPeriod` before any step up.
    mutating func setStart(_ startBitrate: Int) {
        bitrate = min(targetBitrate, max(policy.minBitrate, startBitrate))
        holdStart = true
        resetWindow()
    }

    private mutating func resetWindow() {
        windowStart = nil
        windowPairs = 0
        windowSkips = 0
        windowBacklog = 0
        windowLink = nil
    }

    /// The bitrate that fits the link measured over a congested window, or nil without enough
    /// data. `link` and `windowLink` are running totals at the window's end and start.
    private func linkFit(_ link: LinkSample?, seconds: Double) -> Int? {
        guard let end = link, let begin = windowLink, seconds > 0 else { return nil }
        let frames = end.videoFrames - begin.videoFrames
        let delivered = Double(end.delivered - begin.delivered) * 8 / seconds
        guard frames > 0, delivered > 0 else { return nil }
        // What the encoder really produces at the full frame rate, against what it was asked for.
        let produced = Double(end.videoBytes - begin.videoBytes) * 8 / Double(frames) * framesPerSecond
        let overshoot = min(2.5, max(0.7, produced / Double(max(1, bitrate))))
        return Int((policy.linkHeadroom * delivered - audioBitrate) / overshoot)
    }

    /// Records one due pair at `now` (sent on, or skipped for congestion) with the estimated
    /// backlog when it was due. Returns the new encoder bitrate when it changed.
    /// `link` (optional) is `StreamSender.linkSample()` at this pair: with it, a congested window
    /// steps straight to the bitrate that fits the measured link instead of only ×`downFactor`.
    mutating func record(at now: Double, skipped: Bool, backlog: Double = 0, link: LinkSample? = nil) -> Int? {
        if let start = windowStart, now < start { windowStart = nil }   // clock went back
        let start = windowStart ?? now
        if windowStart == nil { windowLink = link }
        windowStart = start
        windowPairs += 1
        windowBacklog += max(0, backlog)
        if skipped {
            windowSkips += 1
            lastSkip = now
        }
        if holdStart {
            holdStart = false
            lastChange = now
        }
        guard policy.adaptiveBitrate else { return nil }
        var changed: Int?
        if now - start >= policy.downWindow {
            let pairs = Double(windowPairs)
            let congested = windowBacklog / pairs >= policy.downBacklog
            if windowPairs >= policy.downMinPairs,
               Double(windowSkips) > policy.downSkipFraction * pairs || congested {
                // At least one ×downFactor step; further down at once when the link fit says so.
                var lowered = Int(Double(bitrate) * policy.downFactor)
                if let fit = linkFit(link, seconds: now - start) { lowered = min(lowered, fit) }
                lowered = max(policy.minBitrate, lowered)
                if lowered < bitrate {
                    bitrate = lowered
                    lastChange = now
                    changed = lowered
                }
            }
            resetWindow()
            windowStart = now
            windowLink = link
            if congested { lastSkip = now }   // a backed-up window also delays the next step up
        }
        if changed == nil, bitrate < targetBitrate,
           now - lastSkip >= policy.upQuietPeriod, now - lastChange >= policy.upQuietPeriod {
            bitrate = min(targetBitrate, max(bitrate + 1, Int(Double(bitrate) * policy.upFactor)))
            lastChange = now
            changed = bitrate
        }
        return changed
    }
}
