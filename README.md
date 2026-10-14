<p align="center"><img src="docs/logo.png" width="140" alt="3D Streaming logo"></p>

# S3DSKit

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform: visionOS 26+](https://img.shields.io/badge/platform-visionOS%2026%2B-lightgrey)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
[![SwiftPM](https://img.shields.io/badge/SwiftPM-compatible-brightgreen)](#adding-the-package)

Swift package that streams stereo frames (and audio) from a visionOS app to a New Nintendo 3DS running
the [3DSStream](https://github.com/NSCabezon/3DSStream) receiver, shown glasses-free on the 3DS
top screen.

It takes eye images (Metal textures, a RealityKit scene, or ready-made pixel buffers), scales
and rotates them into the 3DS framebuffer layout on the GPU, encodes H.264 Baseline with
VideoToolbox and sends it over TCP (Network.framework). No third-party dependencies.

- Platforms: visionOS 26+ (Swift 6 language mode; works from Swift 5 mode apps too).
- Video/wire contract: [`docs/PROTOCOL.md`](docs/PROTOCOL.md), a copy of 3DSStream's
  `docs/ARCHITECTURE.md`, which is the source of truth.
- License: MIT.

## The stream in one paragraph

Each eye is a 400x240 image rotated 90° clockwise into a 240-wide x 400-tall block (eye pixel
`(x, y)` → block pixel `(column 239 - y, row x)`), so the 3DS hardware decoder writes
framebuffer-ready pixels. The default layout, `.alternating240x400`, sends one eye per H.264
frame, L, R, L, R at twice the stereo rate (60 fps for 30 stereo frames). Keyframes are always
left frames, at least every second, with SPS+PPS before every IDR and no AUD NALs.
`VIDEO_AU` flags: bit0 keyframe, bit1 eye (0 left, 1 right), bit2 alternating. The
`.stacked240x800` layout puts both blocks in one 240x800 frame (left on top); only the
alternating layout has been proven on hardware. The 3DS is the TCP
server on port 7777. The app connects and sends `HELLO`, then `VIDEO_AU`s, and forces an IDR
whenever the 3DS sends `KEYFRAME_REQ`.

## Adding the package

- **Git URL:** Xcode ▸ File ▸ Add Package Dependencies… ▸ `https://github.com/NSCabezon/S3DSKit`,
  rule "Up to Next Major Version" from `0.1.0`. In `Package.swift`:
  ```swift
  .package(url: "https://github.com/NSCabezon/S3DSKit", from: "0.1.0")
  ```
- **Local path:** Add Local… ▸ pick your `S3DSKit` checkout. With XcodeGen:
  ```yaml
  packages:
    S3DSKit:
      path: ../S3DSKit
  targets:
    MyApp:
      dependencies:
        - package: S3DSKit
  ```

**Info.plist (required):** `NSLocalNetworkUsageDescription`, e.g. "Streams 3D video to your
Nintendo 3DS on the local network." Without it visionOS blocks the LAN connection. The Vision
Pro and the 3DS must be on the same Wi-Fi.

## Usage

```swift
import S3DSKit

let streamer = S3DSStreamer()              // hardware-proven defaults, see "Recommended settings"
streamer.connect(host: "192.168.1.50")     // IP shown on the 3DS bottom screen; port 7777
// UI: streamer.connectionState, streamer.stats, streamer.bitrate = 1_500_000, ...
// optional: streamer.isPreviewEnabled = true → streamer.previewImage (800x240 SBS CGImage)
```

`S3DSStreamer` is `@MainActor @Observable` (state for SwiftUI). Its `submit…` methods,
`nextCaptureDue(at:)` and `requestKeyframe()` are `nonisolated` and thread-safe.

### 1. Texture pair: your app already has eye images

Call it every display frame. The built-in throttle passes `framesPerSecond` (default 30) and
returns `false` from extra calls without doing any work. It keeps a fixed cadence (every 2nd call
at 60 Hz, every 3rd at 90 Hz, a 3/4 mix at 100 Hz) and restarts after pauses without a burst. For example, in a frame pump that copies
an emulator's stereo frame each display frame, before `cb.commit()`:

```swift
streamer.submit(left: frame.left, right: frame.right, commandBuffer: cb)
```

- **Sizes**: any. Each eye is fitted into 400x240 per `streamer.frameOptions.fit`.
  `.letterbox` is the default (keeps the aspect ratio with black bars, so 4:3 becomes 320x240
  centered), `.crop` fills and cuts the excess, `.stretch` ignores the aspect ratio. Large
  sources get up to 4x4 bilinear taps per output pixel, so 1920x1440 → 320x240 does not alias.
- **Mono**: `right: nil` shows `left` to both eyes.
- **Formats**: `rgba8Unorm` and `bgra8Unorm` (and other Unorm formats) are copied as-is, so
  they should hold sRGB-encoded color, which is what the 3DS shows. `*_srgb` and float formats
  are read as linear and re-encoded to sRGB. Textures need `.shaderRead` usage and must live on
  `streamer.device` (the system default device unless you pass one to `init`).
- **`commandBuffer`**: if you pass yours, the scale/rotate pass is encoded into it, after your
  rendering. You still commit it, and the library adds a completion handler. If you pass `nil`,
  the library uses its own queue. Either way nothing blocks your thread. Encoding and
  networking run on background queues after the GPU completes.
- `frameOptions.swapEyes` and `frameOptions.flipY` (for bottom-up sources) can be changed live.

### 2. Metal / Compositor Services: let the library own the eye targets

`StereoCamera` gives per-eye view and projection matrices for a 3DS-like camera: IPD 0.063 m ×
`depthMultiplier`, 40° vertical FOV, 5:3, reverse-Z, and convergence at 1.5 m by default
(`nil` for parallel eyes). `StereoEyeRenderer` owns triple-buffered 400x240 color and depth
targets and calls your draw code once per eye:

```swift
import ARKit
import CompositorServices
import S3DSKit

final class StreamCapture {
    let streamer: S3DSStreamer
    let eyes: StereoEyeRenderer          // .bgra8Unorm_srgb + .depth32Float by default
    var camera = StereoCamera()
    let scenePipeline: MTLRenderPipelineState   // built with eyes.colorPixelFormat/depthPixelFormat
    let depthState: MTLDepthStencilState         // compare .greater (reverse-Z)

    // Call from the Compositor Services render loop, after rendering the drawables.
    func captureIfDue(commandBuffer: MTLCommandBuffer, deviceAnchor: DeviceAnchor?, time: Double) {
        guard streamer.nextCaptureDue() else { return }          // cheap when not due
        let head = deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        let textures = eyes.render(commandBuffer: commandBuffer, camera: camera,
                                   headTransform: head) { encoder, eye in
            encoder.setRenderPipelineState(self.scenePipeline)
            encoder.setDepthStencilState(self.depthState)
            // Same scene draw as for the wearer, with this eye's matrices:
            drawScene(encoder, view: eye.view, projection: eye.projection, time: time)
        }
        streamer.submit(textures, commandBuffer: commandBuffer, throttle: false)
    }
}
// In the frame loop: render each drawable view, then
//   capture.captureIfDue(commandBuffer: cb, deviceAnchor: anchor, time: t)
//   drawable.encodePresent(commandBuffer: cb); cb.commit(); frame.endSubmission()
```

The streamer is a `@MainActor` class, but `nextCaptureDue()` and `submit` are `nonisolated`, so
the render thread can call them directly. Keep a reference to the streamer and create it on the
main actor.

### 3. RealityKit

`S3DSRealityCapture` renders entities with an offscreen `RealityRenderer`, using one
`PerspectiveCamera` render per eye:

```swift
let capture = try S3DSRealityCapture(streamer: streamer)
capture.renderer.entities.append(sceneCopy)   // an entity can be in one scene only: use a clone
// every frame (main actor):
try capture.capture(headTransform: headPose, deltaTime: dt)
```

`PerspectiveCamera` frusta are symmetric, so the eyes are parallel and `convergenceDistance` is
ignored. Tested in the simulator: a box renders into both eyes.

### 4. Pre-rotated pixel buffers (advanced)

`submit(pixelBuffer:eye:)` takes 32BGRA, sRGB-encoded buffers already in the layout: 240x400
with `eye: .left` and then `.right` for the alternating layout, or one 240x800 buffer with
`eye: nil` for stacked. `RotationMapping` has the pixel mapping.

### 5. Audio

Audio goes out on the same connection as the video. The library encodes it as Opus at 48 kHz
stereo, in 20 ms packets (960 frames) at 96 kbps by default (`audioBitrate`). Each packet is
sent as an `AUDIO` (0x03) message: a big-endian µs timestamp followed by the Opus packet. The
timestamp uses the same clock as the video frames (`CACurrentMediaTime`, i.e.
`mach_absolute_time`). Audio is on by default; turn it off with
`S3DSConfiguration(audioEnabled: false)`. Submissions are ignored while not connected.

The submit calls are **real-time safe**. They only copy into a ring buffer, holding an
`os_unfair_lock` for the copy and allocating nothing. Resampling, upmixing and encoding run on
a background queue. Any sample rate works; mono is sent to both channels.

Example: a game core that produces mono Float32 at 48 kHz on its audio thread. Hand each
rendered block to the streamer from that same callback:

```swift
// inside the audio render block, after filling `out` (frameCount mono Float32 samples):
streamer.submitAudio(samples: UnsafeBufferPointer(start: out, count: Int(frameCount)),
                     channels: 1, sampleRate: 48_000)
```

Other inputs: `submitAudio(_ buffer: AVAudioPCMBuffer, hostTime:)` takes Float32 or Int16
buffers, interleaved or not (for example from an `AVAudioEngine` tap; pass `when.hostTime`).
Interleaved stereo works with `submitAudio(samples:channels: 2, sampleRate:)`.

To check the input rate, read `stats.audioInputFramesPerSecond` (frames per channel per second
of wall-clock time, last ~2 s; it should equal the `sampleRate` you declare, e.g. 48000),
`stats.audioPacketsPerSecond` (50 for real-time input) and `stats.audioDroppedInputFrames`
(input lost in the ring, normally 0). A rate above the declared one means the app produces audio
faster than real time and the 3DS will receive more audio than it can play.

Audio is never dropped by the video backpressure logic, only when the connection is down. Sends
are asynchronous, so audio and video do not wait on each other.

## Recommended settings / hardware notes

The defaults are the settings proven on a New 3DS XL: 29.9 stereo pairs/s with 0 decode errors.
See [`docs/ARCHITECTURE.md` › Hardware findings](docs/PROTOCOL.md#hardware-findings-new-3ds-xl-2026-10-14).

| Setting | Default | Notes |
|---|---|---|
| `layout` | `.alternating240x400` | The 3DS MVD decoder crashes on 240x800. |
| `framesPerSecond` | 20 stereo pairs | 40 encoded fps (L, R, L, R…). 30 pairs worked on a New 3DS XL with x264; lowered after Vision Pro device runs. |
| `bitrate` | 1.2 Mbps | Clamped to 0.5–3 Mbps. Above ~2 Mbps risks stalls over the 3DS's Wi-Fi (2.5 Mbps stalled). |
| `keyframeInterval` | 2 × `framesPerSecond` | An IDR every 2 s (80 encoded frames), always on a **left** frame, with SPS+PPS before each IDR. Forced IDRs (connect, `KEYFRAME_REQ`, oversize/multi-slice drops) are rate-limited to 1 per second. |
| `maxInFlightFrames` | ≈ 250 ms | 5 pairs = 10 AUs at the default rate. Beyond that, video is dropped until the next **scheduled** keyframe; no extra IDR is forced (that caused IDR storms on a congested link). |
| `audioBitrate` | 96 kbps | Opus, 48 kHz stereo, 20 ms. |
| `encoder` | `.automatic` | Software H.264 encoder (see below). |

The library always enforces the following:

- **Exactly one slice per picture.** The MVD decoder corrupts and then crashes on
  multi-slice frames. VideoToolbox's software H.264 encoder (used in the simulator) emits 2–5
  slices by default. S3DSKit sets the session property `NumberOfSlices = 1`, which
  `VTSessionCopySupportedPropertyDictionary` lists but has no public constant, and never sets
  `MaxH264SliceBytes`.
  - It also checks every picture. A multi-slice picture is logged (`log.fault`) and dropped, an
    IDR is requested, and `stats.multiSlicePicturesDropped` counts it. From a software session
    it also triggers an assertion in DEBUG.
  - **Software encoder by default** (`encoder: .automatic`): the Vision Pro's hardware H.264
    encoder was suspected of ignoring `NumberOfSlices` (being verified on device). On a real Vision
    Pro, VideoToolbox ignores the software request and uses the hardware encoder, which so far
    emitted no multi-slice pictures. 240x400 costs little CPU (~5 ms average latency per frame
    at 60 fps in the simulator). If a hardware session is ever in use (software unavailable) and
    emits a multi-slice picture, the session is rebuilt once on the software encoder.
    `.software` never uses hardware; `.hardware` is VideoToolbox's default choice, and its
    multi-slice pictures are only dropped. `stats.encoderIsHardware` shows which one is running,
    and the session's choice is logged (`Logger` subsystem `S3DSKit`, category `encoder`).
- H.264 Baseline, no B-frames (`AllowFrameReordering = false`), no AUD or SEI NALs.
- **Zero output delay in the SPS.** VideoToolbox writes a VUI without `bitstream_restriction`,
  so a decoder may assume reordering and hold pictures before output. On the 3DS that desynced
  the eyes (the right eye showed an older picture). S3DSKit rewrites every SPS it sends to add
  `bitstream_restriction` with `max_num_reorder_frames = 0` and
  `max_dec_frame_buffering = max(1, max_num_ref_frames)` (like x264), all other fields unchanged.
  An SPS it cannot parse is sent unchanged and logged once. It also asks for
  `ReferenceBufferCount = 1` where the encoder supports it (the simulator's does not).
- A `VIDEO_AU` payload may be at most 256 KiB, the receiver's limit. A larger AU is dropped and an
  IDR is forced on the next left frame. An `AUDIO` payload may be at most 4 KiB.

## Threading notes

- `S3DSStreamer` state (`connectionState`, `stats`, `previewImage`, `bitrate`, `frameOptions`)
  is main-actor. Frame input is thread-safe and never blocks. The library never calls
  `waitUntilCompleted`.
- `StereoEyeRenderer.render` must be called from one thread at a time. `S3DSRealityCapture` is
  main-actor.
- At most 3 stereo frames are in flight on the GPU. If the network backs up (more than
  `maxInFlightFrames` stereo frames, 12 AUs by default, unsent), non-key frames are dropped and
  a new left IDR is forced once the backlog drains. Audio is exempt.
- `connect` does not retry on its own. On failure `connectionState` is `.failed(reason)`. Call
  `connect` again, for example from a button.

## Building and testing

```sh
cd visionos
xcodebuild build -scheme S3DSKit -destination 'platform=visionOS Simulator,name=Apple Vision Pro'
xcodebuild test  -scheme S3DSKit -destination 'platform=visionOS Simulator,name=Apple Vision Pro'
```

`swift test` cannot run visionOS tests, so use `xcodebuild`. The suite covers:

- protocol framing, AVCC→Annex-B, the SPS `bitstream_restriction` rewrite, slice counting, mapping, fit and letterbox math, camera math,
  and the hardware defaults;
- GPU kernel exactness, pixel by pixel, for both layouts;
- encoder keyframe placement (IDR only on left frames, deferred requests);
- the frame throttle (60/90/100/120 Hz, jitter, pauses) on a synthetic clock; audio stats
  (input rate, packet rate, ring drops);
- Opus at 50 packets/s with 20 ms timestamps, from 48 kHz and from 44.1 kHz input, decoded back
  to a 440 Hz sine; the audio ring buffer;
- end-to-end loopback streaming to a fake 3DS, for alternating (with interleaved audio, decoded
  back to 440 Hz, and one slice per AU), stacked, mono 1920x1440 at 90 Hz (throttle) and
  preview;
- the RealityKit adapter.

The end-to-end tests write what they received to the simulator's temp dir and print
`S3DSKIT_DUMP <name>: <path>`. Inspect a dump with:

```sh
ffprobe -v error -show_streams -count_frames <path>/s3ds_alternating.h264   # 240x400 Constrained Baseline
ffmpeg -i <path>/s3ds_alternating.h264 -vf "select=between(n\,40\,41),transpose=cclock,tile=2x1" -frames:v 1 pair.png
```

Use 3DSStream's `tools/recv_sim.py` as a fake 3DS on the Mac when testing a real app in the simulator.
