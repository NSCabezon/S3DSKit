# S3DSKit: notes for Claude

Swift package (visionOS 26+, Swift 6) that streams stereo video + audio to a New 3DS running the
[3DSStream](https://github.com/NSCabezon/3DSStream) receiver. The wire contract is
`docs/PROTOCOL.md`, a copy of 3DSStream's `docs/ARCHITECTURE.md`. Change the protocol there first,
then re-copy it here.

## Hard rules (each one broke the 3DS on hardware)

- H.264 must be **exactly one slice per frame**. VideoToolbox splits pictures by default, and a
  multi-slice frame crashes the 3DS `mvd` sysmodule. `H264Encoder` sets the session's
  `NumberOfSlices` to 1 and checks every picture. Never remove that check.
- Defaults are the hardware-proven ones: alternating 240x400 at 60 fps, 1.5 Mbps, an IDR every
  60 frames and only on LEFT frames, Baseline, ≤ 256 KiB per AU, ≤ 200 ms of video in flight, Opus
  48 kHz stereo 20 ms 96 kbps. `DefaultsTests` asserts them.
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

55 tests pass. Not yet verified on a real Vision Pro: that its hardware encoder honors
`NumberOfSlices` (a DEBUG build asserts if not). First intended consumer is one of the user's own visionOS apps;
don't modify other repos without the user's OK.

## Delegation

Concurrency and VideoToolbox code (`H264Encoder`, `StreamEngine`, `StreamSender`, `Audio/`) goes
to `general-purpose` or `deep-reasoner`, never `fast-worker`. Docs and tests are fine for
`fast-worker`.
