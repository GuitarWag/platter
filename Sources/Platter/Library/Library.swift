import Foundation
import Combine
import AVFoundation

/// Files on disk: ~/Library/Application Support/Platter/{library.db, cache/<id>.m4a}.
enum AppPaths {
    static let support: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Platter", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let audio: URL = {
        let dir = support.appendingPathComponent("cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var database: URL { support.appendingPathComponent("library.db") }
    static var legacyJSON: URL { support.appendingPathComponent("library.json") }
}

/// A track ready for a deck: its audio file on disk, with duration, BPM, and peaks filled in.
struct PreparedTrack {
    let url: URL
    let track: Track
    /// Saved main cue point and hot cues.
    var cue: Double? = nil
    var hotCues: [Double?] = Array(repeating: nil, count: 8)
}

/// The music library: albums and tracks from the database, search, downloads, and analysis.
///
/// Main-actor only. Slow work (yt-dlp, analysis) runs off the main thread and comes back here
/// to write the database, so the database has exactly one user.
@MainActor
final class Library: ObservableObject {
    @Published private(set) var albums: [Album] = []
    @Published private(set) var smartAlbums: [SmartAlbum] = []
    @Published private(set) var tracks: [Track] = []          // of the selected source
    @Published private(set) var searchResults: [Track] = []
    /// What the track list shows.
    @Published var source: Source = .all {
        didSet {
            guard source != oldValue else { return }
            attempt { try db.setSetting("source", source.key) }
            reloadTracks()
        }
    }
    /// Quick filter over the visible rows.
    @Published var filter = TrackFilter()
    @Published var sort: TrackSort?
    @Published var searchText = "" {
        didSet { runSearch() }
    }
    /// Track id -> what is happening to it now ("Downloading…", "Analyzing…").
    @Published private(set) var activity: [String: String] = [:]
    @Published private(set) var isResolving = false
    @Published var error: String?

    private let db: LibraryDB
    /// In-flight downloads by track id. A second request for the same track waits on the
    /// first one instead of starting a second yt-dlp that writes the same file.
    private var downloads: [String: Task<String, Error>] = [:]

    /// The selected album, when the source is an album.
    var selectedAlbumID: Int64? {
        get { if case .album(let id) = source { return id } else { return nil } }
        set { source = newValue.map(Source.album) ?? .all }
    }
    var selectedAlbum: Album? { albums.first { $0.id == selectedAlbumID } }
    var selectedSmartAlbum: SmartAlbum? {
        guard case .smart(let id) = source else { return nil }
        return smartAlbums.first { $0.id == id }
    }
    var isSearching: Bool { !searchText.trimmed.isEmpty }

    /// Rows can be dragged into a new order only in an album shown as it is.
    var canReorder: Bool { selectedAlbumID != nil && !isSearching && filter.isEmpty && sort == nil }

    /// The rows the track list shows: search results or the source, then the quick filter,
    /// then the sort.
    var visibleTracks: [Track] {
        var rows = isSearching ? searchResults : tracks
        if !filter.isEmpty { rows = rows.filter(filter.matches) }
        if let sort { rows.sort(by: sort.areInOrder) }
        return rows
    }

    init(db: LibraryDB) {
        self.db = db
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

    private func reload() {
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
    func addPlaylist(url raw: String) async {
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
    func refresh(_ album: Album) async {
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

    func createAlbum(named name: String) {
        attempt {
            let id = try db.createAlbum(name: Self.cleanName(name, or: "New Album"), sourceURL: nil)
            reload()
            selectedAlbumID = id
        }
    }

    func rename(_ album: Album, to name: String) {
        attempt { try db.renameAlbum(album.id, to: Self.cleanName(name, or: album.name)) }
        reload()
    }

    /// Delete the album. The tracks and their downloads stay in the library (search finds them).
    func delete(_ album: Album) {
        attempt { try db.deleteAlbum(album.id) }
        reload()
    }

    func moveAlbums(from source: IndexSet, to destination: Int) {
        var ids = albums.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        attempt { try db.reorderAlbums(ids) }
        reload()
    }

    // MARK: Tracks

    func moveTracks(from source: IndexSet, to destination: Int) {
        guard let album = selectedAlbumID else { return }
        var ids = tracks.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        attempt { try db.reorderTracks(ids, in: album) }
        reloadTracks()
    }

    func add(_ track: Track, to album: Album) {
        attempt { try db.addTracks([track], to: album.id) }
        reload()
    }

    func remove(_ track: Track, from album: Album) {
        attempt { try db.removeTrack(track.id, from: album.id) }
        reload()
    }

    func edit(_ track: Track, title: String, artist: String) {
        attempt { try db.updateTrack(track.id, title: Self.cleanName(title, or: track.title), artist: artist.trimmed) }
        reload()
    }

    /// Delete the downloaded audio file. The track stays in its albums and downloads again
    /// when it is next loaded.
    func deleteDownload(_ track: Track) {
        if let name = track.fileName {
            try? FileManager.default.removeItem(at: AppPaths.audio.appendingPathComponent(name))
        }
        attempt { try db.clearDownload(track.id) }
        reload()
    }

    /// Download every track of the album that is not downloaded yet, one at a time.
    func downloadAll(_ album: Album) async {
        guard let list = try? db.tracks(album: album.id) else { return }
        for t in list where !t.isCached {
            _ = try? await audioFile(for: t)
        }
    }

    // MARK: Download and analysis

    /// Download (if needed) and analyze (if needed) a track for a deck. Errors are also shown
    /// in the panel.
    func prepare(_ track: Track) async throws -> PreparedTrack {
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
                                       beatOffset: a.grid?.firstBeat, key: a.key?.name, version: Analysis.version)
                }
                t.duration = a.duration
                t.bpm = a.bpm
                t.beatOffset = a.grid?.firstBeat
                t.key = a.key?.name
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
    func audioFile(for track: Track) async throws -> URL {
        if let name = try? db.track(track.id)?.fileName {
            let url = AppPaths.audio.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
            attempt { try db.clearDownload(track.id) } // the file was deleted outside the app
        }
        if track.isLocal {
            throw LibraryError("The imported file for \"\(track.title)\" is missing from \(AppPaths.audio.path).")
        }
        if let running = downloads[track.id] {
            return AppPaths.audio.appendingPathComponent(try await running.value)
        }
        let task = Task { try await YTDLP.download(id: track.id, into: AppPaths.audio) }
        downloads[track.id] = task
        activity[track.id] = "Downloading…"
        defer {
            downloads[track.id] = nil
            activity[track.id] = nil
        }
        let name = try await task.value
        let url = AppPaths.audio.appendingPathComponent(name)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
        attempt { try db.setDownload(track.id, fileName: name, size: size) }
        reload()
        return url
    }

    // MARK: Cues and history

    func saveCue(trackID: String, slot: Int, seconds: Double?) {
        attempt { try db.setCue(trackID, slot: slot, seconds: seconds) }
    }

    func logPlay(_ track: Track, deck: DeckID) {
        attempt { try db.addHistory(track.id, deck: deck.label) }
        historyChanged()
    }

    private func historyChanged() {
        if source == .history { reloadTracks() }
    }

    func clearHistory() {
        attempt { try db.clearHistory() }
        historyChanged()
    }

    // MARK: Smart albums

    /// Save the quick filter as a smart album and show it.
    func saveFilterAsSmartAlbum(named name: String) {
        guard !filter.isEmpty else { return }
        attempt {
            let id = try db.createSmartAlbum(name: Self.cleanName(name, or: "Smart Album"), filter: filter)
            filter = TrackFilter()
            reload()
            source = .smart(id)
        }
    }

    func rename(_ smart: SmartAlbum, to name: String) {
        var s = smart
        s.name = Self.cleanName(name, or: smart.name)
        attempt { try db.updateSmartAlbum(s) }
        reload()
    }

    func delete(_ smart: SmartAlbum) {
        attempt { try db.deleteSmartAlbum(smart.id) }
        reload()
    }

    // MARK: Local files

    static let importableTypes = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "caf", "alac"]

    /// Copy audio files into the library. They go into the selected album when it is one you
    /// made, else into "Local Files". Title and artist come from the file's tags, or its name.
    func importFiles(_ urls: [URL]) async {
        let files = urls.filter { Self.importableTypes.contains($0.pathExtension.lowercased()) }
        guard !files.isEmpty else {
            error = "No audio files to import. Supported: \(Self.importableTypes.joined(separator: ", "))."
            return
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
            return
        }
        var failed: [String] = []
        for url in files {
            do {
                let meta = try await Self.readTags(url)
                let id = Track.localPrefix + UUID().uuidString.prefix(13).lowercased()
                let name = "\(id).\(url.pathExtension.lowercased())"
                let dest = AppPaths.audio.appendingPathComponent(name)
                try FileManager.default.copyItem(at: url, to: dest)
                _ = try AVAudioFile(forReading: dest) // the decoder can read it
                let size = (try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? Int64 ?? 0
                try db.addLocalTrack(Track(id: id, title: meta.title, artist: meta.artist, duration: meta.duration),
                                     fileName: name, size: size, to: target)
            } catch {
                failed.append(url.lastPathComponent)
            }
        }
        if !failed.isEmpty { error = "Could not import: \(failed.joined(separator: ", "))" }
        reload()
        source = .album(target)
    }

    /// `source_url` of the "Local Files" album, so imports find it again.
    static let localFilesKey = "local:files"

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
            try db.importLegacyJSON(data, audioDirectory: AppPaths.audio)
            try FileManager.default.moveItem(at: json, to: json.appendingPathExtension("imported"))
        }
    }

    /// Remove what old or killed yt-dlp runs left in the audio folder: temp folders, partial
    /// downloads, and source files that never became m4a.
    private func removeStaleDownloadFiles() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: AppPaths.audio.path) else { return }
        for name in names where name.hasPrefix(".tmp-") || name.hasSuffix(".part") || name.hasSuffix(".webm") {
            try? fm.removeItem(at: AppPaths.audio.appendingPathComponent(name))
        }
    }

    // MARK: Helpers

    /// Strip query params (playnext, si, etc.) so the same playlist resolves to the same album.
    nonisolated static func normalize(_ url: String) -> String {
        var comps = URLComponents(string: url.trimmed)
        var items = comps?.queryItems ?? []
        items.removeAll { $0.name == "playnext" || $0.name == "si" }
        comps?.queryItems = items.isEmpty ? nil : items
        comps?.fragment = nil
        return comps?.url?.absoluteString ?? url.trimmed
    }

    /// Name for a playlist whose JSON has no title.
    nonisolated static func fallbackName(for url: String) -> String {
        let list = URLComponents(string: url)?.queryItems?.first { $0.name == "list" }?.value
        return list.map { "Playlist " + $0.suffix(6).uppercased() } ?? "Playlist"
    }

    private static func cleanName(_ name: String, or fallback: String) -> String {
        let t = name.trimmed
        return t.isEmpty ? fallback : t
    }
}

/// Where the track list comes from.
enum Source: Hashable {
    case all
    case history
    case album(Int64)
    case smart(Int64)

    /// Stored in settings.
    var key: String {
        switch self {
        case .all: return "all"
        case .history: return "history"
        case .album(let id): return "album:\(id)"
        case .smart(let id): return "smart:\(id)"
        }
    }

    init?(key: String) {
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
struct TrackSort: Equatable {
    enum Column: String, CaseIterable {
        case title, artist, bpm, key, duration
    }
    var column: Column
    var ascending = true

    func areInOrder(_ a: Track, _ b: Track) -> Bool {
        let result: Bool
        switch column {
        case .title: result = a.title.localizedStandardCompare(b.title) == .orderedAscending
        case .artist: result = a.artist.localizedStandardCompare(b.artist) == .orderedAscending
        case .bpm: result = (a.bpm ?? .infinity) < (b.bpm ?? .infinity)
        case .duration: result = (a.duration ?? .infinity) < (b.duration ?? .infinity)
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
