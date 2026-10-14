import Foundation
import Network
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
    var framesDropped = 0
    var keyframesSent = 0
}

/// TCP client to the 3DS receiver (Network.framework).
///
/// All mutable state is confined to `queue`; public methods hop onto it, which makes the class
/// safe to use from any thread.
final class StreamSender: @unchecked Sendable {
    struct Callbacks: Sendable {
        var stateChanged: @Sendable (S3DSConnectionState) -> Void
        /// The encoder must produce an IDR next (connect, KEYFRAME_REQ, congestion recovery).
        var keyframeNeeded: @Sendable () -> Void
    }

    private let queue = DispatchQueue(label: "S3DSKit.sender", qos: .userInteractive)
    private let callbacks: Callbacks
    private let senderName: String
    private let maxInFlight: Int
    private static let log = Logger(subsystem: "S3DSKit", category: "sender")

    // queue-confined
    private var connection: NWConnection?
    private var generation = 0
    private var inFlight = 0
    private var needKeyframe = true
    private var congested = false
    private var connected = false
    private var counters = SenderCounters()

    init(senderName: String, maxInFlightFrames: Int, callbacks: Callbacks) {
        self.senderName = senderName
        self.maxInFlight = max(1, maxInFlightFrames)
        self.callbacks = callbacks
    }

    /// Snapshot of the counters (blocking hop to the sender queue; cheap).
    var counterSnapshot: SenderCounters { queue.sync { counters } }

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

    /// Queues one access unit, applying keyframe gating and backpressure. `eye` is nil for the
    /// stacked layout; in the alternating layout only a left keyframe resynchronizes the stream.
    func sendVideo(_ accessUnit: Data, isKeyframe rawKeyframe: Bool, eye: S3DSEye?) {
        queue.async { [self] in
            guard connected, let conn = connection else { return }
            let isKeyframe = rawKeyframe && eye != .right
            guard accessUnit.count <= S3DSProtocol.maxPayloadLength else {
                Self.log.error("access unit too large (\(accessUnit.count) B), dropped")
                drop(requestKeyframe: true)
                return
            }
            if !isKeyframe {
                if needKeyframe { counters.framesDropped += 1; return }
                if inFlight >= maxInFlight {
                    congested = true
                    drop(requestKeyframe: false)  // IDR is requested once the backlog drains
                    return
                }
            } else if inFlight >= maxInFlight * 2 {
                // Badly backed up: even keyframes would only add latency.
                congested = true
                drop(requestKeyframe: false)
                return
            }
            if isKeyframe { needKeyframe = false }
            let flags = S3DSProtocol.videoFlags(isKeyframe: rawKeyframe, eye: eye)
            let message = S3DSProtocol.message(.videoAU, flags: flags, payload: accessUnit)
            inFlight += 1
            let gen = generation
            conn.send(content: message, completion: .contentProcessed { [weak self] error in
                self?.sendCompleted(error: error, bytes: message.count, keyframe: isKeyframe, generation: gen)
            })
        }
    }

    // MARK: - queue-confined helpers

    private func drop(requestKeyframe: Bool) {
        counters.framesDropped += 1
        needKeyframe = true
        if requestKeyframe { callbacks.keyframeNeeded() }
    }

    private func sendCompleted(error: NWError?, bytes: Int, keyframe: Bool, generation gen: Int) {
        guard gen == generation else { return }
        inFlight = max(0, inFlight - 1)
        if let error {
            fail("send: \(error.localizedDescription)")
            return
        }
        counters.framesSent += 1
        counters.bytesSent += bytes
        if keyframe { counters.keyframesSent += 1 }
        if congested && inFlight < maxInFlight {
            congested = false
            needKeyframe = true
            callbacks.keyframeNeeded()
        }
    }

    private func handle(state: NWConnection.State, generation gen: Int) {
        guard gen == generation else { return }
        switch state {
        case .ready:
            connected = true
            inFlight = 0
            congested = false
            needKeyframe = true
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
        inFlight = 0
        congested = false
        needKeyframe = true
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
            callbacks.keyframeNeeded()
        }
    }
}
