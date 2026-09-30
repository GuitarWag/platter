import XCTest
import AVFoundation
@testable import Platter

/// The real audio graph, rendered offline (no device, no sound): pitch modes, filter,
/// effects, limiter, crossfader, loops, and scratch, measured on generated signals.
@MainActor
final class OfflineGraphTests: XCTestCase {
    private let sr = 44_100.0
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("platter-offline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Helpers

    /// Write a stereo WAV of `seconds` from `sample(i)`.
    private func wav(_ name: String, seconds: Double, _ sample: (Int) -> Float) throws -> URL {
        let url = dir.appendingPathComponent(name + ".wav")
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let n = AVAudioFrameCount(seconds * sr)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
        buf.frameLength = n
        for i in 0..<Int(n) {
            let v = sample(i)
            buf.floatChannelData![0][i] = v
            buf.floatChannelData![1][i] = v
        }
        do { try AVAudioFile(forWriting: url, settings: fmt.settings).write(from: buf) }
        return url
    }

    private func rig() -> (AudioEngine, DeckState, DeckState) {
        let engine = AudioEngine(offline: AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!)
        try? engine.start()
        return (engine, DeckState(deck: .a, engine: engine), DeckState(deck: .b, engine: engine))
    }

    private func load(_ d: DeckState, _ url: URL) {
        XCTAssertTrue(d.load(PreparedTrack(url: url, track: Track(id: url.lastPathComponent, title: "t"))))
    }

    /// Left channel samples from `from` to `to` seconds of a rendered buffer.
    private func samples(_ b: AVAudioPCMBuffer, _ from: Double, _ to: Double) -> [Float] {
        let lo = Int(from * sr), hi = min(Int(b.frameLength), Int(to * sr))
        return Array(UnsafeBufferPointer(start: b.floatChannelData![0] + lo, count: max(0, hi - lo)))
    }

    private func rms(_ x: [Float]) -> Float {
        x.isEmpty ? 0 : (x.map { $0 * $0 }.reduce(0, +) / Float(x.count)).squareRoot()
    }

    /// Frequency from rising zero crossings.
    private func frequency(_ x: [Float]) -> Double {
        var n = 0
        for i in 1..<x.count where x[i - 1] < 0 && x[i] >= 0 { n += 1 }
        return Double(n) / (Double(x.count) / sr)
    }

    // MARK: Tests

    func testPitchModesChangeTheRightThing() throws {
        let sine = try wav("sine440", seconds: 12) { 0.5 * sin(2 * .pi * 440 * Float($0) / 44_100) }
        let cases: [(PitchMode, Double, Double)] = [
            (.varispeed, 475.2, 3.24),  // tempo and pitch
            (.keyLock, 440, 3.24),      // tempo only
            (.bpmShift, 475.2, 3.0),    // pitch only
        ]
        for (mode, wantHz, wantAdvance) in cases {
            let (engine, a, _) = rig()
            load(a, sine)
            a.pitchMode = mode
            a.pitch = 0.08
            a.applyPitch()
            a.play()
            let out = try engine.renderOffline(seconds: 3)
            let hz = frequency(samples(out, 1.5, 2.9))
            print("PITCH \(mode.label): \(String(format: "%.1f", hz)) Hz, playhead \(String(format: "%.3f", a.position)) s")
            XCTAssertEqual(hz, wantHz, accuracy: 3, "\(mode.label) frequency")
            XCTAssertEqual(a.position, wantAdvance, accuracy: 0.12, "\(mode.label) tempo")
        }
    }

    func testFilter() throws {
        var rng = SeededRandom("noise")
        let noise = try wav("noise", seconds: 6) { _ in Float.random(in: -0.5...0.5, using: &rng) }
        let bass = try wav("bass", seconds: 6) { 0.5 * sin(2 * .pi * 100 * Float($0) / 44_100) }
        // High-frequency content: the first difference of the signal.
        func hf(_ x: [Float]) -> Float { rms(zip(x.dropFirst(), x).map { $0 - $1 }) }

        var results: [String: Float] = [:]
        for (name, url, filter) in [("noise dry", noise, 0.0), ("noise LPF", noise, -0.8),
                                    ("bass dry", bass, 0.0), ("bass HPF", bass, 0.8)] {
            let (engine, a, _) = rig()
            load(a, url)
            engine.setFilter(filter, deck: .a)
            a.play()
            let x = samples(try engine.renderOffline(seconds: 3), 1, 3)
            results[name] = name.hasPrefix("noise") ? hf(x) : rms(x)
        }
        print("FILTER", results)
        XCTAssertLessThan(results["noise LPF"]!, results["noise dry"]! * 0.1, "low-pass removes the highs")
        XCTAssertLessThan(results["bass HPF"]!, results["bass dry"]! * 0.1, "high-pass removes a 100 Hz tone")
    }

    func testEchoAndReverb() throws {
        // One click at 0.5 s.
        let click = try wav("click", seconds: 4) { i in (22_050..<22_100).contains(i) ? 0.9 : 0 }
        func render(_ fx: ChannelFX) throws -> AVAudioPCMBuffer {
            let (engine, a, _) = rig()
            load(a, click)
            engine.setFX(fx, amount: fx == .off ? 0 : 1, echoSeconds: 0.25, deck: .a)
            a.play()
            return try engine.renderOffline(seconds: 2.5)
        }
        let dry = try render(.off), echo = try render(.echo), verb = try render(.reverb)
        // Echo: repeats at 0.75 s and 1.0 s; none in the dry signal.
        let rep1 = rms(samples(echo, 0.74, 0.77)), rep2 = rms(samples(echo, 0.99, 1.02))
        let dryRep = rms(samples(dry, 0.74, 0.77))
        // Reverb: a tail 0.2 ... 1 s after the click.
        let tail = rms(samples(verb, 0.7, 1.5)), dryTail = rms(samples(dry, 0.7, 1.5))
        print("FX echo repeats \(rep1) \(rep2) (dry \(dryRep)); reverb tail \(tail) (dry \(dryTail))")
        XCTAssertGreaterThan(rep1, 0.002)
        XCTAssertGreaterThan(rep2, 0.0005)
        XCTAssertLessThan(dryRep, 1e-5)
        XCTAssertGreaterThan(tail, 1e-4)
        XCTAssertLessThan(dryTail, 1e-6)
    }

    func testLimiterStopsClipping() throws {
        let loud = try wav("loud", seconds: 5) { 0.95 * sin(2 * .pi * 220 * Float($0) / 44_100) }
        let (engine, a, b) = rig()
        load(a, loud); load(b, loud)
        engine.setCrossfader(0.5) // 0.707 each: 0.95 * 1.414 = 1.34 before the limiter
        a.play(); b.play()
        let x = samples(try engine.renderOffline(seconds: 4), 1, 4)
        let peak = x.map(abs).max() ?? 0
        print("LIMITER peak \(peak) (sum before the limiter would be 1.34)")
        XCTAssertLessThanOrEqual(peak, 1.0)
        XCTAssertGreaterThan(peak, 0.5)
    }

    func testCrossfaderAndLevel() throws {
        let sine = try wav("sine", seconds: 5) { 0.5 * sin(2 * .pi * 440 * Float($0) / 44_100) }
        func level(xf: Double, channel: Double) throws -> Float {
            let (engine, a, _) = rig()
            load(a, sine)
            engine.setCrossfader(xf)
            engine.setChannelLevel(channel, deck: .a)
            a.play()
            return rms(samples(try engine.renderOffline(seconds: 2), 1, 2))
        }
        let full = try level(xf: 0, channel: 1), half = try level(xf: 0, channel: 0.5), cut = try level(xf: 1, channel: 1)
        print("XFADER A-side \(full), level 0.5 \(half), B-side \(cut)")
        XCTAssertEqual(full, Float(0.5 / 2.0.squareRoot()), accuracy: 0.02) // sine RMS
        XCTAssertEqual(half / full, 0.5, accuracy: 0.02)
        XCTAssertLessThan(cut, 1e-4)
    }

    func testLoopHoldsThePlayhead() throws {
        let sine = try wav("loop", seconds: 20) { 0.5 * sin(2 * .pi * 440 * Float($0) / 44_100) }
        let (engine, a, _) = rig()
        load(a, sine)
        a.seek(to: 5)
        a.play()
        a.player.setLoop(from: 5, to: 6)
        var positions: [Double] = []
        for _ in 0..<10 {
            _ = try engine.renderOffline(seconds: 0.45)
            positions.append(a.position)
        }
        print("LOOP positions", positions.map { String(format: "%.2f", $0) })
        XCTAssertTrue(positions.allSatisfy { (4.99...6.01).contains($0) })
        XCTAssertGreaterThan(Set(positions.map { Int($0 * 10) }).count, 4) // it moves
    }

    func testVinylNoiseFollowsTheDeck() throws {
        let silence = try wav("silence", seconds: 10) { _ in 0 }
        let (engine, a, _) = rig()
        load(a, silence)
        a.vinylLevel = 3
        a.play()
        let playing = rms(samples(try engine.renderOffline(seconds: 3), 1, 3))
        a.pause()
        let stopped = rms(samples(try engine.renderOffline(seconds: 1), 0.5, 1))
        a.vinylLevel = 0
        a.play()
        let off = rms(samples(try engine.renderOffline(seconds: 1), 0.5, 1))
        print("VINYL graph playing \(playing), stopped \(stopped), off \(off)")
        XCTAssertGreaterThan(playing, 0.001)
        XCTAssertLessThan(stopped, 1e-5)
        XCTAssertLessThan(off, 1e-5)
    }

    func testScratchThroughTheGraph() async throws {
        let sine = try wav("scratch", seconds: 30) { 0.5 * sin(2 * .pi * 1000 * Float($0) / 44_100) }
        let (engine, a, _) = rig()
        load(a, sine)
        a.seek(to: 10)
        a.beginScratch()
        try await Task.sleep(for: .milliseconds(300)) // the window decodes in the background
        let still = rms(samples(try engine.renderOffline(seconds: 0.3), 0.1, 0.3))
        // Hand moves forward at normal speed: 10 ms of audio per 10 ms render.
        var moving: [Float] = []
        var t = 10.0
        for _ in 0..<40 {
            t += 0.01
            a.scratch(to: t)
            moving += samples(try engine.renderOffline(seconds: 0.01), 0, 0.01)
        }
        a.endScratch(resume: false)
        print("SCRATCH still \(still), moving \(rms(Array(moving.suffix(8_000))))")
        XCTAssertLessThan(still, 0.01)
        XCTAssertGreaterThan(rms(Array(moving.suffix(8_000))), 0.1)
    }
}
