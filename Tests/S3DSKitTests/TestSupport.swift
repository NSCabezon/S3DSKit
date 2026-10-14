import CoreVideo
import Foundation
import Metal
import Testing
@testable import S3DSKit

/// Runtime-compiled helper shaders (test target has no metallib of its own).
enum TestShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // R = x % 256, G = y % 256, B = eye*128 + x/256 (exactly representable in 8 bits)
    kernel void fill_pattern(texture2d<float, access::write> t [[texture(0)]],
                             constant uint &eye [[buffer(0)]],
                             uint2 g [[thread_position_in_grid]]) {
        if (g.x >= t.get_width() || g.y >= t.get_height()) return;
        t.write(float4(float(g.x % 256) / 255.0, float(g.y % 256) / 255.0,
                       float(eye * 128 + g.x / 256) / 255.0, 1.0), g);
    }

    kernel void fill_solid(texture2d<float, access::write> t [[texture(0)]],
                           constant float4 &c [[buffer(0)]],
                           uint2 g [[thread_position_in_grid]]) {
        if (g.x >= t.get_width() || g.y >= t.get_height()) return;
        t.write(c, g);
    }

    // Big "game frame": gradient, white marker top-left, moving bar.
    kernel void fill_game(texture2d<float, access::write> t [[texture(0)]],
                          constant float &phase [[buffer(0)]],
                          uint2 g [[thread_position_in_grid]]) {
        if (g.x >= t.get_width() || g.y >= t.get_height()) return;
        float2 uv = (float2(g) + 0.5) / float2(t.get_width(), t.get_height());
        float4 c = float4(uv.x, uv.y, 0.5, 1.0);
        if (uv.x < 0.15 && uv.y < 0.2) c = float4(1.0);
        if (abs(uv.x - fract(phase)) < 0.02) c = float4(1.0, 1.0, 0.0, 1.0);
        t.write(c, g);
    }

    struct VOut { float4 pos [[position]]; float2 uv; };

    vertex VOut fs_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VOut o;
        o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    struct EyeParams { uint eye; float phase; };

    // Left: red gradient; right: green/blue gradient. White marker at the eye's top-left.
    fragment float4 eye_fragment(VOut in [[stage_in]], constant EyeParams &p [[buffer(0)]]) {
        float2 uv = in.uv;
        if (uv.x < 0.15 && uv.y < 0.2) return float4(1.0);
        if (abs(uv.x - fract(p.phase)) < 0.02) return float4(1.0, 1.0, 0.0, 1.0);
        return p.eye == 0 ? float4(uv.x, 0.05, 0.05, 1.0) : float4(0.05, uv.x, uv.y, 1.0);
    }
    """

    struct EyeParams { var eye: UInt32; var phase: Float }

    static func library(_ device: any MTLDevice) throws -> any MTLLibrary {
        try device.makeLibrary(source: source, options: nil)
    }

    static func compute(_ device: any MTLDevice, _ name: String) throws -> any MTLComputePipelineState {
        try device.makeComputePipelineState(function: try #require(library(device).makeFunction(name: name)))
    }

    static func texture(_ device: any MTLDevice, _ w: Int, _ h: Int,
                        _ format: MTLPixelFormat = .rgba8Unorm) throws -> any MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        return try #require(device.makeTexture(descriptor: d))
    }

    static func dispatch<T: BitwiseCopyable>(_ cb: any MTLCommandBuffer, _ pso: any MTLComputePipelineState,
                            _ tex: any MTLTexture, _ value: T) {
        let enc = cb.makeComputeCommandEncoder()!
        enc.setComputePipelineState(pso)
        enc.setTexture(tex, index: 0)
        var v = value
        enc.setBytes(&v, length: MemoryLayout<T>.stride, index: 0)
        enc.dispatchThreads(MTLSize(width: tex.width, height: tex.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
    }
}

/// A CPU copy of a BGRA CVPixelBuffer.
struct PixelReader {
    let width: Int, height: Int
    private let bytes: [UInt8]
    private let stride: Int

    init(pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        width = CVPixelBufferGetWidth(pixelBuffer)
        height = CVPixelBufferGetHeight(pixelBuffer)
        stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        bytes = Array(UnsafeBufferPointer(start: base, count: stride * height))
    }

    /// (b, g, r, a) at (column, row).
    func bgra(_ c: Int, _ r: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let i = r * stride + c * 4
        return (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
    }
}

/// A fake 3DS: BSD-socket TCP server on 127.0.0.1 with an ephemeral port. Sends KEYFRAME_REQ on
/// accept (like the real receiver) and records every byte received.
final class TestReceiver: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32
    private let lock = NSLock()
    private var buffer = Data()
    private var finished = false

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(bound == 0)
        try #require(listen(fd, 1) == 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        listenFD = fd
        port = UInt16(bigEndian: addr.sin_port)
        Thread.detachNewThread { [self] in self.serve(fd) }
    }

    private func serve(_ fd: Int32) {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { markFinished(); return }
        let req = Array(S3DSProtocol.message(.keyframeRequest))
        _ = req.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = chunk.withUnsafeMutableBytes { read(client, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            lock.lock(); buffer.append(contentsOf: chunk[0..<n]); lock.unlock()
        }
        close(client)
        markFinished()
    }

    private func markFinished() { lock.lock(); finished = true; lock.unlock() }

    var received: Data { lock.lock(); defer { lock.unlock() }; return buffer }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

    func stop() { close(listenFD) }
}

/// Parses a byte stream into S3DS messages, recording framing errors.
func parseMessages(_ data: Data) throws -> [(header: S3DSProtocol.Header, payload: Data)] {
    var out: [(S3DSProtocol.Header, Data)] = []
    var i = data.startIndex
    while data.endIndex - i >= S3DSProtocol.headerLength {
        let header = try S3DSProtocol.decodeHeader(data[i..<(i + S3DSProtocol.headerLength)])
        let start = i + S3DSProtocol.headerLength
        let end = start + Int(header.length)
        guard end <= data.endIndex else { break }   // truncated tail at disconnect
        out.append((header, Data(data[start..<end])))
        i = end
    }
    return out
}

/// NAL unit types in an Annex-B buffer, in order.
func nalTypes(_ annexB: Data) -> [UInt8] {
    let b = [UInt8](annexB)
    var types: [UInt8] = []
    var i = 0
    while i + 3 < b.count {
        if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
            types.append(b[i + 3] & 0x1F)
            i += 3
        } else {
            i += 1
        }
    }
    return types
}

@MainActor
func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
