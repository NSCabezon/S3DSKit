import simd

/// Which eye.
public enum S3DSEye: Int, Sendable, CaseIterable {
    case left = 0
    case right = 1
}

/// A virtual stereo camera matching the 3DS top screen (400x240 per eye, 5:3).
///
/// Coordinate conventions: right-handed, camera looks down -Z, +Y up (same as ARKit /
/// Compositor Services `.rightUpBack`). Projections map depth to Metal's [0, 1] NDC range,
/// reversed by default (near = 1, far = 0; use `.greater` depth compare and clear depth to 0).
public struct StereoCamera: Sendable, Equatable {
    /// Base interpupillary distance in meters.
    public var interpupillaryDistance: Float = 0.063
    /// Multiplies the IPD: > 1 exaggerates depth, < 1 flattens it.
    public var depthMultiplier: Float = 1
    /// Vertical field of view in radians.
    public var verticalFieldOfView: Float = 40 * .pi / 180
    /// Width / height of each eye image.
    public var aspectRatio: Float = 5.0 / 3.0
    public var nearZ: Float = 0.05
    public var farZ: Float = 100
    /// Distance (m) of the zero-parallax plane (objects there appear at the 3DS screen surface).
    /// `nil` = parallel eyes with symmetric frusta (zero parallax at infinity, everything pops out).
    public var convergenceDistance: Float? = 1.5
    /// Reverse-Z projection (near → 1, far → 0).
    public var reverseZ: Bool = true

    public init() {}

    public init(interpupillaryDistance: Float = 0.063, depthMultiplier: Float = 1,
                verticalFieldOfView: Float = 40 * .pi / 180, convergenceDistance: Float? = 1.5) {
        self.interpupillaryDistance = interpupillaryDistance
        self.depthMultiplier = depthMultiplier
        self.verticalFieldOfView = verticalFieldOfView
        self.convergenceDistance = convergenceDistance
    }

    /// Effective eye separation in meters.
    public var eyeSeparation: Float { interpupillaryDistance * depthMultiplier }

    /// Per-eye camera parameters.
    public struct EyePose: Sendable {
        public var eye: S3DSEye
        /// World-from-eye transform (the eye's camera transform in world space).
        public var worldFromEye: simd_float4x4
        /// Eye-from-world (view) matrix.
        public var view: simd_float4x4
        /// Projection matrix.
        public var projection: simd_float4x4
        /// `projection * view`.
        public var viewProjection: simd_float4x4 { projection * view }
        /// Eye position in world space.
        public var position: SIMD3<Float> {
            SIMD3(worldFromEye.columns.3.x, worldFromEye.columns.3.y, worldFromEye.columns.3.z)
        }
    }

    /// Computes the eye pose for a head (or camera) transform in world space, e.g. an ARKit
    /// `DeviceAnchor.originFromAnchorTransform`. The eyes sit at ±separation/2 along the head's +X.
    public func eyePose(_ eye: S3DSEye, headTransform: simd_float4x4) -> EyePose {
        let offset = (eye == .left ? -0.5 : 0.5) * eyeSeparation
        var local = matrix_identity_float4x4
        local.columns.3 = SIMD4(offset, 0, 0, 1)
        let worldFromEye = headTransform * local
        return EyePose(eye: eye, worldFromEye: worldFromEye, view: worldFromEye.inverse,
                       projection: projection(eyeOffset: offset))
    }

    /// Both eye poses.
    public func eyePoses(headTransform: simd_float4x4) -> [EyePose] {
        S3DSEye.allCases.map { eyePose($0, headTransform: headTransform) }
    }

    /// Projection for an eye displaced `eyeOffset` meters along X (off-axis when converging).
    func projection(eyeOffset: Float) -> simd_float4x4 {
        let n = nearZ, f = farZ
        let top = n * tan(verticalFieldOfView / 2)
        let halfWidth = top * aspectRatio
        let shift = convergenceDistance.map { -eyeOffset * n / max($0, 0.001) } ?? 0
        return Self.offCenterPerspective(left: -halfWidth + shift, right: halfWidth + shift,
                                         bottom: -top, top: top, near: n, far: f, reverseZ: reverseZ)
    }

    /// Right-handed off-center perspective with Metal clip depth [0, 1].
    public static func offCenterPerspective(left l: Float, right r: Float, bottom b: Float, top t: Float,
                                            near n: Float, far f: Float, reverseZ: Bool) -> simd_float4x4 {
        let zz: Float, zw: Float
        if reverseZ {
            zz = n / (f - n); zw = n * f / (f - n)
        } else {
            zz = f / (n - f); zw = n * f / (n - f)
        }
        return simd_float4x4(columns: (
            SIMD4(2 * n / (r - l), 0, 0, 0),
            SIMD4(0, 2 * n / (t - b), 0, 0),
            SIMD4((r + l) / (r - l), (t + b) / (t - b), zz, -1),
            SIMD4(0, 0, zw, 0)
        ))
    }
}
