import XCTest
@testable import Platter

final class ScratchTests: XCTestCase {
    /// A 1 kHz tone; the voice's output level tells whether the record moves.
    private func tone(_ n: Int) -> [Float] { (0..<n).map { sin(2 * .pi * 1000 * Float($0) / 48_000) } }

    private func rms(_ x: [Float]) -> Float { (x.map { $0 * $0 }.reduce(0, +) / Float(x.count)).squareRoot() }

    func testFollowsTheHand() {
        let v = ScratchVoice(sampleRate: 48_000)
        let t = tone(96_000)
        v.begin(at: 48_000)
        v.load(left: t, right: t, start: 0)
        var l = [Float](repeating: 0, count: 512), r = l

        // Still hand: silence.
        for _ in 0..<40 { v.render(&l, &r, frames: 512) }
        XCTAssertLessThan(rms(l), 0.01)

        // Normal speed forward (512 frames per 512-sample block): the tone plays.
        var target = 48_000.0
        for _ in 0..<60 { target += 512; v.move(to: target); v.render(&l, &r, frames: 512) }
        XCTAssertGreaterThan(rms(l), 0.5)

        // Backward at normal speed: also plays.
        for _ in 0..<60 { target -= 512; v.move(to: target); v.render(&l, &r, frames: 512) }
        XCTAssertGreaterThan(rms(l), 0.5)

        // Stop the hand: fades to silence.
        for _ in 0..<60 { v.render(&l, &r, frames: 512) }
        XCTAssertLessThan(rms(l), 0.01)

        // Let go while moving: fades out.
        for _ in 0..<5 { target += 512; v.move(to: target); v.render(&l, &r, frames: 512) }
        v.end()
        for _ in 0..<40 { target += 512; v.move(to: target); v.render(&l, &r, frames: 512) }
        XCTAssertLessThan(rms(l), 0.01)
    }

    func testOutsideTheWindowIsSilent() {
        let v = ScratchVoice(sampleRate: 48_000)
        let t = tone(4_800)
        v.begin(at: 100_000)
        v.load(left: t, right: t, start: 0)
        var l = [Float](repeating: 1, count: 512), r = l
        var target = 100_000.0
        for _ in 0..<20 { target += 512; v.move(to: target); v.render(&l, &r, frames: 512) }
        XCTAssertEqual(rms(l), 0)
    }
}
