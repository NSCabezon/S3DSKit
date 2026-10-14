# S3DSKit: notes for Claude

Swift package (visionOS 26+, Swift 6) that streams stereo video + audio to a New 3DS running the
[3DSStream](https://github.com/NSCabezon/3DSStream) receiver. The wire contract is
`docs/PROTOCOL.md`, a copy of 3DSStream's `docs/ARCHITECTURE.md`. Change the protocol there first,
then re-copy it here.

## Hard rules (each one broke the 3DS on hardware)

- H.264 must be **exactly one slice per frame**. VideoToolbox splits pictures by default, and a
  multi-slice frame crashes the 3DS `mvd` sysmodule. `H264Encoder` sets the session's
  `NumberOfSlices` to 1 and checks every picture. Never remove that check.
- `H264Encoder` defaults to the **software** encoder (`S3DSConfiguration.encoder = .automatic`)
  because the Vision Pro hardware encoder was suspected of ignoring `NumberOfSlices` (being
  verified on device). On a real Vision Pro the software request is ignored (the session reports
  hardware) and no multi-slice pictures were seen. A hardware multi-slice picture triggers at most
  one rebuild; it never loops.
- Defaults: alternating 240x400 at 20 pairs (40 encoded fps), 1.2 Mbps, an IDR every 2 s
  (80 frames) and only on LEFT frames (lowered from 30 pairs / 1.5 Mbps / 1 s after Vision Pro
  device runs showed an IDR storm). Forced IDRs are limited to 1/s. Also Baseline, ≤ 256 KiB per
  AU, Opus 48 kHz stereo 20 ms 96 kbps, adaptive bitrate on. `DefaultsTests` asserts them.
- **Congestion is handled before encoding, per stereo pair** (`CongestionPolicy`,
  `CongestionController`). Never drop an already-encoded frame as the normal reaction to a
  backed-up link: it breaks the reference chain, everything until the next IDR is lost, and the
  IDR re-congests the link (device run: 40 frames/s submitted, ~4 pairs/s shown). Instead:
  - Backlog = max(age of the oldest video AU queued in Network.framework, (those bytes + the
    unacknowledged TCP send buffer, sampled every 10 ms) at the stream's bitrate). The send
    buffer matters: NW completes a send once data is in the socket, which can hold ~1 s on a
    slow link.
  - Backlog ≥ 150 ms: the due pair is skipped in `reserveCapture`/`submit` (never rotated nor
    encoded; both eyes together; a pixel-buffer right frame is accepted only after an accepted
    left). `stats.congestionPairsSkipped`.
  - Backlog ≥ 450 ms (or `maxInFlightFrames`, default 9 pairs): last-resort drop of encoded
    left/stacked frames only (a right whose left went out is always sent). The sender then
    requests an IDR once the backlog is < 150 ms, never while congested; `KEYFRAME_REQ` is held
    back the same way.
  - Adaptive bitrate: > 20 % of a 2 s window's pairs skipped, or the window's average backlog
    ≥ 100 ms → ×0.8, or straight to the link fit when lower: (0.85 × bytes the 3DS acked over
    the window − audio) ÷ the encoder's measured overshoot (the Vision Pro HW encoder runs
    20-50 % over its target) (floor 0.5 Mbps); 5 s without a skip or a backed-up window → ×1.1 up to the
    configured bitrate. `stats.videoBitrate`. `setStartBitrate` starts below the ceiling (apps
    pass the rate that last worked with that receiver). Device run: the backlog trigger exists
    because a link just under the bitrate held 1.2 Mbps for 12 s at 5-15 % skips.
  - The 1/s engine log shows `pairs-skipped`, `bitrate`, `backlog` and `socket` KiB.
- `H264Encoder`'s output callback must never take the session lock (`lock`): `reset()` holds it
  across `VTCompressionSessionCompleteFrames`, which waits for callbacks (that deadlocked every
  encoder test). Callback-side state lives in `shared`.
- Every SPS sent goes through `SPSRewriter` (`bitstream_restriction`, `max_num_reorder_frames = 0`,
  `max_dec_frame_buffering = max(1, refs)`). Without it the 3DS decoder delays output and the
  right eye shows an older picture than the left. Never send VideoToolbox's SPS raw.
- `submit…`/`submitAudio` are nonisolated and must never block the caller (no
  `waitUntilCompleted`, no allocation on the audio path).

## Build and test

```sh
xcodebuild test -scheme S3DSKit -destination 'platform=visionOS Simulator,name=Apple Vision Pro'
```

Zero warnings. The integration tests run a fake 3DS on an ephemeral local port. To test with a real
3DS, use 3DSStream's tools (`recv_sim.py` as a fake receiver, or the real CIA).

## Status (2026-10-14)

Release 0.1.1 published. 83 tests pass. Verified on a Vision Pro → New 3DS XL (Time Crisis app): right eye in
sync (SPS rewrite), 21 pairs/s on the 3DS with 0 post-encode drops (was ~4 pairs/s), audio buffer full, the
adaptive bitrate stepping straight to the link fit, and the app's per-host start bitrate working. On a weak
Wi-Fi link it sits at the 0.5 Mbps floor and skips pairs (~16 pairs/s); a lower floor or a lower frame rate at
the floor are the options if that matters. The hardware encoder overshoots its target by 20-50 %.

First real-device run (a visionOS game app at 90 Hz, built against the pre-split package): stereo
works, and the right-eye lag is fixed by the SPS rewrite plus the receiver's SPS patch. Still to
check with a fresh build: the ~88 fps / 2.4 Mbps seen on the 3DS (the old throttle is correct in
simulation, so the cause is unknown), the excess audio (use the new audio stats), and whether the
hardware encoder honours `NumberOfSlices` (a DEBUG build asserts).

Don't modify other repos (the user's apps) without the user's OK.

## Delegation

Concurrency and VideoToolbox code (`H264Encoder`, `StreamEngine`, `StreamSender`, `Audio/`) goes
to `general-purpose` or `deep-reasoner`, never `fast-worker`. Docs and tests are fine for
`fast-worker`.
