import AVFAudio
import AudioToolbox
import Foundation

/// 48 kHz stereo Float32 → Opus packets (20 ms / 960 frames) via `AVAudioConverter`.
/// Not thread-safe; used from the audio queue only.
final class OpusPacketEncoder {
    static let sampleRate: Double = 48_000
    static let framesPerPacket = 960

    /// Deinterleaved stereo Float32 at 48 kHz.
    static let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 2, interleaved: false)!

    /// Opus, 48 kHz, stereo, 960 frames per packet.
    static let opusFormat: AVAudioFormat = {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(framesPerPacket), mBytesPerFrame: 0, mChannelsPerFrame: 2,
            mBitsPerChannel: 0, mReserved: 0)
        return AVAudioFormat(streamDescription: &asbd)!
    }()

    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioCompressedBuffer
    /// Timestamps of submitted input packets not yet matched to an output packet (encoder delay).
    private var pendingTimestamps: [Double] = []

    init(bitrate: Int) throws {
        guard let converter = AVAudioConverter(from: Self.pcmFormat, to: Self.opusFormat) else {
            throw S3DSKitError.audio("Opus encoder unavailable")
        }
        converter.bitRate = bitrate
        self.converter = converter
        input = AVAudioPCMBuffer(pcmFormat: Self.pcmFormat, frameCapacity: AVAudioFrameCount(Self.framesPerPacket))!
        let maxPacket = converter.maximumOutputPacketSize > 0 ? converter.maximumOutputPacketSize : 4000
        output = AVAudioCompressedBuffer(format: Self.opusFormat, packetCapacity: 8, maximumPacketSize: maxPacket)
    }

    /// Encodes one 20 ms packet of interleaved stereo samples (`960 * 2` floats).
    /// - Returns: the Opus packets produced (usually one) with their capture timestamps.
    func encode(interleaved samples: UnsafePointer<Float>, timestamp: Double) -> [(packet: Data, timestamp: Double)] {
        let n = Self.framesPerPacket
        let l = input.floatChannelData![0], r = input.floatChannelData![1]
        for i in 0..<n {
            l[i] = samples[2 * i]
            r[i] = samples[2 * i + 1]
        }
        input.frameLength = AVAudioFrameCount(n)
        pendingTimestamps.append(timestamp)

        let feed = InputFeed(input)
        output.packetCount = 0
        output.byteLength = 0
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            feed.next(outStatus)
        }
        guard status != .error else { return [] }

        var packets: [(Data, Double)] = []
        let base = output.data.assumingMemoryBound(to: UInt8.self)
        for i in 0..<Int(output.packetCount) {
            guard let desc = output.packetDescriptions?[i], desc.mDataByteSize > 0 else { continue }
            let data = Data(bytes: base + Int(desc.mStartOffset), count: Int(desc.mDataByteSize))
            let ts = pendingTimestamps.isEmpty ? timestamp : pendingTimestamps.removeFirst()
            packets.append((data, ts))
        }
        return packets
    }

    /// Supplies the prepared input buffer once per `convert` call.
    private final class InputFeed: @unchecked Sendable {
        private let buffer: AVAudioPCMBuffer
        private var supplied = false
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
    }
}
