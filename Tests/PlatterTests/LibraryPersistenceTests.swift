import XCTest
import Foundation
@testable import Platter

final class LibraryPersistenceTests: XCTestCase {
    func testNormalizeStripsTrackingParams() {
        let raw = "https://music.youtube.com/playlist?list=PLabc&playnext=1&si=xyz"
        let n = Library.normalize(raw)
        XCTAssertEqual(n, "https://music.youtube.com/playlist?list=PLabc")
    }

    func testNormalizeSamePlaylistSameKey() {
        let a = Library.normalize("https://music.youtube.com/playlist?list=PL1&playnext=1&si=aaa")
        let b = Library.normalize("https://music.youtube.com/playlist?list=PL1&si=bbb")
        XCTAssertEqual(a, b)
    }
}

/// LibraryDB against an in-memory database. Never touches the real library.
final class LibraryDBTests: XCTestCase {
    private var db: LibraryDB!

    override func setUpWithError() throws {
        db = try LibraryDB(path: ":memory:")
    }

    private func seed() throws -> (Int64, Int64) {
        let a = try db.createAlbum(name: "Warm Up", sourceURL: "https://x/1")
        let b = try db.createAlbum(name: "Peak Time", sourceURL: nil)
        try db.addTracks([
            Track(id: "t1", title: "Café del Mar", artist: "Energy 52", duration: 400),
            Track(id: "t2", title: "Strobe", artist: "deadmau5", duration: 600),
            Track(id: "t3", title: "Opus", artist: "Eric Prydz"),
        ], to: a)
        try db.addTracks([Track(id: "t2", title: "ignored", artist: "ignored")], to: b)
        return (a, b)
    }

    func testAlbumsWithCountsInOrder() throws {
        let (a, b) = try seed()
        let albums = try db.albums()
        XCTAssertEqual(albums.map(\.id), [a, b])
        XCTAssertEqual(albums[0].trackCount, 3)
        XCTAssertEqual(albums[0].duration, 1000)
        XCTAssertEqual(albums[1].trackCount, 1)
        XCTAssertEqual(try db.albumID(sourceURL: "https://x/1"), a)
    }

    func testRenameReorderDelete() throws {
        let (a, b) = try seed()
        try db.renameAlbum(a, to: "Opening Set")
        try db.reorderAlbums([b, a])
        XCTAssertEqual(try db.albums().map(\.name), ["Peak Time", "Opening Set"])

        try db.deleteAlbum(a)
        XCTAssertEqual(try db.albums().map(\.id), [b])
        // The tracks stay in the library and stay searchable.
        XCTAssertNotNil(try db.track("t1"))
        XCTAssertEqual(try db.search("cafe").map(\.id), ["t1"])
    }

    func testTrackOrderAndMembership() throws {
        let (a, _) = try seed()
        try db.reorderTracks(["t3", "t1", "t2"], in: a)
        XCTAssertEqual(try db.tracks(album: a).map(\.id), ["t3", "t1", "t2"])
        try db.removeTrack("t1", from: a)
        XCTAssertEqual(try db.tracks(album: a).map(\.id), ["t3", "t2"])
        // Adding a track that is already in the album keeps its position.
        try db.addTracks([Track(id: "t3", title: "Opus")], to: a)
        XCTAssertEqual(try db.tracks(album: a).map(\.id), ["t3", "t2"])
    }

    func testReimportKeepsUserEditsAndFillsDuration() throws {
        let (a, _) = try seed()
        try db.updateTrack("t2", title: "Strobe (Edit)", artist: "deadmau5")
        try db.addTracks([
            Track(id: "t2", title: "Strobe", artist: "deadmau5", duration: 1),
            Track(id: "t3", title: "Opus", artist: "Eric Prydz", duration: 543),
        ], to: a)
        XCTAssertEqual(try db.track("t2")?.title, "Strobe (Edit)")
        XCTAssertEqual(try db.track("t2")?.duration, 600)   // kept
        XCTAssertEqual(try db.track("t3")?.duration, 543)   // filled in
    }

    func testSearch() throws {
        _ = try seed()
        XCTAssertEqual(try db.search("CAFE").map(\.id), ["t1"], "case and diacritics are ignored")
        XCTAssertEqual(try db.search("dead").map(\.id), ["t2"], "prefix match")
        XCTAssertEqual(try db.search("eric opus").map(\.id), ["t3"], "all words, any column")
        XCTAssertEqual(try db.search("opus strobe"), [], "every word must match")
        XCTAssertEqual(try db.search("   "), [])
        // FTS5 syntax in user input is plain text, not an error.
        XCTAssertEqual(try db.search("\"strobe OR NEAR( *"), [])
        XCTAssertEqual(try db.search("strobe\"").map(\.id), ["t2"])
        // Results carry the album names.
        XCTAssertEqual(try db.search("strobe").first?.albumNames, "Warm Up, Peak Time")
        // An edit updates the index.
        try db.updateTrack("t3", title: "Pjanoo", artist: "Eric Prydz")
        XCTAssertEqual(try db.search("opus"), [])
        XCTAssertEqual(try db.search("pjan").map(\.id), ["t3"])
    }

    func testDownloadAnalysisAndSettings() throws {
        _ = try seed()
        XCTAssertNil(try db.peaks("t1"))
        try db.setAnalysis("t1", duration: 399.5, bpm: 128, peaks: [0, 0.5, 1])
        XCTAssertEqual(try db.peaks("t1"), [0, 0.5, 1])
        XCTAssertEqual(try db.track("t1")?.bpm, 128)
        try db.setAnalysis("t3", duration: 10, bpm: nil, peaks: [0.25])
        XCTAssertNil(try db.track("t3")?.bpm)

        try db.setDownload("t1", fileName: "t1.m4a", size: 42)
        XCTAssertEqual(try db.track("t1")?.isCached, true)
        XCTAssertEqual(try db.albums()[0].cachedCount, 1)
        try db.clearDownload("t1")
        XCTAssertEqual(try db.track("t1")?.isCached, false)

        XCTAssertNil(try db.setting("k"))
        try db.setSetting("k", "1")
        try db.setSetting("k", "2")
        XCTAssertEqual(try db.setting("k"), "2")
        try db.setSetting("k", nil)
        XCTAssertNil(try db.setting("k"))
    }

    func testAnalysisVersionGridAndKey() throws {
        _ = try seed()
        XCTAssertTrue(try db.needsAnalysis("t1", version: 2))
        try db.setAnalysis("t1", duration: 400, bpm: 128, peaks: [1], wave: [1], version: 1)
        XCTAssertTrue(try db.needsAnalysis("t1", version: 2), "old analysis version")
        try db.setAnalysis("t1", duration: 400, bpm: 128.02, peaks: [1], wave: [1],
                           beatOffset: 0.123, key: "Am", version: 2)
        XCTAssertFalse(try db.needsAnalysis("t1", version: 2))
        let t = try XCTUnwrap(try db.track("t1"))
        XCTAssertEqual(t.grid, BeatGrid(bpm: 128.02, firstBeat: 0.123))
        XCTAssertEqual(t.musicalKey?.camelot, "8A")
        XCTAssertTrue(try db.needsAnalysis("missing", version: 2))
    }

    func testCues() throws {
        _ = try seed()
        try db.setCue("t1", slot: -1, seconds: 12.5)
        try db.setCue("t1", slot: 0, seconds: 30)
        try db.setCue("t1", slot: 7, seconds: 90)
        try db.setCue("t1", slot: 0, seconds: 31)
        var c = try db.cues("t1")
        XCTAssertEqual(c.cue, 12.5)
        XCTAssertEqual(c.hot[0], 31)
        XCTAssertEqual(c.hot[7], 90)
        XCTAssertNil(c.hot[1])
        try db.setCue("t1", slot: 7, seconds: nil)
        c = try db.cues("t1")
        XCTAssertNil(c.hot[7])
        XCTAssertNil(try db.cues("t2").cue)
    }

    func testHistory() throws {
        _ = try seed()
        try db.addHistory("t1", deck: "A", at: Date(timeIntervalSince1970: 100))
        try db.addHistory("t2", deck: "B", at: Date(timeIntervalSince1970: 200))
        try db.addHistory("t1", deck: "B", at: Date(timeIntervalSince1970: 300))
        let h = try db.history()
        XCTAssertEqual(h.map(\.id), ["t1", "t2", "t1"])
        XCTAssertTrue(h[0].albumNames.hasPrefix("Deck B"))
        XCTAssertEqual(h[1].playedAt, Date(timeIntervalSince1970: 200))
        try db.clearHistory()
        XCTAssertEqual(try db.history(), [])
    }

    func testSmartAlbumsAndFilter() throws {
        _ = try seed()
        try db.setAnalysis("t1", duration: 400, bpm: 124, peaks: [1], key: "Am", version: 2)
        try db.setAnalysis("t2", duration: 600, bpm: 128, peaks: [1], key: "F#", version: 2)
        try db.setDownload("t2", fileName: "t2.m4a", size: 1)
        let f = TrackFilter(minBPM: 120, maxBPM: 130, compatibleKey: nil, downloadedOnly: false)
        let id = try db.createSmartAlbum(name: "House", filter: f)
        var albums = try db.smartAlbums()
        XCTAssertEqual(albums, [SmartAlbum(id: id, name: "House", filter: f)])

        let all = try db.allTracks()
        XCTAssertEqual(all.filter(f.matches).map(\.id).sorted(), ["t1", "t2"])
        XCTAssertEqual(all.filter(TrackFilter(compatibleKey: "C").matches).map(\.id), ["t1"]) // Am mixes with C
        XCTAssertEqual(all.filter(TrackFilter(downloadedOnly: true).matches).map(\.id), ["t2"])
        XCTAssertEqual(all.filter(TrackFilter(minBPM: 126).matches).map(\.id), ["t2"])

        albums[0].name = "Deep House"
        albums[0].filter.downloadedOnly = true
        try db.updateSmartAlbum(albums[0])
        XCTAssertEqual(try db.smartAlbums().first?.filter.downloadedOnly, true)
        try db.deleteSmartAlbum(id)
        XCTAssertEqual(try db.smartAlbums(), [])
    }

    func testImportLegacyJSON() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("a1.m4a"))

        let json = """
        {"selectedURL": "https://x/2", "albums": [
          {"name": "One", "url": "https://x/1", "addedAt": 0, "tracks": [
            {"id": "a1", "title": "First", "artist": "A", "duration": 100, "bpm": 120, "peaks": [0.5, 1], "isCached": true},
            {"id": "a2", "title": "Second", "artist": "B", "isCached": false}]},
          {"name": "Two", "url": "https://x/2", "addedAt": 0, "tracks": [
            {"id": "a2", "title": "Second", "artist": "B", "isCached": false}]}
        ]}
        """
        XCTAssertEqual(try db.importLegacyJSON(Data(json.utf8), audioDirectory: dir), 2)
        let albums = try db.albums()
        XCTAssertEqual(albums.map(\.name), ["One", "Two"])
        XCTAssertEqual(try db.tracks(album: albums[0].id).map(\.id), ["a1", "a2"])
        XCTAssertEqual(try db.track("a1")?.fileName, "a1.m4a")
        XCTAssertNil(try db.track("a2")?.fileName)
        XCTAssertEqual(try db.peaks("a1"), [0.5, 1])
        XCTAssertEqual(try db.setting("selectedAlbum"), String(albums[1].id))

        // A second import adds nothing.
        try db.importLegacyJSON(Data(json.utf8), audioDirectory: dir)
        XCTAssertEqual(try db.albums().count, 2)
    }

    func testFileDatabasePersists() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).db").path
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        do {
            let db = try LibraryDB(path: path)
            let id = try db.createAlbum(name: "Kept", sourceURL: nil)
            try db.addTracks([Track(id: "k1", title: "Keep Me")], to: id)
        }
        let reopened = try LibraryDB(path: path)
        XCTAssertEqual(try reopened.albums().map(\.name), ["Kept"])
        XCTAssertEqual(try reopened.search("keep").map(\.id), ["k1"])
    }
}

final class LibraryViewModelTests: XCTestCase {
    func testSourceKeys() {
        for s in [Source.all, .history, .album(42), .smart(7)] {
            XCTAssertEqual(Source(key: s.key), s)
        }
        XCTAssertNil(Source(key: "album:x"))
        XCTAssertNil(Source(key: "nope"))
    }

    func testSort() {
        func t(_ id: String, _ title: String, bpm: Double?, key: String?) -> Track {
            var x = Track(id: id, title: title); x.bpm = bpm; x.key = key; return x
        }
        let rows = [t("1", "b", bpm: 128, key: "C"),     // 8B
                    t("2", "a", bpm: nil, key: nil),
                    t("3", "C", bpm: 120, key: "Am"),    // 8A
                    t("4", "d", bpm: 124, key: "B")]     // 1B
        XCTAssertEqual(rows.sorted(by: TrackSort(column: .title).areInOrder).map(\.id), ["2", "1", "3", "4"])
        XCTAssertEqual(rows.sorted(by: TrackSort(column: .bpm).areInOrder).map(\.id), ["3", "4", "1", "2"])
        XCTAssertEqual(rows.sorted(by: TrackSort(column: .bpm, ascending: false).areInOrder).map(\.id).first, "2")
        XCTAssertEqual(rows.sorted(by: TrackSort(column: .key).areInOrder).map(\.id), ["4", "3", "1", "2"])
    }
}
