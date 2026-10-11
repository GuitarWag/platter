import Foundation

/// One track. `id` is the YouTube video id and the key of the downloaded audio file.
package struct Track: Identifiable, Equatable {
    package let id: String
    package var title: String
    package var artist: String
    /// Seconds. `nil` until the source or the analysis gives it.
    package var duration: Double?

    package var bpm: Double?
    /// Time of the first beat, seconds. With `bpm` it gives the beat grid.
    package var beatOffset: Double?
    /// Key name, "Am" or "F#".
    package var key: String?
    /// Average level (dBFS RMS over the parts that are not silent), for volume leveling.
    package var loudness: Double?
    /// 0 (none) ... 5 stars.
    package var rating = 0
    package var playCount = 0
    /// Waveform peaks. Loaded only for a track on a deck, never for list rows.
    package var peaks: [Float]?
    /// Detail waveform, `Analysis.waveRate` buckets per second. Loaded only for a deck.
    package var wave: [Float]?

    /// File name of the downloaded audio in `AudioStore.directory`, or `nil` when not downloaded.
    package var fileName: String?
    /// Names of the albums that contain the track. Filled only in search results.
    package var albumNames: String = ""
    /// When it played. Filled only in the play history.
    package var playedAt: Date?

    package var isCached: Bool { fileName != nil }

    package var grid: BeatGrid? {
        guard let bpm, let beatOffset, bpm > 0 else { return nil }
        return BeatGrid(bpm: bpm, firstBeat: beatOffset)
    }

    package var musicalKey: MusicalKey? { key.flatMap(MusicalKey.init(name:)) }

    /// Tracks from local files have ids with this prefix; the rest are YouTube video ids.
    package static let localPrefix = "local-"
    package var isLocal: Bool { id.hasPrefix(Self.localPrefix) }

    package init(id: String, title: String, artist: String = "", duration: Double? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.duration = duration
    }
}

/// A named, ordered list of tracks. `sourceURL` is the YouTube playlist it came from, or
/// `nil` for an album the user made.
package struct Album: Identifiable, Equatable, Hashable {
    package let id: Int64
    package var name: String
    package var sourceURL: String?
    package var trackCount = 0
    package var cachedCount = 0
    package var duration: Double = 0
}

/// A saved filter over the whole library. Every set condition must hold.
package struct TrackFilter: Equatable, Hashable {
    package var minBPM: Double?
    package var maxBPM: Double?
    /// Key name ("Am"); matches tracks whose key mixes with it on the Camelot wheel.
    package var compatibleKey: String?
    package var downloadedOnly = false
    /// At least this many stars.
    package var minRating: Int?
    /// Played at least this many times.
    package var minPlays: Int?

    package init(minBPM: Double? = nil, maxBPM: Double? = nil, compatibleKey: String? = nil,
                 downloadedOnly: Bool = false, minRating: Int? = nil, minPlays: Int? = nil) {
        self.minBPM = minBPM
        self.maxBPM = maxBPM
        self.compatibleKey = compatibleKey
        self.downloadedOnly = downloadedOnly
        self.minRating = minRating
        self.minPlays = minPlays
    }

    package var isEmpty: Bool {
        minBPM == nil && maxBPM == nil && compatibleKey == nil && !downloadedOnly && minRating == nil && minPlays == nil
    }

    package func matches(_ t: Track) -> Bool {
        if downloadedOnly, !t.isCached { return false }
        if minBPM != nil || maxBPM != nil {
            guard let bpm = t.bpm else { return false }
            if let lo = minBPM, bpm < lo { return false }
            if let hi = maxBPM, bpm > hi { return false }
        }
        if let r = minRating, t.rating < r { return false }
        if let p = minPlays, t.playCount < p { return false }
        if let k = compatibleKey.flatMap(MusicalKey.init(name:)) {
            guard let tk = t.musicalKey, tk.isCompatible(with: k) else { return false }
        }
        return true
    }
}

/// A named `TrackFilter`, listed with the albums.
package struct SmartAlbum: Identifiable, Equatable, Hashable {
    package let id: Int64
    package var name: String
    package var filter: TrackFilter
}
