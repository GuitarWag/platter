import Foundation
import AVFoundation
import os

/// The surface of a record: crackle, pops, groove damage that repeats every turn, hiss, and
/// rumble. Everything is placed along the groove, not in time, so it follows the platter:
/// silent when the deck stops, faster with the pitch, backward when scratched.
///
/// The main thread sets the amount and the groove speed (1 = normal play); the render thread
/// makes the noise. While scratching, the speed comes from the hand and falls to 0 when the
/// hand stops.
final class VinylNoise: @unchecked Sendable {
    /// Seconds of groove per turn at 33 1/3 RPM.
    static let secondsPerTurn = 1.8

    private struct State {
        var amount: Float = 0
        var target: Double = 0         // groove speed the main thread asks for
        var speed: Double = 0          // smoothed, used for rendering
        var scratching = false
        var groove: Double = 0         // groove position, seconds
        var damage: [(turnFraction: Double, level: Float)] = []
        var rng: UInt64 = 0x9E37_79B9_7F4A_7C15
        var click: Float = 0           // decaying click energy
        var clickSign: Float = 1
        var pop: Float = 0
        var hp: (x: Float, y: Float) = (0, 0)   // high-pass for ticks and hiss
        var rumble: Float = 0
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    let format: AVAudioFormat

    init(sampleRate: Double) {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        newRecord(seed: "")
    }

    /// 0 = off ... 1 = a well-worn record.
    var amount: Float {
        get { state.withLockUnchecked { $0.amount } }
        set { state.withLockUnchecked { $0.amount = min(1, max(0, newValue)) } }
    }

    /// A new record on the platter: new groove damage, from `seed` (the track id).
    func newRecord(seed: String) {
        var rng = SeededRandom(seed + "vinyl")
        let marks = (0..<2).map { _ in
            (turnFraction: Double.random(in: 0..<1, using: &rng), level: Float.random(in: 0.25...0.5, using: &rng))
        }
        state.withLockUnchecked {
            $0.damage = marks
            $0.groove = 0
        }
    }

    /// Normal play at `speed` (the deck's tempo; 0 when stopped).
    func setSpeed(_ speed: Double) {
        state.withLockUnchecked {
            $0.scratching = false
            $0.target = speed
        }
    }

    /// The hand on the record: `speed` in groove seconds per second (negative = backward).
    /// Falls to 0 when no new value comes.
    func scratchSpeed(_ speed: Double) {
        state.withLockUnchecked {
            $0.scratching = true
            $0.target = min(8, max(-8, speed))
        }
    }

    /// Render thread.
    func render(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames n: Int) {
        state.withLockUnchecked { s in
            guard s.amount > 0, abs(s.speed) > 1e-4 || abs(s.target) > 1e-4 else {
                l.update(repeating: 0, count: n)
                r.update(repeating: 0, count: n)
                s.speed = 0
                return
            }
            let sr = format.sampleRate
            // A still hand: the scratch speed dies away in about 50 ms.
            if s.scratching { s.target *= exp(-Double(n) / sr / 0.05) }
            let a = s.amount
            for i in 0..<n {
                s.speed += (s.target - s.speed) * 0.002
                let v = s.speed, av = Float(min(2, abs(v)))
                let before = s.groove
                s.groove += v / sr

                // Groove damage: a click each time the stylus passes a mark.
                let t0 = before / Self.secondsPerTurn, t1 = s.groove / Self.secondsPerTurn
                for m in s.damage {
                    let lo = min(t0, t1), hi = max(t0, t1)
                    if (lo - m.turnFraction).rounded(.up) <= (hi - m.turnFraction).rounded(.down) {
                        s.click = max(s.click, m.level * a)
                        s.clickSign = -s.clickSign
                    }
                }
                // Crackle (~8 per groove second) and pops (~0.3 per groove second).
                let u = Self.next(&s.rng)
                if u < 8 * Double(av) / sr {
                    s.click = max(s.click, Float(Self.next(&s.rng)) * 0.12 * a)
                    s.clickSign = Self.next(&s.rng) < 0.5 ? -1 : 1
                } else if u > 1 - 0.3 * Double(av) / sr {
                    s.pop = Float(0.15 + 0.2 * Self.next(&s.rng)) * a
                }
                let white = Float(Self.next(&s.rng) * 2 - 1)
                // Ticks: fast decay; pops: slower. Hiss: soft white noise. All high-passed.
                let raw = s.click * s.clickSign * (0.6 + 0.4 * white) + s.pop * white + white * 0.004 * a * av
                s.click *= 0.93
                s.pop *= 0.985
                let y = 0.95 * (s.hp.y + raw - s.hp.x)
                s.hp = (raw, y)
                // Rumble: very low filtered noise, from the motor and bearing.
                s.rumble += (white * 0.02 * a * av - s.rumble) * 0.002
                let out = y + s.rumble
                l[i] = out
                r[i] = out
            }
        }
    }

    nonisolated func makeNode() -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { [self] _, _, frameCount, bufferList in
            let abl = UnsafeMutableAudioBufferListPointer(bufferList)
            guard abl.count >= 2,
                  let l = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            self.render(l, r, frames: Int(frameCount))
            return noErr
        }
    }

    /// xorshift64*, uniform in 0 ..< 1. No allocation, safe on the audio thread.
    private static func next(_ x: inout UInt64) -> Double {
        x ^= x >> 12
        x ^= x << 25
        x ^= x >> 27
        return Double((x &* 0x2545_F491_4F6C_DD1D) >> 11) / Double(1 << 53)
    }
}
