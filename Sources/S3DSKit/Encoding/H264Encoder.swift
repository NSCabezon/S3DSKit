import CoreMedia
import CoreVideo
import Foundation
import Synchronization
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
        var bitrate: Int = 1_200_000
        /// Stereo pairs per second (the encoder runs at `fps * layout.framesPerPair`).
        var fps: Int = 20
        /// Pairs between scheduled keyframes (2 s at the default rate).
        var keyframeInterval: Int = 40
        /// Minimum seconds between *forced* IDRs (connect, KEYFRAME_REQ, drops). A request inside
        /// the window waits until it ends (or the next scheduled keyframe). 0 disables the limit.
        var minForcedKeyframeInterval: Double = 1.0
        /// Which VideoToolbox encoder to ask for (see ``S3DSEncoderPreference``).
        var encoder: S3DSEncoderPreference = .automatic

        var width: Int32 { Int32(layout.frameWidth) }
        var height: Int32 { Int32(layout.frameHeight) }
        var encoderFPS: Int { max(1, fps) * layout.framesPerPair }
    }

    /// `(annexBAccessUnit, isKeyframe, eye)`; `eye` is nil for the stacked layout.
    typealias Output = @Sendable (Data, Bool, S3DSEye?) -> Void

    /// A created session and whether VideoToolbox reports it as hardware (nil = unknown).
    struct SessionInfo {
        var session: VTCompressionSession
        var isHardware: Bool?
    }

    /// Creates a session; `software` asks for the software encoder. Injectable for tests.
    typealias SessionFactory = @Sendable (Settings, _ software: Bool) -> SessionInfo?

    private struct State {
        var session: VTCompressionSession?
        var settings: Settings
        /// Whether the current (or last) session runs on the hardware encoder (nil = unknown).
        var isHardware: Bool?
        /// `.automatic` switched to the software encoder after a hardware multi-slice picture.
        var fellBackToSoftware = false
        /// Set from the output callback; the next `encode` rebuilds on the software encoder
        /// (a session must not be invalidated from its own output callback).
        var softwareRebuildPending = false
        var multiSliceDrops = 0
        var softwareRebuilds = 0
        /// Host time of the last IDR requested (nil: none yet in this session).
        var lastIDRTime: Double?
        var framesSubmitted = 0
        var framesEncoded = 0
        var encodeLatencySum = 0.0
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
    private let sessionFactory: SessionFactory
    private static let log = Logger(subsystem: "S3DSKit", category: "encoder")

    init(settings: Settings, sessionFactory: @escaping SessionFactory = H264Encoder.makeSession,
         output: @escaping Output) {
        self._state = State(session: nil, settings: settings)
        self.sessionFactory = sessionFactory
        self.output = output
    }

    /// Whether the current session uses the hardware encoder (nil before the first session, or
    /// when VideoToolbox does not say).
    var isHardware: Bool? { withState { $0.isHardware } }
    /// Multi-slice pictures dropped so far (the 3DS needs exactly one slice per picture).
    var multiSlicePicturesDropped: Int { withState { $0.multiSliceDrops } }
    /// Times the session was rebuilt on the software encoder after a multi-slice picture (≤ 1).
    var softwareRebuilds: Int { withState { $0.softwareRebuilds } }
    /// Monotonic: frames passed to `encode`, AUs delivered, summed submit→output seconds.
    var encodeCounters: (submitted: Int, encoded: Int, latencySum: Double) {
        withState { ($0.framesSubmitted, $0.framesEncoded, $0.encodeLatencySum) }
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
        let sessionFactory = self.sessionFactory
        let now = ProcessInfo.processInfo.systemUptime
        withState { s in
            s.framesSubmitted += 1
            if s.softwareRebuildPending {
                s.softwareRebuildPending = false
                if let session = s.session { VTCompressionSessionInvalidate(session) }
                s.session = nil
            }
            if s.session == nil {
                let software = s.settings.encoder != .hardware || s.fellBackToSoftware
                if let info = sessionFactory(s.settings, software) {
                    s.session = info.session
                    s.isHardware = info.isHardware
                }
                s.forceNextKeyframe = true
                s.sessionStarted = false
                s.lastIDRTime = nil
            }
            guard let session = s.session else { return }
            // Forced IDRs at most once per `minForcedKeyframeInterval`; pending ones wait.
            let forceAllowed = s.forceNextKeyframe
                && (s.lastIDRTime.map { now - $0 >= s.settings.minForcedKeyframeInterval } ?? true)
            let alternating = s.settings.layout == .alternating240x400
            if alternating, eye == .right, !s.sessionStarted { return }   // never start on a right frame
            var forceKey = false
            if !alternating {
                forceKey = forceAllowed
                if forceKey { s.forceNextKeyframe = false }
            } else if eye != .right {
                // IDR only on left frames: pending requests wait here; plus our own cadence.
                forceKey = forceAllowed || s.leftFramesSinceIDR + 1 >= s.settings.keyframeInterval
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
                s.lastIDRTime = now
            }
            let sessionIsHardware = s.isHardware
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
                let data: Data, key: Bool
                switch H264Encoder.annexBResult(from: sampleBuffer) {
                case .accessUnit(let d, let k):
                    (data, key) = (d, k)
                case .multiSlice(let slices):
                    self?.handleMultiSlicePicture(slices: slices, sessionIsHardware: sessionIsHardware)
                    return
                case .failed:
                    self?.forceKeyframe()   // a dropped picture breaks the reference chain
                    return
                }
                self?.recordEncoded(since: now)
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

    private func recordEncoded(since submitted: Double) {
        let latency = ProcessInfo.processInfo.systemUptime - submitted
        withState { s in
            s.framesEncoded += 1
            s.encodeLatencySum += latency
        }
    }

    /// A picture with `slices != 1` was dropped (the 3DS MVD decoder crashes on multi-slice
    /// pictures). `.automatic` on the hardware encoder rebuilds once on the software encoder,
    /// which honours `NumberOfSlices`; otherwise the picture is just dropped and logged. Either
    /// way an IDR follows on the next left frame. Internal for tests.
    func handleMultiSlicePicture(slices: Int, sessionIsHardware: Bool?) {
        let (count, rebuild) = withState { s -> (Int, Bool) in
            s.multiSliceDrops += 1
            s.forceNextKeyframe = true
            // Unknown (nil) counts as hardware: the rebuild happens at most once anyway.
            let rebuild = sessionIsHardware != false && s.settings.encoder == .automatic
                && s.softwareRebuilds == 0
            if rebuild {
                s.softwareRebuilds += 1
                s.fellBackToSoftware = true
                s.softwareRebuildPending = true
            }
            return (s.multiSliceDrops, rebuild)
        }
        if rebuild {
            Self.log.fault("""
                hardware encoder produced \(slices) slices in one picture (ignores NumberOfSlices); \
                frame dropped, rebuilding the session on the software encoder
                """)
        } else if count == 1 || count.isMultiple(of: 60) {
            Self.log.fault("""
                encoder produced \(slices) slices in one picture; the 3DS requires exactly 1 \
                (frame dropped, \(count) so far)
                """)
            // A software encoder that ignores NumberOfSlices is a bug worth stopping on in DEBUG.
            assert(sessionIsHardware != false, "H.264 access unit has \(slices) slices; the 3DS needs single-slice pictures")
        }
    }

    // MARK: - Session

    /// Creates a configured session, on the software encoder when `software` is true (falling
    /// back to VideoToolbox's default choice if that fails).
    static func makeSession(settings: Settings, software: Bool) -> SessionInfo? {
        if software {
            let spec = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: kCFBooleanFalse!]
            if let info = makeSession(settings: settings, specification: spec as CFDictionary) { return info }
            log.error("software H.264 encoder unavailable; falling back to the default encoder")
        }
        return makeSession(settings: settings, specification: nil)
    }

    private static func makeSession(settings: Settings, specification: CFDictionary?) -> SessionInfo? {
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
            encoderSpecification: specification,
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
        @discardableResult
        func set(_ key: CFString, _ value: CFTypeRef) -> OSStatus {
            let st = VTSessionSetProperty(session, key: key, value: value)
            if st != noErr { log.warning("VTSessionSetProperty \(key as String) failed: \(st)") }
            return st
        }
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel)
        // The 3DS MVD decoder only handles single-slice pictures. VideoToolbox's software H.264
        // encoder (simulator) splits pictures into 2-5 slices by default; "NumberOfSlices" is listed
        // by VTSessionCopySupportedPropertyDictionary but has no public constant. Set it where
        // supported; every output picture is verified in annexB(from:) either way.
        var slicesStatus = "unsupported"
        if Self.supportsProperty(session, Self.numberOfSlicesKey) {
            slicesStatus = "OSStatus \(set(Self.numberOfSlicesKey, 1 as CFNumber))"
        }
        // One reference frame, like x264's stream that stays in sync on the 3DS (fewer DPB frames
        // to hold). Not every encoder supports it; the SPS rewrite below works either way.
        var refsStatus = "unsupported"
        if Self.supportsProperty(session, kVTCompressionPropertyKey_ReferenceBufferCount) {
            refsStatus = "OSStatus \(set(kVTCompressionPropertyKey_ReferenceBufferCount, 1 as CFNumber))"
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
        // The simulator does not report the property; a session created with the software-only
        // specification is software either way.
        let isHardware = usingHardwareEncoder(session) ?? (specification == nil ? nil : false)
        let kind = isHardware.map { $0 ? "hardware" : "software" } ?? "unknown"
        log.info("""
            H.264 session \(settings.width)x\(settings.height)@\(settings.encoderFPS): \(kind) encoder \
            (requested \(specification == nil ? "default" : "software")); NumberOfSlices=1 \(slicesStatus); \
            ReferenceBufferCount=1 \(refsStatus)
            """)
        return SessionInfo(session: session, isHardware: isHardware)
    }

    private static func usingHardwareEncoder(_ session: VTCompressionSession) -> Bool? {
        var value: CFTypeRef?
        let st = withUnsafeMutablePointer(to: &value) {
            VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                  allocator: nil, valueOut: UnsafeMutableRawPointer($0))
        }
        guard st == noErr, let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    static var numberOfSlicesKey: CFString { "NumberOfSlices" as CFString }

    static func supportsProperty(_ session: VTCompressionSession, _ key: CFString) -> Bool {
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

    /// Last (encoder SPS, rewritten SPS). The format description, and so its SPS, only changes
    /// when the session is rebuilt, so this skips re-parsing on every keyframe.
    private static let spsCache = Mutex<(original: Data, rewritten: Data)?>(nil)

    /// SPS NALs get `bitstream_restriction` with zero reordering (see `SPSRewriter`); PPS and
    /// anything else pass through.
    static func rewrittenParameterSet(_ nal: Data) -> Data {
        guard let first = nal.first, first & 0x1F == 7 else { return nal }
        if let cached = spsCache.withLock({ $0 }), cached.original == nal { return cached.rewritten }
        let rewritten = SPSRewriter.rewrite(nal)
        spsCache.withLock { $0 = (nal, rewritten) }
        return rewritten
    }

    enum AnnexBResult {
        case accessUnit(Data, isKey: Bool)
        /// The picture does not have exactly one slice (count given); must be dropped.
        case multiSlice(Int)
        case failed
    }

    /// Extracts an Annex-B access unit (SPS+PPS prepended on keyframes) from an encoder output.
    static func annexB(from sampleBuffer: CMSampleBuffer) -> (Data, Bool)? {
        if case .accessUnit(let data, let key) = annexBResult(from: sampleBuffer) { return (data, key) }
        return nil
    }

    static func annexBResult(from sampleBuffer: CMSampleBuffer) -> AnnexBResult {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer),
              let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return .failed }

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
        guard copyStatus == kCMBlockBufferNoErr else { return .failed }

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
            parameterSets = sets.map(rewrittenParameterSet)
        }
        // The 3DS MVD decoder only handles single-slice pictures (multi-slice crashes its sysmodule).
        // makeSession requests one slice and never sets kVTCompressionPropertyKey_MaxH264SliceBytes;
        // verify anyway: the caller drops it, logs, requests an IDR (handleMultiSlicePicture).
        let slices = AnnexB.sliceCount(avcc: avcc, nalLengthSize: Int(nalLen)) ?? 0
        if slices != 1 { return .multiSlice(slices) }
        guard let annexB = AnnexB.convert(avcc: avcc, nalLengthSize: Int(nalLen), parameterSets: parameterSets,
                                            spsTransform: rewrittenParameterSet)
        else { return .failed }
        return .accessUnit(annexB, isKey: isKey)
    }
}
