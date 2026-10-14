import CoreVideo
import Foundation
import Metal
import simd

/// Mirrors `S3DSEyeParams` / `S3DSRotateParams` in RotateStack.metal.
struct RotateEyeParams {
    var scale: SIMD2<Float>
    var offset: SIMD2<Float>
    var footprint: SIMD2<Float>
    var taps: UInt32
    var encodeSRGB: UInt32
}

struct RotateParams {
    var left: RotateEyeParams
    var right: RotateEyeParams
    var flipY: UInt32
    var singleEye: UInt32   // 0 stacked, 1 left only, 2 right only
}

enum S3DSKitError: Error, CustomStringConvertible {
    case metal(String)
    case pixelBuffer(CVReturn)
    case audio(String)

    var description: String {
        switch self {
        case .metal(let m): "Metal: \(m)"
        case .pixelBuffer(let r): "CVPixelBuffer error \(r)"
        case .audio(let m): "Audio: \(m)"
        }
    }
}

/// Runs the rotate(+stack) compute kernel into IOSurface-backed BGRA pixel buffers sized for the
/// layout (one 240x800 buffer per frame when stacked, two 240x400 buffers L/R when alternating).
///
/// Immutable after init; CoreVideo pools and texture caches are thread-safe, so `encode` may be
/// called from any thread.
final class FrameRotator: @unchecked Sendable {
    let device: any MTLDevice
    let layout: S3DSLayout
    private let pipeline: any MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    private let pool: CVPixelBufferPool
    private let poolAuxAttributes: CFDictionary

    init(device: any MTLDevice, layout: S3DSLayout) throws {
        self.device = device
        self.layout = layout
        let library: any MTLLibrary
        do {
            library = try device.makeDefaultLibrary(bundle: .module)
        } catch {
            throw S3DSKitError.metal("cannot load S3DSKit metallib: \(error)")
        }
        guard let fn = library.makeFunction(name: "s3ds_rotate_stack") else {
            throw S3DSKitError.metal("s3ds_rotate_stack missing")
        }
        pipeline = try device.makeComputePipelineState(function: fn)

        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard cacheStatus == kCVReturnSuccess, let cache else { throw S3DSKitError.pixelBuffer(cacheStatus) }
        textureCache = cache

        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: RotationMapping.frameWidth,
            kCVPixelBufferHeightKey: layout.frameHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(
            nil, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary, attrs as CFDictionary, &pool)
        guard poolStatus == kCVReturnSuccess, let pool else { throw S3DSKitError.pixelBuffer(poolStatus) }
        self.pool = pool
        // Cap the pool so a stalled encoder cannot grow memory without bound.
        poolAuxAttributes = [kCVPixelBufferPoolAllocationThresholdKey: 8] as CFDictionary
    }

    /// Encodes the kernel into `commandBuffer`, writing new pool pixel buffers.
    /// - Returns: the frame buffers in send order (`[stacked]` or `[left, right]`), valid once
    ///   `commandBuffer` completes; nil if the pool is exhausted (drop the frame).
    func encode(left: any MTLTexture, right: any MTLTexture, fit: S3DSFit, flipY: Bool,
                into commandBuffer: any MTLCommandBuffer) -> [CVPixelBuffer]? {
        let passes: [UInt32] = layout == .stacked240x800 ? [0] : [1, 2]
        var targets: [(CVPixelBuffer, CVMetalTexture, any MTLTexture)] = []
        for _ in passes {
            var pb: CVPixelBuffer?
            let st = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, poolAuxAttributes, &pb)
            guard st == kCVReturnSuccess, let pixelBuffer = pb else { return nil }
            var cvTexture: CVMetalTexture?
            let texStatus = CVMetalTextureCacheCreateTextureFromImage(
                nil, textureCache, pixelBuffer, nil, .bgra8Unorm,
                layout.frameWidth, layout.frameHeight, 0, &cvTexture)
            guard texStatus == kCVReturnSuccess, let cvTexture,
                  let output = CVMetalTextureGetTexture(cvTexture) else { return nil }
            targets.append((pixelBuffer, cvTexture, output))
        }
        guard let enc = commandBuffer.makeComputeCommandEncoder() else { return nil }
        enc.label = "S3DSKit rotate+stack"
        enc.setComputePipelineState(pipeline)
        enc.setTexture(left, index: 0)
        enc.setTexture(right, index: 1)
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        let grid = MTLSize(width: layout.frameWidth, height: layout.frameHeight, depth: 1)
        for (pass, target) in zip(passes, targets) {
            var params = RotateParams(left: Self.eyeParams(left, fit: fit),
                                      right: Self.eyeParams(right, fit: fit),
                                      flipY: flipY ? 1 : 0, singleEye: pass)
            enc.setTexture(target.2, index: 2)
            enc.setBytes(&params, length: MemoryLayout<RotateParams>.stride, index: 0)
            enc.dispatchThreads(grid, threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        }
        enc.endEncoding()

        // Keep the CVMetalTextures (and their cache, which must outlive them) alive until the GPU
        // is done, even if the rotator itself is released meanwhile.
        let lease = TextureLease(textures: targets.map(\.1), cache: textureCache)
        commandBuffer.addCompletedHandler { _ in lease.end() }
        return targets.map(\.0)
    }

    static func eyeParams(_ texture: any MTLTexture, fit: S3DSFit) -> RotateEyeParams {
        let t = S3DSFitTransform(sourceWidth: texture.width, sourceHeight: texture.height, fit: fit)
        let footprint = t.scale / SIMD2(Float(RotationMapping.eyeWidth), Float(RotationMapping.eyeHeight))
        return RotateEyeParams(scale: t.scale, offset: t.offset, footprint: footprint,
                               taps: UInt32(tapCount(sourceWidth: texture.width, sourceHeight: texture.height,
                                                     scale: t.scale)),
                               encodeSRGB: readsLinear(texture.pixelFormat) ? 1 : 0)
    }

    /// Taps per axis so that n bilinear taps (each averaging ~2 texels) cover the footprint.
    static func tapCount(sourceWidth: Int, sourceHeight: Int, scale: SIMD2<Float>) -> Int {
        let texelsX = Float(sourceWidth) * scale.x / Float(RotationMapping.eyeWidth)
        let texelsY = Float(sourceHeight) * scale.y / Float(RotationMapping.eyeHeight)
        return min(4, max(1, Int((max(texelsX, texelsY) / 2).rounded(.up))))
    }

    /// Whether shader reads of this format return linear values (sRGB-decoded or float),
    /// which the kernel then re-encodes to sRGB. Unorm formats are passed through as-is.
    static func readsLinear(_ format: MTLPixelFormat) -> Bool {
        switch format {
        case .rgba8Unorm, .bgra8Unorm, .rgb10a2Unorm, .bgr10a2Unorm, .rgba16Unorm:
            return false
        default:
            return true   // *_srgb, rgba16Float, rgba32Float, bgr10_xr_srgb, ...
        }
    }
}

/// Holds CVMetalTextures until GPU completion and releases them strictly before their cache
/// (releasing a CVMetalTexture after its CVMetalTextureCache is gone crashes in CoreVideo).
final class TextureLease: @unchecked Sendable {
    private var textures: [CVMetalTexture]?
    private let cache: CVMetalTextureCache
    private let lock = NSLock()

    init(textures: [CVMetalTexture], cache: CVMetalTextureCache) {
        self.textures = textures
        self.cache = cache
    }

    func end() {
        lock.lock()
        textures = nil
        lock.unlock()
    }

    deinit {
        textures = nil   // before `cache` is released
        withExtendedLifetime(cache) {}
    }
}

/// Carries a non-Sendable reference across a concurrency boundary where we know it is safe
/// (immutable CF objects / objects only touched after GPU completion).
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
