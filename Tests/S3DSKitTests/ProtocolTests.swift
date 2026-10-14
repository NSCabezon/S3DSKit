import Foundation
import Testing
@testable import S3DSKit

@Suite("Wire protocol")
struct ProtocolTests {
    @Test func headerRoundTrip() throws {
        let h = S3DSProtocol.Header(type: .videoAU, flags: S3DSProtocol.keyframeFlag, length: 0x0001_E240)
        let bytes = h.encoded()
        #expect(Array(bytes) == [0x53, 0x33, 0x44, 0x53, 0x01, 0x01, 0x00, 0x00, 0x00, 0x01, 0xE2, 0x40])
        let decoded = try S3DSProtocol.decodeHeader(bytes)
        #expect(decoded == h)
        #expect(decoded.messageType == .videoAU)
    }

    @Test func keyframeRequestHeader() throws {
        let d = S3DSProtocol.message(.keyframeRequest)
        #expect(d.count == 12)
        let h = try S3DSProtocol.decodeHeader(d)
        #expect(h.messageType == .keyframeRequest && h.length == 0 && h.flags == 0)
    }

    @Test func rejectsBadInput() {
        #expect(throws: S3DSProtocol.DecodeError.tooShort) { try S3DSProtocol.decodeHeader([UInt8](repeating: 0, count: 11)) }
        var bad = Array(S3DSProtocol.message(.hello))
        bad[0] = 0x58
        #expect(throws: S3DSProtocol.DecodeError.badMagic) { try S3DSProtocol.decodeHeader(bad) }
        let huge = S3DSProtocol.Header(type: .videoAU, length: UInt32(S3DSProtocol.maxPayloadLength + 1)).encoded()
        #expect(throws: S3DSProtocol.DecodeError.payloadTooLarge(UInt32(S3DSProtocol.maxPayloadLength + 1))) {
            try S3DSProtocol.decodeHeader(huge)
        }
    }

    @Test func videoFlags() {
        #expect(S3DSProtocol.videoFlags(isKeyframe: true, eye: nil) == 0x01)
        #expect(S3DSProtocol.videoFlags(isKeyframe: false, eye: nil) == 0x00)
        #expect(S3DSProtocol.videoFlags(isKeyframe: true, eye: .left) == 0x05)
        #expect(S3DSProtocol.videoFlags(isKeyframe: false, eye: .left) == 0x04)
        #expect(S3DSProtocol.videoFlags(isKeyframe: false, eye: .right) == 0x06)
    }

    @Test func helloTruncatesOnScalarBoundary() throws {
        let name = String(repeating: "é", count: 40)   // 80 UTF-8 bytes
        let msg = S3DSProtocol.hello(name: name)
        let h = try S3DSProtocol.decodeHeader(msg)
        #expect(h.messageType == .hello)
        #expect(h.length == 64)
        #expect(String(data: msg.dropFirst(12), encoding: .utf8) == String(repeating: "é", count: 32))
    }
}

@Suite("AVCC to Annex-B")
struct AnnexBTests {
    let sps: [UInt8] = [0x67, 0x42, 0xC0, 0x1E, 0xAA]
    let pps: [UInt8] = [0x68, 0xCE, 0x3C, 0x80]

    func avcc(_ nals: [[UInt8]], lengthSize: Int = 4) -> Data {
        var d = Data()
        for n in nals {
            for k in (0..<lengthSize).reversed() { d.append(UInt8((n.count >> (8 * k)) & 0xFF)) }
            d.append(contentsOf: n)
        }
        return d
    }

    @Test func convertsNonKeyframe() throws {
        let p1: [UInt8] = [0x41, 0x9A, 0x01, 0x02]
        let out = try #require(AnnexB.convert(avcc: avcc([p1]), nalLengthSize: 4))
        #expect(Array(out) == [0, 0, 0, 1] + p1)
    }

    @Test func prependsParameterSetsOnKeyframe() throws {
        let idr: [UInt8] = [0x65, 0x88, 0x84, 0x00, 0x10]
        let out = try #require(AnnexB.convert(avcc: avcc([idr]), nalLengthSize: 4,
                                              parameterSets: [Data(sps), Data(pps)]))
        #expect(Array(out) == [0, 0, 0, 1] + sps + [0, 0, 0, 1] + pps + [0, 0, 0, 1] + idr)
    }

    @Test func dropsAUDSEIAndDuplicateParameterSets() throws {
        let aud: [UInt8] = [0x09, 0xF0]
        let sei: [UInt8] = [0x06, 0x05, 0x01, 0x80]
        let idr: [UInt8] = [0x65, 0x11]
        let input = avcc([aud, sei, sps, pps, idr], lengthSize: 2)
        let out = try #require(AnnexB.convert(avcc: input, nalLengthSize: 2, parameterSets: [Data(sps), Data(pps)]))
        #expect(Array(out) == [0, 0, 0, 1] + sps + [0, 0, 0, 1] + pps + [0, 0, 0, 1] + idr)
    }

    @Test func rejectsMalformed() {
        #expect(AnnexB.convert(avcc: Data([0, 0, 0, 9, 0x41]), nalLengthSize: 4) == nil)
        #expect(AnnexB.convert(avcc: Data([0, 0]), nalLengthSize: 4) == nil)
        #expect(AnnexB.convert(avcc: Data([0x41]), nalLengthSize: 3) == nil)
    }
}
