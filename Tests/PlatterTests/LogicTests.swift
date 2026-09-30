import XCTest
@testable import Platter

final class PeakTableTests: XCTestCase {
    func testNormalizesToPeakOne() {
        var s = [Float]()
        for i in 0..<1000 { s.append(sin(Float(i))) }
        s.append(5) // spike
        let p = PeakTable.peaks(from: s, bucketCount: 100)
        XCTAssertEqual(p.count, 100)
        XCTAssertEqual(p.max() ?? 0, 1, accuracy: 0.001)
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertEqual(PeakTable.peaks(from: []), [])
    }

    func testProgressClamps() {
        let t = PeakTable(peaks: [0, 1, 0])
        XCTAssertEqual(t.progress(-1, duration: 10), 0)
        XCTAssertEqual(t.progress(11, duration: 10), 1)
        XCTAssertEqual(t.progress(5, duration: 10), 0.5)
    }
}

final class BPMTests: XCTestCase {
    // A 120 BPM beat grid: one strong onset every 0.5 s.
    func testDetectsSynthetic120BPM() {
        let sr = Double(44100)
        let beat = 0.5
        var s = [Float](repeating: 0, count: Int(sr * 8)) // 8 s
        var t = 0.0
        while t < 8 {
            let center = Int(t * sr)
            for k in 0..<800 where center + k < s.count {
                s[center + k] = sin(Float(k) / 30) // a short hit
            }
            t += beat
        }
        let bpm = BPM.estimateBPM(from: s, sampleRate: sr)
        XCTAssertNotNil(bpm)
        XCTAssertEqual(bpm ?? -1, 120, accuracy: 12)
    }

    func testSilenceReturnsNil() {
        let s = [Float](repeating: 0, count: 44100)
        XCTAssertNil(BPM.estimateBPM(from: s, sampleRate: 44100))
    }
}

final class PitchTests: XCTestCase {
    func testRateMapping() {
        XCTAssertEqual(Pitch.rate(for: 0), 1.0)
        XCTAssertEqual(Pitch.rate(for: 0.08), 1.08, accuracy: 0.0001)
        XCTAssertEqual(Pitch.rate(for: -0.08), 0.92, accuracy: 0.0001)
    }

    func testClampsOutOfRange() {
        XCTAssertEqual(Pitch.rate(for: 0.5), 1.08)
        XCTAssertEqual(Pitch.rate(for: -0.5), 0.92)
    }

    func testJogSignAndMagnitude() {
        XCTAssertEqual(Pitch.jogSeconds(deltaPixels: 40), 1.0)
        XCTAssertEqual(Pitch.jogSeconds(deltaPixels: -40), -1.0)
        XCTAssertEqual(Pitch.jogSeconds(deltaPixels: 0), 0)
    }

    func testSemitones() {
        XCTAssertEqual(Pitch.semitones(for: 1.0), 0, accuracy: 1e-6)
        XCTAssertEqual(Pitch.semitones(for: 2.0), 12, accuracy: 0.01)
        // 1.08 ~ +1.37 st; 0.92 ~ -1.44 st.
        XCTAssertEqual(Pitch.semitones(for: 1.08), 1.37, accuracy: 0.05)
        XCTAssertEqual(Pitch.semitones(for: 0.92), -1.444, accuracy: 0.05)
    }

    func testPitchModeCycles() {
        XCTAssertEqual(PitchMode.varispeed.next, .keyLock)
        XCTAssertEqual(PitchMode.keyLock.next, .bpmShift)
        XCTAssertEqual(PitchMode.bpmShift.next, .varispeed)
    }
}

final class CrossfaderTests: XCTestCase {
    func testEndpoints() {
        let l = Crossfader.gains(crossfader: 0)
        XCTAssertEqual(l.a, 1, accuracy: 0.001)
        XCTAssertEqual(l.b, 0, accuracy: 0.001)
        let r = Crossfader.gains(crossfader: 1)
        XCTAssertEqual(r.a, 0, accuracy: 0.001)
        XCTAssertEqual(r.b, 1, accuracy: 0.001)
    }

    func testEqualPowerMidpointSumsToOne() {
        let m = Crossfader.gains(crossfader: 0.5)
        XCTAssertEqual(m.a, 0.7071, accuracy: 0.001)
        XCTAssertEqual(m.b, 0.7071, accuracy: 0.001)
        // a^2 + b^2 ~ 1 for equal-power
        XCTAssertEqual(m.a * m.a + m.b * m.b, 1, accuracy: 0.001)
    }

    func testClamps() {
        XCTAssertEqual(Crossfader.gains(crossfader: 5).a, 0, accuracy: 1e-9)
        XCTAssertEqual(Crossfader.gains(crossfader: -5).b, 0, accuracy: 1e-9)
    }
}

final class SyncTests: XCTestCase {
    func testPitchToMatch() {
        XCTAssertEqual(Sync.pitch(toMatch: 128, from: 125)!, 0.024, accuracy: 1e-9)
        XCTAssertEqual(Sync.pitch(toMatch: 120, from: 128)!, -0.0625, accuracy: 1e-9)
        XCTAssertEqual(Sync.pitch(toMatch: 174, from: 88)!, 174.0 / 2 / 88 - 1, accuracy: 1e-9) // half time
        XCTAssertEqual(Sync.pitch(toMatch: 64, from: 126)!, 128.0 / 126 - 1, accuracy: 1e-9)   // double time
        XCTAssertNil(Sync.pitch(toMatch: 140, from: 120))                                      // +16.7%
        XCTAssertNil(Sync.pitch(toMatch: 120, from: 0))
    }

    func testPhaseShift() {
        let g = BeatGrid(bpm: 120, firstBeat: 0) // 0.5 s beats
        // At t = 10.1 the phase is 0.2; to reach 0.5 move +0.15 s.
        XCTAssertEqual(Sync.phaseShift(grid: g, at: 10.1, targetPhase: 0.5), 0.15, accuracy: 1e-9)
        // To reach 0.9 the short way is back 0.15 s (phase 0.2 -> -0.1 = 0.9).
        XCTAssertEqual(Sync.phaseShift(grid: g, at: 10.1, targetPhase: 0.9), -0.15, accuracy: 1e-9)
        XCTAssertEqual(Sync.phaseShift(grid: g, at: 10.1, targetPhase: 0.2), 0, accuracy: 1e-9)
        // Result lands on the target phase.
        let shift = Sync.phaseShift(grid: g, at: 3.33, targetPhase: 0.71)
        XCTAssertEqual(g.phase(at: 3.33 + shift), 0.71, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(abs(shift), g.period / 2 + 1e-9)
    }
}

final class MixPlanTests: XCTestCase {
    func testTransitionStartsOnAPhrase() {
        let g = BeatGrid(bpm: 120, firstBeat: 0.2) // phrase = 16 beats = 8 s
        // 200 s track, 10 s fade: plain start 190; phrase boundaries at 0.2 + 8k -> 184.2.
        XCTAssertEqual(MixPlan.transitionStart(grid: g, duration: 200, fade: 10), 184.2, accuracy: 1e-9)
        // No grid: plain.
        XCTAssertEqual(MixPlan.transitionStart(grid: nil, duration: 200, fade: 10), 190)
        // Fade longer than the track: from 0.
        XCTAssertEqual(MixPlan.transitionStart(grid: nil, duration: 5, fade: 10), 0)
        // The boundary is always at most one phrase before the plain start, and on the grid.
        for dur in stride(from: 120.0, to: 300, by: 7.3) {
            let t = MixPlan.transitionStart(grid: g, duration: dur, fade: 12)
            XCTAssertLessThanOrEqual(t, dur - 12 + 1e-9)
            XCTAssertLessThanOrEqual(dur - 12 - t, 8 + 1e-9)
            let ph = g.phase(at: t)
            XCTAssertLessThan(min(ph, 1 - ph), 1e-6, "on a beat")
        }
    }

    func testEntryPoint() {
        let g = BeatGrid(bpm: 128, firstBeat: 0.31)
        XCTAssertEqual(MixPlan.entryPoint(grid: g, cue: 12), 12)
        XCTAssertEqual(MixPlan.entryPoint(grid: g, cue: nil), 0.31)
        XCTAssertEqual(MixPlan.entryPoint(grid: nil, cue: nil), 0)
    }

    func testBassSwap() {
        XCTAssertEqual(MixPlan.bassSwap(progress: 0).outgoing, 0)
        XCTAssertEqual(MixPlan.bassSwap(progress: 0).incoming, -12)
        XCTAssertEqual(MixPlan.bassSwap(progress: 1).outgoing, -12)
        XCTAssertEqual(MixPlan.bassSwap(progress: 1).incoming, 0)
        let mid = MixPlan.bassSwap(progress: 0.5)
        XCTAssertEqual(mid.outgoing, -6, accuracy: 1e-9)
        XCTAssertEqual(mid.incoming, -6, accuracy: 1e-9)
        // Never both at full bass.
        for p in stride(from: 0.0, through: 1, by: 0.01) {
            let b = MixPlan.bassSwap(progress: p)
            XCTAssertLessThanOrEqual(b.outgoing + b.incoming, -12 + 1e-9)
        }
    }

    func testCrossfadeAndGlide() {
        XCTAssertEqual(MixPlan.crossfade(progress: 0), 0)
        XCTAssertEqual(MixPlan.crossfade(progress: 0.5), 0.5)
        XCTAssertEqual(MixPlan.crossfade(progress: 2), 1)
        XCTAssertEqual(MixPlan.glide(from: 0.03, elapsed: 10), 0.02, accuracy: 1e-12)
        XCTAssertEqual(MixPlan.glide(from: -0.03, elapsed: 10), -0.02, accuracy: 1e-12)
        XCTAssertEqual(MixPlan.glide(from: 0.005, elapsed: 10), 0)
    }
}
