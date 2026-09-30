import Foundation
import Libsql

/// The library database (libSQL): albums, tracks, album membership, downloads, and settings.
///
/// One connection, not thread-safe. `Library` uses it only on the main actor. Every query is
/// small (the largest write is an 8 KB peaks blob), so calls run inline.
///
/// Track search uses an FTS5 index (`track_fts`) that triggers keep in sync with `track`.
final class LibraryDB {
    private let db: Database
    private let conn: Connection

    /// `path` is a file path, or ":memory:" for tests.
    init(path: String) throws {
        db = try Database(path)
        conn = try db.connect()
        _ = try first("PRAGMA journal_mode=WAL") { $0.text(0) }
        _ = try conn.execute("PRAGMA foreign_keys=ON")
        try migrate()
    }

    // MARK: Schema

    private func migrate() throws {
        let version = try first("PRAGMA user_version") { $0.int(0) } ?? 0
        if version < 1 { try conn.executeBatch(Self.schemaV1) }
        if version < 2 { try conn.executeBatch(Self.schemaV2) }
        if version < 3 { try conn.executeBatch(Self.schemaV3) }
    }

    // `track.pk` is an explicit INTEGER PRIMARY KEY so VACUUM cannot renumber the rowids
    // that the external-content FTS table points at.
    private static let schemaV1 = """
    BEGIN;
    CREATE TABLE album (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        source_url TEXT UNIQUE,
        position INTEGER NOT NULL,
        created_at REAL NOT NULL
    );
    CREATE TABLE track (
        pk INTEGER PRIMARY KEY,
        id TEXT NOT NULL UNIQUE,
        title TEXT NOT NULL,
        artist TEXT NOT NULL DEFAULT '',
        duration REAL,
        bpm REAL,
        peaks BLOB,
        file_name TEXT,
        file_size INTEGER,
        downloaded_at REAL
    );
    CREATE TABLE album_track (
        album_id INTEGER NOT NULL REFERENCES album(id) ON DELETE CASCADE,
        track_id TEXT NOT NULL REFERENCES track(id) ON DELETE CASCADE,
        position INTEGER NOT NULL,
        PRIMARY KEY (album_id, track_id)
    );
    CREATE INDEX album_track_by_track ON album_track(track_id);
    CREATE TABLE setting (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE VIRTUAL TABLE track_fts USING fts5(
        title, artist, content='track', content_rowid='pk',
        tokenize='unicode61 remove_diacritics 2'
    );
    CREATE TRIGGER track_ai AFTER INSERT ON track BEGIN
        INSERT INTO track_fts(rowid, title, artist) VALUES (new.pk, new.title, new.artist);
    END;
    CREATE TRIGGER track_ad AFTER DELETE ON track BEGIN
        INSERT INTO track_fts(track_fts, rowid, title, artist) VALUES ('delete', old.pk, old.title, old.artist);
    END;
    CREATE TRIGGER track_au AFTER UPDATE OF title, artist ON track BEGIN
        INSERT INTO track_fts(track_fts, rowid, title, artist) VALUES ('delete', old.pk, old.title, old.artist);
        INSERT INTO track_fts(rowid, title, artist) VALUES (new.pk, new.title, new.artist);
    END;
    PRAGMA user_version = 1;
    COMMIT;
    """

    /// The first row of a query, read with `read`. Steps through every row: a statement that
    /// is not run to the end stays active, and then COMMIT fails.
    private func first<T>(_ sql: String, _ params: [ValueRepresentable] = [], _ read: (Row) -> T?) throws -> T? {
        var result: T?
        for row in try conn.query(sql, params) where result == nil { result = read(row) }
        return result
    }

    /// v2: the detail waveform. Tracks analyzed before v2 have none and are analyzed again.
    private static let schemaV2 = """
    BEGIN;
    ALTER TABLE track ADD COLUMN wave BLOB;
    PRAGMA user_version = 2;
    COMMIT;
    """

    /// v3: beat grid, key, analysis version; saved cues; play history; smart albums.
    /// Cue slot -1 is the main cue point, 0...7 the hot cues.
    private static let schemaV3 = """
    BEGIN;
    ALTER TABLE track ADD COLUMN beat_offset REAL;
    ALTER TABLE track ADD COLUMN musical_key TEXT;
    ALTER TABLE track ADD COLUMN analysis_version INTEGER NOT NULL DEFAULT 0;
    CREATE TABLE cue (
        track_id TEXT NOT NULL REFERENCES track(id) ON DELETE CASCADE,
        slot INTEGER NOT NULL,
        seconds REAL NOT NULL,
        PRIMARY KEY (track_id, slot)
    );
    CREATE TABLE play_history (
        id INTEGER PRIMARY KEY,
        track_id TEXT NOT NULL REFERENCES track(id) ON DELETE CASCADE,
        deck TEXT NOT NULL,
        played_at REAL NOT NULL
    );
    CREATE INDEX play_history_by_time ON play_history(played_at DESC);
    CREATE TABLE smart_album (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        min_bpm REAL,
        max_bpm REAL,
        key_name TEXT,
        downloaded_only INTEGER NOT NULL DEFAULT 0,
        position INTEGER NOT NULL
    );
    PRAGMA user_version = 3;
    COMMIT;
    """

    private func transaction(_ body: () throws -> Void) throws {
        _ = try conn.execute("BEGIN")
        do {
            try body()
            _ = try conn.execute("COMMIT")
        } catch {
            _ = try? conn.execute("ROLLBACK")
            throw error
        }
    }

    // MARK: Albums

    func albums() throws -> [Album] {
        let sql = """
        SELECT a.id, a.name, a.source_url, count(t.pk), count(t.file_name), coalesce(sum(t.duration), 0)
        FROM album a
        LEFT JOIN album_track at ON at.album_id = a.id
        LEFT JOIN track t ON t.id = at.track_id
        GROUP BY a.id
        ORDER BY a.position, a.id
        """
        return try conn.query(sql).map { r in
            Album(id: r.int(0) ?? 0, name: r.text(1) ?? "", sourceURL: r.text(2),
                  trackCount: Int(r.int(3) ?? 0), cachedCount: Int(r.int(4) ?? 0),
                  duration: r.real(5) ?? 0)
        }
    }

    func albumID(sourceURL: String) throws -> Int64? {
        try first("SELECT id FROM album WHERE source_url = ?", [sourceURL]) { $0.int(0) }
    }

    @discardableResult
    func createAlbum(name: String, sourceURL: String?) throws -> Int64 {
        let sql = """
        INSERT INTO album (name, source_url, position, created_at)
        VALUES (?, ?, (SELECT coalesce(max(position), -1) + 1 FROM album), ?)
        RETURNING id
        """
        guard let id = try first(sql, [name, sourceURL, Date().timeIntervalSince1970], { $0.int(0) }) else {
            throw LibraryError("Could not create the album.")
        }
        return id
    }

    func renameAlbum(_ id: Int64, to name: String) throws {
        _ = try conn.execute("UPDATE album SET name = ? WHERE id = ?", [name, id])
    }

    func deleteAlbum(_ id: Int64) throws {
        _ = try conn.execute("DELETE FROM album WHERE id = ?", [id])
    }

    /// Store the album order. `ids` is the complete list, first to last.
    func reorderAlbums(_ ids: [Int64]) throws {
        try transaction {
            for (i, id) in ids.enumerated() {
                _ = try conn.execute("UPDATE album SET position = ? WHERE id = ?", [i, id])
            }
        }
    }

    // MARK: Tracks

    private static let trackColumns = "t.id, t.title, t.artist, t.duration, t.bpm, t.file_name, t.musical_key, t.beat_offset"

    private static func track(from r: Row) -> Track {
        var t = Track(id: r.text(0) ?? "", title: r.text(1) ?? "", artist: r.text(2) ?? "",
                      duration: r.real(3))
        t.bpm = r.real(4)
        t.fileName = r.text(5)
        t.key = r.text(6)
        t.beatOffset = r.real(7)
        return t
    }

    func tracks(album: Int64) throws -> [Track] {
        let sql = """
        SELECT \(Self.trackColumns) FROM album_track at JOIN track t ON t.id = at.track_id
        WHERE at.album_id = ? ORDER BY at.position
        """
        return try conn.query(sql, [album]).map(Self.track(from:))
    }

    func track(_ id: String) throws -> Track? {
        try first("SELECT \(Self.trackColumns) FROM track t WHERE t.id = ?", [id], Self.track(from:))
    }

    /// Full-text search on title and artist over the whole library, best match first.
    /// Every word is a prefix match, and all words must match. Diacritics are ignored.
    func search(_ text: String, limit: Int = 200) throws -> [Track] {
        guard let match = Self.ftsQuery(text) else { return [] }
        let sql = """
        SELECT \(Self.trackColumns),
            (SELECT group_concat(a.name, ', ') FROM album_track at JOIN album a ON a.id = at.album_id
             WHERE at.track_id = t.id)
        FROM track_fts JOIN track t ON t.pk = track_fts.rowid
        WHERE track_fts MATCH ?
        ORDER BY rank
        LIMIT ?
        """
        return try conn.query(sql, [match, limit]).map { r in
            var t = Self.track(from: r)
            t.albumNames = r.text(8) ?? ""
            return t
        }
    }

    /// `daft pu"nk` -> `"daft"* "pu""nk"*`: each word is quoted (inner quotes doubled) and made
    /// a prefix term, so user input is never read as FTS5 syntax.
    static func ftsQuery(_ text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        return words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }
            .joined(separator: " ")
    }

    /// Insert new tracks and append them to the album. A track that is already in the library
    /// keeps its (maybe user-edited) title and artist; only a missing duration is filled in.
    /// A track that is already in the album keeps its position.
    func addTracks(_ tracks: [Track], to album: Int64) throws {
        try transaction {
            for t in tracks {
                _ = try conn.execute("""
                    INSERT INTO track (id, title, artist, duration) VALUES (?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET duration = coalesce(track.duration, excluded.duration)
                    """, [t.id, t.title, t.artist, t.duration])
                _ = try conn.execute("""
                    INSERT OR IGNORE INTO album_track (album_id, track_id, position)
                    VALUES (?, ?, (SELECT coalesce(max(position), -1) + 1 FROM album_track WHERE album_id = ?))
                    """, [album, t.id, album])
            }
        }
    }

    func removeTrack(_ id: String, from album: Int64) throws {
        _ = try conn.execute("DELETE FROM album_track WHERE album_id = ? AND track_id = ?", [album, id])
    }

    /// Store the track order of an album. `ids` is the complete list, first to last.
    func reorderTracks(_ ids: [String], in album: Int64) throws {
        try transaction {
            for (i, id) in ids.enumerated() {
                _ = try conn.execute("UPDATE album_track SET position = ? WHERE album_id = ? AND track_id = ?",
                                     [i, album, id])
            }
        }
    }

    func updateTrack(_ id: String, title: String, artist: String) throws {
        _ = try conn.execute("UPDATE track SET title = ?, artist = ? WHERE id = ?", [title, artist, id])
    }

    // MARK: Downloads and analysis

    func setDownload(_ id: String, fileName: String, size: Int64) throws {
        _ = try conn.execute("UPDATE track SET file_name = ?, file_size = ?, downloaded_at = ? WHERE id = ?",
                             [fileName, size, Date().timeIntervalSince1970, id])
    }

    func clearDownload(_ id: String) throws {
        _ = try conn.execute("UPDATE track SET file_name = NULL, file_size = NULL, downloaded_at = NULL WHERE id = ?",
                             [id])
    }

    func setAnalysis(_ id: String, duration: Double, bpm: Double?, peaks: [Float], wave: [Float]? = nil,
                     beatOffset: Double? = nil, key: String? = nil, version: Int = 0) throws {
        _ = try conn.execute("""
            UPDATE track SET duration = ?, bpm = ?, peaks = ?, wave = ?, beat_offset = ?, musical_key = ?,
                analysis_version = ?
            WHERE id = ?
            """, [duration, bpm, Self.blob(peaks), wave.map(Self.blob), beatOffset, key, version, id])
    }

    /// True when the track has no stored analysis, or one from before `version`.
    func needsAnalysis(_ id: String, version: Int) throws -> Bool {
        try first("SELECT peaks IS NULL OR wave IS NULL OR analysis_version < ? FROM track WHERE id = ?",
                  [version, id]) { $0.int(0) }.map { $0 != 0 } ?? true
    }

    /// Stored overview peaks, or `nil` when the track was never analyzed.
    func peaks(_ id: String) throws -> [Float]? {
        try first("SELECT peaks FROM track WHERE id = ?", [id], { $0.blob(0) }).map(Self.floats)
    }

    /// Stored detail waveform (`Analysis.waveRate` buckets per second), or `nil`.
    func wave(_ id: String) throws -> [Float]? {
        try first("SELECT wave FROM track WHERE id = ?", [id], { $0.blob(0) }).map(Self.floats)
    }

    private static func blob(_ floats: [Float]) -> Data {
        floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func floats(_ data: Data) -> [Float] {
        var out = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = out.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return out
    }

    // MARK: Local files

    /// Add a track whose audio file is already in the audio folder (an imported local file).
    func addLocalTrack(_ track: Track, fileName: String, size: Int64, to album: Int64) throws {
        try addTracks([track], to: album)
        try setDownload(track.id, fileName: fileName, size: size)
    }

    func allTracks() throws -> [Track] {
        try conn.query("SELECT \(Self.trackColumns) FROM track t ORDER BY t.title COLLATE NOCASE")
            .map(Self.track(from:))
    }

    // MARK: Cues

    /// The saved main cue point and hot cues 1-8 of a track.
    func cues(_ trackID: String) throws -> (cue: Double?, hot: [Double?]) {
        var cue: Double?
        var hot = [Double?](repeating: nil, count: 8)
        for r in try conn.query("SELECT slot, seconds FROM cue WHERE track_id = ?", [trackID]) {
            let slot = Int(r.int(0) ?? -99), t = r.real(1)
            if slot == -1 { cue = t } else if hot.indices.contains(slot) { hot[slot] = t }
        }
        return (cue, hot)
    }

    /// Store (or clear, with `nil`) one cue. Slot -1 is the main cue point.
    func setCue(_ trackID: String, slot: Int, seconds: Double?) throws {
        if let seconds {
            _ = try conn.execute("""
                INSERT INTO cue (track_id, slot, seconds) VALUES (?, ?, ?)
                ON CONFLICT(track_id, slot) DO UPDATE SET seconds = excluded.seconds
                """, [trackID, slot, seconds])
        } else {
            _ = try conn.execute("DELETE FROM cue WHERE track_id = ? AND slot = ?", [trackID, slot])
        }
    }

    // MARK: History

    func addHistory(_ trackID: String, deck: String, at date: Date = Date()) throws {
        _ = try conn.execute("INSERT INTO play_history (track_id, deck, played_at) VALUES (?, ?, ?)",
                             [trackID, deck, date.timeIntervalSince1970])
    }

    /// Played tracks, newest first. `albumNames` carries "deck · time" for the list.
    func history(limit: Int = 500) throws -> [Track] {
        let sql = """
        SELECT \(Self.trackColumns), h.deck, h.played_at
        FROM play_history h JOIN track t ON t.id = h.track_id
        ORDER BY h.played_at DESC LIMIT ?
        """
        let f = DateFormatter()
        f.dateFormat = "EEE HH:mm"
        return try conn.query(sql, [limit]).map { r in
            var t = Self.track(from: r)
            t.albumNames = "Deck \(r.text(8) ?? "?") · \(f.string(from: Date(timeIntervalSince1970: r.real(9) ?? 0)))"
            t.playedAt = r.real(9).map(Date.init(timeIntervalSince1970:))
            return t
        }
    }

    func clearHistory() throws {
        _ = try conn.execute("DELETE FROM play_history")
    }

    // MARK: Smart albums

    func smartAlbums() throws -> [SmartAlbum] {
        try conn.query("SELECT id, name, min_bpm, max_bpm, key_name, downloaded_only FROM smart_album ORDER BY position, id")
            .map { r in
                SmartAlbum(id: r.int(0) ?? 0, name: r.text(1) ?? "",
                           filter: TrackFilter(minBPM: r.real(2), maxBPM: r.real(3),
                                               compatibleKey: r.text(4), downloadedOnly: (r.int(5) ?? 0) != 0))
            }
    }

    @discardableResult
    func createSmartAlbum(name: String, filter: TrackFilter) throws -> Int64 {
        let sql = """
        INSERT INTO smart_album (name, min_bpm, max_bpm, key_name, downloaded_only, position)
        VALUES (?, ?, ?, ?, ?, (SELECT coalesce(max(position), -1) + 1 FROM smart_album))
        RETURNING id
        """
        guard let id = try first(sql, [name, filter.minBPM, filter.maxBPM, filter.compatibleKey,
                                       filter.downloadedOnly ? 1 : 0], { $0.int(0) }) else {
            throw LibraryError("Could not create the smart album.")
        }
        return id
    }

    func updateSmartAlbum(_ album: SmartAlbum) throws {
        _ = try conn.execute("""
            UPDATE smart_album SET name = ?, min_bpm = ?, max_bpm = ?, key_name = ?, downloaded_only = ? WHERE id = ?
            """, [album.name, album.filter.minBPM, album.filter.maxBPM, album.filter.compatibleKey,
                  album.filter.downloadedOnly ? 1 : 0, album.id])
    }

    func deleteSmartAlbum(_ id: Int64) throws {
        _ = try conn.execute("DELETE FROM smart_album WHERE id = ?", [id])
    }

    // MARK: Settings

    func setting(_ key: String) throws -> String? {
        try first("SELECT value FROM setting WHERE key = ?", [key]) { $0.text(0) }
    }

    func setSetting(_ key: String, _ value: String?) throws {
        if let value {
            _ = try conn.execute("INSERT INTO setting (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                                 [key, value])
        } else {
            _ = try conn.execute("DELETE FROM setting WHERE key = ?", [key])
        }
    }

    // MARK: Import from library.json (v1 of the app)

    private struct LegacyState: Decodable {
        var albums: [LegacyAlbum] = []
        var selectedURL: String?
    }

    private struct LegacyAlbum: Decodable {
        var name: String
        var url: String
        var tracks: [LegacyTrack] = []
    }

    private struct LegacyTrack: Decodable {
        var id: String
        var title: String
        var artist: String?
        var duration: Double?
        var bpm: Double?
        var peaks: [Float]?
    }

    /// Copy the albums of an old `library.json` into the database. Tracks whose audio file is
    /// in `audioDirectory` are marked as downloaded. Returns the number of albums imported.
    @discardableResult
    func importLegacyJSON(_ data: Data, audioDirectory: URL) throws -> Int {
        let state = try JSONDecoder().decode(LegacyState.self, from: data)
        for album in state.albums where try albumID(sourceURL: album.url) == nil {
            let id = try createAlbum(name: album.name, sourceURL: album.url)
            try addTracks(album.tracks.map {
                Track(id: $0.id, title: $0.title, artist: $0.artist ?? "", duration: $0.duration)
            }, to: id)
            for t in album.tracks {
                if let peaks = t.peaks, !peaks.isEmpty {
                    try setAnalysis(t.id, duration: t.duration ?? 0, bpm: t.bpm, peaks: peaks)
                }
                let name = "\(t.id).m4a"
                let file = audioDirectory.appendingPathComponent(name)
                if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int64 {
                    try setDownload(t.id, fileName: name, size: size)
                }
            }
            if album.url == state.selectedURL { try setSetting("selectedAlbum", String(id)) }
        }
        return state.albums.count
    }
}

/// Error carrying a user-facing message.
struct LibraryError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: libSQL helpers

/// Lets an optional be bound as a parameter: `nil` binds SQL NULL.
extension Optional: @retroactive ValueRepresentable where Wrapped: ValueRepresentable {
    public func toValue() -> Libsql.Value {
        switch self {
        case .some(let wrapped): return wrapped.toValue()
        case .none: return .null
        }
    }
}

private extension Row {
    func text(_ i: Int32) -> String? {
        if case .text(let s)? = try? get(i) { return s }
        return nil
    }

    func int(_ i: Int32) -> Int64? {
        if case .integer(let n)? = try? get(i) { return n }
        return nil
    }

    func real(_ i: Int32) -> Double? {
        switch try? get(i) {
        case .real(let d)?: return d
        case .integer(let n)?: return Double(n)
        default: return nil
        }
    }

    func blob(_ i: Int32) -> Data? {
        if case .blob(let d)? = try? get(i) { return d }
        return nil
    }
}
