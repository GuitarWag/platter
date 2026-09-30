import Foundation
import Combine
import AppKit

/// The center mixer: crossfader plus per-channel level and 3-band EQ.
/// `crossfader` is 0 (deck A hard in) to 1 (deck B hard in).
@MainActor
final class MixerState: ObservableObject {
    @Published var crossfader: Double = 0.5 {
        didSet { engine?.setCrossfader(crossfader) }
    }
    @Published var level: [DeckID: Double] = [
        .a: 1.0,
        .b: 1.0,
    ] {
        didSet {
            for d in DeckID.allCases { engine?.setChannelLevel(level[d] ?? 1.0, deck: d) }
        }
    }
    /// dB per band, roughly -12 ... +12.
    @Published var eq: [DeckID: (low: Double, mid: Double, high: Double)] = [
        .a: (0, 0, 0),
        .b: (0, 0, 0),
    ] {
        didSet {
            for d in DeckID.allCases {
                guard let e = eq[d] else { continue }
                engine?.setEQ(low: e.low, mid: e.mid, high: e.high, deck: d)
            }
        }
    }

    /// -1 (low-pass) ... 0 (off) ... +1 (high-pass).
    @Published var filter: [DeckID: Double] = [.a: 0, .b: 0] {
        didSet { for d in DeckID.allCases { engine?.setFilter(filter[d] ?? 0, deck: d) } }
    }
    @Published var fx: [DeckID: ChannelFX] = [.a: .echo, .b: .echo] {
        didSet { applyFX() }
    }
    /// Effect amount 0 ... 1.
    @Published var fxAmount: [DeckID: Double] = [.a: 0, .b: 0] {
        didSet { applyFX() }
    }
    @Published var master: Double = 0.9 {
        didSet { engine?.setMasterLevel(master) }
    }
    /// Headphone cue per channel.
    @Published var pfl: [DeckID: Bool] = [.a: false, .b: false] {
        didSet { for d in DeckID.allCases { engine?.setPFL(pfl[d] ?? false, deck: d) } }
    }
    @Published var phonesLevel: Double = 0.8 {
        didSet { engine?.cue.volume = Float(min(1, max(0, phonesLevel))) }
    }
    /// Headphone device, `nil` when off.
    @Published private(set) var headphones: CueOutput.Device?
    @Published private(set) var recordingSince: Date?

    /// The deck's BPM at its current tempo, for the echo time. Set by the app model.
    var bpm: (DeckID) -> Double? = { _ in nil }
    /// Shows a message to the user. Set by the app model.
    var onError: ((String) -> Void)?

    private(set) var engine: AudioEngine?

    init(engine: AudioEngine?) {
        self.engine = engine
        engine?.setMasterLevel(master)
    }

    /// Re-apply the effects, for example after a tempo change moves the echo time.
    func applyFX() {
        for d in DeckID.allCases {
            let beat = bpm(d).map { 60 / $0 } ?? 0.5
            engine?.setFX(fx[d] ?? .off, amount: fxAmount[d] ?? 0, echoSeconds: beat / 2, deck: d)
        }
    }

    func toggleRecording() {
        guard let engine else { return }
        if recordingSince != nil {
            if let url = engine.stopRecording() {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            recordingSince = nil
        } else {
            do {
                _ = try engine.startRecording()
                recordingSince = Date()
            } catch {
                onError?("Could not start recording: \(error.localizedDescription)")
            }
        }
    }

    func setHeadphones(_ device: CueOutput.Device?) {
        do {
            try engine?.setHeadphones(device?.id)
            headphones = device
        } catch {
            headphones = nil
            onError?("Headphones: \((error as? LibraryError)?.message ?? error.localizedDescription)")
        }
    }

    func setLevel(_ value: Double, deck: DeckID) {
        level[deck] = value
    }

    func setEQBand(_ value: Double, band: EQBand, deck: DeckID) {
        var e = eq[deck] ?? (0, 0, 0)
        switch band {
        case .low: e.low = value
        case .mid: e.mid = value
        case .high: e.high = value
        }
        eq[deck] = e
    }
}

/// The effect on a channel.
enum ChannelFX: String, CaseIterable {
    case off, echo, reverb

    var label: String {
        switch self {
        case .off: return "FX OFF"
        case .echo: return "ECHO"
        case .reverb: return "REVERB"
        }
    }

    var next: ChannelFX {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

enum EQBand: String, CaseIterable {
    case low, mid, high
}
