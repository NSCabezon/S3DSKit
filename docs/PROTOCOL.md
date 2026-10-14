> Copy of [3DSStream `docs/ARCHITECTURE.md`](https://github.com/NSCabezon/3DSStream/blob/main/docs/ARCHITECTURE.md), the source of truth for the wire protocol. Keep both in sync.

# 3DSStream — Architecture

Stream stereoscopic 3D content rendered by a visionOS app (Apple Vision Pro) to a
**New Nintendo 3DS** (CFW, Homebrew Launcher), shown glasses-free on the top screen.

```
 Apple Vision Pro (visionOS app "StereoCaster")            New 3DS (homebrew "3DSStream")
 ┌──────────────────────────────────────────────┐         ┌──────────────────────────────────┐
 │ Metal scene ──► stereo capture (2 eyes,      │         │ TCP server :7777                 │
 │                 400x240 each, head pose)     │         │   │                              │
 │             ──► rotate+stack → 240x800 BGRA  │  WiFi   │   ▼ parse frames, split NALs     │
 │             ──► VideoToolbox H.264 Baseline  │ ──TCP──►│ MVD hw decoder → BGR565 240x800  │
 │             ──► Annex-B AU ──► framing       │         │   ├ rows   0..399 → top LEFT fb  │
 │ ◄── keyframe request (optional) ─────────────│◄────────│   └ rows 400..799 → top RIGHT fb │
 └──────────────────────────────────────────────┘         └──────────────────────────────────┘
```

Components:

| Where | What |
|---|---|
| `3ds/` (this repo) | 3DS receiver (C, libctru, devkitARM). Outputs `3DSStream.cia` / `.3dsx`. |
| `tools/` (this repo) | Mac tools (Python 3 stdlib + ffmpeg): test sender, fake 3DS receiver, CIA QR server, spatial-video converter. |
| [S3DSKit](https://github.com/NSCabezon/S3DSKit) (separate repo) | visionOS sender library (Swift 6, Metal, VideoToolbox, Opus). Ships a copy of this file as `docs/PROTOCOL.md`; this file is the source of truth. |

## Video format (the contract)

> **Default layout is now _alternating_ (2026-10-14).** Stacked 240×800 crashed the New 3DS `mvd`
> system module on hardware (data abort inside mvd, FAR in our linear heap). Alternating sends one
> eye per H.264 frame at **240×400** (the size the official devkitPro example uses), frames
> L, R, L, R… at 2× the stereo rate (60 fps for 30 pairs); every IDR is a LEFT frame. Each eye
> uses the same 90°-clockwise pre-rotation described below; MVD decodes each frame straight into
> that eye's back framebuffer and the receiver swaps after the right eye. The stacked description
> below is kept for reference and is still supported behind flag bit2 = 0.

The 3DS top-screen framebuffer is stored **rotated**: a 400×240 screen is a 240-wide ×
400-tall buffer, pixel at screen `(x, y)` (x 0..399 left→right, y 0..239 top→bottom) lives at
index `x*240 + (239 - y)`. To let the MVD decoder write framebuffer-ready pixels with zero CPU
rotation (same trick as the devkitPro `mvd` example), **the sender pre-rotates**:

- Encoded frame size: **240 wide × 800 tall**.
- Each eye is a 400×240 image rotated **90° clockwise** (→ 240×400). ffmpeg: `transpose=clock`.
- Rows `0..399` = **left** eye, rows `400..799` = **right** eye (vertical stack).
- Mapping: encoded pixel at (col `c`, row `r`): eye = `r < 400 ? L : R`, `sx = r % 400`,
  `sy = 239 - c` → eye image pixel `(sx, sy)` (eye image origin top-left).

On the 3DS the decoded 240×800 BGR565 buffer is contiguous: first `240*400*2 = 192000` bytes
are exactly the left-eye framebuffer, next 192000 bytes the right-eye framebuffer.

Codec: **H.264 Baseline**, no B-frames, single slice, ~30 fps, 1–2 Mbps (default 1500 kbps),
keyframe interval ≤ 1 s (30 frames), SPS+PPS repeated in-band before every IDR, no AUD NALs.

Fallback if MVD rejects 240×800: decode 800×240 unrotated (as topos 3DS does) and draw via
GPU textures. Reference: `github.com/mockmodular/topos_3ds-video-player` (GPL-3.0).

## Wire protocol (TCP, port 7777)

The **3DS is the server** (listens on 7777, shows its IP on the bottom screen). The sender
connects. One sender at a time; a new connection replaces the old one.

All integers big-endian. Every message = 12-byte header + payload:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | magic `"S3DS"` (0x53 0x33 0x44 0x53) |
| 4 | 1 | type |
| 5 | 1 | flags |
| 6 | 2 | reserved (0) |
| 8 | 4 | payload length (bytes) |

Types:

| Type | Dir | Payload | Notes |
|---|---|---|---|
| `0x01` VIDEO_AU | sender→3DS | one H.264 access unit, Annex-B (start codes `00 00 00 01` or `00 00 01`) | flags: bit0 (0x01) keyframe (AU contains IDR); bit1 (0x02) eye in alternating layout, 0 = left / 1 = right; bit2 (0x04) layout, 1 = alternating, 0 = stacked. Max payload 512 KiB. |
| `0x02` HELLO | sender→3DS | UTF-8 sender name (≤ 64 B) | optional, first message |
| `0x03` AUDIO | sender→3DS | `u64` BE timestamp in µs (sender clock, same clock as video capture) + one **Opus** packet | 48 kHz, stereo (mono senders upmix or send mono Opus — the decoder outputs stereo either way), 20 ms frames, ~96 kbps CBR/VBR. flags unused (0). Max payload 4 KiB. |
| `0x10` KEYFRAME_REQ | 3DS→sender | empty | sent on connect, after decode error, or after dropping frames |

Rules:
- Sender's first VIDEO_AU after (re)connect or KEYFRAME_REQ must be a keyframe (force IDR).
- Receiver drops non-key AUs until it has seen a keyframe (SPS+PPS+IDR).
- Latency control: receiver keeps ≤ 2 queued AUs; if more pile up it drops until the next
  keyframe and sends KEYFRAME_REQ. Sender drops non-key frames if its send buffer backs up.
- Bad magic / oversize length → receiver closes the connection.

## Hardware findings (New 3DS XL, 2026-10-14)

- **MVD only decodes single-slice pictures.** Multi-slice frames (x264 `-tune zerolatency`
  defaults to one slice per thread) return INCOMPLETEPROCESSING / 0x17005 and the next IDR
  crashes the `mvd` sysmodule. Senders MUST emit exactly one slice per frame
  (x264: `sliced-threads=0:slices=1`).
- **SPS/PPS are fed to MVD once** (re-fed only if they change), although senders repeat them.
- **WiFi delivers AUs in bursts.** The receiver allows up to 12 pending AUs (200 ms at 60 fps)
  before flushing to the next IDR; with 2 it dropped to ~1 fps. Receiver payload cap 256 KiB.
- Measured: alternating 240×400 @ 60 fps (30 stereo pairs) at ~2.5 Mbps → 25–29 pairs/s shown.

## Audio

- Opus, 48 kHz, stereo out, 20 ms packets, sent as AUDIO messages interleaved with video on the
  same TCP connection.
- 3DS: decoded with libopus (devkitPro `3ds-libopus`) on an audio thread, played with `ndsp`
  (needs `sdmc:/3ds/dspfirm.cdc`), ~100 ms jitter buffer; if the buffer underruns, insert
  silence; if it exceeds ~300 ms, drop oldest packets. A/V sync v1 = play on arrival (both
  streams have similar latency); timestamps are carried for a later sync pass.
- CIA RSF needs `dsp::DSP` service access.

## 3DS receiver notes

- New 3DS only (`APT_CheckNew3DS`); `osSetSpeedupEnable(true)`.
- `gfxInit(GSP_RGB565_OES, GSP_BGR8_OES, false)`, `gfxSet3D(true)`, console on bottom screen.
- MVD: `mvdstdInit(MVDMODE_VIDEOPROCESSING, MVD_INPUT_H264, MVD_OUTPUT_BGR565, MVD_DEFAULT_WORKBUF_SIZE, NULL)`,
  `mvdstdGenerateDefaultConfig(&cfg, 240, 800, 240, 800, NULL, out, out)`. Feed one NAL per
  `mvdstdProcessVideoFrame` call **with a 3-byte `00 00 01` prefix** (as the devkitPro example
  does); render with `mvdstdRenderVideoFrame` when status is not PARAMSET / INCOMPLETEPROCESSING.
  Input/output buffers in linear memory (`linearMemAlign`), flush/invalidate caches.
- Sockets: `socInit` with a 0x100000-byte `memalign(0x1000)` buffer; network thread receives,
  main thread decodes + presents.

## visionOS sender notes

- Same Metal scene drawn (a) to the Compositor Services layer for the wearer in the immersive
  space and (b) offscreen as a 400×240 stereo pair from the wearer's head pose (ARKit
  `WorldTrackingProvider` device anchor), at ≤ 30 fps.
- Virtual stereo camera: IPD default 0.063 m × user "depth" multiplier, vertical FOV ~40°, 5:3.
- Compute pass rotates + stacks into an IOSurface-backed 240×800 BGRA `CVPixelBuffer`
  → `VTCompressionSession` → AVCC→Annex-B → Network.framework TCP (`noDelay`).
- Window-only mode (no immersive space, orbit camera) for the simulator and quick tests.

## Dev loop

1. `tools/recv_sim.py` = fake 3DS on the Mac: run the visionOS app in the simulator, connect to
   `127.0.0.1:7777`, see the de-rotated SBS stream in ffplay.
2. `tools/send_test.py --host <3DS IP>` = fake Vision Pro: test the 3DS receiver alone.
3. Real devices: both on the same WiFi, Vision Pro app → 3DS IP shown on its bottom screen.
