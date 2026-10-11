import Foundation
import Accelerate
import AVFoundation
import os

/// The newest audio of the player, for the visualizer. The tap thread writes; the UI reads a
/// snapshot (it does not consume).
package final class VizBuffer: @unchecked Sendable {
    package static let size = 4096
    private struct Ring {
        package var data = [Float](repeating: 0, count: VizBuffer.size)
        package var write = 0
        package var enabled = false
    }
    private let ring = OSAllocatedUnfairLock(uncheckedState: Ring())

    package var enabled: Bool {
        get { ring.withLockUnchecked { $0.enabled } }
        set { ring.withLockUnchecked { $0.enabled = newValue } }
    }

    /// Tap thread: mono mix of the buffer.
    package func push(_ buffer: AVAudioPCMBuffer) {
        guard let d = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength), ch = Int(buffer.format.channelCount)
        ring.withLockUnchecked { r in
            guard r.enabled else { return }
            for i in 0..<n {
                var s: Float = 0
                for c in 0..<ch { s += d[c][i] }
                r.data[r.write] = s / Float(ch)
                r.write = (r.write + 1) % Self.size
            }
        }
    }

    /// The last `count` samples, oldest first.
    package func snapshot(_ count: Int) -> [Float] {
        ring.withLockUnchecked { r in
            let n = min(count, Self.size)
            return (0..<n).map { r.data[(r.write - n + $0 + Self.size) % Self.size] }
        }
    }
}

/// Spectrum bars from audio samples. Pure, so it unit-tests.
package enum Spectrum {
    package static let fftSize = 2048
    private static let log2n = vDSP_Length(11)
    /// Made once: the visualizer calls `bars` 60 times a second. The setup is read-only, so
    /// it is safe to share.
    nonisolated(unsafe) private static let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    private static let window: [Float] = {
        var w = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&w, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        return w
    }()

    /// Band edges (Hz) of `bands` log-spaced bars from `low` to `high`.
    package static func edges(bands: Int, low: Double = 40, high: Double = 16_000) -> [Double] {
        (0...bands).map { low * pow(high / low, Double($0) / Double(bands)) }
    }

    /// Bar heights 0 ... 1 (−60 ... 0 dBFS) for the last `fftSize` samples.
    package static func bars(_ samples: [Float], sampleRate: Double, bands: Int = 20) -> [Float] {
        let n = fftSize
        guard samples.count >= n else { return [Float](repeating: 0, count: bands) }
        var x = [Float](repeating: 0, count: n)
        vDSP_vmul(Array(samples.suffix(n)), 1, window, 1, &x, 1, vDSP_Length(n))
        var re = [Float](repeating: 0, count: n / 2), im = re, mag = re
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                x.withUnsafeBufferPointer { xp in
                    xp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(n / 2))
            }
        }
        // Peak magnitude of a full-scale sine: zrip doubles the DFT, and the window scales it
        // by sum(window) / 2, so the product is the window's sum.
        let fullScale = window.reduce(0, +)
        let e = edges(bands: bands)
        let binHz = sampleRate / Double(n)
        return (0..<bands).map { b in
            let lo = min(mag.count - 1, max(1, Int(e[b] / binHz))), hi = max(lo + 1, Int(e[b + 1] / binHz)) // bands above Nyquist use the top bin
            let peak = mag[lo..<min(hi, mag.count)].max() ?? 0
            let db = 20 * log10(max(1e-9, peak / fullScale))
            return Float(min(1, max(0, (db + 60) / 60)))
        }
    }
}
