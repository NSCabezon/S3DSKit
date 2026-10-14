import Testing
@testable import S3DSKit

/// `FrameThrottle` driven with synthetic display timestamps (no real clock).
@Suite("Frame throttle")
struct ThrottleTests {
    /// Deterministic jitter in [-1, 1] (LCG), so failures reproduce.
    struct Jitter {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53) * 2 - 1
        }
    }

    /// Call timestamps of a `hz` display loop over `seconds`, starting at `start`.
    static func calls(hz: Double, seconds: Double, start: Double = 1000, jitter: Double = 0) -> [Double] {
        var j = Jitter()
        return (0..<Int(hz * seconds)).map { start + Double($0) / hz + jitter * j.next() }
    }

    /// Indices of accepted calls.
    static func run(_ times: [Double], throttle: inout FrameThrottle) -> [Int] {
        times.indices.filter { throttle.accept(at: times[$0]) }
    }

    static func run(_ times: [Double], fps: Int = 30) -> [Int] {
        var t = FrameThrottle(framesPerSecond: fps)
        return run(times, throttle: &t)
    }

    @Test(arguments: [(90.0, 3), (60.0, 2), (120.0, 4)])
    func exactDivisorRates(hz: Double, every: Int) {
        let accepted = Self.run(Self.calls(hz: hz, seconds: 10))
        let rate = Double(accepted.count) / 10
        #expect(abs(rate - 30) <= 0.5, "\(hz) Hz → \(rate)/s")
        let gaps = Set(zip(accepted.dropFirst(), accepted).map { $0 - $1 })
        #expect(gaps == [every], "\(hz) Hz gaps \(gaps)")
    }

    @Test func hundredHertzMixesThreeAndFour() {
        let accepted = Self.run(Self.calls(hz: 100, seconds: 10))
        let rate = Double(accepted.count) / 10
        #expect(abs(rate - 30) <= 0.5, "100 Hz → \(rate)/s")
        let gaps = Set(zip(accepted.dropFirst(), accepted).map { $0 - $1 })
        #expect(gaps == [3, 4], "gaps \(gaps)")
    }

    @Test(arguments: [90.0, 60.0, 120.0])
    func jitteredDisplay(hz: Double) {
        let accepted = Self.run(Self.calls(hz: hz, seconds: 10, jitter: 0.002))
        let rate = Double(accepted.count) / 10
        #expect(abs(rate - 30) <= 1, "\(hz) Hz ±2 ms → \(rate)/s")
    }

    @Test func pauseThenResumeDoesNotBurst() {
        let before = Self.calls(hz: 90, seconds: 2)
        let after = Self.calls(hz: 90, seconds: 2, start: before.last! + 1)   // 1 s with no calls
        var throttle = FrameThrottle(framesPerSecond: 30)
        let a = Self.run(before, throttle: &throttle)
        let b = Self.run(after, throttle: &throttle)
        #expect(abs(a.count - 60) <= 1 && abs(b.count - 60) <= 1, "\(a.count) / \(b.count)")
        #expect(b.first == 0)                                            // resumes at once
        let gaps = Set(zip(b.dropFirst(), b).map { $0 - $1 })
        #expect(gaps == [3], "no catch-up burst after the pause: gaps \(gaps)")
    }

    @Test func slowCallerGetsEveryCall() {
        // Below the target rate every call is due.
        let times = Self.calls(hz: 20, seconds: 5)
        #expect(Self.run(times).count == times.count)
    }

    @Test func clockJumpingBackDoesNotStall() {
        var throttle = FrameThrottle(framesPerSecond: 30)
        let results = [5000, 10, 10.011, 10.034].map { throttle.accept(at: $0) }
        // A different clock restarts the cadence instead of stalling for 5000 s.
        #expect(results == [true, true, false, true])
    }

    @Test func toleranceIsSmallerOfTwoMillisecondsAndTenPercent() {
        #expect(FrameThrottle(framesPerSecond: 30).tolerance == 0.002)
        #expect(abs(FrameThrottle(framesPerSecond: 120).tolerance - 0.1 / 120) < 1e-12)
    }
}
