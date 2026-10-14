import AVFAudio
import Foundation
import Synchronization
import Testing
@testable import S3DSKit

/// Opus test helpers.
enum OpusTestSupport {
    /// Decodes Opus packets (48 kHz stereo) and returns the left channel.
    static func decode(_ packets: [Data]) throws -> [Float] {
        let converter = try #require(AVAudioConverter(from: OpusPacketEncoder.opusFormat, to: OpusPacketEncoder.pcmFormat))
        var out: [Float] = []
        for packet in packets {
            let input = AVAudioCompressedBuffer(format: OpusPacketEncoder.opusFormat, packetCapacity: 1,
                                                maximumPacketSize: max(1, packet.count))
            packet.withUnsafeBytes { input.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
            input.packetDescriptions![0] = AudioStreamPacketDescription(
                mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
            input.packetCount = 1
            input.byteLength = UInt32(packet.count)
            let pcm = try #require(AVAudioPCMBuffer(pcmFormat: OpusPacketEncoder.pcmFormat, frameCapacity: 960 * 2))
            let feed = Feed(input)
            var error: NSError?
            let status = converter.convert(to: pcm, error: &error) { _, s in feed.next(s) }
            try #require(status != .error, "decode failed: \(String(describing: error))")
            out.append(contentsOf: UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength)))
        }
        return out
    }

    /// Dominant frequency estimate from positive-going zero crossings (skips decoder priming).
    static func frequency(_ samples: [Float], sampleRate: Double = 48_000) -> Double {
        let s = Array(samples.dropFirst(4800))
        guard s.count > 4800 else { return 0 }
        var crossings = 0
        for i in 1..<s.count where s[i - 1] < 0 && s[i] >= 0 { crossings += 1 }
        return Double(crossings) / (Double(s.count) / sampleRate)
    }

    static func rms(_ samples: [Float]) -> Float {
        let s = samples.dropFirst(4800)
        guard !s.isEmpty else { return 0 }
        return (s.reduce(0) { $0 + $1 * $1 } / Float(s.count)).squareRoot()
    }

    final class Feed: @unchecked Sendable {
        let buffer: AVAudioBuffer
        var supplied = false
        init(_ buffer: AVAudioBuffer) { self.buffer = buffer }
        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
    }
}

@Suite("Audio")
struct AudioTests {
    final class Collector: Sendable {
        let packets = Mutex<[(data: Data, micros: UInt64)]>([])
    }

    /// Feeds `seconds` of a mono 440 Hz sine at `rate` in 10 ms chunks with a real-time clock.
    func feedSine(_ pipeline: AudioPipeline, rate: Double, seconds: Double, startTime: Double = 1000) {
        let chunk = Int(rate / 100)
        let total = Int(rate * seconds)
        var written = 0
        while written < total {
            let n = min(chunk, total - written)
            let end = startTime + Double(written + n) / rate
            let base = written
            pipeline.ring.write(frames: n, sampleRate: rate, endTime: end) { f, _ in
                Float(0.5 * sin(2 * Double.pi * 440 * Double(base + f) / rate))
            }
            written += n
            if written % (chunk * 10) == 0 { pipeline.drainNow() }   // consumer keeps up
        }
        pipeline.drainNow()
    }

    @Test(arguments: [48_000.0, 44_100.0])
    func opusPacketsAt50PerSecond(rate: Double) throws {
        let collector = Collector()
        let pipeline = AudioPipeline(bitrate: 96_000) { data, micros in
            collector.packets.withLock { $0.append((data, micros)) }
        }
        feedSine(pipeline, rate: rate, seconds: 1)
        let packets = collector.packets.withLock { $0 }
        #expect(packets.count >= 47 && packets.count <= 50, "got \(packets.count) packets")
        #expect(packets.allSatisfy { $0.data.count > 0 && $0.data.count + 8 <= S3DSProtocol.maxAudioPayloadLength })
        // 20 ms apart on the capture clock, starting at the first sample's time.
        let deltas = zip(packets.dropFirst(), packets).map { Int64($0.micros) - Int64($1.micros) }
        #expect(deltas.allSatisfy { abs($0 - 20_000) <= 2 }, "deltas \(deltas.prefix(5))")
        #expect(abs(Int64(packets[0].micros) - 1_000_000_000) < 30_000)

        let decoded = try OpusTestSupport.decode(packets.map(\.data))
        #expect(decoded.count >= 960 * (packets.count - 2))
        let f = OpusTestSupport.frequency(decoded)
        #expect(abs(f - 440) < 15, "decoded frequency \(f) Hz")
        #expect(OpusTestSupport.rms(decoded) > 0.2)
    }

    @Test func ringOverwritesOldestAndResetsOnRateChange() {
        let ring = AudioRing(capacityFrames: 4)
        ring.write(frames: 6, sampleRate: 48_000, endTime: 1) { f, ch in Float(f * 10 + ch) }
        let dst = UnsafeMutablePointer<Float>.allocate(capacity: 16)
        defer { dst.deallocate() }
        var r = ring.read(into: dst, maxFrames: 8)
        #expect(r.frames == 4)
        #expect(Array(UnsafeBufferPointer(start: dst, count: 8)) == [20, 21, 30, 31, 40, 41, 50, 51])
        ring.write(frames: 2, sampleRate: 48_000, endTime: 2) { _, _ in 1 }
        ring.write(frames: 1, sampleRate: 44_100, endTime: 3) { _, _ in 7 }
        r = ring.read(into: dst, maxFrames: 8)
        #expect(r.frames == 1 && r.sampleRate == 44_100 && r.generation == 1 && dst[0] == 7)
    }

    @Test func audioMessageFraming() throws {
        let msg = S3DSProtocol.audio(timestampMicros: 0x0102_0304_0506_0708, opusPacket: Data([0xAA, 0xBB]))
        let h = try S3DSProtocol.decodeHeader(msg)
        #expect(h.messageType == .audio && h.flags == 0 && h.length == 10)
        #expect(Array(msg.dropFirst(12)) == [1, 2, 3, 4, 5, 6, 7, 8, 0xAA, 0xBB])
    }
}
