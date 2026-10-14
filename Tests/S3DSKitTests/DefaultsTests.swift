import Testing
@testable import S3DSKit

/// Defaults must match the settings proven on New 3DS XL hardware (docs/ARCHITECTURE.md,
/// "Hardware findings").
@Suite("Hardware defaults")
struct DefaultsTests {
    @Test func configurationDefaults() {
        let c = S3DSConfiguration()
        #expect(c.layout == .alternating240x400)
        #expect(c.framesPerSecond == 30)                 // stereo pairs → 60 encoded fps
        #expect(c.framesPerSecond * c.layout.framesPerPair == 60)
        #expect(c.bitrate == 1_500_000)
        #expect(c.keyframeInterval * c.layout.framesPerPair == 60)   // IDR every 60 frames = 1 s
        #expect(c.maxInFlightFrames * c.layout.framesPerPair == 12)  // ≤ 200 ms of video ahead
        #expect(c.audioEnabled)
        #expect(c.audioBitrate == 96_000)
        #expect(c.frameOptions == S3DSFrameOptions(fit: .letterbox, swapEyes: false, flipY: false))
    }

    @Test func bitrateIsClamped() {
        #expect(S3DSConfiguration(bitrate: 100_000).bitrate == 500_000)
        #expect(S3DSConfiguration(bitrate: 9_000_000).bitrate == 3_000_000)
        var c = S3DSConfiguration()
        c.bitrate = 10
        #expect(c.bitrate == 500_000)
        c.bitrate = 2_000_000
        #expect(c.bitrate == 2_000_000)
    }

    @Test func protocolLimits() {
        #expect(S3DSProtocol.maxPayloadLength == 256 * 1024)
        #expect(S3DSProtocol.maxAudioPayloadLength == 4 * 1024)
        #expect(OpusPacketEncoder.framesPerPacket == 960 && OpusPacketEncoder.sampleRate == 48_000)
    }

    @Test func encoderSettingsDefaults() {
        let s = H264Encoder.Settings()
        #expect(s.width == 240 && s.height == 400 && s.encoderFPS == 60 && s.bitrate == 1_500_000)
    }
}
