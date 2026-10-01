import AppKit
import MediaPlayer
import Combine

/// Connects the music player to macOS: Now Playing (Control Center and the menu bar) and
/// the media keys, AirPods, and other remote commands.
@MainActor
final class NowPlaying {
    enum Command: Equatable { case play, pause, toggle, next, previous, seek(Double) }

    private let player: PlayerState // the player does not hold this
    private let library: Library
    private var subscription: AnyCancellable?
    private var artworkFor: String?
    private var artwork: MPMediaItemArtwork?

    init(player: PlayerState, library: Library) {
        self.player = player
        self.library = library
        let center = MPRemoteCommandCenter.shared()
        let bind: (MPRemoteCommand, Command) -> Void = { cmd, c in
            cmd.addTarget { [weak self] _ in self?.handle(c) == true ? .success : .commandFailed }
        }
        bind(center.playCommand, .play)
        bind(center.pauseCommand, .pause)
        bind(center.togglePlayPauseCommand, .toggle)
        bind(center.nextTrackCommand, .next)
        bind(center.previousTrackCommand, .previous)
        center.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return self?.handle(.seek(e.positionTime)) == true ? .success : .commandFailed
        }
        subscription = player.changes
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] in self?.update() }
    }

    /// Returns false when there is nothing to act on.
    @discardableResult
    func handle(_ c: Command) -> Bool {
        guard !player.queue.isEmpty else { return false }
        switch c {
        case .play: if !player.isPlaying { player.togglePlay() }
        case .pause: player.pause()
        case .toggle: player.togglePlay()
        case .next: player.next()
        case .previous: player.previous()
        case .seek(let t): player.seek(to: t)
        }
        return true
    }

    /// The Now Playing fields for the current state.
    static func info(track: Track, position: Double, duration: Double, isPlaying: Bool,
                     album: String?) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let album, !album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = album }
        return info
    }

    private func update() {
        let center = MPNowPlayingInfoCenter.default()
        guard let track = player.current else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info = Self.info(track: track, position: player.position, duration: player.duration,
                             isPlaying: player.isPlaying, album: track.albumNames)
        if artworkFor == track.id, let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
        center.playbackState = player.isPlaying ? .playing : .paused
        if artworkFor != track.id { loadArtwork(track) }
    }

    private func loadArtwork(_ track: Track) {
        artworkFor = track.id
        artwork = nil
        Task {
            guard let img = await Artwork.image(for: track, audioDirectory: library.audioDirectory),
                  artworkFor == track.id else { return }
            artwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
            update()
        }
    }
}
