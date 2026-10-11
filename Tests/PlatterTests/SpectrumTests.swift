import XCTest
import AVFoundation
@testable import PlatterCore
@testable import Platter
@testable import PlatterPlayer

final class SpectrumTests: XCTestCase {
    private func tone(_ hz: Double, amp: Float = 0.5, sr: Double = 44_100) -> [Float] {
        (0..<Spectrum.fftSize).map { amp * sin(Float(2 * .pi * hz * Double($0) / sr)) }
    }

    func testToneLightsItsBand() {
        let edges = Spectrum.edges(bands: 20)
        for hz in [100.0, 1_000, 8_000] {
            let bars = Spectrum.bars(tone(hz), sampleRate: 44_100)
            let top = bars.indices.max { bars[$0] < bars[$1] }!
            XCTAssertTrue((edges[top]...edges[top + 1]).contains(hz), "\(hz) Hz lands in bar \(top) (\(edges[top])...\(edges[top + 1]))")
            // Amplitude 0.5 is -6 dBFS: (60 - 6) / 60.
            XCTAssertEqual(bars[top], 0.9, accuracy: 0.03)
        }
    }

    func testSilenceIsEmpty() {
        XCTAssertEqual(Spectrum.bars([Float](repeating: 0, count: Spectrum.fftSize), sampleRate: 44_100).max(), 0)
        XCTAssertEqual(Spectrum.bars([0, 1], sampleRate: 44_100).count, 20, "too few samples: flat bars")
    }

    func testVizBufferKeepsTheNewest() {
        let viz = VizBuffer()
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        func push(_ values: [Float]) {
            let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(values.count))!
            b.frameLength = b.frameCapacity
            for (i, v) in values.enumerated() { b.floatChannelData![0][i] = v }
            viz.push(b)
        }
        push([1, 2, 3])
        XCTAssertEqual(viz.snapshot(3), [0, 0, 0], "disabled: nothing recorded")
        viz.enabled = true
        push([1, 2, 3]); push([4, 5])
        XCTAssertEqual(viz.snapshot(3), [3, 4, 5])
    }
}
