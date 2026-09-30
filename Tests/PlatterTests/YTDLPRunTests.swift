import XCTest
@testable import Platter

/// End-to-end test of YTDLP.run() against the network: proves the concurrent pipe-drain fix
/// actually unblocks the large-output resolve case (the ~250 KB playlist dump that deadlocked
/// the old waitUntilExit-then-read code). Skips gracefully if yt-dlp is absent.
final class YTDLPRunTests: XCTestCase {
    func testLargeOutputDoesNotDeadlock() throws {
        // Network, YouTube, and a playlist that may change: opt-in, so CI and other machines
        // do not fail for reasons outside the code.
        guard ProcessInfo.processInfo.environment["PLATTER_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("network test; run with PLATTER_NETWORK_TESTS=1")
        }
        guard YTDLP.isInstalled() else { throw XCTSkip("yt-dlp not installed") }
        let url = "https://music.youtube.com/playlist?list=RDCLAK5uy_kx0d2-VPr69KAkIQOTVFq04hCBsJE9LaI"
        let r = YTDLP.run(["--flat-playlist", "--dump-json", "--no-warnings", url], timeout: 120)
        XCTAssertEqual(r.exit, 0)
        // The old deadlock would leave stdout empty; a resolved 111-track playlist is ~250 KB.
        XCTAssertGreaterThan(r.stdout.count, 65_536, "stdout exceeds one pipe buffer (deadlock regression)")
        // Parser sees tracks from the real output.
        let tracks = YTDLP.parseFlatJSON(r.stdout)
        XCTAssertGreaterThan(tracks.count, 50)
        XCTAssertEqual(tracks.first?.id, "IBy7TCSY2wk")
        XCTAssertEqual(tracks.first?.artist, "Slipknot")
    }
}
