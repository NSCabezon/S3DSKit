/// Frame-rate limiter for callers that submit every display frame (60/90/100/120 Hz…).
///
/// A deadline accumulator: a call is accepted when `now >= nextDeadline - tolerance`, and each
/// accept moves the deadline forward by exactly one interval, so the accepted rate never drifts
/// above the target (30/s from 90 Hz is every 3rd call, from 60 Hz every 2nd, from 100 Hz a 3/4
/// mix). When the caller fell behind by more than an interval (first call, pause, stall) the
/// deadline restarts from `now` instead of letting a backlog through as a burst. Not thread-safe;
/// `StreamEngine` keeps it inside a `Mutex`.
struct FrameThrottle: Sendable {
    let interval: Double
    /// Early-arrival slack: 2 ms or 10% of the interval, whichever is smaller. Absorbs display
    /// timing jitter without ever accepting the call one display frame early.
    let tolerance: Double
    private(set) var nextDeadline: Double = -.infinity

    init(framesPerSecond: Int) {
        interval = 1 / Double(max(1, framesPerSecond))
        tolerance = min(0.002, interval * 0.1)
    }

    /// Whether a frame is due at `now` (seconds, monotonic clock); consumes the slot if so.
    mutating func accept(at now: Double) -> Bool {
        // The deadline can't legitimately be more than one interval ahead of the clock: the
        // caller's clock jumped back (or changed). Restart rather than stall.
        if nextDeadline - now > 2 * interval { nextDeadline = now }
        guard now >= nextDeadline - tolerance else { return false }
        if now - nextDeadline > interval {
            nextDeadline = now + interval   // fell behind / first call / after a pause: no burst
        } else {
            nextDeadline += interval        // on cadence: no drift
        }
        return true
    }
}
