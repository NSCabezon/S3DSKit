import Foundation

/// The 3DSStream TCP wire protocol (see `docs/ARCHITECTURE.md`).
///
/// Every message is a 12-byte big-endian header followed by `length` payload bytes:
/// `"S3DS"` | type u8 | flags u8 | reserved u16 (0) | length u32.
public enum S3DSProtocol {
    /// Default TCP port the 3DS listens on.
    public static let defaultPort: UInt16 = 7777
    /// Header size in bytes.
    public static let headerLength = 12
    /// Magic bytes `"S3DS"`.
    public static let magic: [UInt8] = [0x53, 0x33, 0x44, 0x53]
    /// Largest message payload the 3DS receiver accepts (256 KiB; bigger closes the connection).
    public static let maxPayloadLength = 256 * 1024
    /// Largest `AUDIO` payload (timestamp + Opus packet) the receiver accepts.
    public static let maxAudioPayloadLength = 4 * 1024
    /// `VIDEO_AU` flag bit 0: the access unit contains an IDR (keyframe).
    public static let keyframeFlag: UInt8 = 0x01
    /// `VIDEO_AU` flag bit 1 (alternating layout): 0 = left eye, 1 = right eye.
    public static let rightEyeFlag: UInt8 = 0x02
    /// `VIDEO_AU` flag bit 2: the stream uses the alternating 240x400 one-eye-per-frame layout.
    public static let alternatingFlag: UInt8 = 0x04

    /// `VIDEO_AU` flags for an access unit. `eye` is nil for the stacked layout.
    public static func videoFlags(isKeyframe: Bool, eye: S3DSEye?) -> UInt8 {
        var f: UInt8 = isKeyframe ? keyframeFlag : 0
        if let eye {
            f |= alternatingFlag
            if eye == .right { f |= rightEyeFlag }
        }
        return f
    }

    /// Message types.
    public enum MessageType: UInt8, Sendable {
        /// sender → 3DS: one H.264 access unit, Annex-B.
        case videoAU = 0x01
        /// sender → 3DS: UTF-8 sender name (≤ 64 bytes).
        case hello = 0x02
        /// sender → 3DS: u64 BE timestamp (µs) + one Opus packet (48 kHz stereo, 20 ms).
        case audio = 0x03
        /// 3DS → sender: please send a keyframe next.
        case keyframeRequest = 0x10
    }

    /// A decoded message header.
    public struct Header: Equatable, Sendable {
        public var type: UInt8
        public var flags: UInt8
        public var length: UInt32

        public init(type: UInt8, flags: UInt8 = 0, length: UInt32) {
            self.type = type
            self.flags = flags
            self.length = length
        }

        public init(type: MessageType, flags: UInt8 = 0, length: UInt32) {
            self.init(type: type.rawValue, flags: flags, length: length)
        }

        /// The known message type, if any.
        public var messageType: MessageType? { MessageType(rawValue: type) }

        /// The 12 encoded header bytes.
        public func encoded() -> Data {
            var d = Data(capacity: S3DSProtocol.headerLength)
            d.append(contentsOf: S3DSProtocol.magic)
            d.append(type)
            d.append(flags)
            d.append(contentsOf: [0, 0])
            d.append(UInt8(truncatingIfNeeded: length >> 24))
            d.append(UInt8(truncatingIfNeeded: length >> 16))
            d.append(UInt8(truncatingIfNeeded: length >> 8))
            d.append(UInt8(truncatingIfNeeded: length))
            return d
        }
    }

    /// Header decoding errors.
    public enum DecodeError: Error, Equatable, Sendable {
        case tooShort
        case badMagic
        case payloadTooLarge(UInt32)
    }

    /// Decodes a header from the first 12 bytes of `data`.
    public static func decodeHeader(_ data: some Collection<UInt8>) throws(DecodeError) -> Header {
        let b = Array(data.prefix(headerLength))
        guard b.count == headerLength else { throw .tooShort }
        guard Array(b[0..<4]) == magic else { throw .badMagic }
        let length = UInt32(b[8]) << 24 | UInt32(b[9]) << 16 | UInt32(b[10]) << 8 | UInt32(b[11])
        guard length <= UInt32(maxPayloadLength) else { throw .payloadTooLarge(length) }
        return Header(type: b[4], flags: b[5], length: length)
    }

    /// Encodes a complete message (header + payload).
    public static func message(_ type: MessageType, flags: UInt8 = 0, payload: Data = Data()) -> Data {
        var d = Header(type: type, flags: flags, length: UInt32(payload.count)).encoded()
        d.append(payload)
        return d
    }

    /// An `AUDIO` message: big-endian µs timestamp followed by the Opus packet.
    public static func audio(timestampMicros: UInt64, opusPacket: Data) -> Data {
        var payload = Data(capacity: 8 + opusPacket.count)
        withUnsafeBytes(of: timestampMicros.bigEndian) { payload.append(contentsOf: $0) }
        payload.append(opusPacket)
        return message(.audio, payload: payload)
    }

    /// A `HELLO` message carrying `name` truncated to 64 UTF-8 bytes.
    public static func hello(name: String) -> Data {
        var bytes = Array(name.utf8.prefix(64))
        // Do not cut a multi-byte scalar in half.
        while !bytes.isEmpty, String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        return message(.hello, payload: Data(bytes))
    }
}
