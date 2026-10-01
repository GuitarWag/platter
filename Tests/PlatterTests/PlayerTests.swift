import XCTest
import AVFoundation
@testable import Platter

final class QueueOrderTests: XCTestCase {
    func testOrderAndShuffle() {
        XCTAssertEqual(QueueOrder.order(count: 4, shuffle: false, first: 2), [0, 1, 2, 3])
        let s = QueueOrder.order(count: 10, shuffle: true, first: 6, seed: 42)
        XCTAssertEqual(s.first, 6, "the playing track stays first")
        XCTAssertEqual(Set(s), Set(0..<10))
        XCTAssertEqual(QueueOrder.order(count: 10, shuffle: true, first: 6, seed: 42), s, "same seed, same order")
    }

    func testNextAndPrevious() {
        let o = [0, 1, 2]
        XCTAssertEqual(QueueOrder.next(after: 0, order: o, repeat: .off, ended: true), 1)
        XCTAssertNil(QueueOrder.next(after: 2, order: o, repeat: .off, ended: true))
        XCTAssertEqual(QueueOrder.next(after: 2, order: o, repeat: .all, ended: true), 0)
        XCTAssertEqual(QueueOrder.next(after: 1, order: o, repeat: .one, ended: true), 1, "repeat one at the end")
        XCTAssertEqual(QueueOrder.next(after: 1, order: o, repeat: .one, ended: false), 2, "a skip still moves on")
        XCTAssertEqual(QueueOrder.next(after: 0, order: [2, 0, 1], repeat: .off, ended: true), 1, "follows the shuffle")
        XCTAssertNil(QueueOrder.previous(before: 0, order: o, repeat: .off))
        XCTAssertEqual(QueueOrder.previous(before: 0, order: o, repeat: .all), 2)
        XCTAssertNil(QueueOrder.next(after: 0, order: [], repeat: .all, ended: true))
    }

    func testLevelingGain() {
        XCTAssertEqual(QueueOrder.levelingGain(loudness: -14), 1, accuracy: 1e-6)
        XCTAssertEqual(QueueOrder.levelingGain(loudness: -20), Float(pow(10, 6.0 / 20)), accuracy: 1e-5) // +6 dB
        XCTAssertEqual(QueueOrder.levelingGain(loudness: -40), Float(pow(10, 6.0 / 20)), accuracy: 1e-5) // capped
        XCTAssertEqual(QueueOrder.levelingGain(loudness: 0), Float(pow(10, -12.0 / 20)), accuracy: 1e-5) // capped
        XCTAssertEqual(QueueOrder.levelingGain(loudness: nil), 1)
    }

    func testLoudness() {
        let sr = 44_100.0
        let sine = (0..<Int(sr * 2)).map { 0.5 * sin(2 * Float.pi * 440 * Float($0) / Float(sr)) }
        let withSilence = sine + [Float](repeating: 0, count: Int(sr * 4))
        let l = Analysis.loudness(sine, sampleRate: sr)!
        XCTAssertEqual(l, 20 * log10(0.5 / 2.0.squareRoot()), accuracy: 0.1) // -9.03 dB
        XCTAssertEqual(Analysis.loudness(withSilence, sampleRate: sr)!, l, accuracy: 0.1, "silence does not count")
        XCTAssertNil(Analysis.loudness([Float](repeating: 0, count: 44_100), sampleRate: sr))
    }
}

/// The player end to end: library, queue, engine (offline), history, and saved state.
@MainActor
final class PlayerStateTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("platter-player-\(UUID().uuidString)")
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
            buf.floatChannelData![0][i] = v; buf.floatChannelData![1][i] = v
        }
        let file = "\(name).wav"
        do { try AVAudioFile(forWriting: dir.appendingPathComponent(file), settings: fmt.settings).write(from: buf) }
        return file
    }

    func testQueuePlaysThroughAndRemembers() async throws {
        let dbPath = dir.appendingPathComponent("lib.db").path
        let db = try LibraryDB(path: dbPath)
        let album = try db.createAlbum(name: "Test", sourceURL: nil)
        for (id, hz) in [("local-a", Float(440)), ("local-b", 880)] {
            let f = try wav(id, seconds: 1.0, hz: hz)
            try db.addLocalTrack(Track(id: id, title: id), fileName: f, size: 1, to: album)
        }
        let library = Library(db: db, audioDirectory: dir)
        let engine = AudioEngine(offline: AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!)
        try engine.start()
        let player = PlayerState(engine: engine, library: library)
        library.source = .album(album)
        player.prefs.leveling = false
        player.playAll(library.tracks)

        // Render until both tracks played (prepare and prefetch run between chunks).
        var advancedToB = false
        for _ in 0..<400 {
            _ = try engine.renderOffline(seconds: 0.01)
            try await Task.sleep(for: .milliseconds(2))
            if player.current?.id == "local-b" { advancedToB = true }
            if advancedToB, !player.isPlaying { break }
        }
        XCTAssertTrue(advancedToB, "the second track took over")
        XCTAssertFalse(player.isPlaying, "stops after the last track (repeat off)")

        let history = try db.history()
        XCTAssertEqual(history.map(\.id), ["local-b", "local-a"])
        XCTAssertTrue(history[0].albumNames.hasPrefix("Player"))
        XCTAssertEqual(try db.track("local-a")?.playCount, 1)

        // A new player on the same database gets the queue and the settings back.
        player.prefs.repeatMode = .all
        player.prefs.crossfade = 4
        try await Task.sleep(for: .milliseconds(600)) // settings save after a short rest
        let again = PlayerState(engine: engine, library: library)
        XCTAssertEqual(again.queue.map(\.track.id), ["local-a", "local-b"])
        XCTAssertEqual(again.prefs.repeatMode, .all)
        XCTAssertEqual(again.prefs.crossfade, 4)
        XCTAssertEqual(again.currentIndex, 1)
    }

    func testQueueEditing() async throws {
        let db = try LibraryDB(path: ":memory:")
        let album = try db.createAlbum(name: "T", sourceURL: nil)
        try db.addTracks((1...4).map { Track(id: "t\($0)", title: "T\($0)") }, to: album)
        let library = Library(db: db, audioDirectory: dir)
        let engine = AudioEngine(offline: AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!)
        let player = PlayerState(engine: engine, library: library)
        let tracks = try db.tracks(album: album)
        player.enqueue(Array(tracks[0...1]))
        player.enqueue([tracks[3]], next: false)
        XCTAssertEqual(player.queue.map(\.track.id), ["t1", "t2", "t4"])
        player.move(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(player.queue.map(\.track.id), ["t4", "t1", "t2"])
        player.remove(at: IndexSet(integer: 1))
        XCTAssertEqual(player.queue.map(\.track.id), ["t4", "t2"])
        player.enqueue([tracks[0]]) // the same track can be queued twice
        player.enqueue([tracks[0]])
        XCTAssertEqual(player.queue.count, 4)
        XCTAssertNotEqual(player.queue[2].id, player.queue[3].id)
        player.clear()
        XCTAssertTrue(player.queue.isEmpty)
    }
}
