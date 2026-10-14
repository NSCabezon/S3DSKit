import Testing
@testable import S3DSKit

/// Defaults must match the settings proven on New 3DS XL hardware (docs/ARCHITECTURE.md,
/// "Hardware findings").
@Suite("Hardware defaults")
struct DefaultsTests {
    @Test func configurationDefaults() {
        let c = S3DSConfiguration()
        #expect(c.layout == .alternating240x400)
        #expect(c.framesPerSecond == 20)                 // stereo pairs → 40 encoded fps
        #expect(c.framesPerSecond * c.layout.framesPerPair == 40)
        #expect(c.bitrate == 1_200_000)
        #expect(c.keyframeInterval * c.layout.framesPerPair == 80)   // IDR every 80 frames = 2 s
        #expect(c.maxInFlightFrames * c.layout.framesPerPair == 18)  // last-resort cap ≈ 450 ms
        #expect(c.adaptiveBitrate)
        // Congestion: skip whole pairs before encoding at 150 ms of backlog; drop encoded frames
        // only at 3× that.
        #expect(c.congestion.skipLatency == 0.15 && c.congestion.dropLatency == 0.45 && c.congestion.skipPairs)
        #expect(c.congestion.downWindow == 2 && c.congestion.downSkipFraction == 0.2 && c.congestion.downFactor == 0.8)
        #expect(c.congestion.upQuietPeriod == 5 && c.congestion.upFactor == 1.1)
        #expect(c.congestion.minBitrate == 500_000)
        #expect(S3DSConfiguration(framesPerSecond: 30).keyframeInterval == 60)   // follows the rate
        #expect(c.audioEnabled)
        #expect(c.audioBitrate == 96_000)
        #expect(c.frameOptions == S3DSFrameOptions(fit: .letterbox, swapEyes: false, flipY: false))
        #expect(c.encoder == .automatic)   // software encoder: the HW one may ignore NumberOfSlices
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
        #expect(s.width == 240 && s.height == 400 && s.encoderFPS == 40 && s.bitrate == 1_200_000)
        #expect(s.keyframeInterval == 40 && s.minForcedKeyframeInterval == 1.0)
        #expect(s.encoder == .automatic)
    }
}
