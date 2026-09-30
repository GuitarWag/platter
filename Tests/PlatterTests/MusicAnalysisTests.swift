import XCTest
@testable import Platter

final class BeatGridTests: XCTestCase {
    /// A kick-like hit (decaying 60 Hz sine) every beat, plus a quieter off-beat hat.
    private func clicks(bpm: Double, firstBeat: Double, seconds: Double, sr: Double = 44_100) -> [Float] {
        var s = [Float](repeating: 0, count: Int(sr * seconds))
        let period = 60 / bpm
        var t = firstBeat
        while t < seconds {
            let c = Int(t * sr)
            for k in 0..<Int(sr * 0.12) where c + k < s.count {
                let env = exp(-Float(k) / Float(sr * 0.03))
                s[c + k] += 0.9 * env * sin(2 * .pi * 60 * Float(k) / Float(sr))
            }
            let h = Int((t + period / 2) * sr)
            for k in 0..<Int(sr * 0.02) where h + k < s.count {
                s[h + k] += 0.15 * Float.random(in: -1...1) * exp(-Float(k) / Float(sr * 0.005))
            }
            t += period
        }
        return s
    }

    func testTempoAndPhase() throws {
        for (bpm, first) in [(128.0, 0.123), (90.0, 0.4), (174.0, 0.05), (120.0, 0.0)] {
            let g = try XCTUnwrap(BeatGrid.analyze(mono: clicks(bpm: bpm, firstBeat: first, seconds: 30), sampleRate: 44_100))
            XCTAssertEqual(g.bpm, bpm, accuracy: 0.05, "bpm for \(bpm)")
            // Phase error, wrapped into a beat.
            var err = abs(g.firstBeat - first).truncatingRemainder(dividingBy: g.period)
            err = min(err, g.period - err)
            XCTAssertLessThan(err, 0.01, "phase for \(bpm): got \(g.firstBeat), want \(first)")
        }
    }

    func testSilenceHasNoGrid() {
        XCTAssertNil(BeatGrid.analyze(mono: [Float](repeating: 0, count: 44_100 * 10), sampleRate: 44_100))
    }

    func testGridMath() {
        let g = BeatGrid(bpm: 120, firstBeat: 0.1)
        XCTAssertEqual(g.period, 0.5)
        XCTAssertEqual(g.nearestBeat(to: 1.34), 1.1, accuracy: 1e-9)
        XCTAssertEqual(g.nearestBeat(to: 1.36), 1.6, accuracy: 1e-9)
        XCTAssertEqual(g.phase(at: 0.35), 0.5, accuracy: 1e-9)
        XCTAssertEqual(g.phase(at: 0.0), 0.8, accuracy: 1e-9)
        XCTAssertEqual(g.beats(in: 0...1.2), [0.1, 0.6, 1.1])
    }
}

final class KeyTests: XCTestCase {
    /// Sine tones at the given MIDI notes; the first note is louder (the tonic / bass).
    private func chord(_ notes: [Int], seconds: Double = 6, sr: Double = 44_100) -> [Float] {
        var s = [Float](repeating: 0, count: Int(sr * seconds))
        for (i, note) in notes.enumerated() {
            let f = 440 * pow(2, Double(note - 69) / 12)
            let amp: Float = i == 0 ? 0.5 : 0.25
            for k in s.indices { s[k] += amp * sin(Float(2 * .pi * f * Double(k) / sr)) }
        }
        return s
    }

    func testDetectsTriads() {
        // A minor: A2 A3 C4 E4.
        XCTAssertEqual(MusicalKey.detect(mono: chord([45, 57, 60, 64]), sampleRate: 44_100)?.name, "Am")
        // C major: C3 C4 E4 G4.
        XCTAssertEqual(MusicalKey.detect(mono: chord([48, 60, 64, 67]), sampleRate: 44_100)?.name, "C")
        // F# minor at 48 kHz: F#2 F#3 A3 C#4.
        XCTAssertEqual(MusicalKey.detect(mono: chord([42, 54, 57, 61], sr: 48_000), sampleRate: 48_000)?.name, "F#m")
    }

    func testCamelot() {
        XCTAssertEqual(MusicalKey(name: "Am")?.camelot, "8A")
        XCTAssertEqual(MusicalKey(name: "C")?.camelot, "8B")
        XCTAssertEqual(MusicalKey(name: "G")?.camelot, "9B")
        XCTAssertEqual(MusicalKey(name: "F")?.camelot, "7B")
        XCTAssertEqual(MusicalKey(name: "Em")?.camelot, "9A")
        XCTAssertEqual(MusicalKey(name: "B")?.camelot, "1B")
        XCTAssertEqual(MusicalKey(name: "F#m")?.camelot, "11A")
        XCTAssertNil(MusicalKey(name: "H"))
    }

    func testCompatibility() {
        let am = MusicalKey(name: "Am")!
        XCTAssertTrue(am.isCompatible(with: MusicalKey(name: "C")!))   // 8A-8B
        XCTAssertTrue(am.isCompatible(with: MusicalKey(name: "Em")!))  // 8A-9A
        XCTAssertTrue(am.isCompatible(with: MusicalKey(name: "Dm")!))  // 8A-7A
        XCTAssertFalse(am.isCompatible(with: MusicalKey(name: "F#")!)) // 8A-2B
        // 12 wraps to 1.
        XCTAssertTrue(MusicalKey(name: "Dbm".replacingOccurrences(of: "Db", with: "C#"))!
            .isCompatible(with: MusicalKey(name: "G#m")!)) // 12A-1A
    }
}
