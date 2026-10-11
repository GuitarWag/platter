import Foundation
import AVFoundation
import Accelerate

/// One-time analysis of a downloaded track: duration, BPM, and waveform peaks. The result is
/// stored in the database, so a track is analyzed only once.
package enum Analysis {
    package struct Result {
        package let duration: Double
        package let bpm: Double?
        package let peaks: [Float]
        /// Peak amplitude per 1/`waveRate` s, normalized like `peaks`. Drives the zoomed waveform.
        package let wave: [Float]
        package let grid: BeatGrid?
        package let key: MusicalKey?
        /// dBFS RMS over the 50 ms blocks above -60 dBFS (silence does not lower it).
        package let loudness: Double?
    }

    /// Bumped when the analysis changes. Tracks analyzed by an older version are analyzed
    /// again on their next load. 2 = beat grid and key. 3 = loudness.
    package static let version = 3

    /// Buckets per second of `Result.wave`.
    package static let waveRate: Double = 100

    /// Read the file in chunks into a mono mixdown and analyze it. The mixdown exists only
    /// during this call (about 58 MB for a 5-minute 48 kHz track); nothing stays in memory.
    package static func analyze(url: URL) throws -> Result {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        guard channels > 0,
              let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else {
            throw LibraryError("Unsupported audio format in \(url.lastPathComponent).")
        }

        var mono: [Float] = []
        mono.reserveCapacity(Int(file.length))
        while file.framePosition < file.length {
            try file.read(into: chunk)
            let n = Int(chunk.frameLength)
            guard n > 0, let data = chunk.floatChannelData else { break }
            for i in 0..<n {
                var sum: Float = 0
                for c in 0..<channels { sum += data[c][i] }
                mono.append(sum / Float(channels))
            }
        }
        guard !mono.isEmpty else {
            throw LibraryError("No audio data in \(url.lastPathComponent).")
        }
        let grid = BeatGrid.analyze(mono: mono, sampleRate: format.sampleRate)
        return Result(duration: Double(mono.count) / format.sampleRate,
                      bpm: grid?.bpm,
                      peaks: PeakTable.peaks(from: mono),
                      wave: wave(from: mono, sampleRate: format.sampleRate),
                      grid: grid,
                      key: MusicalKey.detect(mono: mono, sampleRate: format.sampleRate),
                      loudness: loudness(mono, sampleRate: format.sampleRate))
    }

    /// Average loudness in dBFS RMS, over 50 ms blocks louder than -60 dBFS.
    package static func loudness(_ mono: [Float], sampleRate: Double) -> Double? {
        let block = max(1, Int(sampleRate * 0.05))
        var sum = 0.0, count = 0
        var i = 0
        while i + block <= mono.count {
            var ms: Float = 0
            mono.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress! + i, 1, &ms, vDSP_Length(block)) }
            if ms > 1e-6 { sum += Double(ms); count += 1 } // -60 dBFS
            i += block
        }
        guard count > 0 else { return nil }
        return 10 * log10(sum / Double(count))
    }

    /// Peak per exactly `sampleRate / waveRate` frames, so bucket `k` starts at `k / waveRate`
    /// seconds. (`PeakTable` rounds its bucket size, which drifts over a long track.)
    package static func wave(from mono: [Float], sampleRate: Double) -> [Float] {
        let per = max(1, Int((sampleRate / waveRate).rounded()))
        var out = [Float](repeating: 0, count: (mono.count + per - 1) / per)
        var maxAbs: Float = 0
        for (i, s) in mono.enumerated() {
            let a = abs(s)
            if a > out[i / per] { out[i / per] = a }
            if a > maxAbs { maxAbs = a }
        }
        if maxAbs > 0 { for i in out.indices { out[i] /= maxAbs } }
        return out
    }
}
