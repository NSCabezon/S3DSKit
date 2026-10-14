import Metal
import Synchronization
import simd

/// The two eye images of one stereo capture.
public struct StereoEyeTextures {
    public let left: any MTLTexture
    public let right: any MTLTexture
}

/// Owns 400x240 color + depth render targets for both eyes and drives your Metal draw code
/// once per eye. Pass the result to ``S3DSStreamer/submit(left:right:commandBuffer:throttle:)``.
///
/// Targets are triple-buffered, so a capture never overwrites textures a previous, still
/// in-flight capture is reading. Call `render` from one thread at a time.
public final class StereoEyeRenderer: @unchecked Sendable {
    /// Eye image size.
    public static let eyeWidth = RotationMapping.eyeWidth
    public static let eyeHeight = RotationMapping.eyeHeight

    public let device: any MTLDevice
    /// Color format of the eye targets; build your pipelines with it.
    public let colorPixelFormat: MTLPixelFormat
    /// Depth format of the eye targets; build your pipelines with it.
    public let depthPixelFormat: MTLPixelFormat
    /// Clear color of each eye pass (linear values for sRGB formats).
    public let clearColor: MTLClearColor

    private struct Slot {
        let color: [any MTLTexture]
        let depth: (any MTLTexture)?
    }
    private let slots: [Slot]
    private let nextSlot = Mutex(0)

    /// - Parameters:
    ///   - colorPixelFormat: e.g. `.bgra8Unorm_srgb` (default: shaders output linear color) or
    ///     `.bgra8Unorm` (shaders output sRGB-encoded color).
    ///   - depthPixelFormat: `.invalid` for no depth buffer.
    ///   - scale: render targets are `scale` x 400x240 (supersampling; the library downsamples).
    public init(device: any MTLDevice,
                colorPixelFormat: MTLPixelFormat = .bgra8Unorm_srgb,
                depthPixelFormat: MTLPixelFormat = .depth32Float,
                clearColor: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1),
                scale: Int = 1) throws {
        self.device = device
        self.colorPixelFormat = colorPixelFormat
        self.depthPixelFormat = depthPixelFormat
        self.clearColor = clearColor
        let s = max(1, scale)
        func make(_ format: MTLPixelFormat, _ usage: MTLTextureUsage) throws -> any MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: Self.eyeWidth * s, height: Self.eyeHeight * s, mipmapped: false)
            d.usage = usage
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else {
                throw S3DSKitError.metal("cannot allocate eye texture")
            }
            return t
        }
        var slots: [Slot] = []
        for _ in 0..<3 {
            let color = try [make(colorPixelFormat, [.renderTarget, .shaderRead]),
                             make(colorPixelFormat, [.renderTarget, .shaderRead])]
            let depth = depthPixelFormat == .invalid ? nil : try make(depthPixelFormat, [.renderTarget])
            slots.append(Slot(color: color, depth: depth))
        }
        self.slots = slots
    }

    /// Encodes one render pass per eye into `commandBuffer` and calls `draw` inside each.
    ///
    /// The encoder already has the viewport set; depth is cleared to 0 for reverse-Z cameras,
    /// 1 otherwise. Do not end the encoder in `draw`.
    /// - Parameters:
    ///   - headTransform: world-from-head transform (e.g. ARKit device anchor).
    ///   - draw: your draw code; receives the encoder and the eye's view/projection.
    /// - Returns: the eye textures to submit (valid once the command buffer completes).
    @discardableResult
    public func render(commandBuffer: any MTLCommandBuffer,
                       camera: StereoCamera,
                       headTransform: simd_float4x4,
                       draw: (any MTLRenderCommandEncoder, StereoCamera.EyePose) -> Void) -> StereoEyeTextures {
        let index = nextSlot.withLock { i -> Int in
            let current = i
            i = (i + 1) % slots.count
            return current
        }
        let slot = slots[index]
        for eye in S3DSEye.allCases {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = slot.color[eye.rawValue]
            rp.colorAttachments[0].loadAction = .clear
            rp.colorAttachments[0].storeAction = .store
            rp.colorAttachments[0].clearColor = clearColor
            if let depth = slot.depth {
                rp.depthAttachment.texture = depth
                rp.depthAttachment.loadAction = .clear
                rp.depthAttachment.storeAction = .dontCare
                rp.depthAttachment.clearDepth = camera.reverseZ ? 0 : 1
            }
            guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else { continue }
            enc.label = eye == .left ? "S3DSKit left eye" : "S3DSKit right eye"
            let tex = slot.color[eye.rawValue]
            enc.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(tex.width),
                                        height: Double(tex.height), znear: 0, zfar: 1))
            draw(enc, camera.eyePose(eye, headTransform: headTransform))
            enc.endEncoding()
        }
        return StereoEyeTextures(left: slot.color[0], right: slot.color[1])
    }
}
