import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox
@testable import S3DSKit

@Suite("SPS bitstream_restriction rewrite")
struct SPSRewriterTests {
    typealias SPS = SPSRewriter.SPS

    /// SPS captured from VideoToolbox's simulator encoder before the rewrite (Constrained Baseline
    /// 3.0, 240x400, POC type 0, 2 ref frames, VUI with colour description and NAL HRD, no
    /// bitstream_restriction).
    static let capturedVTSPS = Data([0x27, 0x42, 0xE0, 0x1E, 0xA9, 0x18, 0x78, 0x67, 0x60, 0x2D, 0x40,
                                     0x80, 0x80, 0x8C, 0x2B, 0x5E, 0xF7, 0xC0, 0x40])

    /// Asserts `rewritten` carries the zero-delay restriction and otherwise equals `original`.
    func expectRewritten(_ original: Data, _ rewritten: Data, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let before = try SPSRewriter.parse(original)
        let after = try SPSRewriter.parse(rewritten)
        let r = try #require(after.vui?.restriction, sourceLocation: sourceLocation)
        #expect(r.maxNumReorderFrames == 0, sourceLocation: sourceLocation)
        #expect(r.maxDecFrameBuffering >= after.maxNumRefFrames, sourceLocation: sourceLocation)
        #expect(r.maxDecFrameBuffering >= 1, sourceLocation: sourceLocation)
        #expect(r == SPSRewriter.restriction(maxNumRefFrames: before.maxNumRefFrames), sourceLocation: sourceLocation)
        // Every other field is preserved.
        var expected = before
        var vui = expected.vui ?? SPSRewriter.VUI()
        vui.restriction = r
        expected.vui = vui
        #expect(after == expected, sourceLocation: sourceLocation)
        // No start-code emulation in the output.
        let b = [UInt8](rewritten)
        for i in 0..<max(0, b.count - 2) {
            #expect(!(b[i] == 0 && b[i + 1] == 0 && b[i + 2] <= 2), sourceLocation: sourceLocation)
        }
    }

    @Test func capturedVideoToolboxSPS() throws {
        let sps = try SPSRewriter.parse(Self.capturedVTSPS)
        #expect(sps.profileIDC == 66 && sps.levelIDC == 30)
        #expect(sps.picOrderCntType == 0 && sps.maxNumRefFrames == 2)
        #expect(sps.vui?.nalHRD != nil && sps.vui?.restriction == nil)
        let out = SPSRewriter.rewrite(Self.capturedVTSPS)
        try expectRewritten(Self.capturedVTSPS, out)
        #expect(try SPSRewriter.parse(out).vui?.restriction?.maxDecFrameBuffering == 2)
        // Idempotent: rewriting again keeps the same bytes.
        #expect(SPSRewriter.rewrite(out) == out)
    }

    /// The SPS of a live VideoToolbox session (configured like H264Encoder), before any rewrite.
    @Test func liveVideoToolboxSPS() throws {
        let original = try Self.encodeOneFrameSPS(referenceBufferCount: nil)
        try expectRewritten(original, SPSRewriter.rewrite(original))
        let reduced = try Self.encodeOneFrameSPS(referenceBufferCount: 1)
        try expectRewritten(reduced, SPSRewriter.rewrite(reduced))
        print("S3DSKIT_SPS max_num_ref_frames: default=\(try SPSRewriter.parse(original).maxNumRefFrames) "
              + "ReferenceBufferCount=1 → \(try SPSRewriter.parse(reduced).maxNumRefFrames)")
    }

    /// The encoder's output keyframes carry the rewritten SPS.
    @Test func encoderEmitsRewrittenSPS() throws {
        let collected = EncoderTests.Collector()
        let encoder = H264Encoder(settings: .init()) { data, key, eye in
            collected.items.withLock { $0.append((data, key, eye)) }
        }
        let tests = EncoderTests()
        for i in 0..<4 {
            encoder.encode(try tests.makeBuffer(height: 400, shade: UInt8(i * 30)),
                           presentationTime: CMTime(value: CMTimeValue(i), timescale: 60),
                           eye: i % 2 == 0 ? .left : .right)
        }
        encoder.reset()
        let first = try #require(collected.items.withLock { $0.first })
        let sps = try SPSRewriter.parse(try #require(firstNAL(ofType: 7, in: first.data)))
        let r = try #require(sps.vui?.restriction)
        #expect(r.maxNumReorderFrames == 0 && r.maxDecFrameBuffering >= max(1, sps.maxNumRefFrames))
    }

    @Test func syntheticWithoutVUI() throws {
        let original = Self.makeSPS(pocType: 2, refFrames: 1, cropping: [0, 0, 0, 4], vui: nil)
        let out = SPSRewriter.rewrite(original)
        try expectRewritten(original, out)
        let vui = try #require(try SPSRewriter.parse(out).vui)
        #expect(vui.aspectRatioIDC == nil && vui.timing == nil && vui.nalHRD == nil && !vui.picStructPresent)
        #expect(vui.restriction?.maxDecFrameBuffering == 1)
    }

    @Test func syntheticZeroRefFrames() throws {
        let original = Self.makeSPS(pocType: 2, refFrames: 0, vui: nil)
        let out = SPSRewriter.rewrite(original)
        try expectRewritten(original, out)
        #expect(try SPSRewriter.parse(out).vui?.restriction?.maxDecFrameBuffering == 1)
    }

    @Test func syntheticVUIWithTimingAndEverything() throws {
        var vui = SPSRewriter.VUI()
        vui.aspectRatioIDC = 255
        vui.sarWidth = 4
        vui.sarHeight = 3
        vui.overscanAppropriate = true
        vui.videoFormat = 5
        vui.videoFullRange = true
        vui.colourDescription = [1, 1, 1]
        vui.chromaLoc = [0, 2]
        vui.timing = [1, 120, 1]
        vui.vclHRD = .init(bitRateScale: 2, cpbSizeScale: 4,
                           cpbs: [.init(bitRateValueMinus1: 1000, cpbSizeValueMinus1: 2000, cbr: false),
                                  .init(bitRateValueMinus1: 5, cpbSizeValueMinus1: 6, cbr: true)],
                           initialCPBRemovalDelayLengthMinus1: 23, cpbRemovalDelayLengthMinus1: 23,
                           dpbOutputDelayLengthMinus1: 23, timeOffsetLength: 24)
        vui.lowDelayHRD = true
        vui.picStructPresent = true
        let original = Self.makeSPS(pocType: 0, refFrames: 3, vui: vui)
        #expect(try SPSRewriter.parse(original).vui == vui)   // the synthetic builder round-trips
        let out = SPSRewriter.rewrite(original)
        try expectRewritten(original, out)
        #expect(try SPSRewriter.parse(out).vui?.restriction?.maxDecFrameBuffering == 3)
    }

    @Test func syntheticExistingRestrictionIsReplaced() throws {
        var vui = SPSRewriter.VUI()
        vui.timing = [1001, 60000, 0]
        vui.restriction = .init(motionVectorsOverPicBoundaries: false, maxBytesPerPicDenom: 0, maxBitsPerMBDenom: 0,
                                log2MaxMVLengthHorizontal: 10, log2MaxMVLengthVertical: 9,
                                maxNumReorderFrames: 2, maxDecFrameBuffering: 4)
        let original = Self.makeSPS(pocType: 1, refFrames: 4, vui: vui)
        let out = SPSRewriter.rewrite(original)
        try expectRewritten(original, out)
        #expect(try SPSRewriter.parse(out).vui?.restriction?.maxNumReorderFrames == 0)
    }

    @Test func syntheticHighProfileWithScalingLists() throws {
        let original = Self.makeSPS(profile: 100, pocType: 0, refFrames: 2, vui: SPSRewriter.VUI())
        try expectRewritten(original, SPSRewriter.rewrite(original))
    }

    @Test func emulationPreventionRoundTrip() throws {
        let raw: [UInt8] = [0x67, 0, 0, 0, 0, 0, 1, 0, 0, 2, 0, 0, 3, 0xFF, 0, 0]
        let escaped = SPSRewriter.addEmulationPrevention(raw)
        #expect([UInt8](escaped) == [0x67, 0, 0, 3, 0, 0, 3, 0, 1, 0, 0, 3, 2, 0, 0, 3, 3, 0xFF, 0, 0])
        #expect(SPSRewriter.removeEmulationPrevention([UInt8](escaped)) == raw)
    }

    @Test func unparseableSPSPassesThroughUnchanged() {
        let garbage: [Data] = [Data(), Data([0x67]), Data([0x68, 0xCE, 0x3C, 0x80]),   // PPS, not SPS
                               Self.capturedVTSPS.prefix(8),                           // truncated
                               Self.capturedVTSPS + Data([0xFF])]                      // junk after stop bit
        for g in garbage { #expect(SPSRewriter.rewrite(g) == g) }
        #expect(H264Encoder.rewrittenParameterSet(Data([0x68, 0xCE, 0x3C, 0x80])) == Data([0x68, 0xCE, 0x3C, 0x80]))
    }

    @Test func annexBRewritesInBandSPS() throws {
        let sps = Self.makeSPS(pocType: 2, refFrames: 1, vui: nil)
        var avcc = Data()
        for nal in [sps, Data([0x41, 0x9A, 0x01])] {
            withUnsafeBytes(of: UInt32(nal.count).bigEndian) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }
        let out = try #require(AnnexB.convert(avcc: avcc, nalLengthSize: 4, spsTransform: SPSRewriter.rewrite))
        let inBand = try #require(firstNAL(ofType: 7, in: out))
        try expectRewritten(sps, inBand)
    }

    // MARK: - Helpers

    /// Builds an SPS NAL with the given VUI (written field by field per H.264 E.1.1).
    static func makeSPS(profile: UInt32 = 66, pocType: UInt32, refFrames: UInt32,
                        cropping: [UInt32]? = nil, vui: SPSRewriter.VUI?) -> Data {
        var w = SPSRewriter.BitWriter()
        w.write(0x67, bits: 8)
        w.write(profile, bits: 8)
        w.write(0xC0, bits: 8)
        w.write(30, bits: 8)
        w.writeUE(0)
        if profile == 100 {
            w.writeUE(1)              // chroma_format_idc
            w.writeUE(0); w.writeUE(0)
            w.write(0, bits: 1)
            w.write(1, bits: 1)       // seq_scaling_matrix_present_flag
            for i in 0..<8 {
                w.write(i % 2 == 0 ? 1 : 0, bits: 1)
                if i % 2 == 0 {       // a short list ending early with delta → 0
                    w.writeSE(3); w.writeSE(-11)
                }
            }
        }
        w.writeUE(0)                  // log2_max_frame_num_minus4
        w.writeUE(pocType)
        if pocType == 0 { w.writeUE(2) }
        if pocType == 1 {
            w.write(0, bits: 1); w.writeSE(-2); w.writeSE(1); w.writeUE(2); w.writeSE(4); w.writeSE(-4)
        }
        w.writeUE(refFrames)
        w.write(0, bits: 1)
        w.writeUE(14)                 // 240 px
        w.writeUE(24)                 // 400 px
        w.write(1, bits: 1)           // frame_mbs_only_flag
        w.write(1, bits: 1)
        if let cropping {
            w.write(1, bits: 1)
            cropping.forEach { w.writeUE($0) }
        } else {
            w.write(0, bits: 1)
        }
        if let vui {
            w.write(1, bits: 1)
            if let idc = vui.aspectRatioIDC {
                w.write(1, bits: 1); w.write(idc, bits: 8)
                if idc == 255 { w.write(vui.sarWidth, bits: 16); w.write(vui.sarHeight, bits: 16) }
            } else { w.write(0, bits: 1) }
            if let o = vui.overscanAppropriate { w.write(1, bits: 1); w.write(o ? 1 : 0, bits: 1) } else { w.write(0, bits: 1) }
            if let f = vui.videoFormat {
                w.write(1, bits: 1); w.write(f, bits: 3); w.write(vui.videoFullRange ? 1 : 0, bits: 1)
                if let c = vui.colourDescription { w.write(1, bits: 1); c.forEach { w.write($0, bits: 8) } } else { w.write(0, bits: 1) }
            } else { w.write(0, bits: 1) }
            if let c = vui.chromaLoc { w.write(1, bits: 1); c.forEach { w.writeUE($0) } } else { w.write(0, bits: 1) }
            if let t = vui.timing {
                w.write(1, bits: 1); w.write(t[0], bits: 32); w.write(t[1], bits: 32); w.write(t[2], bits: 1)
            } else { w.write(0, bits: 1) }
            for hrd in [vui.nalHRD, vui.vclHRD] {
                guard let hrd else { w.write(0, bits: 1); continue }
                w.write(1, bits: 1)
                w.writeUE(UInt32(hrd.cpbs.count - 1)); w.write(hrd.bitRateScale, bits: 4); w.write(hrd.cpbSizeScale, bits: 4)
                for c in hrd.cpbs { w.writeUE(c.bitRateValueMinus1); w.writeUE(c.cpbSizeValueMinus1); w.write(c.cbr ? 1 : 0, bits: 1) }
                for v in [hrd.initialCPBRemovalDelayLengthMinus1, hrd.cpbRemovalDelayLengthMinus1,
                          hrd.dpbOutputDelayLengthMinus1, hrd.timeOffsetLength] { w.write(v, bits: 5) }
            }
            if vui.nalHRD != nil || vui.vclHRD != nil { w.write(vui.lowDelayHRD == true ? 1 : 0, bits: 1) }
            w.write(vui.picStructPresent ? 1 : 0, bits: 1)
            if let r = vui.restriction {
                w.write(1, bits: 1); w.write(r.motionVectorsOverPicBoundaries ? 1 : 0, bits: 1)
                for v in [r.maxBytesPerPicDenom, r.maxBitsPerMBDenom, r.log2MaxMVLengthHorizontal,
                          r.log2MaxMVLengthVertical, r.maxNumReorderFrames, r.maxDecFrameBuffering] { w.writeUE(v) }
            } else { w.write(0, bits: 1) }
        } else {
            w.write(0, bits: 1)
        }
        w.write(1, bits: 1)
        w.alignWithZeros()
        return SPSRewriter.addEmulationPrevention(w.bytes)
    }

    /// Encodes one 240x400 frame with a raw VideoToolbox session set up like H264Encoder and
    /// returns its SPS as VideoToolbox wrote it.
    static func encodeOneFrameSPS(referenceBufferCount: Int?) throws -> Data {
        var session: VTCompressionSession?
        let st = VTCompressionSessionCreate(allocator: nil, width: 240, height: 400, codecType: kCMVideoCodecType_H264,
                                            encoderSpecification: nil, imageBufferAttributes: nil,
                                            compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                            compressionSessionOut: &session)
        let s = try #require(st == noErr ? session : nil)
        defer { VTCompressionSessionInvalidate(s) }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: 1_500_000 as CFNumber)
        if let referenceBufferCount {
            let st = VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ReferenceBufferCount,
                                          value: referenceBufferCount as CFNumber)
            print("S3DSKIT_SPS ReferenceBufferCount supported="
                  + "\(H264Encoder.supportsProperty(s, kVTCompressionPropertyKey_ReferenceBufferCount)) set status=\(st)")
        }
        let buffer = try EncoderTests().makeBuffer(height: 400, shade: 40)
        let box = SPSBox()
        VTCompressionSessionEncodeFrame(s, imageBuffer: buffer, presentationTimeStamp: .zero, duration: .invalid,
                                        frameProperties: nil, infoFlagsOut: nil) { status, _, sample in
            guard status == noErr, let sample, let format = CMSampleBufferGetFormatDescription(sample) else { return }
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                box.set(Data(bytes: ptr, count: size))
            }
        }
        VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
        return try #require(box.get())
    }

    final class SPSBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
        func get() -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    }
}

/// The first NAL of `type` in an Annex-B buffer (payload without start code).
func firstNAL(ofType type: UInt8, in annexB: Data) -> Data? {
    let b = [UInt8](annexB)
    var starts: [Int] = []
    var i = 0
    while i + 3 <= b.count {
        if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 { starts.append(i + 3); i += 3 } else { i += 1 }
    }
    for (k, s) in starts.enumerated() where s < b.count && b[s] & 0x1F == type {
        var end = k + 1 < starts.count ? starts[k + 1] - 3 : b.count
        while end > s, b[end - 1] == 0 { end -= 1 }   // zero byte of a 4-byte start code
        return Data(b[s..<end])
    }
    return nil
}
