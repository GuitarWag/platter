import XCTest
@testable import Platter

final class VinylNoiseTests: XCTestCase {
    private let sr = 48_000.0

    private func render(_ v: VinylNoise, seconds: Double) -> [Float] {
        var out: [Float] = []
        var l = [Float](repeating: 0, count: 480), r = l
        for _ in 0..<Int(seconds * sr / 480) {
            v.render(&l, &r, frames: 480)
            out += l
        }
        return out
    }

    private func rms(_ x: [Float]) -> Float { (x.map { $0 * $0 }.reduce(0, +) / Float(max(1, x.count))).squareRoot() }

    /// Seconds between the two biggest-correlation repeats of the click envelope.
    private func repeatPeriod(_ x: [Float]) -> Double {
        // Envelope in 5 ms bins.
        let bin = Int(sr * 0.005)
        let env = stride(from: 0, to: x.count - bin, by: bin).map { i in x[i..<i + bin].map(abs).max()! }
        var best = (lag: 0, score: Float(0))
        for lag in 200...500 { // 1.0 ... 2.5 s
            var s: Float = 0
            for i in 0..<(env.count - lag) { s += env[i] * env[i + lag] }
            if s > best.score { best = (lag, s) }
        }
        return Double(best.lag) * 0.005
    }

    func testOffAndStoppedAreSilent() {
        let v = VinylNoise(sampleRate: sr)
        v.newRecord(seed: "a")
        v.setSpeed(1)
        XCTAssertEqual(rms(render(v, seconds: 1)), 0, "amount 0")
        v.amount = 1
        v.setSpeed(0)
        XCTAssertEqual(rms(render(v, seconds: 1)), 0, "deck stopped")
    }

    func testPlayingIsQuietNoise() {
        let v = VinylNoise(sampleRate: sr)
        v.newRecord(seed: "b")
        v.amount = 1
        v.setSpeed(1)
        let x = Array(render(v, seconds: 6).dropFirst(Int(sr)))
        let level = rms(x), peak = x.map(abs).max()!
        print("VINYL rms \(level) peak \(peak)")
        XCTAssertGreaterThan(level, 0.002)
        XCTAssertLessThan(level, 0.05)
        XCTAssertLessThan(peak, 0.6)
        // Level 1 of 3 is quieter.
        let soft = VinylNoise(sampleRate: sr)
        soft.newRecord(seed: "b"); soft.amount = 1 / 3; soft.setSpeed(1)
        XCTAssertLessThan(rms(Array(render(soft, seconds: 6).dropFirst(Int(sr)))), level * 0.5)
    }

    func testDamageRepeatsEveryTurn() {
        for (speed, want) in [(1.0, 1.8), (1.08, 1.8 / 1.08)] {
            let v = VinylNoise(sampleRate: sr)
            v.newRecord(seed: "turns")
            v.amount = 1
            v.setSpeed(speed)
            let p = repeatPeriod(render(v, seconds: 12))
            print("VINYL speed \(speed): repeats every \(p) s (want \(want))")
            XCTAssertEqual(p, want, accuracy: 0.02)
        }
    }

    func testScratchFollowsTheHand() {
        let v = VinylNoise(sampleRate: sr)
        v.newRecord(seed: "c")
        v.amount = 1
        v.scratchSpeed(-2) // backward, twice normal speed
        let moving = rms(render(v, seconds: 0.05))
        let after = rms(Array(render(v, seconds: 0.6).suffix(Int(sr * 0.1))))
        print("VINYL scratch moving \(moving), hand still after 0.6 s \(after)")
        XCTAssertGreaterThan(moving, 0.001)
        XCTAssertLessThan(after, moving * 0.05)
    }
}
