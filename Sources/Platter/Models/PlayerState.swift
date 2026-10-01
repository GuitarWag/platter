import Foundation
import Combine

enum RepeatMode: String, Codable, CaseIterable {
    case off, all, one

    var next: RepeatMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// Which queue entry plays next. Pure, so the order rules unit-test on their own.
enum QueueOrder {
    /// The play order: `0 ..< count`, or a shuffle that starts with `first` (so turning
    /// shuffle on does not change the playing track).
    static func order(count: Int, shuffle: Bool, first: Int?, seed: UInt64 = .random(in: 0 ... .max)) -> [Int] {
        guard shuffle else { return Array(0..<count) }
        var rng = SeededRandom(String(seed))
        var rest = (0..<count).filter { $0 != first }.shuffled(using: &rng)
        if let first, first < count { rest.insert(first, at: 0) }
        return rest
    }

    /// The entry after `index` in `order`. `ended` is true when the track finished by itself:
    /// then repeat-one plays it again. `nil` at the end with repeat off.
    static func next(after index: Int, order: [Int], repeat mode: RepeatMode, ended: Bool) -> Int? {
        guard !order.isEmpty else { return nil }
        if ended, mode == .one { return index }
        guard let pos = order.firstIndex(of: index) else { return order.first }
        if pos + 1 < order.count { return order[pos + 1] }
        return mode == .off ? nil : order.first
    }

    static func previous(before index: Int, order: [Int], repeat mode: RepeatMode) -> Int? {
        guard let pos = order.firstIndex(of: index) else { return order.first }
        if pos > 0 { return order[pos - 1] }
        return mode == .off ? nil : order.last
    }

    /// Linear leveling gain for a track: brings its loudness to `target` dBFS RMS, within
    /// -12 ... +6 dB. 1 when the loudness is unknown.
    static func levelingGain(loudness: Double?, target: Double = -14) -> Float {
        guard let l = loudness else { return 1 }
        let db = min(6, max(-12, target - l))
        return Float(pow(10, db / 20))
    }
}

/// One row of the play queue. The id keeps the same track twice apart.
struct QueueEntry: Identifiable, Equatable {
    let id = UUID()
    var track: Track
}

/// Player settings saved in the database.
struct PlayerPrefs: Codable, Equatable {
    var shuffle = false
    var repeatMode = RepeatMode.off
    var crossfade = 0.0
    var leveling = true
    var volume = 0.8
    var balance = 0.0
    var eqOn = false
    var eqGains = [Double](repeating: 0, count: PlayerEQ.frequencies.count)
    var preamp = 0.0
    var current: Int?
    /// Pause the DJ decks when the player starts, and the player when a deck starts.
    var exclusive = true
}

/// The music player: a queue played through `QueuePlayer` with prefetch, gapless or
/// crossfaded changes, shuffle, repeat, and volume leveling. It shares the library (and its
/// downloads and analysis) with the DJ decks.
@MainActor
final class PlayerState: ObservableObject {
    @Published private(set) var queue: [QueueEntry] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var isPlaying = false
    @Published private(set) var loadingTitle: String?
    @Published var prefs = PlayerPrefs() {
        didSet { apply(old: oldValue) }
    }
    /// Shows a message to the user. Set by the app model.
    var onError: ((String) -> Void)?
    /// The player is about to start. The app model pauses the decks.
    var onWillPlay: (() -> Void)?

    let player: QueuePlayer
    private unowned let engine: AudioEngine
    private unowned let library: Library
    private var order: [Int] = []
    /// The entry planned after the current one, while it is being prepared or is ready.
    private var plannedNext: Int?
    private var prefetch: Task<Void, Never>?
    private var loadToken = UUID()

    init(engine: AudioEngine, library: Library) {
        self.engine = engine
        self.library = library
        player = engine.queuePlayer()
        if let json = library.setting("player.prefs"), let p = try? JSONDecoder().decode(PlayerPrefs.self, from: Data(json.utf8)) {
            prefs = p
        }
        queue = library.playerQueue().map { QueueEntry(track: $0) }
        currentIndex = prefs.current.flatMap { queue.indices.contains($0) ? $0 : nil }
        reorder()
        apply(old: nil)
        player.onAdvance = { [weak self] in self?.advanced() }
        player.onEnd = { [weak self] in self?.ended() }
    }

    var current: Track? { currentIndex.map { queue[$0].track } }
    var position: Double { player.position }
    var duration: Double { player.hasTrack ? player.duration : current?.duration ?? 0 }
    var totalDuration: Double { queue.reduce(0) { $0 + ($1.track.duration ?? 0) } }

    // MARK: Queue editing

    /// Add tracks at the end, or after the current one with `next`. `play` starts the first.
    func enqueue(_ tracks: [Track], next: Bool = false, play: Bool = false) {
        guard !tracks.isEmpty else { return }
        let at = next ? (currentIndex.map { $0 + 1 } ?? queue.count) : queue.count
        queue.insert(contentsOf: tracks.map { QueueEntry(track: $0) }, at: at)
        if let c = currentIndex, at <= c { currentIndex = c + tracks.count }
        reorder()
        save()
        if play { self.play(index: at) } else { planNext() }
    }

    /// Replace the queue with `tracks` and play from `start`.
    func playAll(_ tracks: [Track], from start: Int = 0) {
        player.stop()
        queue = tracks.map { QueueEntry(track: $0) }
        currentIndex = nil
        reorder()
        save()
        play(index: prefs.shuffle ? order.first ?? 0 : start)
    }

    func remove(at offsets: IndexSet) {
        let removingCurrent = currentIndex.map { offsets.contains($0) } ?? false
        let currentID = currentIndex.map { queue[$0].id }
        queue.remove(atOffsets: offsets)
        currentIndex = removingCurrent ? nil : currentID.flatMap { id in queue.firstIndex { $0.id == id } }
        if removingCurrent { player.stop(); isPlaying = false }
        reorder()
        save()
        planNext()
    }

    func move(from source: IndexSet, to destination: Int) {
        let currentID = currentIndex.map { queue[$0].id }
        queue.move(fromOffsets: source, toOffset: destination)
        currentIndex = currentID.flatMap { id in queue.firstIndex { $0.id == id } }
        reorder()
        save()
        planNext()
    }

    func clear() {
        player.stop()
        queue = []
        currentIndex = nil
        isPlaying = false
        reorder()
        save()
    }

    // MARK: Transport

    func play(index: Int) {
        guard queue.indices.contains(index) else { return }
        let token = UUID()
        loadToken = token
        currentIndex = index
        let track = queue[index].track
        loadingTitle = track.title
        Task {
            defer { if loadToken == token { loadingTitle = nil } }
            guard let p = try? await library.prepare(track), loadToken == token else { return }
            queue[index].track = p.track
            do {
                try player.load(p.url, gain: gain(p.track))
            } catch {
                onError?("Could not open \(track.title): \(error.localizedDescription)")
                return
            }
            onWillPlay?()
            player.play()
            isPlaying = true
            library.logPlayerPlay(p.track)
            save()
            planNext()
        }
    }

    func togglePlay() {
        if isPlaying {
            pause()
        } else if player.hasTrack {
            onWillPlay?()
            player.play()
            isPlaying = true
            planNext()
        } else if let i = currentIndex ?? order.first {
            play(index: i)
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func stop() {
        player.stop()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        player.seek(to: seconds)
        planNext()
    }

    func next() {
        guard let c = currentIndex,
              let n = QueueOrder.next(after: c, order: order, repeat: prefs.repeatMode == .one ? .all : prefs.repeatMode,
                                      ended: false) else { return }
        play(index: n)
    }

    /// Back to the start of the track, or to the previous one in its first 3 seconds.
    func previous() {
        guard let c = currentIndex else { return }
        if position > 3 { seek(to: 0); return }
        if let p = QueueOrder.previous(before: c, order: order, repeat: prefs.repeatMode) { play(index: p) }
    }

    // MARK: Engine events

    /// The planned next track started (gapless or crossfading).
    private func advanced() {
        guard let n = plannedNext, queue.indices.contains(n) else { return }
        currentIndex = n
        plannedNext = nil
        library.logPlayerPlay(queue[n].track)
        save()
        planNext()
    }

    /// The last track ended with nothing planned (the next one was not ready, or the end).
    private func ended() {
        isPlaying = false
        guard let c = currentIndex,
              let n = QueueOrder.next(after: c, order: order, repeat: prefs.repeatMode, ended: true) else { return }
        play(index: n)
    }

    /// Prepare the next entry (download and analysis) and plan it on the player.
    private func planNext() {
        prefetch?.cancel()
        player.setNext(nil)
        plannedNext = nil
        guard isPlaying, let c = currentIndex,
              let n = QueueOrder.next(after: c, order: order, repeat: prefs.repeatMode, ended: true),
              queue.indices.contains(n) else { return }
        let entryID = queue[n].id
        prefetch = Task {
            guard let p = try? await library.prepare(queue[n].track), !Task.isCancelled,
                  queue.indices.contains(n), queue[n].id == entryID else { return }
            queue[n].track = p.track
            plannedNext = n
            player.setNext(p.url, gain: gain(p.track))
        }
    }

    private func gain(_ t: Track) -> Float {
        prefs.leveling ? QueueOrder.levelingGain(loudness: t.loudness) : 1
    }

    // MARK: Settings

    private func reorder() {
        order = QueueOrder.order(count: queue.count, shuffle: prefs.shuffle, first: currentIndex)
    }

    private func apply(old: PlayerPrefs?) {
        player.crossfade = prefs.crossfade
        engine.setPlayerVolume(prefs.volume)
        engine.setPlayerBalance(prefs.balance)
        engine.setPlayerEQ(gains: prefs.eqGains, preamp: prefs.preamp, enabled: prefs.eqOn)
        guard let old else { return }
        if old.shuffle != prefs.shuffle { reorder() }
        if old.shuffle != prefs.shuffle || old.repeatMode != prefs.repeatMode || old.leveling != prefs.leveling {
            planNext()
        }
        saveSoon()
    }

    private var saveTask: Task<Void, Never>?

    /// Many settings change while a slider moves; save once it rests.
    private func saveSoon() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { save() }
        }
    }

    private func save() {
        var p = prefs
        p.current = currentIndex
        if let data = try? JSONEncoder().encode(p) { library.setSetting("player.prefs", String(decoding: data, as: UTF8.self)) }
        library.savePlayerQueue(queue.map(\.track.id))
    }
}
