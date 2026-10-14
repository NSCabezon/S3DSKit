import CoreVideo
import Foundation
import QuartzCore
import Testing
@testable import S3DSKit

/// `CongestionController` on a synthetic clock.
@Suite("Congestion controller")
struct CongestionControllerTests {
    static let policy = CongestionPolicy()

    @Test func skipThresholdIsTheBacklog() {
        let c = CongestionController(policy: Self.policy, bitrate: 1_200_000)
        #expect(!c.shouldSkip(backlog: 0))
        #expect(!c.shouldSkip(backlog: 0.149))   // an ordinary IDR draining: no skip
        #expect(c.shouldSkip(backlog: 0.15))
        #expect(Self.policy.dropLatency >= 2.5 * Self.policy.skipLatency)   // drop is a last resort
    }

    /// Pairs at 20/s with a given skip pattern from `start` for `seconds`; returns bitrate changes.
    static func run(_ c: inout CongestionController, from start: Double, seconds: Double,
                    skipEvery n: Int?) -> [Int] {
        var changes: [Int] = []
        for i in 0..<Int(seconds * 20) {
            let skipped = n.map { i % $0 == 0 } ?? false
            if let b = c.record(at: start + Double(i) / 20, skipped: skipped) { changes.append(b) }
        }
        return changes
    }

    @Test func stepsDownUnderSustainedCongestionThenBackUp() {
        var c = CongestionController(policy: Self.policy, bitrate: 1_200_000)
        // Half the pairs skipped for 10 s: a step per 2 s window, ×0.8, down to the 0.5 Mbps floor.
        let down = Self.run(&c, from: 100, seconds: 10.01, skipEvery: 2)
        #expect(down == [960_000, 768_000, 614_400, 500_000])
        #expect(c.bitrate == 500_000)
        // Clear link: nothing for 5 s, then +10 % every 5 s up to the configured bitrate.
        let up = Self.run(&c, from: 110.01, seconds: 60, skipEvery: nil)
        #expect(up.first == 550_000)
        #expect(up.last == 1_200_000)
        #expect(c.bitrate == 1_200_000 && c.targetBitrate == 1_200_000)
        #expect(zip(up.dropFirst(), up).allSatisfy { $0 > $1 })
    }

    @Test func occasionalSkipsDoNotLowerTheBitrate() {
        var c = CongestionController(policy: Self.policy, bitrate: 1_200_000)
        // 1 pair in 10 skipped (10 %, under the 20 % threshold).
        #expect(Self.run(&c, from: 0, seconds: 20, skipEvery: 10).isEmpty)
        #expect(c.bitrate == 1_200_000)
    }

    @Test func skipsHoldTheBitrateDown() {
        var c = CongestionController(policy: Self.policy, bitrate: 1_000_000)
        _ = Self.run(&c, from: 0, seconds: 2.06, skipEvery: 1)
        #expect(c.bitrate == 800_000)
        // A skip every 3 s keeps the raise from ever happening (needs 5 quiet seconds).
        var changes: [Int] = []
        for i in 0..<400 {
            let t = 2.06 + Double(i) / 20
            if let b = c.record(at: t, skipped: i % 60 == 0) { changes.append(b) }
        }
        #expect(changes.isEmpty && c.bitrate == 800_000)
    }

    @Test func appBitrateChangeResetsTheAdaptation() {
        var c = CongestionController(policy: Self.policy, bitrate: 1_200_000)
        _ = Self.run(&c, from: 0, seconds: 4.01, skipEvery: 1)
        #expect(c.bitrate < 1_200_000)
        c.setTarget(2_000_000)
        #expect(c.bitrate == 2_000_000 && c.targetBitrate == 2_000_000)
    }

    /// Pairs at 20/s with a constant backlog and a skip every `n`; returns bitrate changes.
    static func run(_ c: inout CongestionController, from start: Double, seconds: Double,
                    backlog: Double, skipEvery n: Int?) -> [Int] {
        var changes: [Int] = []
        for i in 0..<Int(seconds * 20) {
            let skipped = n.map { i % $0 == 0 } ?? false
            if let b = c.record(at: start + Double(i) / 20, skipped: skipped, backlog: backlog) {
                changes.append(b)
            }
        }
        return changes
    }

    /// The device case: a link just under the bitrate, 10 % of pairs skipped (under the 20 % skip
    /// threshold) but the backlog sitting at ~120 ms. It must step down every window, not hold.
    @Test func sustainedBacklogStepsDownWithFewSkips() {
        var c = CongestionController(policy: Self.policy, bitrate: 1_200_000)
        let down = Self.run(&c, from: 0, seconds: 6.06, backlog: 0.12, skipEvery: 10)
        #expect(down == [960_000, 768_000, 614_400])
    }

    @Test func clearLinkBacklogDoesNotStepDown() {
        var c = CongestionController(policy: Self.policy, bitrate: 1_200_000)
        // 0-40 ms of backlog (the device's healthy range) never lowers the bitrate.
        #expect(Self.run(&c, from: 0, seconds: 20, backlog: 0.04, skipEvery: nil).isEmpty)
        #expect(c.bitrate == 1_200_000)
    }

    @Test func startBitrateIsHeldThenRaised() {
        var c = CongestionController(policy: Self.policy, bitrate: 1_500_000)
        c.setStart(740_000)
        #expect(c.bitrate == 740_000 && c.targetBitrate == 1_500_000)
        // Held for the quiet period on a clear link, then +10 % steps toward the ceiling.
        let up = Self.run(&c, from: 50, seconds: 5.5, backlog: 0, skipEvery: nil)
        #expect(up == [814_000])
        c.setStart(100_000)
        #expect(c.bitrate == Self.policy.minBitrate)   // clamped to the floor
        c.setStart(9_000_000)
        #expect(c.bitrate == 1_500_000)                // and to the ceiling
    }

    @Test func adaptationCanBeTurnedOff() {
        var policy = Self.policy
        policy.adaptiveBitrate = false
        var c = CongestionController(policy: policy, bitrate: 1_200_000)
        #expect(Self.run(&c, from: 0, seconds: 10, skipEvery: 1).isEmpty)
        #expect(c.shouldSkip(backlog: 1))   // skipping itself stays on
    }

    @Test func configurationWiresTheFlag() {
        #expect(S3DSConfiguration().adaptiveBitrate)
        #expect(!S3DSConfiguration(adaptiveBitrate: false).adaptiveBitrate)
    }
}

/// Engine → loopback TCP → a fake 3DS that reads slowly (a congested Wi-Fi link), then fast.
@Suite("Congestion end-to-end", .serialized)
@MainActor
struct CongestionTests {
    /// What the feeding loop saw.
    struct Feed {
        var leftsAccepted = 0
        var rightsAccepted = 0
        var orphanRightsRejected = 0
        var maxBacklog = 0.0
        var maxSocketBytes = 0
        var minBitrate = Int.max
    }

    static let buffers: [CVPixelBuffer] = (0..<12).map { try! IntegrationTests.patternBuffer(seed: $0) }

    /// Submits like a 90 Hz app using pixel buffers: the left frame throttled, the right one
    /// submitted *whatever the left's result was* (the engine must reject a right without its left).
    func pump(_ engine: StreamEngine, seconds: Double, into f: inout Feed, frame: inout Int) async throws {
        let start = CACurrentMediaTime()
        var leftAccepted = false
        while CACurrentMediaTime() - start < seconds {
            let left = Self.buffers[frame % Self.buffers.count]
            let right = Self.buffers[(frame + 5) % Self.buffers.count]
            leftAccepted = engine.submit(pixelBuffer: left, eye: .left, throttled: true)
            if leftAccepted { f.leftsAccepted += 1 }
            let rightAccepted = engine.submit(pixelBuffer: right, eye: .right, throttled: true)
            if rightAccepted { f.rightsAccepted += 1 }
            if !leftAccepted, !rightAccepted { f.orphanRightsRejected += 1 }
            #expect(rightAccepted == leftAccepted)
            frame += 1
            f.maxBacklog = max(f.maxBacklog, engine.videoBacklog)
            f.maxSocketBytes = max(f.maxSocketBytes, engine.socketBacklog)
            f.minBitrate = min(f.minBitrate, engine.videoBitrate)
            try await Task.sleep(for: .milliseconds(11))
        }
    }

    func connect(_ engine: StreamEngine, _ receiver: TestReceiver) async throws {
        engine.connect(host: "127.0.0.1", port: receiver.port)
        let up = await waitUntil { engine.isConnected }
        try #require(up, "never connected")
        try await Task.sleep(for: .milliseconds(100))   // HELLO + the receiver's KEYFRAME_REQ
    }

    func finish(_ engine: StreamEngine, _ receiver: TestReceiver) async throws -> [S3DSProtocol.Header] {
        receiver.readBytesPerSecond = 0
        try await Task.sleep(for: .milliseconds(500))
        engine.disconnect()
        _ = await waitUntil { receiver.isFinished }
        return try parseMessages(receiver.received).map(\.header).filter { $0.messageType == .videoAU }
    }

    /// Every right AU directly follows a left one; returns the count of lefts without a right.
    func checkPairs(_ aus: [S3DSProtocol.Header]) -> Int {
        var loneLefts = 0
        for (i, au) in aus.enumerated() {
            let isRight = au.flags & S3DSProtocol.rightEyeFlag != 0
            if isRight {
                #expect(i > 0 && aus[i - 1].flags & S3DSProtocol.rightEyeFlag == 0, "right AU \(i) without its left")
                #expect(au.flags & S3DSProtocol.keyframeFlag == 0, "IDR on right AU \(i)")
            } else if i + 1 < aus.count, aus[i + 1].flags & S3DSProtocol.rightEyeFlag == 0 {
                loneLefts += 1
            }
        }
        return loneLefts
    }

    func checkKeyframeSpacing(_ engine: StreamEngine) {
        let times = engine.encoderKeyframeTimes
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        print("S3DSKIT_IDR_GAPS \(gaps.map { String(format: "%.2f", $0) })")
        #expect(gaps.allSatisfy { $0 >= 0.95 }, "IDRs closer than 1 s: \(gaps)")
    }

    /// (a) congested pairs are skipped before the encoder ever sees them, (b) no right frame
    /// without its left, (c) no keyframe wait: nothing is dropped after encoding and video flows
    /// at once when the link clears, (d) IDRs ≥ 1 s apart, (e) the bitrate steps down under
    /// congestion and back up after.
    @Test func congestedLinkSkipsPairsBeforeEncoding() async throws {
        let receiver = try TestReceiver(readBytesPerSecond: 40_000, receiveBuffer: 4096)   // ~320 kbps
        defer { receiver.stop() }
        var config = S3DSConfiguration(senderName: "S3DSKitTests", audioEnabled: false)
        config.congestion.downWindow = 1
        config.congestion.upQuietPeriod = 1
        let engine = StreamEngine(configuration: config, device: nil)
        try await connect(engine, receiver)

        var feed = Feed()
        var frame = 0
        try await pump(engine, seconds: 5, into: &feed, frame: &frame)
        let congested = engine.counters
        let skippedWhileCongested = engine.congestionPairsSkipped
        let bitrateWhileCongested = engine.videoBitrate

        receiver.readBytesPerSecond = 0   // the link clears
        try await pump(engine, seconds: 1, into: &feed, frame: &frame)
        let flowing = engine.counters
        let skippedAtClear = engine.congestionPairsSkipped
        try await pump(engine, seconds: 3, into: &feed, frame: &frame)
        let end = engine.counters
        let finalBitrate = engine.videoBitrate
        let encoded = engine.encoderCounters
        let aus = try await finish(engine, receiver)

        print("""
            S3DSKIT_CONGESTION lefts=\(feed.leftsAccepted) rights=\(feed.rightsAccepted) \
            skipped=\(engine.congestionPairsSkipped) (congested \(skippedWhileCongested)) \
            encoderSubmitted=\(encoded.submitted) sentCongested=\(congested.framesSent) \
            sentEnd=\(end.framesSent) dropped=\(end.framesDropped) maxBacklog=\(feed.maxBacklog) maxSocket=\(feed.maxSocketBytes) \
            bitrate congested=\(bitrateWhileCongested) min=\(feed.minBitrate) final=\(finalBitrate) aus=\(aus.count)
            """)
        // (a) skipped pairs never reach the encoder: it saw exactly the accepted frames.
        #expect(skippedWhileCongested >= 20, "the slow link should have forced skips")
        #expect(feed.rightsAccepted == feed.leftsAccepted)
        #expect(encoded.submitted == feed.leftsAccepted + feed.rightsAccepted)
        // The backlog (what audio waits behind) stays near the skip threshold, far from the drop.
        #expect(feed.maxBacklog < config.congestion.dropLatency)
        // (b) pairs stay whole on the wire.
        #expect(checkPairs(aus) <= 1)   // the tail may be cut at disconnect
        // (c) no post-encode drops, so no keyframe wait; video flows as soon as the link clears.
        #expect(end.framesDropped == 0 && end.awaitingKeyframeDropped == 0 && end.backpressureDropped == 0)
        #expect(flowing.framesSent - congested.framesSent >= 25, "1 s after clearing: \(flowing.framesSent - congested.framesSent) AUs")
        #expect(end.framesSent - flowing.framesSent >= 90, "last 3 s: \(end.framesSent - flowing.framesSent) AUs")
        #expect(engine.congestionPairsSkipped - skippedAtClear <= 2)
        // (d)
        checkKeyframeSpacing(engine)
        // (e) down while congested, up again after.
        #expect(bitrateWhileCongested < config.bitrate)
        #expect(feed.minBitrate >= config.congestion.minBitrate)
        #expect(finalBitrate > feed.minBitrate)
    }

    /// The last-resort path alone (pair skipping off): encoded frames are dropped on a badly
    /// backed-up link, and the stream resumes with an IDR requested once the backlog drains —
    /// long before the scheduled one (20 s here) — with forced IDRs still ≥ 1 s apart.
    @Test func lastResortDropRecoversWithoutTheScheduledKeyframe() async throws {
        let receiver = try TestReceiver(readBytesPerSecond: 40_000, receiveBuffer: 4096)
        defer { receiver.stop() }
        var config = S3DSConfiguration(keyframeInterval: 400, senderName: "S3DSKitTests",
                                       maxInFlightFrames: 1000, audioEnabled: false, adaptiveBitrate: false)
        config.congestion.skipPairs = false
        let engine = StreamEngine(configuration: config, device: nil)
        try await connect(engine, receiver)
        let atStart = engine.counters

        var feed = Feed()
        var frame = 0
        try await pump(engine, seconds: 4, into: &feed, frame: &frame)
        let congested = engine.counters

        receiver.readBytesPerSecond = 0
        try await pump(engine, seconds: 1.5, into: &feed, frame: &frame)
        let recovered = engine.counters
        try await pump(engine, seconds: 1.5, into: &feed, frame: &frame)
        let end = engine.counters
        let aus = try await finish(engine, receiver)

        print("""
            S3DSKIT_LAST_RESORT backpressure=\(end.backpressureDropped) awaiting=\(end.awaitingKeyframeDropped) \
            recoveryIDRs=\(end.recoveryKeyframesRequested) (start \(atStart.recoveryKeyframesRequested)) \
            keys=\(end.keyframesSent) sent congested=\(congested.framesSent) end=\(end.framesSent) aus=\(aus.count)
            """)
        #expect(engine.congestionPairsSkipped == 0)
        #expect(congested.backpressureDropped > 0, "the slow link should have forced last-resort drops")
        #expect(end.recoveryKeyframesRequested > atStart.recoveryKeyframesRequested)
        // Flowing again within the 1.5 s after the link cleared, and nothing gated in the last 1.5 s.
        #expect(end.awaitingKeyframeDropped == recovered.awaitingKeyframeDropped)
        #expect(end.backpressureDropped == recovered.backpressureDropped)
        #expect(end.framesSent - recovered.framesSent >= 45, "last 1.5 s: \(end.framesSent - recovered.framesSent) AUs")
        #expect(checkPairs(aus) <= 1)
        checkKeyframeSpacing(engine)
    }
}
