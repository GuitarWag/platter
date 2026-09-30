import Foundation
import AVFoundation

/// Plays one deck straight from its audio file on disk.
///
/// A seek, a pause, or a load schedules a new file segment. No decoded copy of the track is
/// held in memory, so a jog scrub costs nothing.
///
/// The playhead comes from the audio clock: `startFrame` (where the scheduled segment begins)
/// plus the player node's own sample time. The player sits before varispeed and timePitch,
/// so its sample time counts source frames at any tempo, and it cannot drift from the audio.
///
/// A loop plays gaplessly: the segment up to the loop end is scheduled, then copies of the
/// loop body are kept queued (a new one each time the player has read one). The playhead
/// folds back into the loop.
@MainActor
final class DeckPlayer {
    private unowned let engine: AudioEngine
    private let player: AVAudioPlayerNode
    private let varispeed: AVAudioUnitVarispeed
    private let timePitch: AVAudioUnitTimePitch
    private let scratchVoice: ScratchVoice
    /// The record surface noise. Its speed follows the platter.
    let vinyl: VinylNoise
    private var pitchRate: Float = 1
    private var pitchMode: PitchMode = .varispeed
    /// Wow and flutter: a tiny tempo wobble, only while vinyl noise is on.
    private var wobble: Float = 0
    private var wowTask: Task<Void, Never>?
    /// Last hand position and time, for the scratch speed of the noise.
    private var lastScratch: (t: Double, at: Date)?

    private var file: AVAudioFile?
    private var fileURL: URL?
    /// Hand position (seconds) while the record is held; `nil` otherwise.
    private var scratchPosition: Double?
    private var scratchLoad: Task<Void, Never>?
    private var sampleRate: Double = 44_100
    /// File frame where the scheduled segment starts.
    private var startFrame: AVAudioFramePosition = 0
    /// Last playhead read while playing. Used when the engine restarts and the node clock resets.
    private var lastPosition: TimeInterval = 0
    /// Bumped on every reschedule, so the completion of a replaced segment is ignored.
    private var generation = 0

    /// The active loop, in file frames.
    private(set) var loop: Range<AVAudioFramePosition>?
    /// Loop bodies kept queued ahead of the playhead.
    private static let queuedLoopBodies = 3

    private(set) var isPlaying = false
    /// Called when playback reaches the end of the file.
    var onEnd: (() -> Void)?

    init(engine: AudioEngine, player: AVAudioPlayerNode, varispeed: AVAudioUnitVarispeed,
         timePitch: AVAudioUnitTimePitch, scratch: ScratchVoice, vinyl: VinylNoise) {
        self.engine = engine
        self.player = player
        self.varispeed = varispeed
        self.timePitch = timePitch
        self.scratchVoice = scratch
        self.vinyl = vinyl
        setPitch(rate: 1, mode: .varispeed)
    }

    var hasTrack: Bool { file != nil }

    var duration: TimeInterval {
        guard let file else { return 0 }
        return Double(file.length) / sampleRate
    }

    /// The active loop in seconds.
    var loopSeconds: ClosedRange<Double>? {
        loop.map { Double($0.lowerBound) / sampleRate...Double($0.upperBound) / sampleRate }
    }

    var position: TimeInterval {
        guard file != nil else { return 0 }
        if let scratchPosition { return scratchPosition }
        var frame = Double(startFrame)
        // playerTime(forNodeTime:) raises an exception for a render time that is not valid
        // yet (just after the engine starts or restarts), so check it first.
        if isPlaying, let now = player.lastRenderTime, now.isSampleTimeValid || now.isHostTimeValid,
           let pt = player.playerTime(forNodeTime: now) {
            frame += Double(max(0, pt.sampleTime)) / pt.sampleRate * sampleRate
        }
        if let loop, startFrame < loop.upperBound, frame >= Double(loop.upperBound) {
            frame = Double(loop.lowerBound)
                + (frame - Double(loop.upperBound)).truncatingRemainder(dividingBy: Double(loop.count))
        }
        let t = min(duration, max(0, frame / sampleRate))
        if isPlaying { lastPosition = t }
        return t
    }

    func load(_ url: URL) throws {
        let f = try AVAudioFile(forReading: url)
        endScratch()
        isPlaying = false
        stopMotion()
        vinyl.newRecord(seed: url.lastPathComponent)
        file = f
        fileURL = url
        sampleRate = f.processingFormat.sampleRate
        startFrame = 0
        loop = nil
        schedule()
    }

    func play() {
        guard let file, !isPlaying else { return }
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        if startFrame >= file.length {
            startFrame = 0
            schedule()
        }
        player.play()
        isPlaying = true
        vinyl.setSpeed(grooveSpeed)
        startWow()
    }

    func pause() {
        guard isPlaying else { return }
        startFrame = frame(at: position)
        isPlaying = false
        stopMotion()
        schedule()
    }

    /// Jump to `seconds`. A jump out of the active loop ends the loop.
    func seek(to seconds: TimeInterval) {
        guard file != nil else { return }
        let target = frame(at: seconds)
        if let loop, !loop.contains(target) { self.loop = nil }
        reschedule(from: target)
    }

    /// Loop `start ..< end` (seconds). The playhead stays where it is when it is inside the
    /// loop, else it jumps to the loop start.
    func setLoop(from start: Double, to end: Double) {
        guard let file else { return }
        let s = frame(at: start), e = min(file.length, frame(at: end))
        guard e - s >= AVAudioFramePosition(sampleRate * 0.05) else { return }
        let pos = frame(at: position)
        loop = s..<e
        reschedule(from: loop!.contains(pos) ? pos : s)
    }

    /// Leave the loop and play on from the current position.
    func clearLoop() {
        guard loop != nil else { return }
        let pos = frame(at: position)
        loop = nil
        reschedule(from: pos)
    }

    // MARK: Scratch

    /// The hand is on the record. Stops the player (the caller pauses first) and starts the
    /// scratch voice; its audio window decodes in the background.
    func beginScratch() {
        guard let url = fileURL, file != nil, !isPlaying else { return }
        let pos = position
        scratchPosition = pos
        let frame = pos * sampleRate
        scratchVoice.begin(at: frame)
        lastScratch = (pos, Date())
        let voice = scratchVoice
        scratchLoad?.cancel()
        scratchLoad = Task.detached(priority: .userInitiated) {
            guard let w = try? ScratchVoice.decodeWindow(url: url, around: frame, seconds: 20),
                  !Task.isCancelled else { return }
            voice.load(left: w.left, right: w.right, start: w.start)
        }
    }

    /// Move the record to `seconds` under the hand.
    func scratch(to seconds: Double) {
        guard scratchPosition != nil else { return }
        let t = min(duration, max(0, seconds))
        scratchPosition = t
        scratchVoice.move(to: t * sampleRate)
        if let last = lastScratch {
            let dt = Date().timeIntervalSince(last.at)
            if dt > 0.002 { vinyl.scratchSpeed((t - last.t) / dt) }
        }
        lastScratch = (t, Date())
    }

    /// The hand lets go: the player continues from where the record is now.
    func endScratch() {
        guard let t = scratchPosition else { return }
        scratchLoad?.cancel()
        scratchVoice.end()
        lastScratch = nil
        vinyl.setSpeed(0)
        scratchPosition = nil
        seek(to: t)
    }

    /// The engine restarted for a new output device and stopped the player. Stay paused at the
    /// last known position.
    func engineRestarted() {
        guard file != nil else { return }
        if isPlaying { startFrame = frame(at: lastPosition) }
        isPlaying = false
        schedule()
    }

    /// Apply the pitch fader. `rate` is 1 + fader (0.92 ... 1.08).
    ///   - varispeed: tempo and pitch follow the fader.
    ///   - keyLock:   tempo follows the fader, pitch is held.
    ///   - bpmShift:  tempo is held, pitch follows the fader.
    /// A node at its neutral setting is bypassed, so it adds no processing.
    func setPitch(rate: Float, mode: PitchMode) {
        pitchRate = rate
        pitchMode = mode
        applyRates()
        if isPlaying { vinyl.setSpeed(grooveSpeed) }
    }

    /// The platter speed: the tempo, which BPM SHIFT holds at 1.
    private var grooveSpeed: Double { pitchMode == .bpmShift ? 1 : Double(pitchRate) }

    private func applyRates() {
        let rate = pitchRate, mode = pitchMode
        let vRate: Float = (mode == .varispeed ? rate : 1) * (1 + wobble)
        let tRate: Float = mode == .keyLock ? rate : 1
        let cents: Float = mode == .bpmShift ? Pitch.semitones(for: rate) * 100 : 0
        varispeed.rate = vRate
        varispeed.bypass = vRate == 1
        timePitch.rate = tRate
        timePitch.pitch = cents
        timePitch.bypass = tRate == 1 && cents == 0
    }

    // MARK: Vinyl motion

    private func stopMotion() {
        vinyl.setSpeed(0)
        wowTask?.cancel()
        wowTask = nil
        if wobble != 0 { wobble = 0; applyRates() }
    }

    /// Wow (once per turn, ±0.08%) and flutter (6.3 Hz, ±0.03%) while playing with vinyl
    /// noise on. Both average to zero, so the tempo and a sync do not drift.
    private func startWow() {
        wowTask?.cancel()
        wowTask = Task { [weak self] in
            let start = Date()
            while !Task.isCancelled, let self, self.isPlaying {
                let a = self.vinyl.amount
                let t = Date().timeIntervalSince(start)
                let w = Float(a) * Float(0.0008 * sin(2 * .pi * t / VinylNoise.secondsPerTurn)
                                         + 0.0003 * sin(2 * .pi * 6.3 * t))
                if w != self.wobble { self.wobble = w; self.applyRates() }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func frame(at seconds: TimeInterval) -> AVAudioFramePosition {
        guard let file else { return 0 }
        return min(file.length, max(0, AVAudioFramePosition(seconds * sampleRate)))
    }

    private func reschedule(from frame: AVAudioFramePosition) {
        let wasPlaying = isPlaying
        startFrame = frame
        isPlaying = false
        schedule()
        if wasPlaying { play() }
    }

    /// Stop the node and queue the file from `startFrame`: to the end, or into the loop.
    private func schedule() {
        generation += 1
        player.stop()
        guard let file else { return }
        let gen = generation
        if let loop {
            if startFrame < loop.lowerBound || startFrame >= loop.upperBound { startFrame = loop.lowerBound }
            player.scheduleSegment(file, startingFrame: startFrame,
                                   frameCount: AVAudioFrameCount(loop.upperBound - startFrame), at: nil)
            for _ in 0..<Self.queuedLoopBodies { queueLoopBody(gen) }
            return
        }
        guard startFrame < file.length else { return }
        player.scheduleSegment(file, startingFrame: startFrame,
                               frameCount: AVAudioFrameCount(file.length - startFrame),
                               at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.segmentFinished(gen) }
        }
    }

    /// Queue one more copy of the loop body; its consumption queues the next.
    private func queueLoopBody(_ gen: Int) {
        guard gen == generation, let file, let loop else { return }
        player.scheduleSegment(file, startingFrame: loop.lowerBound, frameCount: AVAudioFrameCount(loop.count),
                               at: nil, completionCallbackType: .dataConsumed) { [weak self] _ in
            Task { @MainActor in self?.queueLoopBody(gen) }
        }
    }

    private func segmentFinished(_ gen: Int) {
        guard gen == generation, isPlaying, let file else { return }
        isPlaying = false
        stopMotion()
        startFrame = file.length
        onEnd?()
    }
}
