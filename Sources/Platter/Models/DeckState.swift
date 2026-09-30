import Foundation
import Combine

/// Which physical deck a control belongs to.
enum DeckID: Int, CaseIterable, Identifiable {
    case a = 0
    case b = 1
    var id: Int { rawValue }
    var label: String { self == .a ? "A" : "B" }
}

/// How the pitch fader affects the audio. Cycles like the PITCH button on a DJ player.
enum PitchMode: Int, CaseIterable, Identifiable {
    /// Tempo and pitch both follow the fader (turntable feel).
    case varispeed = 0
    /// Tempo follows the fader, pitch is held (key stays).
    case keyLock = 1
    /// Tempo is held, pitch follows the fader (BPM is unchanged).
    case bpmShift = 2

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .varispeed: return "VARISPEED"
        case .keyLock: return "KEY LOCK"
        case .bpmShift: return "BPM SHIFT"
        }
    }

    var shortLabel: String {
        switch self {
        case .varispeed: return "VAR"
        case .keyLock: return "KEY"
        case .bpmShift: return "BPM"
        }
    }

    var next: PitchMode {
        let all = PitchMode.allCases
        return all[(rawValue + 1) % all.count]
    }
}

/// Per-deck state the UI shows. Transport truth lives in the `DeckPlayer` (which owns the
/// playhead clock); the published flags here drive the buttons and the waveform TimelineView.
@MainActor
final class DeckState: ObservableObject {
    let deck: DeckID

    @Published var track: Track?
    @Published private(set) var isPlaying = false
    /// Title of the track that is downloading or analyzing for this deck, else `nil`.
    @Published private(set) var loadingTitle: String?
    @Published var isCued = false
    @Published var pitch: Double = 0               // -0.08 ... +0.08
    @Published var pitchMode: PitchMode = .varispeed
    /// Temporary tempo nudge while a BEND button is held, added to `pitch`.
    @Published var bend: Double = 0 {
        didSet { applyPitch() }
    }
    @Published private(set) var hotCues: [TimeInterval?] = Array(repeating: nil, count: 8)
    @Published private(set) var cuePoint: TimeInterval?
    /// Snap cues and loops to the nearest beat when the track has a beat grid.
    @Published var quantize = true
    /// The active loop, seconds.
    @Published private(set) var loop: ClosedRange<Double>?
    /// Where LOOP IN was pressed, waiting for LOOP OUT.
    @Published private(set) var loopIn: Double?
    /// Vinyl surface noise level: 0 (off) ... 3.
    @Published var vinylLevel = 0 {
        didSet { player.vinyl.amount = Float(vinylLevel) / 3 }
    }
    /// Length of the beat loop button, in beats.
    @Published var loopBeats: Double = 4
    /// The last loop, for RELOOP after EXIT.
    private var lastLoop: ClosedRange<Double>?

    let player: DeckPlayer
    /// Shows a message to the user. Set by the app model.
    var onError: ((String) -> Void)?
    /// A cue changed: (track id, slot, seconds or nil). Slot -1 is the main cue. Saves it.
    var onCueChanged: ((String, Int, Double?) -> Void)?
    /// The loaded track started playing for the first time. Logs the play history.
    var onFirstPlay: ((Track) -> Void)?
    private var playLogged = false
    /// The newest load request. An older request that finishes later is dropped.
    private var pendingLoad: UUID?

    init(deck: DeckID, engine: AudioEngine) {
        self.deck = deck
        self.player = engine.deckPlayer(for: deck)
        player.onEnd = { [weak self] in self?.isPlaying = false }
    }

    /// Live playhead in seconds. Read fresh each animation frame by the waveform.
    var position: TimeInterval { player.position }
    var duration: TimeInterval { player.duration }
    var hasTrack: Bool { player.hasTrack }
    var grid: BeatGrid? { track?.grid }

    /// Prepare a track (download and analysis when needed) and load it. Returns `false` when
    /// the track failed, or when a newer load replaced this one.
    @discardableResult
    func load(_ track: Track, from library: Library) async -> Bool {
        let token = UUID()
        pendingLoad = token
        loadingTitle = track.title
        defer { if pendingLoad == token { loadingTitle = nil } }
        guard let prepared = try? await library.prepare(track), pendingLoad == token else { return false }
        return load(prepared)
    }

    /// Load a prepared track and stop at its cue point (or the top), with its saved cues.
    @discardableResult
    func load(_ prepared: PreparedTrack) -> Bool {
        phaseLock?.cancel()
        pendingLoad = nil
        loadingTitle = nil
        do {
            try player.load(prepared.url)
        } catch {
            onError?("Could not open \(prepared.url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
        track = prepared.track
        isPlaying = false
        playLogged = false
        cuePoint = prepared.cue
        isCued = prepared.cue != nil
        hotCues = prepared.hotCues
        loop = nil
        loopIn = nil
        lastLoop = nil
        pitch = 0
        bend = 0
        pitchMode = .varispeed
        applyPitch()
        if let c = prepared.cue { player.seek(to: c) }
        return true
    }

    /// Cycle the pitch mode: VARISPEED -> KEY LOCK -> BPM SHIFT.
    func cyclePitchMode() {
        pitchMode = pitchMode.next
        applyPitch()
    }

    /// `t`, snapped to the nearest beat when quantize is on and the track has a grid.
    func snapped(_ t: Double) -> Double {
        guard quantize, let grid else { return t }
        return min(duration, max(0, grid.nearestBeat(to: t)))
    }

    // MARK: Cues

    func toggleCue() {
        guard hasTrack else { return }
        if let c = cuePoint {
            seek(to: c)
        } else {
            setCuePoint(snapped(position))
        }
        isCued = true
    }

    private func setCuePoint(_ t: Double) {
        cuePoint = t
        if let id = track?.id { onCueChanged?(id, -1, t) }
    }

    func setHotCue(_ index: Int) {
        guard hotCues.indices.contains(index), hasTrack else { return }
        hotCues[index] = snapped(position)
        if let id = track?.id { onCueChanged?(id, index, hotCues[index]) }
    }

    func clearHotCue(_ index: Int) {
        guard hotCues.indices.contains(index) else { return }
        hotCues[index] = nil
        if let id = track?.id { onCueChanged?(id, index, nil) }
    }

    func fireHotCue(_ index: Int) {
        guard hotCues.indices.contains(index), let t = hotCues[index] else { return }
        seek(to: t)
    }

    // MARK: Loops

    func setLoopIn() {
        guard hasTrack else { return }
        loopIn = snapped(position)
    }

    /// Close the loop started with LOOP IN at the current position.
    func setLoopOut() {
        guard let a = loopIn else { return }
        let b = snapped(position)
        loopIn = nil
        guard b > a + 0.05 else { return }
        startLoop(a...b)
    }

    /// Loop `loopBeats` beats from the beat at (or just before) the playhead.
    func beatLoop() {
        guard hasTrack else { return }
        guard let grid else {
            onError?("This track has no beat grid, so beat loops are off. Use LOOP IN and OUT.")
            return
        }
        let pos = position
        var start = grid.nearestBeat(to: pos)
        if start > pos + 0.01 { start -= grid.period }
        startLoop(max(0, start)...min(duration, start + loopBeats * grid.period))
    }

    /// Halve or double the loop length (and the beat loop size), keeping its start.
    func resizeLoop(by factor: Double) {
        loopBeats = min(32, max(0.25, loopBeats * factor))
        guard let l = loop else { return }
        let len = (l.upperBound - l.lowerBound) * factor
        guard len >= 0.05 else { return }
        startLoop(l.lowerBound...min(duration, l.lowerBound + len))
    }

    func exitLoop() {
        guard loop != nil else { return }
        player.clearLoop()
        loop = nil
    }

    /// Turn the last loop back on and jump to its start.
    func reloop() {
        guard let l = lastLoop else { return }
        startLoop(l)
        seek(to: l.lowerBound)
    }

    private func startLoop(_ range: ClosedRange<Double>) {
        player.setLoop(from: range.lowerBound, to: range.upperBound)
        loop = player.loopSeconds
        lastLoop = loop
        isPlaying = player.isPlaying
    }

    // MARK: Transport

    func togglePlay() {
        guard hasTrack else { return }
        isPlaying ? pause() : play()
    }

    func play() {
        player.play()
        isPlaying = player.isPlaying
        if isPlaying, !playLogged, let t = track {
            playLogged = true
            onFirstPlay?(t)
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    /// Move the playhead to `seconds`. Jumping out of the loop ends it.
    func seek(to seconds: TimeInterval) {
        player.seek(to: seconds)
        loop = player.loopSeconds
        isPlaying = player.isPlaying
    }

    // MARK: Scratch

    /// The hand is on the record: stop the platter and start the scratch sound.
    func beginScratch() {
        guard hasTrack else { return }
        player.pause()
        isPlaying = false
        player.beginScratch()
        objectWillChange.send()
    }

    func scratch(to seconds: Double) {
        player.scratch(to: seconds)
        objectWillChange.send() // the platter and waveform follow the hand
    }

    func endScratch(resume: Bool) {
        player.endScratch()
        loop = player.loopSeconds
        if resume { play() } else { isPlaying = false }
    }

    func engineRestarted() {
        player.engineRestarted()
        isPlaying = false
    }

    /// Apply the pitch fader (plus any bend) per the current mode to the player.
    func applyPitch() {
        player.setPitch(rate: Float(1 + pitch + bend), mode: pitchMode)
    }

    /// The playback rate the fader and bend give, 1 = original tempo.
    var rate: Double { 1 + pitch + bend }

    /// BPM at the current tempo. BPM SHIFT holds the tempo, so there it is the original BPM.
    var effectiveBPM: Double? {
        guard let bpm = track?.bpm else { return nil }
        return pitchMode == .bpmShift ? bpm : bpm * rate
    }

    /// Match this deck's tempo, then its beat phase, to `other`. Returns a message when it
    /// cannot (no grid, or more than the pitch range away).
    @discardableResult
    func sync(to other: DeckState) -> String? {
        guard let grid, let otherGrid = other.grid, let target = other.effectiveBPM else {
            return "Sync needs a beat grid on both decks."
        }
        guard let p = Sync.pitch(toMatch: target, from: grid.bpm) else {
            return String(format: "%.1f BPM is more than 8%% away from %.1f BPM.", grid.bpm, target)
        }
        if pitchMode == .bpmShift { pitchMode = .keyLock } // BPM SHIFT cannot change tempo
        pitch = p
        applyPitch()
        if other.hasTrack {
            let shift = Sync.phaseShift(grid: grid, at: position, targetPhase: otherGrid.phase(at: other.position))
            seek(to: position + shift)
            lockPhase(to: other)
        }
        return nil
    }

    private var phaseLock: Task<Void, Never>?

    /// A seek restarts playback one render cycle late (~30 ms). Once both decks run, measure
    /// the phase error again and remove it with a short bend, like a DJ nudging the platter.
    private func lockPhase(to other: DeckState) {
        phaseLock?.cancel()
        phaseLock = Task { [weak self, weak other] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, let other, !Task.isCancelled, self.isPlaying, other.isPlaying,
                  let grid = self.grid, let otherGrid = other.grid else { return }
            let error = Sync.phaseShift(grid: grid, at: self.position, targetPhase: otherGrid.phase(at: other.position))
            guard abs(error) > 0.003 else { return }
            let amount = 0.04
            self.bend = error > 0 ? amount : -amount
            try? await Task.sleep(for: .seconds(abs(error) / amount))
            self.bend = 0
        }
    }
}
