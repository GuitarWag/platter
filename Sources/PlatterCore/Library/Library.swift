import Foundation
import Combine
import AVFoundation

/// Files on disk: ~/Library/Application Support/Platter/{library.db, cache/<id>.m4a}.
package enum AppPaths {
    package static let support: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Platter", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    package static let audio: URL = {
        let dir = support.appendingPathComponent("cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    package static var database: URL { support.appendingPathComponent("library.db") }
    package static var legacyJSON: URL { support.appendingPathComponent("library.json") }
}

/// Opens the shared store (the library database and the audio folder) for either app.
@MainActor
package enum LibraryStore {
    /// The library, and a message when the database could not open (then nothing is saved
    /// this session).
    package static func open() -> (library: Library, error: String?) {
        do {
            return (Library(db: try LibraryDB(path: AppPaths.database.path)), nil)
        } catch {
            let message = "Could not open \(AppPaths.database.path): \(error). The library is not saved this session."
            return (Library(db: try! LibraryDB(path: ":memory:")), message)
        }
    }
}

/// A track ready for a deck: its audio file on disk, with duration, BPM, and peaks filled in.
package struct PreparedTrack {
    package let url: URL
    package let track: Track
    /// Saved main cue point and hot cues.
    package var cue: Double? = nil
    package var hotCues: [Double?] = Array(repeating: nil, count: 8)
}

/// The music library: albums and tracks from the database, search, downloads, and analysis.
///
/// Main-actor only. Slow work (yt-dlp, analysis) runs off the main thread and comes back here
/// to write the database, so the database has exactly one user.
@MainActor
package final class Library: ObservableObject {
    @Published package private(set) var albums: [Album] = []
    @Published package private(set) var smartAlbums: [SmartAlbum] = []
    @Published package private(set) var tracks: [Track] = []          // of the selected source
    @Published package private(set) var searchResults: [Track] = []
    /// What the track list shows.
    @Published package var source: Source = .all {
        didSet {
            guard source != oldValue else { return }
            attempt { try db.setSetting("source", source.key) }
            reloadTracks()
        }
    }
    /// Quick filter over the visible rows.
    @Published package var filter = TrackFilter()
    @Published package var sort: TrackSort?
    @Published package var searchText = "" {
        didSet { runSearch() }
    }
    /// Track id -> what is happening to it now ("Downloading…", "Analyzing…").
    @Published package private(set) var activity: [String: String] = [:]
    @Published package private(set) var isResolving = false
    @Published package var error: String?

    private let db: LibraryDB
    /// In-flight downloads by track id. A second request for the same track waits on the
    /// first one instead of starting a second yt-dlp that writes the same file.
    private var downloads: [String: Task<String, Error>] = [:]

    /// The selected album, when the source is an album.
    package var selectedAlbumID: Int64? {
        get { if case .album(let id) = source { return id } else { return nil } }
        set { source = newValue.map(Source.album) ?? .all }
    }
    package var selectedAlbum: Album? { albums.first { $0.id == selectedAlbumID } }
    package var selectedSmartAlbum: SmartAlbum? {
        guard case .smart(let id) = source else { return nil }
        return smartAlbums.first { $0.id == id }
    }
    package var isSearching: Bool { !searchText.trimmed.isEmpty }

    /// Rows can be dragged into a new order only in an album shown as it is.
    package var canReorder: Bool { selectedAlbumID != nil && !isSearching && filter.isEmpty && sort == nil }

    /// The rows the track list shows: search results or the source, then the quick filter,
    /// then the sort.
    package var visibleTracks: [Track] {
        var rows = isSearching ? searchResults : tracks
        if !filter.isEmpty { rows = rows.filter(filter.matches) }
        if let sort { rows.sort(by: sort.areInOrder) }
        return rows
    }

    /// Where downloads and imported files live.
    package let audioDirectory: URL

    /// `audioDirectory` is for tests: they use a temp folder, never the user's library.
    package init(db: LibraryDB, audioDirectory: URL = AppPaths.audio) {
        self.db = db
        self.audioDirectory = audioDirectory
        importLegacyLibraryIfNeeded()
        removeStaleDownloadFiles()
        albums = (try? db.albums()) ?? []
        smartAlbums = (try? db.smartAlbums()) ?? []
        let saved = (try? db.setting("source")).flatMap(Source.init(key:))
            ?? (try? db.setting("selectedAlbum")).flatMap { Int64($0) }.map(Source.album)
        source = saved.flatMap { isValid($0) ? $0 : nil } ?? albums.first.map { .album($0.id) } ?? .all
        reloadTracks()
    }

    // MARK: Reading

    /// Tells the other app the store changed. Set by the app.
    package var onStoreChanged: (() -> Void)?
    private var reloadingFromStore = false

    /// The other app changed the store: read it again, without telling it back.
    package func reloadFromStore() {
        reloadingFromStore = true
        defer { reloadingFromStore = false }
        reload()
    }

    private func reload() {
        if !reloadingFromStore { onStoreChanged?() }
        attempt {
            albums = try db.albums()
            smartAlbums = try db.smartAlbums()
        }
        if !isValid(source) { source = albums.first.map { .album($0.id) } ?? .all }
        reloadTracks()
        runSearch()
    }

    private func isValid(_ s: Source) -> Bool {
        switch s {
        case .all, .history: return true
        case .album(let id): return albums.contains { $0.id == id }
        case .smart(let id): return smartAlbums.contains { $0.id == id }
        }
    }

    private func reloadTracks() {
        attempt {
            switch source {
            case .album(let id): tracks = try db.tracks(album: id)
            case .all: tracks = try db.allTracks()
            case .history: tracks = try db.history()
            case .smart(let id):
                let f = smartAlbums.first { $0.id == id }?.filter ?? TrackFilter()
                tracks = try db.allTracks().filter(f.matches)
            }
        }
    }

    private func runSearch() {
        guard isSearching else { searchResults = []; return }
        attempt { searchResults = try db.search(searchText) }
    }

    /// Run a database call and show its error in the panel instead of throwing.
    private func attempt(_ body: () throws -> Void) {
        do { try body() } catch {
            self.error = (error as? LibraryError)?.message ?? "Library: \(error)"
        }
    }

    // MARK: Albums

    /// Resolve a playlist URL and save it as an album, then select it. A URL that is already
    /// in the library selects that album.
    package func addPlaylist(url raw: String) async {
        let url = Self.normalize(raw)
        guard !url.isEmpty else { return }
        if let existing = try? db.albumID(sourceURL: url) {
            selectedAlbumID = existing
            searchText = ""
            return
        }
        isResolving = true
        defer { isResolving = false }
        switch await YTDLP.playlist(url: url) {
        case .playlist(let title, let found):
            attempt {
                let id = try db.createAlbum(name: title ?? Self.fallbackName(for: url), sourceURL: url)
                try db.addTracks(found, to: id)
                searchText = ""
                reload()
                selectedAlbumID = id
            }
        case .failure(let reason):
            error = "Could not resolve the playlist: \(reason)"
        }
    }

    /// Fetch the album's playlist again and append tracks that are new. Existing tracks,
    /// their order, and user edits stay as they are.
    package func refresh(_ album: Album) async {
        guard let url = album.sourceURL else { return }
        isResolving = true
        defer { isResolving = false }
        switch await YTDLP.playlist(url: url) {
        case .playlist(_, let found):
            attempt { try db.addTracks(found, to: album.id) }
            reload()
        case .failure(let reason):
            error = "Could not refresh \"\(album.name)\": \(reason)"
        }
    }

    package func createAlbum(named name: String) {
        attempt {
            let id = try db.createAlbum(name: Self.cleanName(name, or: "New Album"), sourceURL: nil)
            reload()
            selectedAlbumID = id
        }
    }

    package func rename(_ album: Album, to name: String) {
        attempt { try db.renameAlbum(album.id, to: Self.cleanName(name, or: album.name)) }
        reload()
    }

    /// Delete the album. The tracks and their downloads stay in the library (search finds them).
    package func delete(_ album: Album) {
        attempt { try db.deleteAlbum(album.id) }
        reload()
    }

    package func moveAlbums(from source: IndexSet, to destination: Int) {
        var ids = albums.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        attempt { try db.reorderAlbums(ids) }
        reload()
    }

    // MARK: Tracks

    package func moveTracks(from source: IndexSet, to destination: Int) {
        guard let album = selectedAlbumID else { return }
        var ids = tracks.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        attempt { try db.reorderTracks(ids, in: album) }
        reloadTracks()
    }

    package func add(_ track: Track, to album: Album) {
        attempt { try db.addTracks([track], to: album.id) }
        reload()
    }

    package func remove(_ track: Track, from album: Album) {
        attempt { try db.removeTrack(track.id, from: album.id) }
        reload()
    }

    package func edit(_ track: Track, title: String, artist: String) {
        attempt { try db.updateTrack(track.id, title: Self.cleanName(title, or: track.title), artist: artist.trimmed) }
        reload()
    }

    /// Delete the downloaded audio file. The track stays in its albums and downloads again
    /// when it is next loaded.
    package func deleteDownload(_ track: Track) {
        if let name = track.fileName {
            try? FileManager.default.removeItem(at: audioDirectory.appendingPathComponent(name))
        }
        attempt { try db.clearDownload(track.id) }
        reload()
    }

    /// Download every track of the album that is not downloaded yet, one at a time.
    package func downloadAll(_ album: Album) async {
        guard let list = try? db.tracks(album: album.id) else { return }
        for t in list where !t.isCached {
            _ = try? await audioFile(for: t)
        }
    }

    // MARK: Download and analysis

    /// Download (if needed) and analyze (if needed) a track for a deck. Errors are also shown
    /// in the panel.
    package func prepare(_ track: Track) async throws -> PreparedTrack {
        do {
            let url = try await audioFile(for: track)
            var t = (try? db.track(track.id)) ?? track
            if (try? db.needsAnalysis(track.id, version: Analysis.version)) == false,
               let peaks = try? db.peaks(track.id), let wave = try? db.wave(track.id) {
                t.peaks = peaks
                t.wave = wave
            } else {
                activity[track.id] = "Analyzing…"
                defer { activity[track.id] = nil }
                let a = try await Task.detached(priority: .userInitiated) { try Analysis.analyze(url: url) }.value
                attempt {
                    try db.setAnalysis(track.id, duration: a.duration, bpm: a.bpm, peaks: a.peaks, wave: a.wave,
                                       beatOffset: a.grid?.firstBeat, key: a.key?.name, loudness: a.loudness,
                                       version: Analysis.version)
                }
                t.duration = a.duration
                t.bpm = a.bpm
                t.beatOffset = a.grid?.firstBeat
                t.key = a.key?.name
                t.loudness = a.loudness
                t.peaks = a.peaks
                t.wave = a.wave
                reload()
            }
            let cues = (try? db.cues(track.id)) ?? (cue: nil, hot: Array(repeating: nil, count: 8))
            return PreparedTrack(url: url, track: t, cue: cues.cue, hotCues: cues.hot)
        } catch {
            let msg = (error as? LibraryError)?.message ?? error.localizedDescription
            self.error = "\"\(track.title)\": \(msg)"
            throw error
        }
    }

    /// The downloaded audio file of a track, downloading it first when needed.
    package func audioFile(for track: Track) async throws -> URL {
        if let name = try? db.track(track.id)?.fileName {
            let url = audioDirectory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
            attempt { try db.clearDownload(track.id) } // the file was deleted outside the app
        }
        if track.isLocal {
            throw LibraryError("The imported file for \"\(track.title)\" is missing from \(audioDirectory.path).")
        }
        if let running = downloads[track.id] {
            return audioDirectory.appendingPathComponent(try await running.value)
        }
        let task = Task { try await YTDLP.download(id: track.id, into: audioDirectory) }
        downloads[track.id] = task
        activity[track.id] = "Downloading…"
        defer {
            downloads[track.id] = nil
            activity[track.id] = nil
        }
        let name = try await task.value
        let url = audioDirectory.appendingPathComponent(name)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
        attempt { try db.setDownload(track.id, fileName: name, size: size) }
        reload()
        return url
    }

    // MARK: Cues and history

    package func saveCue(trackID: String, slot: Int, seconds: Double?) {
        attempt { try db.setCue(trackID, slot: slot, seconds: seconds) }
    }

    package func logPlay(_ track: Track, deck: DeckID) {
        attempt { try db.addHistory(track.id, deck: deck.label) }
        historyChanged()
    }

    /// A play in the music player.
    package func logPlayerPlay(_ track: Track) {
        attempt { try db.addHistory(track.id, deck: "Player", source: "player") }
        historyChanged()
    }

    package func setRating(_ track: Track, _ rating: Int) {
        attempt { try db.setRating(track.id, rating) }
        reload()
    }

    /// Resolve a YouTube or YouTube Music playlist into library tracks without making an
    /// album (for the player's queue). The tracks get library rows, so their downloads and
    /// analysis are kept.
    package func resolvePlaylistTracks(url raw: String) async -> [Track] {
        let url = Self.normalize(raw)
        isResolving = true
        defer { isResolving = false }
        switch await YTDLP.playlist(url: url) {
        case .playlist(_, let found):
            var out: [Track] = []
            attempt {
                try db.upsertTracks(found)
                out = try found.compactMap { try db.track($0.id) }
            }
            reload()
            return out
        case .failure(let reason):
            error = "Could not resolve the playlist: \(reason)"
            return []
        }
    }

    package func allTracks() -> [Track] { (try? db.allTracks()) ?? [] }

    /// Tracks by id, in the order given; ids not in the library are skipped.
    package func tracks(ids: [String]) -> [Track] {
        ids.compactMap { try? db.track($0) ?? nil }
    }

    /// Every track of an album, in album order.
    package func tracks(inAlbum id: Int64) -> [Track] { (try? db.tracks(album: id)) ?? [] }

    // MARK: Player storage

    package func playerQueue() -> [Track] { (try? db.playerQueue()) ?? [] }

    package func savePlayerQueue(_ ids: [String]) {
        attempt { try db.savePlayerQueue(ids) }
    }

    package func setting(_ key: String) -> String? { (try? db.setting(key)) ?? nil }

    package func setSetting(_ key: String, _ value: String?) {
        attempt { try db.setSetting(key, value) }
    }

    private func historyChanged() {
        if !reloadingFromStore { onStoreChanged?() }
        if source == .history { reloadTracks() }
    }

    package func clearHistory() {
        attempt { try db.clearHistory() }
        historyChanged()
    }

    // MARK: Smart albums

    /// Save the quick filter as a smart album and show it.
    package func saveFilterAsSmartAlbum(named name: String) {
        guard !filter.isEmpty else { return }
        attempt {
            let id = try db.createSmartAlbum(name: Self.cleanName(name, or: "Smart Album"), filter: filter)
            filter = TrackFilter()
            reload()
            source = .smart(id)
        }
    }

    package func rename(_ smart: SmartAlbum, to name: String) {
        var s = smart
        s.name = Self.cleanName(name, or: smart.name)
        attempt { try db.updateSmartAlbum(s) }
        reload()
    }

    package func delete(_ smart: SmartAlbum) {
        attempt { try db.deleteSmartAlbum(smart.id) }
        reload()
    }

    // MARK: Local files

    package static let importableTypes = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "caf", "alac"]

    /// Copy audio files into the library. They go into the selected album when it is one you
    /// made, else into "Local Files". Title and artist come from the file's tags, or its name.
    /// Returns the imported tracks. `select` shows their album afterwards.
    @discardableResult
    package func importFiles(_ urls: [URL], select: Bool = true) async -> [Track] {
        let files = urls.filter { Self.importableTypes.contains($0.pathExtension.lowercased()) }
        guard !files.isEmpty else {
            error = "No audio files to import. Supported: \(Self.importableTypes.joined(separator: ", "))."
            return []
        }
        let target: Int64
        do {
            if let a = selectedAlbum, a.sourceURL == nil {
                target = a.id
            } else if let existing = try db.albumID(sourceURL: Self.localFilesKey) {
                target = existing
            } else {
                target = try db.createAlbum(name: "Local Files", sourceURL: Self.localFilesKey)
            }
        } catch {
            self.error = "Import: \(error)"
            return []
        }
        var failed: [String] = []
        var imported: [Track] = []
        for url in files {
            do {
                let meta = try await Self.readTags(url)
                let id = Track.localPrefix + UUID().uuidString.prefix(13).lowercased()
                let name = "\(id).\(url.pathExtension.lowercased())"
                let dest = audioDirectory.appendingPathComponent(name)
                try FileManager.default.copyItem(at: url, to: dest)
                _ = try AVAudioFile(forReading: dest) // the decoder can read it
                let size = (try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? Int64 ?? 0
                let track = Track(id: id, title: meta.title, artist: meta.artist, duration: meta.duration)
                try db.addLocalTrack(track, fileName: name, size: size, to: target)
                if let t = try db.track(id) { imported.append(t) }
            } catch {
                failed.append(url.lastPathComponent)
            }
        }
        if !failed.isEmpty { error = "Could not import: \(failed.joined(separator: ", "))" }
        reload()
        if select { source = .album(target) }
        return imported
    }

    /// `source_url` of the "Local Files" album, so imports find it again.
    package static let localFilesKey = "local:files"

    private static func readTags(_ url: URL) async throws -> (title: String, artist: String, duration: Double?) {
        let asset = AVURLAsset(url: url)
        let md = (try? await asset.load(.commonMetadata)) ?? []
        func value(_ id: AVMetadataIdentifier) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: md, filteredByIdentifier: id).first else { return nil }
            return (try? await item.load(.stringValue))?.trimmed
        }
        let title = await value(.commonIdentifierTitle)
        let artist = await value(.commonIdentifierArtist)
        let seconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds)
        return (title.flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent,
                artist ?? "", seconds.flatMap { $0.isFinite ? $0 : nil })
    }

    // MARK: Startup housekeeping

    /// Move the albums of the old library.json into the database once, then rename the file.
    private func importLegacyLibraryIfNeeded() {
        let json = AppPaths.legacyJSON
        guard let data = try? Data(contentsOf: json) else { return }
        attempt {
            try db.importLegacyJSON(data, audioDirectory: audioDirectory)
            try FileManager.default.moveItem(at: json, to: json.appendingPathExtension("imported"))
        }
    }

    /// Remove what old or killed yt-dlp runs left in the audio folder: temp folders, partial
    /// downloads, and source files that never became m4a.
    private func removeStaleDownloadFiles() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: audioDirectory.path) else { return }
        for name in names where name.hasPrefix(".tmp-") || name.hasSuffix(".part") || name.hasSuffix(".webm") {
            try? fm.removeItem(at: audioDirectory.appendingPathComponent(name))
        }
    }

    // MARK: Helpers

    /// Strip query params (playnext, si, etc.) so the same playlist resolves to the same album.
    package nonisolated static func normalize(_ url: String) -> String {
        var comps = URLComponents(string: url.trimmed)
        var items = comps?.queryItems ?? []
        items.removeAll { $0.name == "playnext" || $0.name == "si" }
        comps?.queryItems = items.isEmpty ? nil : items
        comps?.fragment = nil
        return comps?.url?.absoluteString ?? url.trimmed
    }

    /// Name for a playlist whose JSON has no title.
    package nonisolated static func fallbackName(for url: String) -> String {
        let list = URLComponents(string: url)?.queryItems?.first { $0.name == "list" }?.value
        return list.map { "Playlist " + $0.suffix(6).uppercased() } ?? "Playlist"
    }

    private static func cleanName(_ name: String, or fallback: String) -> String {
        let t = name.trimmed
        return t.isEmpty ? fallback : t
    }
}

/// Where the track list comes from.
package enum Source: Hashable {
    case all
    case history
    case album(Int64)
    case smart(Int64)

    /// Stored in settings.
    package var key: String {
        switch self {
        case .all: return "all"
        case .history: return "history"
        case .album(let id): return "album:\(id)"
        case .smart(let id): return "smart:\(id)"
        }
    }

    package init?(key: String) {
        let parts = key.split(separator: ":")
        switch (parts.first, parts.count > 1 ? Int64(parts[1]) : nil) {
        case ("all", _): self = .all
        case ("history", _): self = .history
        case ("album", let id?): self = .album(id)
        case ("smart", let id?): self = .smart(id)
        default: return nil
        }
    }
}

/// A sort of the track list by one column.
package struct TrackSort: Equatable {
    package enum Column: String, CaseIterable {
        case title, artist, bpm, key, duration, rating
    }
    package var column: Column
    package var ascending = true

    package init(column: Column, ascending: Bool = true) {
        self.column = column
        self.ascending = ascending
    }

    package func areInOrder(_ a: Track, _ b: Track) -> Bool {
        let result: Bool
        switch column {
        case .title: result = a.title.localizedStandardCompare(b.title) == .orderedAscending
        case .artist: result = a.artist.localizedStandardCompare(b.artist) == .orderedAscending
        case .bpm: result = (a.bpm ?? .infinity) < (b.bpm ?? .infinity)
        case .duration: result = (a.duration ?? .infinity) < (b.duration ?? .infinity)
        // Most stars first; unrated last.
        case .rating: result = (a.rating == 0 ? -1 : a.rating) > (b.rating == 0 ? -1 : b.rating)
        // Camelot order: 1A 1B 2A ... 12B, unknown keys last.
        case .key: result = Self.camelotRank(a) < Self.camelotRank(b)
        }
        return ascending ? result : !result
    }

    private static func camelotRank(_ t: Track) -> Int {
        guard let c = t.musicalKey?.camelot, let n = Int(c.dropLast()) else { return 1_000 }
        return n * 2 + (c.hasSuffix("B") ? 1 : 0)
    }
}
