import XCTest
import AVFoundation
@testable import PlatterCore
@testable import PlatterPlayer

/// Bugs found in review of the player, driven through PlayerState on an offline engine.
@MainActor
final class PlayerRegressionTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func wav(_ name: String, seconds: Double, hz: Float) throws -> String {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let n = AVAudioFrameCount(seconds * 44_100)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
        buf.frameLength = n
        for i in 0..<Int(n) {
            let v = 0.4 * sin(2 * Float.pi * hz * Float(i) / 44_100)
            buf.floatChannelData![0][i] = v
            buf.floatChannelData![1][i] = v
        }
        let file = "\(name).wav"
        try AVAudioFile(forWriting: dir.appendingPathComponent(file), settings: fmt.settings).write(from: buf)
        return file
    }

    private func setUpPlayer(_ ids: [String], seconds: Double) throws -> (PlayerState, AudioEngine, Library) {
        let db = try LibraryDB(path: ":memory:")
        let album = try db.createAlbum(name: "T", sourceURL: nil)
        for (k, id) in ids.enumerated() {
            try db.addLocalTrack(Track(id: id, title: id), fileName: try wav(id, seconds: seconds, hz: 440 * Float(k + 1)),
                                 size: 1, to: album)
        }
        let library = Library(db: db, audioDirectory: dir)
        library.source = .album(album)
        let engine = AudioEngine(decks: false, offline: AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!)
        try engine.start()
        let player = PlayerState(engine: engine, library: library)
        player.persists = false
        player.recordsHistory = false
        return (player, engine, library)
    }

    /// A crossfade used to cut the old track, and the track after it played silent.
    func testCrossfadeKeepsEveryTrackAudible() async throws {
        let (player, engine, library) = try setUpPlayer(["local-a", "local-b", "local-c"], seconds: 3)
        player.prefs.leveling = false
        player.prefs.crossfade = 1
        player.playAll(library.tracks)
        var frames: [(id: String, rms: Float)] = []
        for _ in 0..<900 {
            let b = try engine.renderOffline(seconds: 0.01)
            let p = b.floatChannelData![0]
            var s: Float = 0
            for i in 0..<Int(b.frameLength) { s += p[i] * p[i] }
            frames.append((player.current?.id ?? "-", (s / Float(max(1, b.frameLength))).squareRoot()))
            try await Task.sleep(for: .milliseconds(2))
            if !player.isPlaying, frames.count > 50 { break }
        }
        // At the hand-over to B, A still sounds (it fades out, no dip to silence).
        let firstB = try XCTUnwrap(frames.firstIndex { $0.id == "local-b" })
        XCTAssertGreaterThan(frames[firstB..<firstB + 10].map(\.rms).min() ?? 0, 0.1, "A fades out, not cut")
        // C plays with sound after its fade-in.
        let c = frames.enumerated().filter { $0.element.id == "local-c" }.dropFirst(100).map(\.element.rms)
        XCTAssertFalse(c.isEmpty, "C played")
        XCTAssertGreaterThan(c.reduce(0, +) / Float(max(1, c.count)), 0.1, "C is audible")
    }

    /// Clearing the queue while a track was loading used to crash (index out of range).
    func testClearWhileLoading() async throws {
        let (player, _, library) = try setUpPlayer(["local-a", "local-b"], seconds: 1)
        player.enqueue(library.tracks)
        player.play(index: 1)
        player.clear()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(player.queue.isEmpty)
        XCTAssertFalse(player.isPlaying)
        XCTAssertNil(player.currentIndex)
    }
}
