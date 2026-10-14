import CoreGraphics
import CoreVideo
import Foundation

/// Converts encoded-layout BGRA frames back into an 800x240 side-by-side image
/// (left eye | right eye) for on-screen previews.
public enum SideBySidePreview {
    /// From one stacked 240x800 `32BGRA` frame. Returns nil on a size/format mismatch.
    public static func makeImage(fromStacked pixelBuffer: CVPixelBuffer) -> CGImage? {
        guard check(pixelBuffer, height: 800) else { return nil }
        return render { eye, body in
            withPixels(pixelBuffer) { src, stride in body(src + eye.rawValue * 400 * stride, stride) }
        }
    }

    /// From a pair of alternating-layout 240x400 `32BGRA` frames. Returns nil on a mismatch.
    public static func makeImage(left: CVPixelBuffer, right: CVPixelBuffer) -> CGImage? {
        guard check(left, height: 400), check(right, height: 400) else { return nil }
        return render { eye, body in
            withPixels(eye == .left ? left : right) { src, stride in body(src, stride) }
        }
    }

    private static func check(_ pb: CVPixelBuffer, height: Int) -> Bool {
        CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA
            && CVPixelBufferGetWidth(pb) == 240 && CVPixelBufferGetHeight(pb) == height
    }

    private static func withPixels(_ pb: CVPixelBuffer, _ body: (UnsafePointer<UInt32>, Int) -> Void) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        body(UnsafePointer(base.assumingMemoryBound(to: UInt32.self)), CVPixelBufferGetBytesPerRow(pb) / 4)
    }

    /// `eyeBlock(eye, body)` must call `body` with a pointer to that eye's rotated 240x400 block.
    private static func render(
        _ eyeBlock: (S3DSEye, (UnsafePointer<UInt32>, Int) -> Void) -> Void
    ) -> CGImage? {
        let ew = RotationMapping.eyeWidth, eh = RotationMapping.eyeHeight
        let outW = ew * 2
        var out = [UInt32](repeating: 0, count: outW * eh)
        for eye in S3DSEye.allCases {
            eyeBlock(eye) { src, stride in
                for y in 0..<eh {
                    for x in 0..<ew {
                        let p = RotationMapping.blockPixel(x: x, y: y)
                        out[y * outW + eye.rawValue * ew + x] = src[p.row * stride + p.column]
                    }
                }
            }
        }
        let data = out.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        // 32BGRA in memory == 32-bit little-endian ARGB with the alpha byte ignored.
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                | CGImageAlphaInfo.noneSkipFirst.rawValue)
        return CGImage(width: outW, height: eh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: outW * 4,
                       space: space, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
