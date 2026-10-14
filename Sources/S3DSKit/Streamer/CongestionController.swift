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

    init(policy: CongestionPolicy, bitrate: Int) {
        self.policy = policy
        targetBitrate = bitrate
        self.bitrate = bitrate
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
    }

    /// Records one due pair at `now` (sent on, or skipped for congestion) with the estimated
    /// backlog when it was due. Returns the new encoder bitrate when it changed.
    mutating func record(at now: Double, skipped: Bool, backlog: Double = 0) -> Int? {
        if let start = windowStart, now < start { windowStart = nil }   // clock went back
        let start = windowStart ?? now
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
                let lowered = max(policy.minBitrate, Int(Double(bitrate) * policy.downFactor))
                if lowered < bitrate {
                    bitrate = lowered
                    lastChange = now
                    changed = lowered
                }
            }
            resetWindow()
            windowStart = now
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
