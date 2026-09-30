import XCTest
@testable import Platter

final class YTDLPParserTests: XCTestCase {
    // Shape yt-dlp actually emits for `--flat-playlist --dump-json`: one object, "entries" array.
    let playlistObject = """
    {
      "id": "RDCLAK5uy_kx0d2",
      "title": "My Playlist",
      "entries": [
        {"id": "IBy7TCSY2wk", "title": "Track One", "creator": "Artist A", "duration": 205.0},
        {"id": "iywaBOMvYLI", "title": "Track Two", "creator": "Artist B", "duration": 300.5}
      ]
    }
    """

    func testParsesPlaylistObjectWithEntries() {
        let tracks = YTDLP.parseFlatJSON(playlistObject)
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks.first?.id, "IBy7TCSY2wk")
        XCTAssertEqual(tracks.first?.title, "Track One")
        XCTAssertEqual(tracks.first?.artist, "Artist A")
        XCTAssertEqual(tracks.first?.duration ?? -1, 205.0, accuracy: 0.01)
    }

    func testParsesBareArray() {
        let arr = """
        [{"id": "abc123", "title": "Solo", "creator": "X", "duration": 10}]
        """
        let tracks = YTDLP.parseFlatJSON(arr)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.id, "abc123")
    }

    // Real yt-dlp shape: newline-delimited objects, artist under "channel"/"uploader".
    func testParsesNDJSONWithChannel() {
        let nd = """
        {"id": "IBy7TCSY2wk", "title": "Wait and Bleed", "channel": "Slipknot", "uploader": "Slipknot", "duration": 148}
        {"id": "iywaBOMvYLI", "title": "Another", "uploader": "Band Y", "duration": 300}
        """
        let tracks = YTDLP.parseFlatJSON(nd)
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks.first?.id, "IBy7TCSY2wk")
        XCTAssertEqual(tracks.first?.artist, "Slipknot")
        XCTAssertEqual(tracks[1].artist, "Band Y")
    }

    func testArtistPrefersChannelOverUploader() {
        let obj = """
        {"entries": [{"id": "x", "title": "T", "channel": "The Channel", "uploader": "The Uploader", "creator": "The Creator"}]}
        """
        let tracks = YTDLP.parseFlatJSON(obj)
        XCTAssertEqual(tracks.first?.artist, "The Channel")
    }

    func testTitleFallsBackToCreatorAndId() {
        let obj = """
        {"entries": [{"id": "zzz", "creator": "OnlyArtist"}]}
        """
        let tracks = YTDLP.parseFlatJSON(obj)
        XCTAssertEqual(tracks.first?.title, "OnlyArtist")
        let obj2 = """
        {"entries": [{"id": "zzz"}]}
        """
        let tracks2 = YTDLP.parseFlatJSON(obj2)
        XCTAssertEqual(tracks2.first?.title, "zzz")
    }

    func testEmptyAndGarbage() {
        XCTAssertEqual(YTDLP.parseFlatJSON(""), [])
        XCTAssertEqual(YTDLP.parseFlatJSON("not json"), [])
    }
}
