import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import os

/// Real-time H.264 Baseline encoder producing Annex-B access units.
///
/// Thread-safe: `encode`, `forceKeyframe`, `setBitrate` may be called from any thread.
/// Output is delivered on a VideoToolbox thread. Mutable state is guarded by `lock`
/// (a `Mutex` cannot hold the session: region isolation rejects merging the pixel buffer into it).
final class H264Encoder: @unchecked Sendable {
    struct Settings: Sendable {
        var layout: S3DSLayout = .alternating240x400
        var bitrate: Int = 1_500_000
        /// Stereo pairs per second (the encoder runs at `fps * layout.framesPerPair`).
        var fps: Int = 30
        /// Pairs between keyframes.
        var keyframeInterval: Int = 30

        var width: Int32 { Int32(layout.frameWidth) }
        var height: Int32 { Int32(layout.frameHeight) }
        var encoderFPS: Int { max(1, fps) * layout.framesPerPair }
    }

    /// `(annexBAccessUnit, isKeyframe, eye)`; `eye` is nil for the stacked layout.
    typealias Output = @Sendable (Data, Bool, S3DSEye?) -> Void

    private struct State {
        var session: VTCompressionSession?
        var settings: Settings
        var forceNextKeyframe = true
        /// Alternating layout: left frames since the last IDR, and whether the current session
        /// has started with a left frame (VT makes its first frame an IDR, which must be left).
        var leftFramesSinceIDR = 0
        var sessionStarted = false
    }

    private let lock = NSLock()
    private var _state: State

    private func withState<R>(_ body: (inout State) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&_state)
    }
    private let output: Output
    private static let log = Logger(subsystem: "S3DSKit", category: "encoder")

    init(settings: Settings, output: @escaping Output) {
        self._state = State(session: nil, settings: settings)
        self.output = output
    }

    deinit {
        withState { s in
            if let session = s.session { VTCompressionSessionInvalidate(session) }
            s.session = nil
        }
    }

    /// Makes the next encoded frame an IDR (the next *left* frame in the alternating layout).
    func forceKeyframe() {
        withState { $0.forceNextKeyframe = true }
    }

    /// Changes the average bitrate (bits per second) of the running session.
    func setBitrate(_ bitrate: Int) {
        withState { s in
            s.settings.bitrate = bitrate
            if let session = s.session { Self.applyBitrate(bitrate, to: session) }
        }
    }

    /// Tears the session down; it is recreated lazily on the next `encode`.
    func reset() {
        withState { s in
            if let session = s.session {
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(session)
            }
            s.session = nil
            s.forceNextKeyframe = true
            s.sessionStarted = false
        }
    }

    /// Encodes one BGRA frame of the layout's size. `eye` must be given for the alternating
    /// layout (nil for stacked).
    func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, eye: S3DSEye?) {
        let output = self.output
        withState { s in
            if s.session == nil {
                s.session = Self.makeSession(settings: s.settings)
                s.forceNextKeyframe = true
                s.sessionStarted = false
            }
            guard let session = s.session else { return }
            let alternating = s.settings.layout == .alternating240x400
            if alternating, eye == .right, !s.sessionStarted { return }   // never start on a right frame
            var forceKey = false
            if !alternating {
                forceKey = s.forceNextKeyframe
                s.forceNextKeyframe = false
            } else if eye != .right {
                // IDR only on left frames: pending requests wait here; plus our own cadence.
                forceKey = s.forceNextKeyframe || s.leftFramesSinceIDR + 1 >= s.settings.keyframeInterval
                if forceKey {
                    s.forceNextKeyframe = false
                    s.leftFramesSinceIDR = 0
                } else {
                    s.leftFramesSinceIDR += 1
                }
                s.sessionStarted = true
            }
            var props: CFDictionary?
            if forceKey {
                props = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            }
            let duration = CMTime(value: 1, timescale: CMTimeScale(s.settings.encoderFPS))
            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: presentationTime,
                duration: duration,
                frameProperties: props,
                infoFlagsOut: nil
            ) { [weak self] status, _, sampleBuffer in
                guard status == noErr, let sampleBuffer else { return }
                guard let (data, key) = H264Encoder.annexB(from: sampleBuffer) else {
                    self?.forceKeyframe()   // a dropped picture breaks the reference chain
                    return
                }
                if key, eye == .right {
                    H264Encoder.log.warning("encoder produced an IDR on a right-eye frame")
                }
                output(data, key, eye)
            }
            if status != noErr {
                Self.log.error("VTCompressionSessionEncodeFrame failed: \(status)")
                // Session may have been invalidated (e.g. app backgrounded): rebuild next time.
                VTCompressionSessionInvalidate(session)
                s.session = nil
                s.sessionStarted = false
            }
        }
    }

    // MARK: - Session

    private static func makeSession(settings: Settings) -> VTCompressionSession? {
        let sourceAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: settings.width,
            kCVPixelBufferHeightKey: settings.height,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
        ]
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: settings.width,
            height: settings.height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: sourceAttrs as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            log.error("VTCompressionSessionCreate failed: \(status)")
            return nil
        }
        func set(_ key: CFString, _ value: CFTypeRef) {
            let st = VTSessionSetProperty(session, key: key, value: value)
            if st != noErr { log.warning("VTSessionSetProperty \(key as String) failed: \(st)") }
        }
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel)
        // The 3DS MVD decoder only handles single-slice pictures. VideoToolbox's software H.264
        // encoder (simulator) splits pictures into 2-5 slices by default; "NumberOfSlices" is listed
        // by VTSessionCopySupportedPropertyDictionary but has no public constant. Set it where
        // supported; every output picture is verified in annexB(from:) either way.
        if Self.supportsProperty(session, Self.numberOfSlicesKey) {
            set(Self.numberOfSlicesKey, 1 as CFNumber)
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        let keyDuration = Double(settings.keyframeInterval) / Double(max(1, settings.fps))
        if settings.layout == .alternating240x400 {
            // We force IDRs ourselves on left frames every `keyframeInterval` pairs; VT's own
            // limit sits just past that so it never has to insert one (possibly on a right frame).
            set(kVTCompressionPropertyKey_MaxKeyFrameInterval, (settings.keyframeInterval * 2 + 4) as CFNumber)
            set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, (keyDuration + 0.5) as CFNumber)
        } else {
            set(kVTCompressionPropertyKey_MaxKeyFrameInterval, settings.keyframeInterval as CFNumber)
            set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, keyDuration as CFNumber)
        }
        set(kVTCompressionPropertyKey_ExpectedFrameRate, settings.encoderFPS as CFNumber)
        applyBitrate(settings.bitrate, to: session)
        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }

    static var numberOfSlicesKey: CFString { "NumberOfSlices" as CFString }

    private static func supportsProperty(_ session: VTCompressionSession, _ key: CFString) -> Bool {
        var dict: CFDictionary?
        guard VTSessionCopySupportedPropertyDictionary(session, supportedPropertyDictionaryOut: &dict) == noErr,
              let keys = dict as? [String: Any] else { return false }
        return keys[key as String] != nil
    }

    private static func applyBitrate(_ bitrate: Int, to session: VTCompressionSession) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        // Hard cap: 1.5x average over a 1 s window (bytes, seconds).
        let limits = [Double(bitrate) * 1.5 / 8.0, 1.0] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
    }

    // MARK: - Output conversion

    /// Extracts an Annex-B access unit (SPS+PPS prepended on keyframes) from an encoder output.
    static func annexB(from sampleBuffer: CMSampleBuffer) -> (Data, Bool)? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer),
              let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }

        var isKey = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]], let first = attachments.first {
            isKey = !((first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        }

        let length = CMBlockBufferGetDataLength(block)
        var avcc = Data(count: length)
        let copyStatus = avcc.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var psCount = 0
        var nalLen: Int32 = 4
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &psCount, nalUnitHeaderLengthOut: &nalLen)

        var parameterSets: [Data]?
        if isKey {
            var sets: [Data] = []
            for i in 0..<psCount {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                let st = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if st == noErr, let ptr { sets.append(Data(bytes: ptr, count: size)) }
            }
            parameterSets = sets
        }
        // The 3DS MVD decoder only handles single-slice pictures (multi-slice crashes its sysmodule).
        // makeSession requests one slice and never sets kVTCompressionPropertyKey_MaxH264SliceBytes;
        // verify anyway: fatal in DEBUG, dropped (+ IDR requested) and logged in release.
        let slices = AnnexB.sliceCount(avcc: avcc, nalLengthSize: Int(nalLen)) ?? 0
        if slices != 1 {
            log.fault("encoder produced \(slices) slices in one picture; the 3DS requires exactly 1 (frame dropped)")
            assertionFailure("H.264 access unit has \(slices) slices; the 3DS needs single-slice pictures")
            return nil
        }
        guard let annexB = AnnexB.convert(avcc: avcc, nalLengthSize: Int(nalLen), parameterSets: parameterSets)
        else { return nil }
        return (annexB, isKey)
    }
}
