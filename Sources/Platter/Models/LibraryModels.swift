import Foundation

/// One track. `id` is the YouTube video id and the key of the downloaded audio file.
struct Track: Identifiable, Equatable {
    let id: String
    var title: String
    var artist: String
    /// Seconds. `nil` until the source or the analysis gives it.
    var duration: Double?

    var bpm: Double?
    /// Time of the first beat, seconds. With `bpm` it gives the beat grid.
    var beatOffset: Double?
    /// Key name, "Am" or "F#".
    var key: String?
    /// Waveform peaks. Loaded only for a track on a deck, never for list rows.
    var peaks: [Float]?
    /// Detail waveform, `Analysis.waveRate` buckets per second. Loaded only for a deck.
    var wave: [Float]?

    /// File name of the downloaded audio in `AudioStore.directory`, or `nil` when not downloaded.
    var fileName: String?
    /// Names of the albums that contain the track. Filled only in search results.
    var albumNames: String = ""
    /// When it played. Filled only in the play history.
    var playedAt: Date?

    var isCached: Bool { fileName != nil }

    var grid: BeatGrid? {
        guard let bpm, let beatOffset, bpm > 0 else { return nil }
        return BeatGrid(bpm: bpm, firstBeat: beatOffset)
    }

    var musicalKey: MusicalKey? { key.flatMap(MusicalKey.init(name:)) }

    /// Tracks from local files have ids with this prefix; the rest are YouTube video ids.
    static let localPrefix = "local-"
    var isLocal: Bool { id.hasPrefix(Self.localPrefix) }

    init(id: String, title: String, artist: String = "", duration: Double? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.duration = duration
    }
}

/// A named, ordered list of tracks. `sourceURL` is the YouTube playlist it came from, or
/// `nil` for an album the user made.
struct Album: Identifiable, Equatable, Hashable {
    let id: Int64
    var name: String
    var sourceURL: String?
    var trackCount = 0
    var cachedCount = 0
    var duration: Double = 0
}

/// A saved filter over the whole library. Every set condition must hold.
struct TrackFilter: Equatable, Hashable {
    var minBPM: Double?
    var maxBPM: Double?
    /// Key name ("Am"); matches tracks whose key mixes with it on the Camelot wheel.
    var compatibleKey: String?
    var downloadedOnly = false

    var isEmpty: Bool { minBPM == nil && maxBPM == nil && compatibleKey == nil && !downloadedOnly }

    func matches(_ t: Track) -> Bool {
        if downloadedOnly, !t.isCached { return false }
        if minBPM != nil || maxBPM != nil {
            guard let bpm = t.bpm else { return false }
            if let lo = minBPM, bpm < lo { return false }
            if let hi = maxBPM, bpm > hi { return false }
        }
        if let k = compatibleKey.flatMap(MusicalKey.init(name:)) {
            guard let tk = t.musicalKey, tk.isCompatible(with: k) else { return false }
        }
        return true
    }
}

/// A named `TrackFilter`, listed with the albums.
struct SmartAlbum: Identifiable, Equatable, Hashable {
    let id: Int64
    var name: String
    var filter: TrackFilter
}
