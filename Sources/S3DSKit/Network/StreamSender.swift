import Foundation
import Network
import QuartzCore
import Synchronization
import os

/// Connection state of the TCP link to the 3DS.
public enum S3DSConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed(String)

    /// Short human-readable description.
    public var label: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .failed(let reason): "Failed: \(reason)"
        }
    }
}

/// Monotonic sender counters.
struct SenderCounters: Sendable {
    var framesSent = 0
    var bytesSent = 0
    /// All dropped video frames (sum of the reasons below).
    var framesDropped = 0
    /// Dropped after encoding because the network was badly backed up (last resort: normally
    /// whole pairs are skipped before encoding instead, see `CongestionPolicy`).
    var backpressureDropped = 0
    /// Dropped while waiting for the next keyframe after an earlier drop (can't decode without it).
    var awaitingKeyframeDropped = 0
    /// Dropped because the AU exceeded the 256 KiB payload limit.
    var oversizeDropped = 0
    /// Video AUs currently handed to the network and not yet sent.
    var inFlight = 0
    var keyframesSent = 0
    var audioPacketsSent = 0
    /// IDRs the sender asked the encoder for after a backpressure drop or a KEYFRAME_REQ (held
    /// back until the backlog drained below the skip threshold).
    var recoveryKeyframesRequested = 0
}

/// TCP client to the 3DS receiver (Network.framework).
///
/// All mutable state is confined to `queue`; public methods hop onto it, which makes the class
/// safe to use from any thread. The backlog (see `backlogSeconds`) is mirrored into atomics so the
/// engine can read it on the capture path without a queue hop.
final class StreamSender: @unchecked Sendable {
    struct Callbacks: Sendable {
        var stateChanged: @Sendable (S3DSConnectionState) -> Void
        /// The encoder should produce an IDR soon (connect, KEYFRAME_REQ, oversize drop, recovery
        /// after a backpressure drop); the encoder rate-limits forced IDRs. Never called while the
        /// link is congested (an IDR then only adds a big frame to a full pipe: IDR storms); such
        /// requests wait until the backlog drains below the skip threshold.
        var keyframeNeeded: @Sendable () -> Void
    }

    private let queue = DispatchQueue(label: "S3DSKit.sender", qos: .userInteractive)
    private let callbacks: Callbacks
    private let senderName: String
    private let maxInFlight: Int
    private let policy: CongestionPolicy
    private static let log = Logger(subsystem: "S3DSKit", category: "sender")
    /// `CACurrentMediaTime()` bit pattern of the oldest unsent video AU's hand-off; 0 = none.
    private let oldestQueuedVideo = Atomic<UInt64>(0)
    /// Bytes of video handed to Network.framework and not yet in the socket.
    private let queuedVideoBytes = Atomic<Int>(0)
    /// Bytes in the TCP send buffer not yet acknowledged by the 3DS (video and audio).
    private let socketBacklogBytes = Atomic<Int>(0)
    /// Bits per second assumed to drain the backlog: the stream's own rate (video + audio). When
    /// the link is the bottleneck it drains slower, so the estimate errs towards sending.
    private let drainRate = Atomic<Int>(1_200_000)
    /// How often the socket backlog is sampled while connected.
    static let backlogSampleInterval = DispatchTimeInterval.milliseconds(10)

    // queue-confined
    private var connection: NWConnection?
    private var generation = 0
    /// Hand-off times and sizes of the unsent video AUs, oldest first (sends complete in order).
    private var queuedVideo: [(time: Double, bytes: Int)] = []
    private var queuedBytes = 0
    private var inFlight: Int { queuedVideo.count }
    private var sampler: (any DispatchSourceTimer)?
    private var needKeyframe = true
    /// A keyframe is wanted but was held back while the link was congested.
    private var recoveryPending = false
    private var connected = false
    private var counters = SenderCounters()

    /// - Parameter maxInFlightFrames: hard cap of unsent video AUs (last resort, with
    ///   `policy.dropLatency`).
    init(senderName: String, maxInFlightFrames: Int, policy: CongestionPolicy = CongestionPolicy(),
         callbacks: Callbacks) {
        self.senderName = senderName
        self.maxInFlight = max(1, maxInFlightFrames)
        self.policy = policy
        self.callbacks = callbacks
        queuedVideo.reserveCapacity(64)
    }

    /// Snapshot of the counters (blocking hop to the sender queue; cheap).
    var counterSnapshot: SenderCounters {
        queue.sync { var c = counters; c.inFlight = inFlight; return c }
    }

    /// Seconds since the oldest video AU still unsent was handed to the network (0 when none).
    /// Lock-free; safe from any thread.
    func queuedVideoAge(now: Double = CACurrentMediaTime()) -> Double {
        let bits = oldestQueuedVideo.load(ordering: .relaxed)
        guard bits != 0 else { return 0 }
        return max(0, now - Double(bitPattern: bits))
    }

    /// Estimated seconds of data queued ahead of a new AU: the larger of the oldest unsent video
    /// AU's age (a stalled link) and the bytes waiting (Network.framework queue + unacknowledged
    /// TCP send buffer) at the stream's own rate. The send buffer matters: Network.framework
    /// completes a send once the data is in the socket, which can hold a second of video on a
    /// slow link. Lock-free; safe from any thread.
    func backlogSeconds(now: Double = CACurrentMediaTime()) -> Double {
        let bytes = queuedVideoBytes.load(ordering: .relaxed) + socketBacklogBytes.load(ordering: .relaxed)
        let rate = Double(max(1, drainRate.load(ordering: .relaxed)))
        return max(queuedVideoAge(now: now), Double(bytes) * 8 / rate)
    }

    /// Unacknowledged bytes in the TCP send buffer at the last sample.
    var socketBacklog: Int { socketBacklogBytes.load(ordering: .relaxed) }

    /// Bits per second the stream is meant to use (video + audio); scales `backlogSeconds`.
    func setDrainRate(_ bitsPerSecond: Int) {
        drainRate.store(max(1, bitsPerSecond), ordering: .relaxed)
    }

    /// Opens a new connection, replacing any existing one.
    func connect(host: String, port: UInt16) {
        queue.async { [self] in
            tearDown()
            guard let nwPort = NWEndpoint.Port(rawValue: port), !host.isEmpty else {
                callbacks.stateChanged(.failed("invalid host/port"))
                return
            }
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            tcp.connectionTimeout = 5
            let params = NWParameters(tls: nil, tcp: tcp)
            let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
            generation += 1
            let gen = generation
            connection = conn
            conn.stateUpdateHandler = { [weak self] state in
                self?.handle(state: state, generation: gen)
            }
            callbacks.stateChanged(.connecting)
            conn.start(queue: queue)
        }
    }

    /// Closes the connection.
    func disconnect() {
        queue.async { [self] in
            let had = connection != nil
            tearDown()
            if had { callbacks.stateChanged(.disconnected) }
        }
    }

    /// Whether the link is up (snapshot, may be stale by the time you act on it).
    var isConnected: Bool { queue.sync { connected } }

    /// Queues one access unit, applying keyframe gating and the last-resort backpressure drop.
    /// `eye` is nil for the stacked layout; in the alternating layout only a left keyframe
    /// resynchronizes the stream, and a right AU is never dropped for backpressure once its left
    /// went out (pairs stay whole on the wire).
    func sendVideo(_ accessUnit: Data, isKeyframe rawKeyframe: Bool, eye: S3DSEye?) {
        queue.async { [self] in
            guard connected, let conn = connection else { return }
            let isKeyframe = rawKeyframe && eye != .right
            guard accessUnit.count <= S3DSProtocol.maxPayloadLength else {
                Self.log.error("access unit too large (\(accessUnit.count) B), dropped")
                counters.oversizeDropped += 1
                drop()
                callbacks.keyframeNeeded()
                return
            }
            if !isKeyframe, needKeyframe {
                counters.framesDropped += 1
                counters.awaitingKeyframeDropped += 1
                return
            }
            if eye != .right {
                // Normally the engine skips whole pairs before encoding long before this; only
                // pairs already in the pipeline (or a huge IDR) get here. Keyframes get twice the
                // budget: dropping one costs another.
                let scale = isKeyframe ? 2.0 : 1.0
                if backlogSeconds() >= policy.dropLatency * scale || Double(inFlight) >= Double(maxInFlight) * scale {
                    counters.backpressureDropped += 1
                    drop()
                    // Ask for an IDR once the backlog drains (not now: IDR storm).
                    recoveryPending = true
                    return
                }
            }
            if isKeyframe {
                needKeyframe = false
                recoveryPending = false
            }
            let flags = S3DSProtocol.videoFlags(isKeyframe: rawKeyframe, eye: eye)
            let message = S3DSProtocol.message(.videoAU, flags: flags, payload: accessUnit)
            enqueuedVideo(at: CACurrentMediaTime(), bytes: message.count)
            let gen = generation
            conn.send(content: message, completion: .contentProcessed { [weak self] error in
                self?.sendCompleted(error: error, bytes: message.count, keyframe: isKeyframe, generation: gen)
            })
        }
    }

    /// Queues one Opus packet. Audio bypasses video backpressure (it is tiny) and is dropped
    /// only when there is no live connection. Sends are asynchronous, so audio never waits on
    /// video or vice versa (both share the TCP stream in submission order).
    func sendAudio(_ opusPacket: Data, timestampMicros: UInt64) {
        queue.async { [self] in
            guard connected, let conn = connection else { return }
            guard 8 + opusPacket.count <= S3DSProtocol.maxAudioPayloadLength else {
                Self.log.error("Opus packet too large (\(opusPacket.count) B), dropped")
                return
            }
            let message = S3DSProtocol.audio(timestampMicros: timestampMicros, opusPacket: opusPacket)
            let gen = generation
            conn.send(content: message, completion: .contentProcessed { [weak self] error in
                guard let self, gen == self.generation else { return }
                if let error {
                    self.fail("send: \(error.localizedDescription)")
                    return
                }
                self.counters.audioPacketsSent += 1
                self.counters.bytesSent += message.count
            })
        }
    }

    // MARK: - queue-confined helpers

    private func drop() {
        counters.framesDropped += 1
        needKeyframe = true
    }

    private func enqueuedVideo(at time: Double, bytes: Int) {
        queuedVideo.append((time, bytes))
        queuedBytes += bytes
        publishQueue()
    }

    private func publishQueue() {
        oldestQueuedVideo.store(queuedVideo.first.map { $0.time.bitPattern } ?? 0, ordering: .relaxed)
        queuedVideoBytes.store(queuedBytes, ordering: .relaxed)
    }

    /// Samples the TCP send buffer (every `backlogSampleInterval` while connected).
    private func sampleSocketBacklog() {
        guard let conn = connection,
              let tcp = conn.metadata(definition: NWProtocolTCP.definition) as? NWProtocolTCP.Metadata
        else { return }
        socketBacklogBytes.store(Int(tcp.availableSendBuffer), ordering: .relaxed)
        requestRecoveryKeyframeIfDrained()
    }

    private func startSampler() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.backlogSampleInterval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.sampleSocketBacklog() }
        timer.resume()
        sampler = timer
    }

    /// Requests the held-back keyframe once the backlog is below the skip threshold.
    private func requestRecoveryKeyframeIfDrained() {
        guard recoveryPending, backlogSeconds() < policy.skipLatency else { return }
        recoveryPending = false
        counters.recoveryKeyframesRequested += 1
        callbacks.keyframeNeeded()
    }

    private func sendCompleted(error: NWError?, bytes: Int, keyframe: Bool, generation gen: Int) {
        guard gen == generation else { return }
        if !queuedVideo.isEmpty {
            queuedBytes -= queuedVideo.removeFirst().bytes
            publishQueue()
        }
        if let error {
            fail("send: \(error.localizedDescription)")
            return
        }
        counters.framesSent += 1
        counters.bytesSent += bytes
        if keyframe { counters.keyframesSent += 1 }
        requestRecoveryKeyframeIfDrained()
    }

    private func handle(state: NWConnection.State, generation gen: Int) {
        guard gen == generation else { return }
        switch state {
        case .ready:
            connected = true
            needKeyframe = true
            startSampler()
            connection?.send(content: S3DSProtocol.hello(name: senderName), completion: .idempotent)
            callbacks.keyframeNeeded()
            callbacks.stateChanged(.connected)
            receiveHeader()
        case .waiting(let error):
            // No automatic retry loop: report and let the user reconnect.
            fail(error.localizedDescription)
        case .failed(let error):
            fail(error.localizedDescription)
        case .cancelled, .setup, .preparing:
            break
        @unknown default:
            break
        }
    }

    private func fail(_ reason: String) {
        Self.log.error("connection failed: \(reason)")
        tearDown()
        callbacks.stateChanged(.failed(reason))
    }

    private func tearDown() {
        generation += 1
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        connected = false
        sampler?.cancel()
        sampler = nil
        queuedVideo.removeAll(keepingCapacity: true)
        queuedBytes = 0
        publishQueue()
        socketBacklogBytes.store(0, ordering: .relaxed)
        needKeyframe = true
        recoveryPending = false
    }

    private func receiveHeader() {
        guard let conn = connection else { return }
        let gen = generation
        conn.receive(minimumIncompleteLength: S3DSProtocol.headerLength,
                     maximumLength: S3DSProtocol.headerLength) { [weak self] data, _, isComplete, error in
            guard let self, gen == self.generation else { return }
            if let error { self.fail("receive: \(error.localizedDescription)"); return }
            if let data, data.count == S3DSProtocol.headerLength {
                do {
                    let header = try S3DSProtocol.decodeHeader(data)
                    self.receivePayload(header)
                } catch {
                    self.fail("bad header from receiver")
                }
                return
            }
            if isComplete { self.fail("receiver closed the connection"); return }
            self.receiveHeader()
        }
    }

    private func receivePayload(_ header: S3DSProtocol.Header) {
        guard header.length > 0 else { dispatch(header); receiveHeader(); return }
        guard let conn = connection else { return }
        let gen = generation
        let len = Int(header.length)
        conn.receive(minimumIncompleteLength: len, maximumLength: len) { [weak self] _, _, isComplete, error in
            guard let self, gen == self.generation else { return }
            if let error { self.fail("receive: \(error.localizedDescription)"); return }
            self.dispatch(header)
            if isComplete { self.fail("receiver closed the connection"); return }
            self.receiveHeader()
        }
    }

    private func dispatch(_ header: S3DSProtocol.Header) {
        if header.messageType == .keyframeRequest {
            needKeyframe = true
            // While congested, wait for the backlog to drain (the request is not lost).
            recoveryPending = true
            requestRecoveryKeyframeIfDrained()
        }
    }
}
