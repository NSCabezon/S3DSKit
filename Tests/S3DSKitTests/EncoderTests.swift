import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import Testing
@testable import S3DSKit

@Suite("H.264 encoder")
struct EncoderTests {
    final class Collector: Sendable {
        let items = Mutex<[(data: Data, key: Bool, eye: S3DSEye?)]>([])
    }

    func makeBuffer(height: Int, shade: UInt8) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        let st = CVPixelBufferCreate(nil, 240, height, kCVPixelFormatType_32BGRA, attrs, &pb)
        let buffer = try #require(st == kCVReturnSuccess ? pb : nil)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<240 {
                let p = base + y * stride + x * 4
                p[0] = UInt8(truncatingIfNeeded: x &+ Int(shade)); p[1] = UInt8(truncatingIfNeeded: y); p[2] = shade; p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// A keyframe requested while a right frame is next is deferred to the following left frame;
    /// no right frame is ever an IDR.
    @Test func alternatingKeyframesOnlyOnLeft() throws {
        let collector = Collector()
        let encoder = H264Encoder(settings: .init(layout: .alternating240x400, fps: 30, keyframeInterval: 30,
                                                  minForcedKeyframeInterval: 0)) {
            data, key, eye in collector.items.withLock { $0.append((data, key, eye)) }
        }
        var t = 0.0
        for pair in 0..<12 {
            let l = try makeBuffer(height: 400, shade: UInt8(pair * 10))
            let r = try makeBuffer(height: 400, shade: UInt8(pair * 10 + 5))
            encoder.encode(l, presentationTime: CMTime(seconds: t, preferredTimescale: 600), eye: .left)
            t += 1.0 / 60
            if pair == 5 { encoder.forceKeyframe() }   // requested just before a right frame
            encoder.encode(r, presentationTime: CMTime(seconds: t, preferredTimescale: 600), eye: .right)
            t += 1.0 / 60
        }
        encoder.reset()   // flushes pending frames
        let items = collector.items.withLock { $0 }
        try #require(items.count == 24)
        #expect(items.map(\.eye) == (0..<24).map { $0 % 2 == 0 ? S3DSEye.left : .right })
        let keyIndices = items.indices.filter { items[$0].key }
        #expect(keyIndices == [0, 12])   // first frame, and the left frame of pair 6
        for i in keyIndices { #expect(Array(nalTypes(items[i].data).prefix(3)) == [7, 8, 5]) }
    }

    @Test func alternatingCadenceIsOneSecond() throws {
        let collector = Collector()
        let encoder = H264Encoder(settings: .init(layout: .alternating240x400, fps: 30, keyframeInterval: 10)) {
            data, key, eye in collector.items.withLock { $0.append((data, key, eye)) }
        }
        var t = 0.0
        for pair in 0..<25 {
            for eye in S3DSEye.allCases {
                let b = try makeBuffer(height: 400, shade: UInt8(pair * 9 + eye.rawValue))
                encoder.encode(b, presentationTime: CMTime(seconds: t, preferredTimescale: 600), eye: eye)
                t += 1.0 / 60
            }
        }
        encoder.reset()
        let items = collector.items.withLock { $0 }
        let keyIndices = items.indices.filter { items[$0].key }
        #expect(keyIndices == [0, 20, 40])   // every 10 pairs, always left
    }

    @Test func stackedEncodesWithoutEye() throws {
        let collector = Collector()
        let encoder = H264Encoder(settings: .init(layout: .stacked240x800, fps: 30, keyframeInterval: 30)) {
            data, key, eye in collector.items.withLock { $0.append((data, key, eye)) }
        }
        for i in 0..<5 {
            let b = try makeBuffer(height: 800, shade: UInt8(i * 20))
            encoder.encode(b, presentationTime: CMTime(value: CMTimeValue(i), timescale: 30), eye: nil)
        }
        encoder.reset()
        let items = collector.items.withLock { $0 }
        try #require(items.count == 5)
        #expect(items.allSatisfy { $0.eye == nil })
        #expect(items[0].key && !items[1].key)
    }

    /// Records which encoder each session request asked for; can lie about the result.
    final class FactorySpy: Sendable {
        let requests = Mutex<[Bool]>([])   // `software` flag per request
        let claimHardware: Bool?
        init(claimHardware: Bool? = nil) { self.claimHardware = claimHardware }

        var factory: H264Encoder.SessionFactory {
            { [self] settings, software in
                requests.withLock { $0.append(software) }
                guard var info = H264Encoder.makeSession(settings: settings, software: software) else { return nil }
                if let claimHardware { info.isHardware = claimHardware }
                return info
            }
        }
    }

    /// `.automatic` (the default) asks VideoToolbox for the software encoder.
    @Test func automaticUsesSoftwareEncoder() throws {
        let spy = FactorySpy()
        let collector = Collector()
        let encoder = H264Encoder(settings: .init(), sessionFactory: spy.factory) {
            data, key, eye in collector.items.withLock { $0.append((data, key, eye)) }
        }
        encoder.encode(try makeBuffer(height: 400, shade: 1), presentationTime: .zero, eye: .left)
        encoder.reset()
        #expect(spy.requests.withLock { $0 } == [true])
        #expect(encoder.isHardware == false)
        #expect(collector.items.withLock { $0.count } == 1)
        #expect(encoder.multiSlicePicturesDropped == 0)
    }

    /// `.hardware` keeps VideoToolbox's default choice.
    @Test func hardwarePreferenceUsesDefaultSpecification() throws {
        let spy = FactorySpy()
        let encoder = H264Encoder(settings: .init(encoder: .hardware), sessionFactory: spy.factory) { _, _, _ in }
        encoder.encode(try makeBuffer(height: 400, shade: 1), presentationTime: .zero, eye: .left)
        encoder.reset()
        #expect(spy.requests.withLock { $0 } == [false])
    }

    /// A multi-slice picture from a hardware session rebuilds the session on the software encoder
    /// exactly once, with an IDR on the next left frame; later multi-slice pictures are only dropped.
    @Test func multiSliceOnHardwareRebuildsOnceOnSoftware() throws {
        let spy = FactorySpy(claimHardware: true)   // pretend every session is hardware
        let collector = Collector()
        let encoder = H264Encoder(settings: .init(minForcedKeyframeInterval: 0), sessionFactory: spy.factory) {
            data, key, eye in collector.items.withLock { $0.append((data, key, eye)) }
        }
        var t = 0.0
        func pair(_ shade: UInt8) throws {
            for eye in S3DSEye.allCases {
                let b = try makeBuffer(height: 400, shade: shade &+ UInt8(eye.rawValue))
                encoder.encode(b, presentationTime: CMTime(seconds: t, preferredTimescale: 600), eye: eye)
                t += 1.0 / 60
            }
        }
        try pair(0); try pair(10)
        #expect(spy.requests.withLock { $0 }.count == 1)

        encoder.handleMultiSlicePicture(slices: 3, sessionIsHardware: true)
        #expect(encoder.softwareRebuilds == 1 && encoder.multiSlicePicturesDropped == 1)
        try pair(20)
        #expect(spy.requests.withLock { $0 } == [true, true])   // rebuilt, on software

        encoder.handleMultiSlicePicture(slices: 3, sessionIsHardware: true)   // "software" still splits
        try pair(30); try pair(40)
        encoder.reset()
        #expect(encoder.softwareRebuilds == 1)                     // never a second rebuild
        #expect(encoder.multiSlicePicturesDropped == 2)
        #expect(spy.requests.withLock { $0 }.count == 2)

        let items = collector.items.withLock { $0 }
        #expect(items.map(\.eye) == (0..<items.count).map { $0 % 2 == 0 ? S3DSEye.left : .right })
        let keyIndices = items.indices.filter { items[$0].key }
        #expect(keyIndices.allSatisfy { items[$0].eye == .left })
        // IDRs: first frame, the rebuilt session's first frame (pair 2), and the forced one (pair 3).
        #expect(keyIndices == [0, 4, 6])
    }

    /// `.hardware` never switches encoders, even on multi-slice pictures.
    @Test func hardwarePreferenceNeverRebuilds() {
        let encoder = H264Encoder(settings: .init(encoder: .hardware)) { _, _, _ in }
        encoder.handleMultiSlicePicture(slices: 2, sessionIsHardware: true)
        #expect(encoder.softwareRebuilds == 0 && encoder.multiSlicePicturesDropped == 1)
    }
}
