import CoreGraphics
import Foundation
import Metal
import RealityKit
import Synchronization
import simd

/// Renders a RealityKit entity hierarchy from a ``StereoCamera`` into the stream, using an
/// offscreen `RealityRenderer` (one `PerspectiveCamera` render per eye).
///
/// RealityKit entities can belong to only one scene, so add the entities to stream to
/// ``renderer``'s `entities` (typically a dedicated copy via `entity.clone(recursive: true)`),
/// not the ones shown in your `RealityView`.
///
/// Limitations: `PerspectiveCamera` has symmetric frusta, so eyes are parallel (zero parallax at
/// infinity) and ``StereoCamera/convergenceDistance`` is ignored; near/far and vertical FOV are
/// honored. Each capture costs two RealityKit renders at 400x240.
@MainActor
public final class S3DSRealityCapture {
    /// The offscreen renderer; put the entities to stream in `renderer.entities` and set lighting.
    public let renderer: RealityRenderer
    /// Stereo camera parameters.
    public var camera: StereoCamera

    private let streamer: S3DSStreamer
    private let cameraEntity = PerspectiveCamera()
    private let eyeTextures: [any MTLTexture]
    private var inFlight = false

    /// - Parameter streamer: frames are submitted to it (its `device` is used for the eye textures).
    public init(streamer: S3DSStreamer, camera: StereoCamera = StereoCamera()) throws {
        guard let device = streamer.device else {
            throw S3DSKitError.metal(streamer.metalError ?? "no Metal device")
        }
        self.streamer = streamer
        self.camera = camera
        renderer = try RealityRenderer()
        renderer.entities.append(cameraEntity)
        renderer.activeCamera = cameraEntity
        renderer.cameraSettings.colorBackground = .color(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        eyeTextures = try S3DSEye.allCases.map { _ in
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm_srgb, width: RotationMapping.eyeWidth,
                height: RotationMapping.eyeHeight, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead, .shaderWrite]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else {
                throw S3DSKitError.metal("cannot allocate eye texture")
            }
            return t
        }
    }

    /// Renders and submits a stereo frame if one is due (call every frame; cheap when not due).
    /// - Parameters:
    ///   - headTransform: world-from-head transform in the renderer's world space.
    ///   - deltaTime: seconds since the previous call, to advance RealityKit animations/systems.
    /// - Returns: true if a frame was rendered and will be submitted.
    @discardableResult
    public func capture(headTransform: simd_float4x4, deltaTime: TimeInterval) throws -> Bool {
        guard !inFlight else { return false }
        guard streamer.nextCaptureDue() else { return false }
        inFlight = true

        cameraEntity.camera.near = camera.nearZ
        cameraEntity.camera.far = camera.farZ
        cameraEntity.camera.fieldOfViewInDegrees = camera.verticalFieldOfView * 180 / .pi
        cameraEntity.camera.fieldOfViewOrientation = .vertical

        let streamer = self.streamer
        let textures = UncheckedBox(eyeTextures)
        let remaining = Mutex(2)
        let onComplete: @Sendable (RealityRenderer) -> Void = { [weak self] _ in
            guard remaining.withLock({ $0 -= 1; return $0 }) == 0 else { return }
            streamer.submit(left: textures.value[0], right: textures.value[1], throttle: false)
            Task { @MainActor [weak self] in self?.inFlight = false }
        }
        do {
            for eye in S3DSEye.allCases {
                let pose = camera.eyePose(eye, headTransform: headTransform)
                cameraEntity.transform = Transform(matrix: pose.worldFromEye)
                let output = try RealityRenderer.CameraOutput(
                    .singleProjection(colorTexture: eyeTextures[eye.rawValue]))
                try renderer.updateAndRender(deltaTime: eye == .left ? deltaTime : 0,
                                             cameraOutput: output, onComplete: onComplete)
            }
        } catch {
            inFlight = false
            throw error
        }
        return true
    }
}
