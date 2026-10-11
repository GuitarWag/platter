import Foundation
import AVFoundation
import Accelerate
import os

/// Peak level of one channel. The audio tap thread writes it, the UI reads it.
package final class LevelMeter: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: Float(0))

    /// Linear peak, 0...1+, with a short fall-off so the meter does not flicker.
    package var level: Float { state.withLock { $0 } }

    fileprivate func push(_ peak: Float) {
        state.withLock { $0 = max(peak, $0 * 0.8) }
    }
}

/// The shared AVAudioEngine graph for the two-deck rig.
///
/// ```
/// deck A: player -> varispeed -> timePitch -> EQ x3 -> filter -> echo -> reverb -> channelA ┐
///                                                                         main -> limiter -> out
/// deck B: player -> varispeed -> timePitch -> EQ x3 -> filter -> echo -> reverb -> channelB ┘
///
/// The high EQ's output is tapped for the channel meter and the headphone (PFL) feed; the
/// limiter's output for recording.
/// ```
///
/// Pitch model (see `DeckPlayer.setPitch`):
///   - `varispeed.rate` changes tempo and pitch together (turntable).
///   - `timePitch.rate` changes tempo only; `timePitch.pitch` (cents) changes pitch only.
/// `AVAudioPlayerNode.rate` is not used: it has an effect only through an environment node.
///
/// `channelA/B.volume` = channel level x crossfader gain. Both inputs are kept here so that
/// one never overwrites the other.
///
/// Node connections use a nil format; the player node converts each file's sample rate.
@MainActor
package final class AudioEngine {
    private let engine = AVAudioEngine()
    private var decks: [DeckID: DeckNodes] = [:]
    private var scratchVoices: [DeckID: ScratchVoice] = [:]
    private var vinylNoises: [DeckID: VinylNoise] = [:]
    private var levels: [DeckID: Double] = [.a: 1, .b: 1]
    private var crossfaderGains: (a: Double, b: Double) = Crossfader.gains(crossfader: 0.5)
    private var configObserver: NSObjectProtocol?
    /// Channel meters, measured after the EQ and before the fader (like a DJ mixer).
    package let meters: [DeckID: LevelMeter] = [.a: LevelMeter(), .b: LevelMeter()]
    /// Master meter, before the limiter, so it shows when the mix runs hot.
    package let masterMeter = LevelMeter()
    /// Headphone output for PFL.
    package let cue = CueOutput()
    private let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    private let recorder = Recorder()

    // The music player's chain: two player nodes (one track ends as the next starts, for
    // gapless playback and crossfades) -> pre-mix -> 10-band EQ -> player mixer -> main.
    private let playerNodes = [AVAudioPlayerNode(), AVAudioPlayerNode()]
    private let playerPre = AVAudioMixerNode()
    private let playerEQ = AVAudioUnitEQ(numberOfBands: PlayerEQ.frequencies.count)
    private let playerMix = AVAudioMixerNode()
    /// The player's audio after its EQ, for the visualizer.
    package let playerViz = VizBuffer()
    /// When the current recording started, and where it goes.
    package private(set) var recording: (started: Date, url: URL)?

    /// Called after the engine restarts for a new output device. Players are stopped by then.
    package var onRestart: (() -> Void)?

    private struct DeckNodes {
        package let player = AVAudioPlayerNode()
        package let varispeed = AVAudioUnitVarispeed()
        package let timePitch = AVAudioUnitTimePitch()
        /// Sums the player with the scratch voice.
        package let deckMix = AVAudioMixerNode()
        package let low = AVAudioUnitEQ(numberOfBands: 1)
        package let mid = AVAudioUnitEQ(numberOfBands: 1)
        package let high = AVAudioUnitEQ(numberOfBands: 1)
        package let filter = AVAudioUnitEQ(numberOfBands: 1)
        package let echo = AVAudioUnitDelay()
        package let reverb = AVAudioUnitReverb()
        package let channel = AVAudioMixerNode()
    }

    /// `decks` builds the two DJ deck chains, `player` the music player's chain: each app
    /// builds only what it uses. `offline`: render without an audio device (manual
    /// rendering, pulled by `renderOffline`), for tests that measure the output.
    package init(decks buildDecks: Bool = true, player buildPlayer: Bool = true, offline: AVAudioFormat? = nil) {
        if let offline {
            try? engine.enableManualRenderingMode(.offline, format: offline, maximumFrameCount: 4096)
        }
        for deck in buildDecks ? DeckID.allCases : [] {
            let d = DeckNodes()
            configureEQ(d.low, type: .lowShelf, freq: 120)
            configureEQ(d.mid, type: .parametric, freq: 1_000)
            configureEQ(d.high, type: .highShelf, freq: 6_000)

            d.filter.bands.first?.bypass = true
            d.filter.bands.first?.bandwidth = 0.7
            d.echo.bypass = true
            d.echo.lowPassCutoff = 9_000
            d.reverb.loadFactoryPreset(.largeHall)
            d.reverb.bypass = true

            let chain: [AVAudioNode] = [d.player, d.varispeed, d.timePitch, d.deckMix, d.low, d.mid, d.high,
                                        d.filter, d.echo, d.reverb, d.channel]
            chain.forEach(engine.attach)
            for (from, to) in zip(chain, chain.dropFirst()) {
                engine.connect(from, to: to, format: nil)
            }
            let voice = ScratchVoice(sampleRate: engine.outputNode.inputFormat(forBus: 0).sampleRate)
            let voiceNode = voice.makeNode()
            engine.attach(voiceNode)
            engine.connect(voiceNode, to: d.deckMix, fromBus: 0, toBus: 1, format: voice.format)
            scratchVoices[deck] = voice
            let vinyl = VinylNoise(sampleRate: voice.format.sampleRate)
            let vinylNode = vinyl.makeNode()
            engine.attach(vinylNode)
            engine.connect(vinylNode, to: d.deckMix, fromBus: 0, toBus: 2, format: vinyl.format)
            vinylNoises[deck] = vinyl
            engine.connect(d.channel, to: engine.mainMixerNode, format: nil)
            Self.installMeter(on: d.high, meter: meters[deck]!, cue: cue.feeds[deck]!)
            decks[deck] = d
        }
        if buildPlayer { buildPlayerChain() }

        // main -> limiter -> output, at the output's format.
        let outFormat = engine.outputNode.inputFormat(forBus: 0)
        engine.attach(limiter)
        engine.connect(engine.mainMixerNode, to: limiter, format: outFormat)
        engine.connect(limiter, to: engine.outputNode, format: outFormat)
        Self.installMeter(on: engine.mainMixerNode, meter: masterMeter, cue: nil)
        applyChannelVolumes()

        // A new output device (headphones in, interface unplugged) stops the engine. Restart
        // it, else the next `player.play()` raises an exception.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                try? self.start()
                self.onRestart?()
            }
        }
    }

    /// The tap block runs on an audio thread, so it is built outside the main actor and
    /// touches only the meter.
    nonisolated private static func installMeter(on node: AVAudioNode, meter: LevelMeter, cue: CueFeed?) {
        node.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            cue?.write(buffer)
            guard let data = buffer.floatChannelData else { return }
            var peak: Float = 0
            for c in 0..<Int(buffer.format.channelCount) {
                var m: Float = 0
                vDSP_maxmgv(data[c], 1, &m, vDSP_Length(buffer.frameLength))
                peak = max(peak, m)
            }
            meter.push(peak)
        }
    }

    nonisolated private static func installViz(on node: AVAudioNode, viz: VizBuffer) {
        node.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in viz.push(buffer) }
    }

    /// Sample rate of the player's visualizer feed.
    package var playerVizRate: Double { playerEQ.outputFormat(forBus: 0).sampleRate }

    nonisolated private static func installRecorder(on node: AVAudioNode, recorder: Recorder) {
        node.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            recorder.write(buffer)
        }
    }

    private func configureEQ(_ eq: AVAudioUnitEQ, type: AVAudioUnitEQFilterType, freq: Float) {
        guard let b = eq.bands.first else { return }
        b.filterType = type
        b.frequency = freq
        b.bandwidth = 1.5
        b.gain = 0
        b.bypass = false
    }

    private func buildPlayerChain() {
        playerNodes.forEach(engine.attach)
        [playerPre, playerEQ, playerMix].forEach(engine.attach)
        for (bus, node) in playerNodes.enumerated() {
            engine.connect(node, to: playerPre, fromBus: 0, toBus: bus, format: nil)
        }
        engine.connect(playerPre, to: playerEQ, format: nil)
        engine.connect(playerEQ, to: playerMix, format: nil)
        engine.connect(playerMix, to: engine.mainMixerNode, format: nil)
        Self.installViz(on: playerEQ, viz: playerViz)
        for (band, freq) in zip(playerEQ.bands, PlayerEQ.frequencies) {
            band.filterType = .parametric
            band.frequency = freq
            band.bandwidth = 1
            band.gain = 0
            band.bypass = true
        }
    }

    /// Render `seconds` of the master output (offline engines only).
    package func renderOffline(seconds: Double) throws -> AVAudioPCMBuffer {
        let format = engine.manualRenderingFormat
        let total = AVAudioFrameCount(seconds * format.sampleRate)
        guard engine.isInManualRenderingMode,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total),
              let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: engine.manualRenderingMaximumFrameCount)
        else { throw LibraryError("Not an offline engine.") }
        while out.frameLength < total {
            let n = min(chunk.frameCapacity, total - out.frameLength)
            guard try engine.renderOffline(n, to: chunk) == .success else { break }
            for c in 0..<Int(format.channelCount) {
                (out.floatChannelData![c] + Int(out.frameLength))
                    .update(from: chunk.floatChannelData![c], count: Int(chunk.frameLength))
            }
            out.frameLength += chunk.frameLength
        }
        return out
    }

    package func start() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    package var isRunning: Bool { engine.isRunning }

    /// A `DeckPlayer` bound to this deck's nodes.
    package func deckPlayer(for deck: DeckID) -> DeckPlayer {
        let d = decks[deck]!
        return DeckPlayer(engine: self, player: d.player, varispeed: d.varispeed, timePitch: d.timePitch,
                          scratch: scratchVoices[deck]!, vinyl: vinylNoises[deck]!)
    }

    // MARK: Mixer

    /// `value` 0 (A in) ... 1 (B in), equal-power.
    package func setCrossfader(_ value: Double) {
        crossfaderGains = Crossfader.gains(crossfader: value)
        applyChannelVolumes()
    }

    package func setChannelLevel(_ level: Double, deck: DeckID) {
        levels[deck] = min(1, max(0, level))
        applyChannelVolumes()
    }

    private func applyChannelVolumes() {
        decks[.a]?.channel.volume = Float((levels[.a] ?? 1) * crossfaderGains.a)
        decks[.b]?.channel.volume = Float((levels[.b] ?? 1) * crossfaderGains.b)
    }

    package func setEQ(low: Double, mid: Double, high: Double, deck: DeckID) {
        guard let d = decks[deck],
              let lb = d.low.bands.first, let mb = d.mid.bands.first, let hb = d.high.bands.first
        else { return }
        lb.gain = Float(clampDB(low))
        mb.gain = Float(clampDB(mid))
        hb.gain = Float(clampDB(high))
    }

    private func clampDB(_ db: Double) -> Double { min(12, max(-12, db)) }

    /// One-knob filter: below 0 a low-pass sweeping 20 kHz -> 200 Hz, above 0 a high-pass
    /// sweeping 20 Hz -> 8 kHz, off near the center.
    package func setFilter(_ value: Double, deck: DeckID) {
        guard let band = decks[deck]?.filter.bands.first else { return }
        let v = min(1, max(-1, value))
        if abs(v) < 0.02 {
            band.bypass = true
            return
        }
        band.filterType = v < 0 ? .resonantLowPass : .resonantHighPass
        band.frequency = Float(v < 0 ? 20_000 * pow(0.01, -v) : 20 * pow(400, v))
        band.bypass = false
    }

    /// The channel effect and its amount (0 ... 1). Echo repeats every `echoSeconds`
    /// (half a beat when the deck has a BPM).
    package func setFX(_ fx: ChannelFX, amount: Double, echoSeconds: Double, deck: DeckID) {
        guard let d = decks[deck] else { return }
        let a = Float(min(1, max(0, amount)))
        d.echo.bypass = fx != .echo || a == 0
        d.echo.delayTime = min(2, max(0.02, echoSeconds))
        d.echo.feedback = 25 + 45 * a
        d.echo.wetDryMix = 55 * a
        d.reverb.bypass = fx != .reverb || a == 0
        d.reverb.wetDryMix = 65 * a
    }

    // MARK: Music player

    /// The music player, bound to the player chain. `clock` is the pre-mix node, which
    /// renders all the time, so its render time is the player's clock.
    package func queuePlayer() -> QueuePlayer {
        QueuePlayer(engine: self, nodes: playerNodes, clock: playerPre)
    }

    package func setPlayerVolume(_ v: Double) { playerMix.outputVolume = Float(min(1, max(0, v))) }

    /// -1 (left) ... 1 (right).
    package func setPlayerBalance(_ b: Double) { playerMix.pan = Float(min(1, max(-1, b))) }

    /// Graphic EQ gains in dB (one per `PlayerEQ.frequencies`) and the preamp. A band at 0 dB,
    /// or the whole EQ when off, is bypassed and costs nothing.
    package func setPlayerEQ(gains: [Double], preamp: Double, enabled: Bool) {
        for (band, g) in zip(playerEQ.bands, gains) {
            band.gain = Float(min(12, max(-12, g)))
            band.bypass = !enabled || g == 0
        }
        playerEQ.globalGain = enabled ? Float(min(12, max(-12, preamp))) : 0
    }

    package func setMasterLevel(_ level: Double) {
        engine.mainMixerNode.outputVolume = Float(min(1, max(0, level)))
    }

    // MARK: Recording

    /// Start recording the master output to an AAC file in ~/Music/Platter.
    package func startRecording() throws -> URL {
        stopRecording()
        let dir = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Platter", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = dir.appendingPathComponent("Mix \(f.string(from: Date())).m4a")
        let format = limiter.outputFormat(forBus: 0)
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 256_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        recorder.open(file)
        Self.installRecorder(on: limiter, recorder: recorder) // only while recording
        recording = (Date(), url)
        return url
    }

    /// Stop recording. Returns the file.
    @discardableResult
    package func stopRecording() -> URL? {
        guard let r = recording else { return nil }
        limiter.removeTap(onBus: 0)
        recorder.close()
        recording = nil
        return r.url
    }

    // MARK: Headphones

    /// Turn PFL on or off for a deck.
    package func setPFL(_ on: Bool, deck: DeckID) {
        cue.feeds[deck]?.enabled = on
    }

    /// Send the headphone feed to `device`, or stop it with `nil`.
    package func setHeadphones(_ device: AudioDeviceID?) throws {
        guard let device else { cue.stop(); return }
        try cue.start(device: device, sampleRate: decks[.a]!.high.outputFormat(forBus: 0).sampleRate)
    }
}
