import simd

/// How a source image whose aspect ratio is not 5:3 is fitted into a 400x240 eye image.
public enum S3DSFit: Sendable, Equatable {
    /// Keep the aspect ratio and add black bars (4:3 → 320x240 centered). Default.
    case letterbox
    /// Keep the aspect ratio and fill the eye, cutting the excess (4:3 → top/bottom cut).
    case crop
    /// Ignore the aspect ratio.
    case stretch
}

/// The mapping from eye image coordinates to source texture coordinates.
///
/// For an eye pixel center `p` in normalized eye coordinates (`(x + 0.5) / 400`, `(y + 0.5) / 240`),
/// the source coordinate is `uv = (p - offset) * scale`; a `uv` outside `[0, 1]` is black.
public struct S3DSFitTransform: Sendable, Equatable {
    public var scale: SIMD2<Float>
    public var offset: SIMD2<Float>

    /// Computes the transform for a `sourceWidth` x `sourceHeight` image into an eye of the
    /// given size (default 400x240).
    public init(sourceWidth: Int, sourceHeight: Int, fit: S3DSFit,
                eyeWidth: Int = RotationMapping.eyeWidth, eyeHeight: Int = RotationMapping.eyeHeight) {
        let a = Float(max(1, sourceWidth)) / Float(max(1, sourceHeight))   // source aspect
        let e = Float(eyeWidth) / Float(eyeHeight)                         // eye aspect
        var s = SIMD2<Float>(1, 1)
        switch fit {
        case .stretch:
            break
        case .letterbox:
            if a < e { s.x = e / a } else { s.y = a / e }
        case .crop:
            if a < e { s.y = a / e } else { s.x = e / a }
        }
        scale = s
        offset = 0.5 - 0.5 / s
    }

    /// Source texture coordinate for eye pixel `(x, y)`, or nil when it falls in a black bar.
    public func sourceUV(eyeX x: Int, eyeY y: Int,
                         eyeWidth: Int = RotationMapping.eyeWidth,
                         eyeHeight: Int = RotationMapping.eyeHeight) -> SIMD2<Float>? {
        let p = SIMD2<Float>((Float(x) + 0.5) / Float(eyeWidth), (Float(y) + 0.5) / Float(eyeHeight))
        let uv = (p - offset) * scale
        guard uv.x >= 0, uv.x <= 1, uv.y >= 0, uv.y <= 1 else { return nil }
        return uv
    }
}
