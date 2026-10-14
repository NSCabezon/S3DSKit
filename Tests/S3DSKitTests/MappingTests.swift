import Metal
import Testing
import simd
@testable import S3DSKit

@Suite("Rotation mapping")
struct RotationMappingTests {
    @Test func corners() {
        // Left eye top-left (0,0) is the top-right pixel of the 240x800 frame.
        #expect(RotationMapping.framePixel(eye: .left, x: 0, y: 0) == (239, 0))
        #expect(RotationMapping.framePixel(eye: .left, x: 399, y: 0) == (239, 399))
        #expect(RotationMapping.framePixel(eye: .left, x: 0, y: 239) == (0, 0))
        #expect(RotationMapping.framePixel(eye: .left, x: 399, y: 239) == (0, 399))
        #expect(RotationMapping.framePixel(eye: .right, x: 0, y: 0) == (239, 400))
        #expect(RotationMapping.framePixel(eye: .right, x: 399, y: 239) == (0, 799))
    }

    @Test func forwardMatchesContract() {
        let p = RotationMapping.eyePixel(forFrameColumn: 239, row: 0)
        #expect(p.eye == .left && p.x == 0 && p.y == 0)
        let q = RotationMapping.eyePixel(forFrameColumn: 0, row: 799)
        #expect(q.eye == .right && q.x == 399 && q.y == 239)
        let m = RotationMapping.eyePixel(forFrameColumn: 100, row: 450)
        #expect(m.eye == .right && m.x == 50 && m.y == 139)
    }

    @Test func alternatingBlockMapping() {
        #expect(RotationMapping.blockPixel(x: 0, y: 0) == (239, 0))
        #expect(RotationMapping.blockPixel(x: 399, y: 239) == (0, 399))
        #expect(RotationMapping.blockPixel(x: 10, y: 20) == (219, 10))
        for (c, r) in [(0, 0), (239, 399), (17, 250)] {
            let e = RotationMapping.eyePixel(forBlockColumn: c, row: r)
            #expect(RotationMapping.blockPixel(x: e.x, y: e.y) == (c, r))
        }
    }

    @Test func inverseRoundTripsEveryPixel() {
        for r in 0..<800 {
            for c in 0..<240 {
                let e = RotationMapping.eyePixel(forFrameColumn: c, row: r)
                let f = RotationMapping.framePixel(eye: e.eye, x: e.x, y: e.y)
                guard f == (c, r) else {
                    Issue.record("mismatch at c=\(c) r=\(r)")
                    return
                }
            }
        }
    }
}

@Suite("Fit transform")
struct FitTests {
    @Test func letterbox4x3() throws {
        // 1920x1440 (4:3) into 400x240 → 320x240 centered: columns 40..359 visible.
        let t = S3DSFitTransform(sourceWidth: 1920, sourceHeight: 1440, fit: .letterbox)
        #expect(abs(t.scale.x - 1.25) < 1e-6 && t.scale.y == 1)
        #expect(abs(t.offset.x - 0.1) < 1e-6 && t.offset.y == 0)
        #expect(t.sourceUV(eyeX: 39, eyeY: 120) == nil)
        #expect(t.sourceUV(eyeX: 360, eyeY: 120) == nil)
        let first = try #require(t.sourceUV(eyeX: 40, eyeY: 0))
        let last = try #require(t.sourceUV(eyeX: 359, eyeY: 239))
        #expect(abs(first.x - 0.5 / 320) < 1e-5)       // first source pixel column center
        #expect(abs(last.x - (1 - 0.5 / 320)) < 1e-5)
        #expect(abs(last.y - (1 - 0.5 / 240)) < 1e-5)
    }

    @Test func letterboxWide() throws {
        // 2:1 into 5:3 → full width, 200 rows tall, bars of 20 rows.
        let t = S3DSFitTransform(sourceWidth: 2000, sourceHeight: 1000, fit: .letterbox)
        #expect(t.sourceUV(eyeX: 200, eyeY: 19) == nil)
        #expect(t.sourceUV(eyeX: 200, eyeY: 20) != nil)
        #expect(t.sourceUV(eyeX: 200, eyeY: 219) != nil)
        #expect(t.sourceUV(eyeX: 200, eyeY: 220) == nil)
    }

    @Test func crop4x3() throws {
        // 4:3 filling 400 wide → 300 rows of which the middle 240 are visible (30 cut each side).
        let t = S3DSFitTransform(sourceWidth: 1920, sourceHeight: 1440, fit: .crop)
        let top = try #require(t.sourceUV(eyeX: 0, eyeY: 0))
        #expect(abs(top.y - 30.5 / 300) < 1e-5)
        #expect(abs(top.x - 0.5 / 400) < 1e-5)
    }

    @Test func stretchAndExact() throws {
        let s = S3DSFitTransform(sourceWidth: 1920, sourceHeight: 1440, fit: .stretch)
        #expect(s.scale == SIMD2(1, 1) && s.offset == SIMD2(0, 0))
        let e = S3DSFitTransform(sourceWidth: 400, sourceHeight: 240, fit: .letterbox)
        #expect(e.scale == SIMD2(1, 1) && e.offset == SIMD2(0, 0))
    }

    @Test func tapCounts() {
        let exact = S3DSFitTransform(sourceWidth: 400, sourceHeight: 240, fit: .letterbox)
        #expect(FrameRotator.tapCount(sourceWidth: 400, sourceHeight: 240, scale: exact.scale) == 1)
        let big = S3DSFitTransform(sourceWidth: 1920, sourceHeight: 1440, fit: .letterbox)
        #expect(FrameRotator.tapCount(sourceWidth: 1920, sourceHeight: 1440, scale: big.scale) == 3)
        #expect(FrameRotator.tapCount(sourceWidth: 8000, sourceHeight: 4800, scale: SIMD2(1, 1)) == 4)
    }

    @Test func formatsReadLinear() {
        #expect(!FrameRotator.readsLinear(.rgba8Unorm))
        #expect(!FrameRotator.readsLinear(.bgra8Unorm))
        #expect(FrameRotator.readsLinear(.rgba8Unorm_srgb))
        #expect(FrameRotator.readsLinear(.bgra8Unorm_srgb))
        #expect(FrameRotator.readsLinear(.rgba16Float))
    }
}

@Suite("Stereo camera")
struct StereoCameraTests {
    @Test func eyesAreSeparated() {
        var cam = StereoCamera()
        cam.depthMultiplier = 2
        var head = matrix_identity_float4x4
        head.columns.3 = SIMD4(0, 1.5, 0, 1)
        let l = cam.eyePose(.left, headTransform: head), r = cam.eyePose(.right, headTransform: head)
        #expect(abs(distance(l.position, r.position) - 0.126) < 1e-5)
        #expect(l.position.x < r.position.x)
    }

    @Test func reverseZDepthRange() {
        let cam = StereoCamera()
        let p = cam.eyePose(.left, headTransform: matrix_identity_float4x4).projection
        let near = p * SIMD4<Float>(0, 0, -cam.nearZ, 1)
        let far = p * SIMD4<Float>(0, 0, -cam.farZ, 1)
        #expect(abs(near.z / near.w - 1) < 1e-4)
        #expect(abs(far.z / far.w) < 1e-4)
    }

    @Test func convergencePlaneHasZeroParallax() {
        let cam = StereoCamera()   // converges at 1.5 m
        let point = SIMD4<Float>(0, 0, -1.5, 1)
        func ndcX(_ eye: S3DSEye) -> Float {
            let pose = cam.eyePose(eye, headTransform: matrix_identity_float4x4)
            let c = pose.viewProjection * point
            return c.x / c.w
        }
        #expect(abs(ndcX(.left) - ndcX(.right)) < 1e-4)
    }
}
