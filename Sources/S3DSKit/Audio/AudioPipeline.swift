import AVFAudio
import Foundation
import QuartzCore
import os

/// App audio → ring → (resample/upmix to 48 kHz stereo) → Opus 20 ms packets with timestamps.
///
/// Producers call `ring.write` (real-time safe). Everything else runs on `queue`, drained by a
/// 10 ms timer while started; all mutable state is confined to that queue.
final class AudioPipeline: @unchecked Sendable {
    /// `(opusPacket, timestampMicros)` on the CACurrentMediaTime clock (same as video PTS).
    typealias Output = @Sendable (Data, UInt64) -> Void

    let ring = AudioRing()
    private let queue = DispatchQueue(label: "S3DSKit.audio", qos: .userInitiated)
    private let output: Output
    private let bitrate: Int
    private static let log = Logger(subsystem: "S3DSKit", category: "audio")
    private static let chunkFrames = 4_800

    // queue-confined
    private var timer: (any DispatchSourceTimer)?
    private var encoder: OpusPacketEncoder?
    private var resampler: AVAudioConverter?
    private var resamplerInput: AVAudioPCMBuffer?
    private var generation = -1
    private var inputRate: Double = 48_000
    private var fifo: [Float] = []            // interleaved stereo at 48 kHz
    private var fifoStartTime: Double?        // capture time of fifo[0]
    private var lastTimestamp: UInt64 = 0
    private let scratch: UnsafeMutablePointer<Float>
    private var encoderFailed = false

    init(bitrate: Int, output: @escaping Output) {
        self.bitrate = bitrate
        self.output = output
        scratch = .allocate(capacity: Self.chunkFrames * 2)
    }

    deinit {
        timer?.cancel()
        scratch.deallocate()
    }

    /// Starts draining (call on connect).
    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            ring.clear()
            resetStream()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.drain() }
            t.resume()
            timer = t
        }
    }

    /// Stops draining and drops buffered audio (call on disconnect).
    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            ring.clear()
            resetStream()
        }
    }

    /// Drains synchronously (tests).
    func drainNow() {
        queue.sync { drain() }
    }

    // MARK: - queue-confined

    private func resetStream() {
        fifo.removeAll(keepingCapacity: true)
        fifoStartTime = nil
        encoder = nil           // a fresh Opus stream after reconnect
        resampler?.reset()
    }

    private func drain() {
        while true {
            let r = ring.read(into: scratch, maxFrames: Self.chunkFrames)
            guard r.frames > 0 else { break }
            if r.generation != generation { configureInput(rate: r.sampleRate, generation: r.generation) }
            // Capture time of the chunk's first frame: frames end at the last write.
            let chunkStart = r.lastWriteEnd - Double(r.frames + r.remaining) / r.sampleRate
            append(frames: r.frames, chunkStart: chunkStart)
        }
        encodeAvailable()
    }

    private func configureInput(rate: Double, generation: Int) {
        self.generation = generation
        inputRate = rate
        fifo.removeAll(keepingCapacity: true)
        fifoStartTime = nil
        if rate == OpusPacketEncoder.sampleRate {
            resampler = nil
            resamplerInput = nil
        } else if let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                               channels: 2, interleaved: false) {
            resampler = AVAudioConverter(from: inFormat, to: OpusPacketEncoder.pcmFormat)
            resamplerInput = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(Self.chunkFrames))
            if resampler == nil { Self.log.error("no resampler from \(rate) Hz") }
        }
    }

    private func append(frames: Int, chunkStart: Double) {
        let fifoFrames = Double(fifo.count / 2) / OpusPacketEncoder.sampleRate
        if let start = fifoStartTime {
            // Keep a continuous sample clock unless the producer clearly jumped (gap / stall).
            if abs(start + fifoFrames - chunkStart) > 0.1 { fifoStartTime = chunkStart - fifoFrames }
        } else {
            fifoStartTime = chunkStart - fifoFrames
        }

        guard let resampler, let resamplerInput else {
            fifo.append(contentsOf: UnsafeBufferPointer(start: scratch, count: frames * 2))
            return
        }
        let l = resamplerInput.floatChannelData![0], r = resamplerInput.floatChannelData![1]
        for i in 0..<frames {
            l[i] = scratch[2 * i]
            r[i] = scratch[2 * i + 1]
        }
        resamplerInput.frameLength = AVAudioFrameCount(frames)
        let capacity = AVAudioFrameCount(Double(frames) * OpusPacketEncoder.sampleRate / inputRate) + 256
        guard let out = AVAudioPCMBuffer(pcmFormat: OpusPacketEncoder.pcmFormat, frameCapacity: capacity) else { return }
        let feed = OneShotFeed(resamplerInput)
        var error: NSError?
        let status = resampler.convert(to: out, error: &error) { _, s in feed.next(s) }
        guard status != .error else {
            Self.log.error("resampler failed: \(error?.localizedDescription ?? "?")")
            return
        }
        let ol = out.floatChannelData![0], or = out.floatChannelData![1]
        fifo.reserveCapacity(fifo.count + Int(out.frameLength) * 2)
        for i in 0..<Int(out.frameLength) {
            fifo.append(ol[i])
            fifo.append(or[i])
        }
    }

    private func encodeAvailable() {
        let packetSamples = OpusPacketEncoder.framesPerPacket * 2
        guard fifo.count >= packetSamples, var start = fifoStartTime else { return }
        if encoder == nil, !encoderFailed {
            do { encoder = try OpusPacketEncoder(bitrate: bitrate) } catch {
                encoderFailed = true
                Self.log.error("\(error)")
            }
        }
        guard let encoder else { fifo.removeAll(); return }
        var consumed = 0
        fifo.withUnsafeBufferPointer { buf in
            while buf.count - consumed >= packetSamples {
                let packets = encoder.encode(interleaved: buf.baseAddress! + consumed, timestamp: start)
                consumed += packetSamples
                start += Double(OpusPacketEncoder.framesPerPacket) / OpusPacketEncoder.sampleRate
                for (packet, ts) in packets {
                    var micros = UInt64(max(0, ts) * 1_000_000)
                    if micros <= lastTimestamp { micros = lastTimestamp + 1 }   // strictly monotonic
                    lastTimestamp = micros
                    output(packet, micros)
                }
            }
        }
        fifo.removeFirst(consumed)
        fifoStartTime = start
    }

    private final class OneShotFeed: @unchecked Sendable {
        private let buffer: AVAudioPCMBuffer
        private var supplied = false
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
    }
}
