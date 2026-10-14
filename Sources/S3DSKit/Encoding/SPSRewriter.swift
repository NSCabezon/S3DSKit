import Foundation
import Synchronization
import os

/// Rewrites an H.264 SPS so a conforming decoder outputs every picture as soon as it is decoded.
///
/// VideoToolbox writes a VUI without `bitstream_restriction`. A decoder must then assume the
/// stream may reorder pictures and can hold decoded pictures in its DPB before output. On the
/// 3DS, whose MVD decoder writes alternating L/R frames straight to the eye framebuffers, that
/// output delay showed the right eye from an older moment than the left. x264 streams (which
/// signal `max_num_reorder_frames = 0`, `max_dec_frame_buffering = 1`) stay in sync.
///
/// The rewriter parses the SPS through the end of the VUI, copies every bit before
/// `bitstream_restriction_flag` unchanged, and writes a new restriction block with
/// `max_num_reorder_frames = 0` and `max_dec_frame_buffering = max(1, max_num_ref_frames)`.
/// Without a VUI it adds a minimal one. Anything it cannot parse is passed through unchanged.
enum SPSRewriter {
    // MARK: - Parsed SPS

    struct HRD: Equatable, Sendable {
        var bitRateScale: UInt32
        var cpbSizeScale: UInt32
        /// (bit_rate_value_minus1, cpb_size_value_minus1, cbr_flag) per CPB.
        var cpbs: [CPB]
        var initialCPBRemovalDelayLengthMinus1: UInt32
        var cpbRemovalDelayLengthMinus1: UInt32
        var dpbOutputDelayLengthMinus1: UInt32
        var timeOffsetLength: UInt32

        struct CPB: Equatable, Sendable {
            var bitRateValueMinus1: UInt32
            var cpbSizeValueMinus1: UInt32
            var cbr: Bool
        }
    }

    struct BitstreamRestriction: Equatable, Sendable {
        var motionVectorsOverPicBoundaries: Bool
        var maxBytesPerPicDenom: UInt32
        var maxBitsPerMBDenom: UInt32
        var log2MaxMVLengthHorizontal: UInt32
        var log2MaxMVLengthVertical: UInt32
        var maxNumReorderFrames: UInt32
        var maxDecFrameBuffering: UInt32
    }

    struct VUI: Equatable, Sendable {
        var aspectRatioIDC: UInt32?            // nil: aspect_ratio_info_present_flag = 0
        var sarWidth: UInt32 = 0, sarHeight: UInt32 = 0   // Extended_SAR (idc 255) only
        var overscanAppropriate: Bool?         // nil: overscan_info_present_flag = 0
        var videoFormat: UInt32?               // nil: video_signal_type_present_flag = 0
        var videoFullRange = false
        var colourDescription: [UInt32]?       // primaries, transfer, matrix
        var chromaLoc: [UInt32]?               // top, bottom
        var timing: [UInt32]?                  // num_units_in_tick, time_scale, fixed_frame_rate
        var nalHRD: HRD?
        var vclHRD: HRD?
        var lowDelayHRD: Bool?                 // present only with an HRD
        var picStructPresent = false
        var restriction: BitstreamRestriction?
    }

    struct SPS: Equatable, Sendable {
        var nalHeader: UInt8
        var profileIDC: UInt32
        var constraintFlags: UInt32
        var levelIDC: UInt32
        var spsID: UInt32
        // High profiles only (defaults per spec otherwise).
        var chromaFormatIDC: UInt32 = 1
        var separateColourPlane = false
        var bitDepthLumaMinus8: UInt32 = 0
        var bitDepthChromaMinus8: UInt32 = 0
        var qpprimeYZeroTransformBypass = false
        /// Raw delta_scale values per list; nil when the list is absent.
        var scalingLists: [[Int32]?]?
        var log2MaxFrameNumMinus4: UInt32
        var picOrderCntType: UInt32
        var log2MaxPicOrderCntLsbMinus4: UInt32 = 0
        var deltaPicOrderAlwaysZero = false
        var offsetForNonRefPic: Int32 = 0
        var offsetForTopToBottomField: Int32 = 0
        var offsetsForRefFrame: [Int32] = []
        var maxNumRefFrames: UInt32
        var gapsInFrameNumAllowed: Bool
        var picWidthInMBsMinus1: UInt32
        var picHeightInMapUnitsMinus1: UInt32
        var frameMBsOnly: Bool
        var mbAdaptiveFrameField = false
        var direct8x8Inference: Bool
        var frameCropping: [UInt32]?           // left, right, top, bottom
        var vui: VUI?
    }

    enum ParseError: Error { case truncated, invalid(String) }

    // MARK: - Public entry points

    /// The values this rewriter writes into `bitstream_restriction`.
    static func restriction(maxNumRefFrames: UInt32) -> BitstreamRestriction {
        BitstreamRestriction(motionVectorsOverPicBoundaries: true, maxBytesPerPicDenom: 2, maxBitsPerMBDenom: 1,
                             log2MaxMVLengthHorizontal: 16, log2MaxMVLengthVertical: 16,
                             maxNumReorderFrames: 0, maxDecFrameBuffering: max(1, maxNumRefFrames))
    }

    /// Returns `sps` (one NAL unit, header byte included, no start code) with
    /// `bitstream_restriction` set for zero output delay. Returns `sps` unchanged, and logs once,
    /// if it cannot be parsed.
    static func rewrite(_ sps: Data) -> Data {
        do {
            return try rewriteOrThrow(sps)
        } catch {
            if !loggedFailure.exchange(true, ordering: .relaxed) {
                log.error("SPS rewrite failed (\(String(describing: error))); sending the encoder's SPS unchanged")
            }
            return sps
        }
    }

    static func rewriteOrThrow(_ sps: Data) throws -> Data {
        let parsed = try parseWithPositions(sps)
        let rbsp = parsed.rbsp
        var w = BitWriter()
        if parsed.sps.vui != nil {
            w.copyBits(from: rbsp, count: parsed.restrictionFlagBit)
        } else {
            w.copyBits(from: rbsp, count: parsed.vuiFlagBit)
            w.write(1, bits: 1)        // vui_parameters_present_flag
            w.write(0, bits: 1)        // aspect_ratio_info_present_flag
            w.write(0, bits: 1)        // overscan_info_present_flag
            w.write(0, bits: 1)        // video_signal_type_present_flag
            w.write(0, bits: 1)        // chroma_loc_info_present_flag
            w.write(0, bits: 1)        // timing_info_present_flag
            w.write(0, bits: 1)        // nal_hrd_parameters_present_flag
            w.write(0, bits: 1)        // vcl_hrd_parameters_present_flag
            w.write(0, bits: 1)        // pic_struct_present_flag
        }
        let r = restriction(maxNumRefFrames: parsed.sps.maxNumRefFrames)
        w.write(1, bits: 1)            // bitstream_restriction_flag
        w.write(r.motionVectorsOverPicBoundaries ? 1 : 0, bits: 1)
        w.writeUE(r.maxBytesPerPicDenom)
        w.writeUE(r.maxBitsPerMBDenom)
        w.writeUE(r.log2MaxMVLengthHorizontal)
        w.writeUE(r.log2MaxMVLengthVertical)
        w.writeUE(r.maxNumReorderFrames)
        w.writeUE(r.maxDecFrameBuffering)
        w.write(1, bits: 1)            // rbsp_stop_one_bit
        w.alignWithZeros()
        let out = addEmulationPrevention(w.bytes)
        // Paranoia: the result must parse back to the same SPS plus the new restriction.
        var expected = parsed.sps
        var vui = expected.vui ?? VUI()
        vui.restriction = r
        expected.vui = vui
        guard try parse(out) == expected else { throw ParseError.invalid("round trip mismatch") }
        return out
    }

    /// Parses one SPS NAL unit (header byte included, emulation prevention present).
    static func parse(_ nal: Data) throws -> SPS {
        try parseWithPositions(nal).sps
    }

    // MARK: - Parsing

    private struct Parsed {
        var sps: SPS
        var rbsp: [UInt8]
        /// Bit offset (in `rbsp`, header byte included) of vui_parameters_present_flag.
        var vuiFlagBit: Int
        /// Bit offset of bitstream_restriction_flag (only meaningful with a VUI).
        var restrictionFlagBit: Int
    }

    private static let highProfiles: Set<UInt32> = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]

    private static func parseWithPositions(_ nal: Data) throws -> Parsed {
        let rbsp = removeEmulationPrevention([UInt8](nal))
        var r = BitReader(rbsp)
        let header = try r.read(8)
        guard header & 0x80 == 0, header & 0x1F == 7 else { throw ParseError.invalid("not an SPS NAL") }
        var sps = SPS(nalHeader: UInt8(header), profileIDC: try r.read(8), constraintFlags: try r.read(8),
                      levelIDC: try r.read(8), spsID: try r.readUE(),
                      log2MaxFrameNumMinus4: 0, picOrderCntType: 0, maxNumRefFrames: 0,
                      gapsInFrameNumAllowed: false, picWidthInMBsMinus1: 0, picHeightInMapUnitsMinus1: 0,
                      frameMBsOnly: true, direct8x8Inference: false)
        guard sps.spsID <= 31 else { throw ParseError.invalid("seq_parameter_set_id") }
        if highProfiles.contains(sps.profileIDC) {
            sps.chromaFormatIDC = try r.readUE()
            guard sps.chromaFormatIDC <= 3 else { throw ParseError.invalid("chroma_format_idc") }
            if sps.chromaFormatIDC == 3 { sps.separateColourPlane = try r.readFlag() }
            sps.bitDepthLumaMinus8 = try r.readUE()
            sps.bitDepthChromaMinus8 = try r.readUE()
            sps.qpprimeYZeroTransformBypass = try r.readFlag()
            if try r.readFlag() {
                var lists: [[Int32]?] = []
                for i in 0..<(sps.chromaFormatIDC == 3 ? 12 : 8) {
                    lists.append(try r.readFlag() ? try readScalingList(&r, size: i < 6 ? 16 : 64) : nil)
                }
                sps.scalingLists = lists
            }
        }
        sps.log2MaxFrameNumMinus4 = try r.readUE()
        guard sps.log2MaxFrameNumMinus4 <= 12 else { throw ParseError.invalid("log2_max_frame_num") }
        sps.picOrderCntType = try r.readUE()
        switch sps.picOrderCntType {
        case 0:
            sps.log2MaxPicOrderCntLsbMinus4 = try r.readUE()
            guard sps.log2MaxPicOrderCntLsbMinus4 <= 12 else { throw ParseError.invalid("log2_max_poc_lsb") }
        case 1:
            sps.deltaPicOrderAlwaysZero = try r.readFlag()
            sps.offsetForNonRefPic = try r.readSE()
            sps.offsetForTopToBottomField = try r.readSE()
            let n = try r.readUE()
            guard n <= 255 else { throw ParseError.invalid("num_ref_frames_in_pic_order_cnt_cycle") }
            for _ in 0..<n { sps.offsetsForRefFrame.append(try r.readSE()) }
        case 2:
            break
        default:
            throw ParseError.invalid("pic_order_cnt_type")
        }
        sps.maxNumRefFrames = try r.readUE()
        guard sps.maxNumRefFrames <= 16 else { throw ParseError.invalid("max_num_ref_frames") }
        sps.gapsInFrameNumAllowed = try r.readFlag()
        sps.picWidthInMBsMinus1 = try r.readUE()
        sps.picHeightInMapUnitsMinus1 = try r.readUE()
        sps.frameMBsOnly = try r.readFlag()
        if !sps.frameMBsOnly { sps.mbAdaptiveFrameField = try r.readFlag() }
        sps.direct8x8Inference = try r.readFlag()
        if try r.readFlag() {
            sps.frameCropping = [try r.readUE(), try r.readUE(), try r.readUE(), try r.readUE()]
        }
        let vuiFlagBit = r.position
        var restrictionFlagBit = 0
        if try r.readFlag() {
            var vui = VUI()
            if try r.readFlag() {
                let idc = try r.read(8)
                vui.aspectRatioIDC = idc
                if idc == 255 {
                    vui.sarWidth = try r.read(16)
                    vui.sarHeight = try r.read(16)
                }
            }
            if try r.readFlag() { vui.overscanAppropriate = try r.readFlag() }
            if try r.readFlag() {
                vui.videoFormat = try r.read(3)
                vui.videoFullRange = try r.readFlag()
                if try r.readFlag() { vui.colourDescription = [try r.read(8), try r.read(8), try r.read(8)] }
            }
            if try r.readFlag() { vui.chromaLoc = [try r.readUE(), try r.readUE()] }
            if try r.readFlag() { vui.timing = [try r.read(32), try r.read(32), try r.read(1)] }
            if try r.readFlag() { vui.nalHRD = try readHRD(&r) }
            if try r.readFlag() { vui.vclHRD = try readHRD(&r) }
            if vui.nalHRD != nil || vui.vclHRD != nil { vui.lowDelayHRD = try r.readFlag() }
            vui.picStructPresent = try r.readFlag()
            restrictionFlagBit = r.position
            if try r.readFlag() {
                vui.restriction = BitstreamRestriction(
                    motionVectorsOverPicBoundaries: try r.readFlag(), maxBytesPerPicDenom: try r.readUE(),
                    maxBitsPerMBDenom: try r.readUE(), log2MaxMVLengthHorizontal: try r.readUE(),
                    log2MaxMVLengthVertical: try r.readUE(), maxNumReorderFrames: try r.readUE(),
                    maxDecFrameBuffering: try r.readUE())
            }
            sps.vui = vui
        }
        // rbsp_trailing_bits: a one followed by zeros to the end. Anything else (unknown
        // extensions, a misparse) means we do not understand this SPS.
        guard try r.readFlag() else { throw ParseError.invalid("missing rbsp_stop_one_bit") }
        while r.bitsLeft > 0 {
            guard try r.read(1) == 0 else { throw ParseError.invalid("data after rbsp_stop_one_bit") }
        }
        return Parsed(sps: sps, rbsp: rbsp, vuiFlagBit: vuiFlagBit, restrictionFlagBit: restrictionFlagBit)
    }

    private static func readHRD(_ r: inout BitReader) throws -> HRD {
        let cpbCount = try r.readUE() + 1
        guard cpbCount <= 32 else { throw ParseError.invalid("cpb_cnt_minus1") }
        let bitRateScale = try r.read(4), cpbSizeScale = try r.read(4)
        var cpbs: [HRD.CPB] = []
        for _ in 0..<cpbCount {
            cpbs.append(HRD.CPB(bitRateValueMinus1: try r.readUE(), cpbSizeValueMinus1: try r.readUE(),
                                cbr: try r.readFlag()))
        }
        return HRD(bitRateScale: bitRateScale, cpbSizeScale: cpbSizeScale, cpbs: cpbs,
                   initialCPBRemovalDelayLengthMinus1: try r.read(5), cpbRemovalDelayLengthMinus1: try r.read(5),
                   dpbOutputDelayLengthMinus1: try r.read(5), timeOffsetLength: try r.read(5))
    }

    private static func readScalingList(_ r: inout BitReader, size: Int) throws -> [Int32] {
        var deltas: [Int32] = []
        var last: Int32 = 8, next: Int32 = 8
        for _ in 0..<size {
            if next != 0 {
                let delta = try r.readSE()
                deltas.append(delta)
                next = (last + delta + 256) % 256
            }
            last = next == 0 ? last : next
        }
        return deltas
    }

    // MARK: - Emulation prevention

    static func removeEmulationPrevention(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var zeros = 0
        for b in bytes {
            if zeros >= 2, b == 3 {
                zeros = 0
                continue
            }
            out.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        return out
    }

    static func addEmulationPrevention(_ bytes: [UInt8]) -> Data {
        var out = Data(capacity: bytes.count + 4)
        var zeros = 0
        for b in bytes {
            if zeros >= 2, b <= 3 {
                out.append(3)
                zeros = 0
            }
            out.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        return out
    }

    // MARK: - Bits

    struct BitReader {
        let bytes: [UInt8]
        private(set) var position = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var bitsLeft: Int { bytes.count * 8 - position }

        mutating func read(_ count: Int) throws -> UInt32 {
            guard count <= 32, bitsLeft >= count else { throw ParseError.truncated }
            var v: UInt64 = 0
            for _ in 0..<count {
                let bit = (bytes[position >> 3] >> (7 - UInt8(position & 7))) & 1
                v = v << 1 | UInt64(bit)
                position += 1
            }
            return UInt32(v)
        }

        mutating func readFlag() throws -> Bool { try read(1) == 1 }

        mutating func readUE() throws -> UInt32 {
            var zeros = 0
            while try read(1) == 0 {
                zeros += 1
                guard zeros <= 31 else { throw ParseError.invalid("exp-Golomb code too long") }
            }
            guard zeros > 0 else { return 0 }
            return UInt32((UInt64(1) << zeros) - 1 + UInt64(try read(zeros)))
        }

        mutating func readSE() throws -> Int32 {
            let k = Int64(try readUE())
            return Int32(k % 2 == 1 ? (k + 1) / 2 : -(k / 2))
        }
    }

    struct BitWriter {
        private(set) var bytes: [UInt8] = []
        private var bitCount = 0

        mutating func write(_ value: UInt32, bits: Int) {
            for i in stride(from: bits - 1, through: 0, by: -1) {
                if bitCount & 7 == 0 { bytes.append(0) }
                if (value >> UInt32(i)) & 1 == 1 { bytes[bytes.count - 1] |= 0x80 >> UInt8(bitCount & 7) }
                bitCount += 1
            }
        }

        mutating func writeUE(_ value: UInt32) {
            let v = UInt64(value) + 1
            let len = 64 - v.leadingZeroBitCount
            write(0, bits: len - 1)
            for i in stride(from: len - 1, through: 0, by: -1) { write(UInt32((v >> UInt64(i)) & 1), bits: 1) }
        }

        mutating func writeSE(_ value: Int32) {
            writeUE(value > 0 ? UInt32(2 * Int64(value) - 1) : UInt32(-2 * Int64(value)))
        }

        mutating func copyBits(from source: [UInt8], count: Int) {
            for p in 0..<count { write(UInt32((source[p >> 3] >> (7 - UInt8(p & 7))) & 1), bits: 1) }
        }

        mutating func alignWithZeros() {
            while bitCount & 7 != 0 { write(0, bits: 1) }
        }
    }

    private static let log = Logger(subsystem: "S3DSKit", category: "encoder")
    private static let loggedFailure = Atomic<Bool>(false)
}
