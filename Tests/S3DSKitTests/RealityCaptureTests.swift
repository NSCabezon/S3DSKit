import CoreGraphics
import Foundation
import RealityKit
import Testing
import simd
@testable import S3DSKit

@Suite("RealityKit adapter")
@MainActor
struct RealityCaptureTests {
    /// Renders a red unlit box 1 m in front of the camera and checks the preview's eye centers.
    @Test func rendersEntityIntoBothEyes() async throws {
        let streamer = S3DSStreamer()
        streamer.isPreviewEnabled = true
        let capture = try S3DSRealityCapture(streamer: streamer)
        let box = ModelEntity(mesh: .generateBox(size: 0.4),
                              materials: [UnlitMaterial(color: .init(red: 1, green: 0, blue: 0, alpha: 1))])
        box.position = [0, 0, -1]
        capture.renderer.entities.append(box)

        let got = await waitUntil(timeout: .seconds(5)) {
            _ = try? capture.capture(headTransform: matrix_identity_float4x4, deltaTime: 1.0 / 30)
            return streamer.previewImage != nil
        }
        try #require(got)
        let image = try #require(streamer.previewImage)
        // Sample the centers of the left (200,120) and right (600,120) halves.
        for x in [200, 600] {
            let px = try #require(pixel(image, x: x, y: 120))
            #expect(px.r > 150 && px.g < 80 && px.b < 80, "eye center at x=\(x) is \(px)")
        }
        let corner = try #require(pixel(image, x: 5, y: 5))
        #expect(corner.r < 40)   // black background
    }

    func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
        var buf = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &buf, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(buf[0]), Int(buf[1]), Int(buf[2]))
    }
}
