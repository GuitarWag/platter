// Pure DSP and math for the DJ rig. No audio or UI types here, so this compiles and
// unit-tests without a runtime, a microphone, or a window.

import Foundation

/// Peak table for the waveform view. Downsamples a mono mixdown to `bucketCount` buckets of
/// peak amplitude, each in `0...1`.
package struct PeakTable {
    package var peaks: [Float] = []

    package static func peaks(from samples: [Float], bucketCount: Int = 2000) -> [Float] {
        let n = samples.count
        guard n > 0, bucketCount > 0 else { return [] }
        let perBucket = max(1, n / bucketCount)
        var out = [Float](repeating: 0, count: bucketCount)
        var maxAbs: Float = 0
        for i in 0..<n {
            let b = min(bucketCount - 1, i / perBucket)
            let a = abs(samples[i])
            if a > out[b] { out[b] = a }
            if a > maxAbs { maxAbs = a }
        }
        if maxAbs > 0 {
            for i in 0..<out.count { out[i] = out[i] / maxAbs }
        }
        return out
    }

    /// Position of the current playhead as a fraction of the track, `0...1`.
    package func progress(_ seconds: Double, duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, seconds / duration))
    }
}

/// Tempo estimation from a mono signal. See `BeatGrid.analyze`. Returns a value in
/// `78...175` BPM or `nil` when the signal has no detectable pulse.
package enum BPM {
    package static func estimateBPM(from samples: [Float], sampleRate: Double) -> Double? {
        BeatGrid.analyze(mono: samples, sampleRate: sampleRate)?.bpm
    }
}

/// Pitch fader math and jog-to-time mapping. The fader spans -8% to +8%.
package enum Pitch {
    package static let minFader: Double = -0.08
    package static let maxFader: Double = 0.08

    /// Map a fader value to the player node rate. Returns `0.92...1.08`, clamped.
    package static func rate(for fader: Double) -> Float {
        let c = min(maxFader, max(minFader, fader))
        return Float(1 + c)
    }

    /// Pixels/second of jog wheel travel per second of audio. Drag `dx` pixels -> `dx / 40` s.
    package static func jogSeconds(deltaPixels dx: CGFloat, pixelsPerSecond: CGFloat = 40) -> Double {
        Double(dx / pixelsPerSecond)
    }

    /// Pitch shift in semitones for a playback rate. Used by BPM SHIFT mode, where the tempo
    /// stays fixed and only the pitch follows the fader (1.08 -> ~+1.37 st).
    package static func semitones(for rate: Float) -> Float {
        guard rate > 0 else { return 0 }
        return Float(12 * log2(Double(rate)))
    }
}

/// Crossfader gain law. Uses an equal-power curve so total output level stays roughly flat as
/// the fader moves. `value` is `0` (A only) to `1` (B only).
package enum Crossfader {
    package static func gains(crossfader value: Double) -> (a: Double, b: Double) {
        let v = min(1, max(0, value))
        // Equal-power: a = cos(v*90deg), b = sin(v*90deg).
        let rad = v * .pi / 2
        return (cos(rad), sin(rad))
    }
}

/// Beat sync between two decks.
package enum Sync {
    /// Pitch fader value (1 + value = rate) that brings `bpm` to `target`, also trying half and
    /// double tempo (87 BPM syncs to 174). The smallest change within `range` wins; `nil` when
    /// no match is within range.
    package static func pitch(toMatch target: Double, from bpm: Double, range: Double = Pitch.maxFader) -> Double? {
        guard bpm > 0, target > 0 else { return nil }
        return [1.0, 2.0, 0.5]
            .map { target * $0 / bpm - 1 }
            .filter { abs($0) <= range + 1e-9 }
            .min { abs($0) < abs($1) }
    }

    /// Seconds to move a deck (in its track time) so its beat phase at `t` becomes
    /// `targetPhase` (0 ..< 1). Takes the shorter way, at most half a beat.
    package static func phaseShift(grid: BeatGrid, at t: Double, targetPhase: Double) -> Double {
        var d = targetPhase - grid.phase(at: t)
        d -= d.rounded() // wrap into -0.5 ... 0.5
        return d * grid.period
    }
}

/// How Auto DJ mixes one track into the next. Pure decisions, so they unit-test without audio.
package enum MixPlan {
    /// A phrase: 4 bars of 4 beats. Mixes start on phrase boundaries.
    package static let phraseBeats = 16.0

    /// When to start the transition on the outgoing track (seconds). With a grid: the last
    /// phrase boundary that still leaves `fade` seconds before the end, unless that is more
    /// than one phrase early. Without a grid: `fade` seconds before the end.
    package static func transitionStart(grid: BeatGrid?, duration: Double, fade: Double) -> Double {
        let plain = max(0, duration - fade)
        guard let grid else { return plain }
        let phrase = phraseBeats * grid.period
        let boundary = grid.firstBeat + ((plain - grid.firstBeat) / phrase).rounded(.down) * phrase
        return boundary >= 0 && plain - boundary <= phrase ? boundary : plain
    }

    /// Where the incoming track starts: its cue point when set, else its first beat, else 0.
    package static func entryPoint(grid: BeatGrid?, cue: Double?) -> Double {
        cue ?? grid?.firstBeat ?? 0
    }

    /// Low EQ (dB) for the outgoing and incoming decks at fade progress `p` (0 ... 1): the
    /// basses swap at the middle, with a ramp of `ramp` (fraction of the fade), so two kick
    /// drums never play at full level together.
    package static func bassSwap(progress p: Double, ramp: Double = 0.1) -> (outgoing: Double, incoming: Double) {
        let x = min(1, max(0, (p - 0.5 + ramp / 2) / ramp)) // 0 before, 1 after the swap
        return (-12 * x, -12 * (1 - x))
    }

    /// The crossfader curve: smoothstep, 0 ... 1.
    package static func crossfade(progress p: Double) -> Double {
        let x = min(1, max(0, p))
        return x * x * (3 - 2 * x)
    }

    /// Pitch after `elapsed` seconds of gliding from `start` back to 0 at `rate` per second
    /// (0.001 = 0.1% per second: inaudible, like a DJ riding the fader).
    package static func glide(from start: Double, elapsed: Double, rate: Double = 0.001) -> Double {
        let step = rate * elapsed
        return abs(start) <= step ? 0 : start - (start > 0 ? step : -step)
    }
}

/// Deterministic random numbers from a string (SplitMix64 over an FNV-1a hash), so a record
/// looks the same every launch.
package struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    package init(_ seed: String) {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        state = h
    }

    package mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}
