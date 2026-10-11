import Foundation
import AVFoundation

/// The music player's 10-band graphic EQ: the classic desktop-player bands.
package enum PlayerEQ {
    package static let frequencies: [Float] = [60, 170, 310, 600, 1_000, 3_000, 6_000, 12_000, 14_000, 16_000]
    package static let labels = ["60", "170", "310", "600", "1K", "3K", "6K", "12K", "14K", "16K"]

    /// Built-in presets: gains in dB per band.
    package static let presets: [(name: String, gains: [Double])] = [
        ("Flat", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ("Rock", [5, 3, -2, -4, -1, 2, 5, 6, 6, 6]),
        ("Pop", [-1, 2, 4, 5, 3, 0, -1, -1, -1, -1]),
        ("Dance", [6, 4, 1, 0, 0, -3, -4, -4, 0, 0]),
        ("Bass", [7, 6, 4, 2, 0, 0, 0, 0, 0, 0]),
        ("Treble", [0, 0, 0, 0, 0, 2, 4, 6, 7, 7]),
        ("Vocal", [-3, -2, 0, 3, 5, 4, 2, 0, -1, -2]),
        ("Live", [-2, 0, 2, 3, 3, 3, 2, 1, 1, 1]),
    ]
}

/// Plays a track and has the next one ready: two player nodes, each track started at a
/// planned sample time on the engine clock with `play(at:)`. The next track starts exactly
/// when the current one ends (gapless), or `crossfade` seconds before with volume ramps.
///
/// The playhead also comes from the engine clock: the current track's start frame plus the
/// samples rendered since its planned start.
@MainActor
package final class QueuePlayer {
    private let engine: AudioEngine // the engine does not hold this player
    private let nodes: [AVAudioPlayerNode]
    private let clock: AVAudioNode

    private struct Voice {
        package var file: AVAudioFile?
        package var url: URL?
        /// File frame where playback of this track starts.
        package var startFrame: AVAudioFramePosition = 0
        /// Engine sample time at which it starts.
        package var startTime: AVAudioFramePosition = 0
        package var gain: Float = 1
    }

    private var voices = [Voice(), Voice()]
    private var current = 0
    private var other: Int { 1 - current }
    /// The next track waiting on the other node, or `nil`.
    private var next: (url: URL, gain: Float)?
    private var nextScheduled = false
    private var monitor: Task<Void, Never>?

    package private(set) var isPlaying = false
    /// Crossfade length in seconds; 0 = gapless.
    package var crossfade: Double = 0 {
        didSet { if isPlaying { replanNext() } }
    }
    /// The next track took over (gapless or after a crossfade began).
    package var onAdvance: (() -> Void)?
    /// The current track ended with no next track.
    package var onEnd: (() -> Void)?

    package init(engine: AudioEngine, nodes: [AVAudioPlayerNode], clock: AVAudioNode) {
        self.engine = engine
        self.nodes = nodes
        self.clock = clock
    }

    // MARK: Reading

    package var hasTrack: Bool { voices[current].file != nil }
    package var url: URL? { voices[current].url }

    package var duration: Double {
        guard let f = voices[current].file else { return 0 }
        return Double(f.length) / f.processingFormat.sampleRate
    }

    package var position: Double {
        let v = voices[current]
        guard let f = v.file else { return 0 }
        let sr = f.processingFormat.sampleRate
        var t = Double(v.startFrame) / sr
        if isPlaying, let now = now() {
            t += Double(max(0, now - v.startTime)) / outRate
        }
        return min(duration, max(0, t))
    }

    /// Sample rate of the engine clock.
    private var outRate: Double { clock.outputFormat(forBus: 0).sampleRate }

    /// The engine clock now, in samples. Before the first render the timeline is at 0.
    private func now() -> AVAudioFramePosition? {
        guard let t = clock.lastRenderTime, t.isSampleTimeValid else { return 0 }
        return t.sampleTime
    }

    // MARK: Transport

    /// Load a track and stop at its start. `gain` is the leveling gain (linear).
    package func load(_ url: URL, gain: Float = 1) throws {
        stopAll()
        let f = try AVAudioFile(forReading: url)
        voices[current] = Voice(file: f, url: url, startFrame: 0, startTime: 0, gain: gain)
        next = nil
    }

    package func play() {
        guard hasTrack, !isPlaying else { return }
        if !engine.isRunning { try? engine.start() }
        guard let now = now() else { return }
        // A short lead, so both nodes can be planned against the same clock.
        start(current, at: now + AVAudioFramePosition(0.05 * outRate))
        isPlaying = true
        replanNext()
        startMonitor()
    }

    package func pause() {
        guard isPlaying else { return }
        let pos = position
        stopAll()
        voices[current].startFrame = frame(pos)
    }

    package func stop() {
        stopAll()
        voices[current].startFrame = 0
    }

    package func seek(to seconds: Double) {
        guard hasTrack else { return }
        let wasPlaying = isPlaying
        stopAll()
        voices[current].startFrame = frame(min(duration, max(0, seconds)))
        if wasPlaying { play() }
    }

    /// The track to play after the current one. Planned on the other node right away.
    package func setNext(_ url: URL?, gain: Float = 1) {
        next = url.map { ($0, gain) }
        replanNext()
    }

    // MARK: Planning

    private func start(_ i: Int, at time: AVAudioFramePosition) {
        guard let f = voices[i].file else { return }
        let node = nodes[i]
        node.stop()
        let from = voices[i].startFrame
        guard from < f.length else { return }
        node.scheduleSegment(f, startingFrame: from, frameCount: AVAudioFrameCount(f.length - from), at: nil)
        voices[i].startTime = time
        node.volume = voices[i].gain
        node.play(at: AVAudioTime(sampleTime: time, atRate: outRate))
    }

    /// When the current track ends on the engine clock.
    private var currentEnd: AVAudioFramePosition? {
        let v = voices[current]
        guard let f = v.file else { return nil }
        let remaining = Double(f.length - v.startFrame) / f.processingFormat.sampleRate
        return v.startTime + AVAudioFramePosition(remaining * outRate)
    }

    /// Put the next track on the other node, timed to start at the end of the current one
    /// (minus the crossfade).
    private func replanNext() {
        nodes[other].stop()
        nextScheduled = false
        guard isPlaying, let next, let end = currentEnd, let now = now(),
              let f = try? AVAudioFile(forReading: next.url) else { return }
        let fade = AVAudioFramePosition(min(crossfade, duration / 2) * outRate)
        voices[other] = Voice(file: f, url: next.url, startFrame: 0, gain: next.gain)
        start(other, at: max(now + AVAudioFramePosition(0.02 * outRate), end - fade))
        if fade > 0 { nodes[other].volume = 0 }
        nextScheduled = true
    }

    /// While playing: hand over to the next track when it starts, ramp the crossfade, and
    /// notice the end of the last track.
    private func startMonitor() {
        monitor?.cancel()
        monitor = Task { [weak self] in
            while let self, self.isPlaying, !Task.isCancelled {
                self.tick()
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private func tick() {
        guard let now = now(), let end = currentEnd else { return }
        if nextScheduled {
            // The next track has started (sample-accurate on the engine clock): it is now
            // the current one. With a crossfade the old one keeps playing and fades out.
            if now >= voices[other].startTime { advance(keepOld: crossfade > 0) }
            return
        }
        if now >= end {
            stopAll()
            voices[current].startFrame = voices[current].file?.length ?? 0
            onEnd?()
        }
    }

    /// The other node is now the current track. With `keepOld` the old one keeps playing
    /// (fading out) until it ends.
    private func advance(keepOld: Bool = false) {
        let old = current
        current = other
        next = nil
        nextScheduled = false
        if !keepOld {
            nodes[old].stop()
            nodes[current].volume = voices[current].gain
        } else {
            // Stop the fading track when its audio is done.
            let oldEnd = voices[old].startTime
                + AVAudioFramePosition(Double((voices[old].file?.length ?? 0) - voices[old].startFrame)
                    / (voices[old].file?.processingFormat.sampleRate ?? 44_100) * outRate)
            fadeOut(old, until: oldEnd)
        }
        onAdvance?()
    }

    private func fadeOut(_ i: Int, until end: AVAudioFramePosition) {
        let start = voices[current].startTime
        Task { [weak self] in
            while let self, !Task.isCancelled, let now = self.now(), now < end {
                let p = min(1, Double(now - start) / Double(max(1, end - start)))
                self.nodes[i].volume = self.voices[i].gain * Float(cos(p * .pi / 2))
                self.nodes[self.current].volume = self.voices[self.current].gain * Float(sin(p * .pi / 2))
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard let self else { return }
            if self.current != i { self.nodes[i].stop() }
            self.nodes[self.current].volume = self.voices[self.current].gain
        }
    }

    private func stopAll() {
        monitor?.cancel()
        monitor = nil
        nodes.forEach { $0.stop() }
        nextScheduled = false
        isPlaying = false
    }

    private func frame(_ seconds: Double) -> AVAudioFramePosition {
        guard let f = voices[current].file else { return 0 }
        return AVAudioFramePosition(seconds * f.processingFormat.sampleRate)
    }
}
