// Tempo, beat phase, and key from a mono signal. Pure DSP (Accelerate), no audio engine, so
// it unit-tests on synthetic signals.

import Foundation
import Accelerate

/// A constant-tempo beat grid: beat `n` is at `firstBeat + n * 60 / bpm` seconds.
struct BeatGrid: Equatable {
    let bpm: Double
    /// Time of a beat near the start, in `0 ..< 60 / bpm`.
    let firstBeat: Double

    var period: Double { 60 / bpm }

    /// The beat time nearest to `t`.
    func nearestBeat(to t: Double) -> Double {
        firstBeat + ((t - firstBeat) / period).rounded() * period
    }

    /// Where `t` sits inside its beat, `0 ..< 1`.
    func phase(at t: Double) -> Double {
        let p = ((t - firstBeat) / period).truncatingRemainder(dividingBy: 1)
        return p < 0 ? p + 1 : p
    }

    /// Beat times in `range`.
    func beats(in range: ClosedRange<Double>) -> [Double] {
        let first = ((range.lowerBound - firstBeat) / period).rounded(.up)
        var out: [Double] = []
        var n = first
        while true {
            let t = firstBeat + n * period
            if t > range.upperBound { break }
            out.append(t)
            n += 1
        }
        return out
    }

    /// Estimate tempo and phase. Onset strength (rise in log energy, full band plus a low band
    /// for the kick) at ~200 frames/s; tempo from its autocorrelation, weighted toward
    /// 120 BPM against octave errors and folded into 78...175; phase from the offset whose
    /// comb of beats collects the most onset strength. `nil` for silence or no pulse.
    static func analyze(mono: [Float], sampleRate: Double) -> BeatGrid? {
        let hop = max(1, Int(sampleRate / 200))
        let frameRate = sampleRate / Double(hop)
        let frames = mono.count / hop
        guard frames > Int(frameRate * 4) else { return nil } // need 4 s

        // Log energy per hop, full band and low-passed (~150 Hz one-pole).
        var full = [Float](repeating: 0, count: frames)
        var low = [Float](repeating: 0, count: frames)
        let a = Float(exp(-2 * Double.pi * 150 / sampleRate))
        var lp: Float = 0
        mono.withUnsafeBufferPointer { x in
            for f in 0..<frames {
                var e: Float = 0, el: Float = 0
                for i in (f * hop)..<(f * hop + hop) {
                    let s = x[i]
                    lp = a * lp + (1 - a) * s
                    e += s * s
                    el += lp * lp
                }
                full[f] = log(1 + 1000 * e / Float(hop))
                low[f] = log(1 + 1000 * el / Float(hop))
            }
        }
        // Half-wave rectified rise, minus a 0.5 s moving average.
        var onset = [Float](repeating: 0, count: frames)
        for f in 1..<frames {
            onset[f] = max(0, full[f] - full[f - 1]) + max(0, low[f] - low[f - 1])
        }
        let win = max(1, Int(frameRate / 2))
        var sum: Float = 0
        var smooth = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            sum += onset[f]
            if f >= win { sum -= onset[f - win] }
            smooth[f] = max(0, onset[f] - sum / Float(min(f + 1, win)))
        }
        guard (smooth.max() ?? 0) > 1e-4 else { return nil }

        // Autocorrelation over lags for 60...200 BPM.
        let minLag = Int(frameRate * 60 / 200), maxLag = Int(frameRate * 60 / 60) + 1
        guard frames > maxLag * 2 else { return nil }
        var r = [Float](repeating: 0, count: maxLag * 2 + 2)
        smooth.withUnsafeBufferPointer { o in
            for lag in 1..<min(r.count, frames) {
                var d: Float = 0
                vDSP_dotpr(o.baseAddress!, 1, o.baseAddress! + lag, 1, &d, vDSP_Length(frames - lag))
                r[lag] = d / Float(frames - lag)
            }
        }
        func score(_ lag: Int) -> Double {
            let bpm = frameRate * 60 / Double(lag)
            let w = exp(-0.5 * pow(log2(bpm / 120) / 0.9, 2))
            let harmonic = lag * 2 < r.count ? Double(r[lag * 2]) * 0.5 : 0
            return w * (Double(r[lag]) + harmonic)
        }
        guard let best = (minLag...maxLag).max(by: { score($0) < score($1) }), r[best] > 0 else { return nil }
        // Parabolic peak refinement for a fractional lag.
        var lag = Double(best)
        if best > 1, best + 1 < r.count {
            let y0 = Double(r[best - 1]), y1 = Double(r[best]), y2 = Double(r[best + 1])
            let den = y0 - 2 * y1 + y2
            if den < 0 { lag += min(0.5, max(-0.5, 0.5 * (y0 - y2) / den)) }
        }
        var bpm = frameRate * 60 / lag
        while bpm < 78 { bpm *= 2 }
        while bpm > 175 { bpm /= 2 }
        let period = frameRate * 60 / bpm // frames per beat

        // Phase: the comb offset that lands on the most onset strength.
        let steps = max(1, Int(period.rounded()))
        var bestPhase = 0, bestSum: Float = -1
        for p in 0..<steps {
            var s: Float = 0
            var t = Double(p)
            while Int(t) + 1 < frames {
                let i = Int(t.rounded())
                s += smooth[i] + 0.5 * (smooth[max(0, i - 1)] + smooth[min(frames - 1, i + 1)])
                t += period
            }
            if s > bestSum { bestSum = s; bestPhase = p }
        }
        // Refine: find the onset peak near each predicted beat and fit t(n) = a + b n by least
        // squares. A small tempo error adds up over a whole track, so this matters more than
        // the coarse estimate.
        var a0 = Double(bestPhase), b0 = period
        for _ in 0..<2 {
            var sn = 0.0, st = 0.0, snn = 0.0, snt = 0.0, count = 0.0
            let w = max(1, Int(b0 / 4))
            var n = 0.0
            while a0 + n * b0 < Double(frames - 1) {
                let c = Int((a0 + n * b0).rounded())
                var peak = -1, peakValue: Float = 0
                for i in max(0, c - w)...min(frames - 1, c + w) where smooth[i] > peakValue {
                    peak = i
                    peakValue = smooth[i]
                }
                if peak >= 0 {
                    let t = Double(peak)
                    sn += n; st += t; snn += n * n; snt += n * t; count += 1
                }
                n += 1
            }
            let den = count * snn - sn * sn
            guard count >= 8, den > 0 else { break }
            let b = (count * snt - sn * st) / den
            guard b > period * 0.97, b < period * 1.03 else { break }
            b0 = b
            a0 = (st - b * sn) / count
        }
        let beatSeconds = b0 / frameRate
        // Onset frames mark the rise at the start of the hit; the hop's center is the beat time.
        var first = ((a0 + 0.5) / frameRate).truncatingRemainder(dividingBy: beatSeconds)
        if first < 0 { first += beatSeconds }
        return BeatGrid(bpm: 60 / beatSeconds, firstBeat: first)
    }
}

/// A musical key: tonic pitch class (0 = C) and mode.
struct MusicalKey: Equatable {
    let tonic: Int
    let minor: Bool

    private static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// "Am", "F#".
    var name: String { Self.names[tonic] + (minor ? "m" : "") }

    /// Camelot wheel code for harmonic mixing: "8A" = A minor, "8B" = C major. Neighbours
    /// (±1, or the same number with the other letter) mix in key.
    var camelot: String {
        let major = minor ? (tonic + 3) % 12 : tonic
        return "\((major * 7 % 12 + 7) % 12 + 1)\(minor ? "A" : "B")"
    }

    init(tonic: Int, minor: Bool) {
        self.tonic = ((tonic % 12) + 12) % 12
        self.minor = minor
    }

    init?(name: String) {
        let minor = name.hasSuffix("m")
        let root = minor ? String(name.dropLast()) : name
        guard let i = Self.names.firstIndex(of: root) else { return nil }
        self.init(tonic: i, minor: minor)
    }

    /// True when the two keys mix well on the Camelot wheel: same code, same number with
    /// the other letter, or ±1 with the same letter.
    func isCompatible(with other: MusicalKey) -> Bool {
        let a = camelot, b = other.camelot
        let na = Int(a.dropLast())!, nb = Int(b.dropLast())!
        if a.last == b.last { return na == nb || (na % 12) + 1 == nb || (nb % 12) + 1 == na }
        return na == nb
    }

    // Krumhansl-Kessler key profiles, C as tonic.
    private static let majorProfile: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let minorProfile: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    /// Estimate the key: a chroma vector from FFT frames (55 Hz - 2 kHz, each frame
    /// normalized so loud parts do not dominate), correlated with the 24 rotated profiles.
    static func detect(mono: [Float], sampleRate: Double) -> MusicalKey? {
        // Decimate to ~12 kHz with a box average (enough for the pitch range used).
        let d = max(1, Int(sampleRate / 12_000))
        let sr = sampleRate / Double(d)
        var x = [Float](repeating: 0, count: mono.count / d)
        mono.withUnsafeBufferPointer { m in
            for i in 0..<x.count {
                var s: Float = 0
                for k in 0..<d { s += m[i * d + k] }
                x[i] = s / Float(d)
            }
        }
        let log2n = vDSP_Length(13), n = 8192, hop = 4096
        guard x.count > n, let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        // Pitch class of each FFT bin in range, -1 outside.
        var pcOfBin = [Int](repeating: -1, count: n / 2)
        for bin in 1..<(n / 2) {
            let f = Double(bin) * sr / Double(n)
            guard f >= 55, f <= 2000 else { continue }
            let midi = 69 + 12 * log2(f / 440)
            pcOfBin[bin] = (Int(midi.rounded()) % 12 + 12) % 12
        }

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var frame = [Float](repeating: 0, count: n)
        var real = [Float](repeating: 0, count: n / 2), imag = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        var chroma = [Double](repeating: 0, count: 12)

        var start = 0
        while start + n <= x.count {
            x.withUnsafeBufferPointer { xp in
                vDSP_vmul(xp.baseAddress! + start, 1, window, 1, &frame, 1, vDSP_Length(n))
            }
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(n / 2))
                }
            }
            var c = [Double](repeating: 0, count: 12)
            for bin in 1..<(n / 2) where pcOfBin[bin] >= 0 { c[pcOfBin[bin]] += Double(mags[bin]) }
            let total = c.reduce(0, +)
            if total > 1e-6 { for i in 0..<12 { chroma[i] += c[i] / total } }
            start += hop
        }
        guard chroma.reduce(0, +) > 0 else { return nil }

        var best: (key: MusicalKey, r: Double)?
        for tonic in 0..<12 {
            for minor in [false, true] {
                let profile = minor ? minorProfile : majorProfile
                let rotated = (0..<12).map { profile[(($0 - tonic) % 12 + 12) % 12] }
                let r = pearson(chroma, rotated)
                if best == nil || r > best!.r { best = (MusicalKey(tonic: tonic, minor: minor), r) }
            }
        }
        return best?.key
    }

    private static func pearson(_ a: [Double], _ b: [Double]) -> Double {
        let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
        var num = 0.0, da = 0.0, db = 0.0
        for i in a.indices {
            num += (a[i] - ma) * (b[i] - mb)
            da += (a[i] - ma) * (a[i] - ma)
            db += (b[i] - mb) * (b[i] - mb)
        }
        return da > 0 && db > 0 ? num / (da * db).squareRoot() : 0
    }
}
