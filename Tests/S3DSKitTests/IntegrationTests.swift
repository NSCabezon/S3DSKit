import Foundation
import Metal
import QuartzCore
import Testing
import simd
@testable import S3DSKit

/// End-to-end: S3DSStreamer → loopback TCP → fake receiver. Writes the received Annex-B
/// stream to the temp dir (path printed as `S3DSKIT_DUMP`) for inspection with ffprobe/ffmpeg.
@Suite("Streaming end-to-end", .serialized)
@MainActor
struct IntegrationTests {
    typealias Message = (header: S3DSProtocol.Header, payload: Data)

    /// Connects, runs `feed`, waits for the tail to flush, disconnects, validates the stream.
    func stream(name: String, layout: S3DSLayout,
                feed: (S3DSStreamer) async throws -> Void) async throws -> [Message] {
        let receiver = try TestReceiver()
        defer { receiver.stop() }
        let streamer = S3DSStreamer(configuration: S3DSConfiguration(layout: layout, senderName: "S3DSKitTests"))
        #expect(streamer.metalError == nil)
        streamer.connect(host: "127.0.0.1", port: receiver.port)
        let up = await waitUntil { streamer.connectionState == .connected }
        try #require(up, "never connected: \(streamer.connectionState)")

        try await feed(streamer)

        try await Task.sleep(for: .seconds(1))
        streamer.disconnect()
        _ = await waitUntil { receiver.isFinished }

        let messages = try parseMessages(receiver.received)   // throws on bad magic / oversize
        let first = try #require(messages.first)
        #expect(first.header.messageType == .hello)
        #expect(String(data: first.payload, encoding: .utf8) == "S3DSKitTests")

        let aus = messages.filter { $0.header.messageType == .videoAU }
        let firstAU = try #require(aus.first)
        #expect(firstAU.header.flags & S3DSProtocol.keyframeFlag != 0)
        #expect(Array(nalTypes(firstAU.payload).prefix(3)) == [7, 8, 5])
        for au in aus {
            let t = nalTypes(au.payload)
            #expect((au.header.flags & 1 != 0) == t.contains(5))   // flag agrees with content
            #expect(!t.contains(9))                                 // no AUD
            if t.contains(5) { #expect(Array(t.prefix(2)) == [7, 8]) }
        }
        #expect(aus.filter { $0.header.flags & 1 != 0 }.count >= 2)   // keyframe interval ≤ 1 s

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).h264")
        try aus.reduce(into: Data()) { $0.append($1.payload) }.write(to: url)
        print("S3DSKIT_DUMP \(name): \(url.path) (\(aus.count) AUs)")
        #expect(streamer.stats.framesSent > 0)
        return aus
    }

    /// Renders stereo frames with StereoEyeRenderer and submits them into the caller's
    /// command buffer (throttle off: the loop already runs at ~30 Hz).
    func feedStereo(_ streamer: S3DSStreamer, frames: Int = 60) async throws {
        let device = try #require(streamer.device)
        let queue = try #require(device.makeCommandQueue())
        let eyes = try StereoEyeRenderer(device: device)
        let lib = try TestShaders.library(device)
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "fs_vertex")
        pd.fragmentFunction = lib.makeFunction(name: "eye_fragment")
        pd.colorAttachments[0].pixelFormat = eyes.colorPixelFormat
        pd.depthAttachmentPixelFormat = eyes.depthPixelFormat
        let pso = try await device.makeRenderPipelineState(descriptor: pd)
        let camera = StereoCamera()
        for i in 0..<frames {
            let cb = try #require(queue.makeCommandBuffer())
            let textures = eyes.render(commandBuffer: cb, camera: camera,
                                       headTransform: matrix_identity_float4x4) { enc, pose in
                var p = TestShaders.EyeParams(eye: UInt32(pose.eye.rawValue), phase: Float(i) / 60)
                enc.setRenderPipelineState(pso)
                enc.setFragmentBytes(&p, length: MemoryLayout<TestShaders.EyeParams>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            #expect(streamer.submit(textures, commandBuffer: cb, throttle: false))
            cb.commit()
            try await Task.sleep(for: .milliseconds(33))
        }
    }

    /// Default layout: one eye per frame, L/R alternating, IDR only on left frames.
    @Test func alternatingStereoStream() async throws {
        let aus = try await stream(name: "s3ds_alternating", layout: .alternating240x400) { try await feedStereo($0) }
        #expect(aus.count >= 100)
        for (i, au) in aus.enumerated() {
            let f = au.header.flags
            #expect(f & S3DSProtocol.alternatingFlag != 0)
            let isRight = f & S3DSProtocol.rightEyeFlag != 0
            #expect(isRight == (i % 2 == 1), "eye order broken at AU \(i)")   // loopback: no drops
            if f & S3DSProtocol.keyframeFlag != 0 { #expect(!isRight, "IDR on right frame at AU \(i)") }
        }
    }

    /// Stacked 240x800 layout via StereoEyeRenderer.
    @Test func stackedStereoStream() async throws {
        let aus = try await stream(name: "s3ds_stereo", layout: .stacked240x800) { try await feedStereo($0) }
        #expect(aus.count >= 50)
        #expect(aus.allSatisfy { $0.header.flags & ~S3DSProtocol.keyframeFlag == 0 })
    }

    /// Mono 1920x1440 rgba8Unorm "game frame" submitted at ~90 Hz with right: nil and no command
    /// buffer (library queue); the throttle should pass ~30 fps.
    @Test func monoLargeTextureThrottled() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let fill = try TestShaders.compute(device, "fill_game")
        let frames = try (0..<3).map { _ in try TestShaders.texture(device, 1920, 1440) }
        var accepted = 0
        var calls = 0

        let aus = try await stream(name: "s3ds_mono", layout: .alternating240x400) { streamer in
            let start = CACurrentMediaTime()
            while CACurrentMediaTime() - start < 2.5 {
                let tex = frames[calls % frames.count]
                try fillAndWait(queue, fill, tex, Float(calls) / 180)   // different queue than the library's
                if streamer.submit(left: tex, right: nil) { accepted += 1 }
                calls += 1
                try await Task.sleep(for: .milliseconds(11))
            }
        }
        print("S3DSKIT_THROTTLE calls=\(calls) accepted=\(accepted)")
        #expect(calls > accepted * 2)             // most 90 Hz calls are no-ops
        #expect(accepted >= 45 && accepted <= 80) // ~30 fps over 2.5 s
        #expect(aus.count >= 80)                  // two AUs per accepted frame
    }

    /// Preview works without a connection.
    @Test func previewWithoutConnection() async throws {
        let streamer = S3DSStreamer()
        streamer.isPreviewEnabled = true
        let device = try #require(streamer.device)
        let queue = try #require(device.makeCommandQueue())
        let fill = try TestShaders.compute(device, "fill_game")
        let tex = try TestShaders.texture(device, 1920, 1440)
        try fillAndWait(queue, fill, tex, 0.5)
        let got = await waitUntil(timeout: .seconds(3)) {
            streamer.submit(left: tex)
            return streamer.previewImage != nil
        }
        #expect(got)
        #expect(streamer.previewImage?.width == 800 && streamer.previewImage?.height == 240)
    }

    /// Synchronous GPU fill (waits, so the library's queue sees finished content).
    nonisolated func fillAndWait(_ queue: any MTLCommandQueue, _ pso: any MTLComputePipelineState,
                                 _ tex: any MTLTexture, _ phase: Float) throws {
        let cb = try #require(queue.makeCommandBuffer())
        TestShaders.dispatch(cb, pso, tex, phase)
        cb.commit()
        cb.waitUntilCompleted()
    }
}

/// Compile check: the one-line integration in a @MainActor frame pump (tc-visionos FramePump shape).
@MainActor
final class FramePumpShape {
    let streamer = S3DSStreamer()
    let queue: any MTLCommandQueue
    init?(device: any MTLDevice) {
        guard let q = device.makeCommandQueue() else { return nil }
        queue = q
    }

    func pump(frame: (left: any MTLTexture, right: (any MTLTexture)?, id: UInt64)) {
        guard let cb = queue.makeCommandBuffer() else { return }
        // ... app copies into its own textures here ...
        streamer.submit(left: frame.left, right: frame.right, commandBuffer: cb)
        cb.commit()
    }
}
