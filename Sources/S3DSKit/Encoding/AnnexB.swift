import Foundation

/// AVCC (length-prefixed) → Annex-B (start-code) conversion for H.264 access units.
enum AnnexB {
    static let startCode: [UInt8] = [0, 0, 0, 1]

    /// NAL unit types dropped from the output: SEI (6) and AUD (9). The 3DS receiver
    /// does not need them and the contract forbids AUDs.
    static let droppedNALTypes: Set<UInt8> = [6, 9]

    /// Converts one AVCC access unit to Annex-B.
    ///
    /// - Parameters:
    ///   - avcc: NAL units each prefixed with a big-endian length of `nalLengthSize` bytes.
    ///   - nalLengthSize: 1, 2 or 4 (VideoToolbox uses 4).
    ///   - parameterSets: when non-nil (keyframes), these NALs (SPS, PPS) are emitted first and
    ///     any in-band SPS/PPS in `avcc` are skipped to avoid duplicates.
    /// - Returns: the Annex-B bytes, or nil if `avcc` is malformed.
    static func convert(avcc: Data, nalLengthSize: Int, parameterSets: [Data]? = nil) -> Data? {
        guard [1, 2, 4].contains(nalLengthSize) else { return nil }
        var out = Data(capacity: avcc.count + 64)
        if let parameterSets {
            for ps in parameterSets {
                out.append(contentsOf: startCode)
                out.append(ps)
            }
        }
        let skipParamSets = parameterSets != nil
        return avcc.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            let bytes = raw.bindMemory(to: UInt8.self)
            var i = 0
            let n = bytes.count
            while i < n {
                guard i + nalLengthSize <= n else { return nil }
                var len = 0
                for k in 0..<nalLengthSize { len = (len << 8) | Int(bytes[i + k]) }
                i += nalLengthSize
                guard len > 0, i + len <= n else { return nil }
                let type = bytes[i] & 0x1F
                let skip = droppedNALTypes.contains(type) || (skipParamSets && (type == 7 || type == 8))
                if !skip {
                    out.append(contentsOf: startCode)
                    out.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[i..<(i + len)]))
                }
                i += len
            }
            return out
        }
    }

    /// Number of coded slice NAL units (types 1 and 5) in an AVCC access unit, or nil if malformed.
    /// The 3DS MVD decoder requires exactly one per picture.
    static func sliceCount(avcc: Data, nalLengthSize: Int) -> Int? {
        guard [1, 2, 4].contains(nalLengthSize) else { return nil }
        return avcc.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
            var i = 0, count = 0
            while i < raw.count {
                guard i + nalLengthSize <= raw.count else { return nil }
                var len = 0
                for k in 0..<nalLengthSize { len = (len << 8) | Int(raw[i + k]) }
                i += nalLengthSize
                guard len > 0, i + len <= raw.count else { return nil }
                let type = raw[i] & 0x1F
                if type == 1 || type == 5 { count += 1 }
                i += len
            }
            return count
        }
    }
}
