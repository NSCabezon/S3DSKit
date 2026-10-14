# S3DSKit

Swift package that streams stereo frames from a visionOS app to a New Nintendo 3DS running
the 3DSStream receiver (`../3ds`), shown glasses-free on the 3DS top screen.

It takes eye images (Metal textures, a RealityKit scene, or ready-made pixel buffers), scales
and rotates them into the 3DS framebuffer layout on the GPU, encodes H.264 Baseline with
VideoToolbox and sends it over TCP (Network.framework). No third-party dependencies.

- Platforms: visionOS 26+ (Swift 6 language mode; works from Swift 5 mode apps too).
- Video/wire contract: [`docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md).

## The stream in one paragraph

Each eye is a 400x240 image rotated 90° clockwise into a 240-wide x 400-tall block (eye pixel
`(x, y)` → block pixel `(column 239 - y, row x)`), so the 3DS hardware decoder writes
framebuffer-ready pixels. The default layout, `.alternating240x400`, sends one eye per H.264
frame, L, R, L, R at twice the stereo rate (60 fps for 30 stereo frames). Keyframes are always
left frames, at least every second, with SPS+PPS before every IDR and no AUD NALs.
`VIDEO_AU` flags: bit0 keyframe, bit1 eye (0 left, 1 right), bit2 alternating. The
`.stacked240x800` layout puts both blocks in one 240x800 frame (left on top), but the 3DS MVD
decoder crashes on 240x800, so use it only with receivers that support it. The 3DS is the TCP
server on port 7777. The app connects and sends `HELLO`, then `VIDEO_AU`s, and forces an IDR
whenever the 3DS sends `KEYFRAME_REQ`.

## Adding the package

The package lives in the `visionos/` subdirectory of the 3DSStream repo:

- **Local path** (simplest): Xcode ▸ File ▸ Add Package Dependencies… ▸ Add Local… ▸ pick
  `3DSStream/visionos`. With XcodeGen:
  ```yaml
  packages:
    S3DSKit:
      path: ../3DSStream/visionos
  targets:
    MyApp:
      dependencies:
        - package: S3DSKit
  ```
- **Git URL**: SwiftPM needs `Package.swift` at the root of the repository, so a URL to the
  3DSStream repo does **not** work as is. To consume it by URL, publish `visionos/` as its own
  repository (e.g. `git subtree split --prefix visionos -b s3dskit` and push that branch to a
  new repo), then add that repo's URL.

**Info.plist (required):** `NSLocalNetworkUsageDescription`, e.g. "Streams 3D video to your
Nintendo 3DS on the local network." Without it visionOS blocks the LAN connection. The Vision
Pro and the 3DS must be on the same Wi-Fi.

## Usage

```swift
import S3DSKit

let streamer = S3DSStreamer()              // defaults: alternating layout, 30 stereo fps, 2 Mbps
streamer.connect(host: "192.168.1.50")     // IP shown on the 3DS bottom screen; port 7777
// UI: streamer.connectionState, streamer.stats, streamer.bitrate = 1_500_000, ...
// optional: streamer.isPreviewEnabled = true → streamer.previewImage (800x240 SBS CGImage)
```

`S3DSStreamer` is `@MainActor @Observable` (state for SwiftUI). Its `submit…` methods,
`nextCaptureDue(at:)` and `requestKeyframe()` are `nonisolated` and thread-safe.

### 1. Texture pair: your app already has eye images

Call it every display frame. The built-in throttle passes `framesPerSecond` (default 30) and
returns `false` from extra calls without doing any work. In the tc-visionos `FramePump.pump`,
before `cb.commit()`:

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

## Threading notes

- `S3DSStreamer` state (`connectionState`, `stats`, `previewImage`, `bitrate`, `frameOptions`)
  is main-actor. Frame input is thread-safe and never blocks. The library never calls
  `waitUntilCompleted`.
- `StereoEyeRenderer.render` must be called from one thread at a time. `S3DSRealityCapture` is
  main-actor.
- At most 3 stereo frames are in flight on the GPU. If the network backs up (more than
  `maxInFlightFrames` stereo frames unacknowledged), non-key frames are dropped and a new left
  IDR is forced once the backlog drains.
- `connect` does not retry on its own. On failure `connectionState` is `.failed(reason)`. Call
  `connect` again, for example from a button.

## Building and testing

```sh
cd visionos
xcodebuild build -scheme S3DSKit -destination 'platform=visionOS Simulator,name=Apple Vision Pro'
xcodebuild test  -scheme S3DSKit -destination 'platform=visionOS Simulator,name=Apple Vision Pro'
```

`swift test` cannot run visionOS tests, so use `xcodebuild`. The suite covers:

- protocol framing, AVCC→Annex-B, mapping, fit and letterbox math, camera math;
- GPU kernel exactness, pixel by pixel, for both layouts;
- encoder keyframe placement (IDR only on left frames, deferred requests);
- end-to-end loopback streaming to a fake 3DS, for alternating, stacked, mono 1920x1440 at
  90 Hz (throttle) and preview;
- the RealityKit adapter.

The end-to-end tests write what they received to the simulator's temp dir and print
`S3DSKIT_DUMP <name>: <path>`. Inspect a dump with:

```sh
ffprobe -v error -show_streams -count_frames <path>/s3ds_alternating.h264   # 240x400 Constrained Baseline
ffmpeg -i <path>/s3ds_alternating.h264 -vf "select=between(n\,40\,41),transpose=cclock,tile=2x1" -frames:v 1 pair.png
```

Use `../tools/recv_sim.py` as a fake 3DS on the Mac when testing a real app in the simulator.
