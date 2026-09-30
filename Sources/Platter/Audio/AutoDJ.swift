import Foundation
import Combine

/// State of one track in the Auto DJ queue.
enum QueueItemState {
    case waiting       // not started yet
    case downloading   // being fetched / analyzed
    case ready         // prepared, waiting to play
    case playing       // on a deck now (or fading in)
    case done          // finished
    case failed        // could not be prepared; skipped
}

/// One row of the Auto DJ queue: which track, which deck it lands on, and its state.
struct QueueItem: Identifiable {
    let id: Int               // position in the queue
    let track: Track
    var deck: DeckID?
    var state: QueueItemState
}

/// Current stage of the Auto DJ.
enum AutoDJPhase {
    case idle
    case playing
    case crossfading
    case waitingForBuffer   // the next track is not ready yet
    case finished
}

/// Auto DJ: plays a track list straight through on alternate decks, and mixes the next track
/// in over `fadeSeconds`. With beatmix (and beat grids) it mixes like a DJ: see `MixPlan`.
///
/// One async task runs the whole show: play, prefetch the next track, wait for the cue point,
/// load the other deck, fade, repeat. `stop()` cancels the task. A track that cannot be
/// prepared is marked failed and skipped.
@MainActor
final class AutoDJ: ObservableObject {
    @Published private(set) var isOn = false
    @Published var fadeSeconds: Double = 8
    /// Beatmix: start mixes on phrase boundaries, match tempo and beat phase, and swap the
    /// basses. Off: a plain crossfade over the last `fadeSeconds`.
    @Published var beatmix = true
    @Published private(set) var status: String = ""
    @Published private(set) var queue: [QueueItem] = []
    @Published private(set) var phase: AutoDJPhase = .idle
    @Published private(set) var currentIndex = 0

    private unowned let deckA: DeckState
    private unowned let deckB: DeckState
    private unowned let mixer: MixerState
    private unowned let library: Library

    private var runTask: Task<Void, Never>?
    private var prefetch: Task<(index: Int, track: PreparedTrack)?, Never>?
    private var skipRequested = false

    init(deckA: DeckState, deckB: DeckState, mixer: MixerState, library: Library) {
        self.deckA = deckA
        self.deckB = deckB
        self.mixer = mixer
        self.library = library
    }

    func start(tracks: [Track]) {
        stop()
        guard !tracks.isEmpty else { return }
        queue = tracks.enumerated().map { QueueItem(id: $0, track: $1, deck: nil, state: .waiting) }
        currentIndex = 0
        status = ""
        isOn = true
        runTask = Task { await run() }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        prefetch?.cancel()
        prefetch = nil
        skipRequested = false
        isOn = false
        phase = .idle
    }

    /// Cut to the next track now.
    func skip() {
        if isOn { skipRequested = true }
    }

    // MARK: The show

    private func run() async {
        guard let first = await prepare(from: 0), !Task.isCancelled else {
            finish("No track in the list could be loaded.")
            return
        }
        var active = deckA
        var index = first.index
        mixer.crossfader = 0
        guard active.load(first.track) else { finish("Could not open the first track."); return }
        active.play()
        mark(index, .playing, deck: active.deck)

        while !Task.isCancelled {
            phase = .playing
            let from = index + 1
            prefetch = Task { await self.prepare(from: from) }

            // Wait for the mix point, a skip, or the end of the track. Meanwhile a tempo that a
            // sync moved glides back to the track's own, too slowly to hear.
            let mixAt = beatmix
                ? MixPlan.transitionStart(grid: active.grid, duration: active.duration, fade: fadeSeconds)
                : max(0, active.duration - fadeSeconds)
            let glideFrom = active.pitch, glideStart = Date()
            while !Task.isCancelled, !skipRequested, active.isPlaying, active.position < mixAt {
                if beatmix, active.pitch != 0, mixAt - active.position > fadeSeconds * 2 {
                    active.pitch = MixPlan.glide(from: glideFrom, elapsed: Date().timeIntervalSince(glideStart))
                    active.applyPitch()
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            if Task.isCancelled { return }

            if queue.indices.contains(from), queue[from].state != .ready { phase = .waitingForBuffer }
            guard let next = await prefetch?.value, !Task.isCancelled else {
                if Task.isCancelled { return }
                // Nothing left: let the last track play out.
                while active.isPlaying, !Task.isCancelled, !skipRequested {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                mark(index, .done)
                finish("Playlist finished")
                return
            }

            let incoming = active === deckA ? deckB : deckA
            guard incoming.load(next.track) else {
                mark(next.index, .failed)
                index = next.index
                continue
            }
            let mixing = beatmix && active.isPlaying && !skipRequested
            if mixing {
                incoming.seek(to: MixPlan.entryPoint(grid: incoming.grid, cue: incoming.cuePoint))
                if incoming.grid != nil, active.grid != nil { incoming.pitchMode = .keyLock }
            }
            incoming.play()
            if mixing, incoming.grid != nil, active.grid != nil {
                _ = incoming.sync(to: active) // no match within ±8%: a plain blend
            }
            mark(index, .done)
            index = next.index
            mark(index, .playing, deck: incoming.deck)

            let target: Double = incoming.deck == .a ? 0 : 1
            let remaining = active.duration - active.position
            if skipRequested || !active.isPlaying {
                mixer.crossfader = target
            } else {
                phase = .crossfading
                await fade(to: target, over: max(0.5, min(fadeSeconds, remaining)),
                           swapBass: mixing ? (active.deck, incoming.deck) : nil)
            }
            skipRequested = false
            active.pause()
            active = incoming
        }
    }

    /// Prepare the first track at or after `start` that works. Failed tracks are marked and
    /// skipped.
    private func prepare(from start: Int) async -> (index: Int, track: PreparedTrack)? {
        var i = start
        while i < queue.count, !Task.isCancelled {
            mark(i, .downloading)
            if let p = try? await library.prepare(queue[i].track) {
                mark(i, .ready)
                return (i, p)
            }
            mark(i, .failed)
            i += 1
        }
        return nil
    }

    /// Move the crossfader to `target` along a smoothstep curve; with `swapBass`
    /// (outgoing, incoming) the low EQs swap at the middle. A skip snaps it. The low EQs
    /// return to their values from before the fade.
    private func fade(to target: Double, over seconds: Double, swapBass: (DeckID, DeckID)?) async {
        let from = mixer.crossfader
        let start = Date()
        let lows = DeckID.allCases.reduce(into: [DeckID: Double]()) { $0[$1] = mixer.eq[$1]?.low ?? 0 }
        defer {
            if let (out, inc) = swapBass {
                mixer.setEQBand(lows[out] ?? 0, band: .low, deck: out)
                mixer.setEQBand(lows[inc] ?? 0, band: .low, deck: inc)
            }
        }
        while !Task.isCancelled, !skipRequested {
            let p = min(1, Date().timeIntervalSince(start) / seconds)
            mixer.crossfader = from + (target - from) * MixPlan.crossfade(progress: p)
            if let (out, inc) = swapBass {
                let b = MixPlan.bassSwap(progress: p)
                mixer.setEQBand(min(lows[out] ?? 0, b.outgoing), band: .low, deck: out)
                mixer.setEQBand(min(lows[inc] ?? 0, b.incoming), band: .low, deck: inc)
            }
            if p >= 1 { return }
            try? await Task.sleep(for: .milliseconds(30))
        }
        mixer.crossfader = target
    }

    private func mark(_ i: Int, _ state: QueueItemState, deck: DeckID? = nil) {
        guard queue.indices.contains(i) else { return }
        queue[i].state = state
        if let deck { queue[i].deck = deck }
        if state == .playing { currentIndex = i }
    }

    private func finish(_ message: String) {
        isOn = false
        phase = .finished
        status = message
    }
}
