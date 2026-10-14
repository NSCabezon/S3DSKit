import CoreVideo
import Metal
import Testing
@testable import S3DSKit

@Suite("Rotate/stack kernel (GPU)")
struct KernelTests {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let rotator: FrameRotator
    let alternatingRotator: FrameRotator

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        queue = try #require(device.makeCommandQueue())
        rotator = try FrameRotator(device: device, layout: .stacked240x800)
        alternatingRotator = try FrameRotator(device: device, layout: .alternating240x400)
    }

    /// Runs the stacked rotator; returns the 240x800 frame.
    func run(left: any MTLTexture, right: any MTLTexture, fit: S3DSFit = .letterbox, flipY: Bool = false,
             prepare: (any MTLCommandBuffer) -> Void) throws -> PixelReader {
        try runFrames(rotator, left: left, right: right, fit: fit, flipY: flipY, prepare: prepare)[0]
    }

    func runFrames(_ rotator: FrameRotator, left: any MTLTexture, right: any MTLTexture,
                   fit: S3DSFit = .letterbox, flipY: Bool = false,
                   prepare: (any MTLCommandBuffer) -> Void) throws -> [PixelReader] {
        let cb = try #require(queue.makeCommandBuffer())
        prepare(cb)
        let pbs = try #require(rotator.encode(left: left, right: right, fit: fit, flipY: flipY, into: cb))
        cb.commit()
        cb.waitUntilCompleted()
        #expect(cb.status == .completed)
        return pbs.map { PixelReader(pixelBuffer: $0) }
    }

    /// Alternating layout: two 240x400 frames, each the eye's image rotated 90° CW.
    @Test func alternatingExactMapping() throws {
        let fill = try TestShaders.compute(device, "fill_pattern")
        let l = try TestShaders.texture(device, 400, 240), r = try TestShaders.texture(device, 400, 240)
        let frames = try runFrames(alternatingRotator, left: l, right: r) { cb in
            TestShaders.dispatch(cb, fill, l, UInt32(0))
            TestShaders.dispatch(cb, fill, r, UInt32(1))
        }
        try #require(frames.count == 2)
        var mismatches = 0
        for (eyeIndex, px) in frames.enumerated() {
            #expect(px.width == 240 && px.height == 400)
            for row in 0..<400 {
                for col in 0..<240 {
                    let e = RotationMapping.eyePixel(forBlockColumn: col, row: row)
                    let (b, g, rr, _) = px.bgra(col, row)
                    if (rr, g, b) != (UInt8(e.x % 256), UInt8(e.y % 256), UInt8(eyeIndex * 128 + e.x / 256)) {
                        mismatches += 1
                    }
                }
            }
        }
        #expect(mismatches == 0)
        // Left eye (0,0) is the top-right pixel (c=239, r=0) of the left frame.
        #expect(frames[0].bgra(239, 0) == (0, 0, 0, 255))
        #expect(frames[1].bgra(239, 0) == (128, 0, 0, 255))
    }

    /// Every output pixel equals the eye pixel the contract mapping names (exact 400x240 input).
    @Test func exactMappingAllPixels() throws {
        let fill = try TestShaders.compute(device, "fill_pattern")
        let l = try TestShaders.texture(device, 400, 240), r = try TestShaders.texture(device, 400, 240)
        let px = try run(left: l, right: r) { cb in
            TestShaders.dispatch(cb, fill, l, UInt32(0))
            TestShaders.dispatch(cb, fill, r, UInt32(1))
        }
        var mismatches = 0
        for row in 0..<800 {
            for col in 0..<240 {
                let e = RotationMapping.eyePixel(forFrameColumn: col, row: row)
                let (b, g, rr, _) = px.bgra(col, row)
                let expected = (UInt8(e.x % 256), UInt8(e.y % 256), UInt8(e.eye.rawValue * 128 + e.x / 256))
                if (rr, g, b) != expected { mismatches += 1 }
            }
        }
        #expect(mismatches == 0)
        // Spot-check the documented corner: left (0,0) → (c=239, r=0); right (399,239) → (0,799).
        #expect(px.bgra(239, 0).2 == 0 && px.bgra(239, 0).1 == 0 && px.bgra(239, 0).0 == 0)
        #expect(px.bgra(0, 799).2 == UInt8(399 % 256) && px.bgra(0, 799).1 == 239 && px.bgra(0, 799).0 == 129)
    }

    @Test func monoUsesLeftForBothEyes() throws {
        let fill = try TestShaders.compute(device, "fill_pattern")
        let l = try TestShaders.texture(device, 400, 240)
        let px = try run(left: l, right: l) { cb in TestShaders.dispatch(cb, fill, l, UInt32(0)) }
        for (col, row) in [(239, 0), (100, 123), (0, 399)] {
            let top = px.bgra(col, row), bottom = px.bgra(col, row + 400)
            #expect(top == bottom)
        }
    }

    @Test func flipY() throws {
        let fill = try TestShaders.compute(device, "fill_pattern")
        let l = try TestShaders.texture(device, 400, 240)
        let px = try run(left: l, right: l, flipY: true) { cb in TestShaders.dispatch(cb, fill, l, UInt32(0)) }
        // Eye (0,0) now shows source row 239.
        #expect(px.bgra(239, 0).1 == 239)
    }

    /// 1920x1440 white source, letterboxed: eye columns 40..359 white, bars black.
    @Test func letterboxLargeSource() throws {
        let fill = try TestShaders.compute(device, "fill_solid")
        let big = try TestShaders.texture(device, 1920, 1440)
        let px = try run(left: big, right: big) { cb in TestShaders.dispatch(cb, fill, big, SIMD4<Float>(1, 1, 1, 1)) }
        func eye(_ x: Int, _ y: Int) -> UInt8 {
            let p = RotationMapping.framePixel(eye: .left, x: x, y: y)
            return px.bgra(p.column, p.row).2
        }
        #expect(eye(0, 120) == 0)
        #expect(eye(39, 120) == 0)
        #expect(eye(40, 120) == 255)
        #expect(eye(200, 0) == 255)
        #expect(eye(359, 239) == 255)
        #expect(eye(360, 120) == 0)
        #expect(eye(399, 120) == 0)
    }

    /// sRGB textures are read decoded and re-encoded: values survive the round trip.
    @Test func srgbInputPreservesEncodedValues() throws {
        let fill = try TestShaders.compute(device, "fill_solid")
        let tex = try TestShaders.texture(device, 400, 240, .rgba8Unorm)
        let view = try #require(tex.makeTextureView(pixelFormat: .rgba8Unorm_srgb))
        // Write raw 0.5 (=128) through the Unorm texture, read through the sRGB view.
        let px = try run(left: view, right: view) { cb in TestShaders.dispatch(cb, fill, tex, SIMD4<Float>(0.5, 0.5, 0.5, 1)) }
        let v = px.bgra(100, 100).2
        #expect(abs(Int(v) - 128) <= 1)
    }
}
