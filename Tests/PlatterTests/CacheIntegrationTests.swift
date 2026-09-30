import XCTest
import AVFoundation
@testable import Platter

/// The analysis path (decode, peaks, grid, key) on a real music file. Set
/// `PLATTER_TEST_TRACK=/path/to/song.m4a` to run it; tests never read the app's own library.
final class CacheIntegrationTests: XCTestCase {
    func testAnalyzeRealTrack() throws {
        guard let path = ProcessInfo.processInfo.environment["PLATTER_TEST_TRACK"] else {
            throw XCTSkip("set PLATTER_TEST_TRACK to an audio file to run this test")
        }
        let r = try Analysis.analyze(url: URL(fileURLWithPath: path))

        XCTAssertGreaterThan(r.duration, 10)
        // Peaks: 2000 buckets, normalized to 1.0, all in range.
        XCTAssertEqual(r.peaks.count, 2000)
        XCTAssertEqual(r.peaks.max() ?? 0, 1, accuracy: 0.001)
        XCTAssertFalse(r.peaks.contains { $0 < 0 || $0 > 1 || $0.isNaN })
        // Detail wave: 100 per second.
        XCTAssertEqual(Double(r.wave.count), r.duration * Analysis.waveRate, accuracy: 2)
        // A grid, when found, is in the DJ range.
        if let g = r.grid {
            XCTAssertTrue((78...175).contains(g.bpm))
            XCTAssertLessThan(g.firstBeat, g.period)
        }
        print("TRACK \(r.duration) s, \(r.grid.map { String(format: "%.2f BPM", $0.bpm) } ?? "no grid"), key \(r.key?.name ?? "-")")
    }
}
