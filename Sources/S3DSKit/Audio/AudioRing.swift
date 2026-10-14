import os

/// Fixed-capacity stereo Float32 ring buffer between the app's audio thread (producer) and the
/// audio encoding queue (consumer).
///
/// Writes take an `os_unfair_lock` only for the duration of a memcpy-like loop and never
/// allocate, so they are safe to call from a real-time audio callback. When full, the oldest
/// frames are overwritten. A change of input sample rate resets the ring (and bumps
/// `generation` so the consumer rebuilds its resampler).
final class AudioRing: @unchecked Sendable {
    struct ReadResult {
        var frames: Int
        var sampleRate: Double
        var generation: Int
        /// Host time (CACurrentMediaTime seconds) at the end of the most recent write.
        var lastWriteEnd: Double
        /// Frames still in the ring after this read.
        var remaining: Int
    }

    private struct State {
        var readIndex = 0
        var count = 0
        var sampleRate: Double = 48_000
        var generation = 0
        var lastWriteEnd: Double = 0
    }

    let capacityFrames: Int
    private let storage: UnsafeMutablePointer<Float>   // interleaved L R L R ...
    private let lock = OSAllocatedUnfairLock(initialState: State())

    init(capacityFrames: Int = 192_000) {
        self.capacityFrames = capacityFrames
        storage = .allocate(capacity: capacityFrames * 2)
        storage.initialize(repeating: 0, count: capacityFrames * 2)
    }

    deinit { storage.deallocate() }

    /// Appends `frames` frames. `sample(frame, channel)` returns channel 0 (left) or 1 (right).
    /// Real-time safe: no allocation, short lock.
    func write(frames: Int, sampleRate: Double, endTime: Double, sample: (Int, Int) -> Float) {
        guard frames > 0 else { return }
        let cap = capacityFrames
        let storage = self.storage
        lock.withLockUnchecked { s in
            if s.sampleRate != sampleRate {
                s = State(readIndex: 0, count: 0, sampleRate: sampleRate, generation: s.generation + 1,
                          lastWriteEnd: 0)
            }
            // Only the newest `cap` frames can survive.
            let skip = max(0, frames - cap)
            var w = (s.readIndex + s.count) % cap
            for f in skip..<frames {
                storage[2 * w] = sample(f, 0)
                storage[2 * w + 1] = sample(f, 1)
                w += 1
                if w == cap { w = 0 }
            }
            let written = frames - skip
            let newCount = s.count + written
            if newCount > cap {
                s.readIndex = (s.readIndex + (newCount - cap)) % cap
                s.count = cap
            } else {
                s.count = newCount
            }
            s.lastWriteEnd = endTime
        }
    }

    /// Copies up to `maxFrames` interleaved stereo frames into `destination`.
    func read(into destination: UnsafeMutablePointer<Float>, maxFrames: Int) -> ReadResult {
        let cap = capacityFrames
        let storage = self.storage
        return lock.withLockUnchecked { s in
            let n = min(maxFrames, s.count)
            var r = s.readIndex
            for i in 0..<n {
                destination[2 * i] = storage[2 * r]
                destination[2 * i + 1] = storage[2 * r + 1]
                r += 1
                if r == cap { r = 0 }
            }
            s.readIndex = r
            s.count -= n
            return ReadResult(frames: n, sampleRate: s.sampleRate, generation: s.generation,
                              lastWriteEnd: s.lastWriteEnd, remaining: s.count)
        }
    }

    /// Drops everything buffered.
    func clear() {
        lock.withLockUnchecked { s in
            s.readIndex = 0
            s.count = 0
        }
    }
}
