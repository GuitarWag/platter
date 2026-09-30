import SwiftUI
import Combine
import AVFoundation

/// Owns the audio engine, the library, and the model group. Created once at launch and
/// shared with the whole window.
@MainActor
final class AppModel: ObservableObject {
    let engine: AudioEngine
    let library: Library
    let deckA: DeckState
    let deckB: DeckState
    let mixer: MixerState
    let autoDJ: AutoDJ

    @Published var error: String?
    private var subscriptions: Set<AnyCancellable> = []
    private var keyMonitor: Any?

    init() {
        let engine = AudioEngine()
        var startError: String? = nil
        do {
            try engine.start()
        } catch {
            startError = "Audio engine failed to start: \(error.localizedDescription)"
        }
        let db: LibraryDB
        do {
            db = try LibraryDB(path: AppPaths.database.path)
        } catch {
            // Keep the app usable; nothing is saved this session.
            startError = "Could not open \(AppPaths.database.path): \(error). The library is not saved this session."
            db = try! LibraryDB(path: ":memory:")
        }
        let library = Library(db: db)
        let deckA = DeckState(deck: .a, engine: engine)
        let deckB = DeckState(deck: .b, engine: engine)
        let mixer = MixerState(engine: engine)
        self.engine = engine
        self.library = library
        self.deckA = deckA
        self.deckB = deckB
        self.mixer = mixer
        self.autoDJ = AutoDJ(deckA: deckA, deckB: deckB, mixer: mixer, library: library)
        self.error = startError

        for deck in [deckA, deckB] {
            deck.onError = { [weak self] in self?.error = $0 }
            deck.onCueChanged = { [weak library] in library?.saveCue(trackID: $0, slot: $1, seconds: $2) }
            deck.onFirstPlay = { [weak library, weak deck] t in
                guard let deck else { return }
                library?.logPlay(t, deck: deck.deck)
            }
        }
        mixer.bpm = { [weak deckA, weak deckB] id in (id == .a ? deckA : deckB)?.effectiveBPM }
        mixer.onError = { [weak self] in self?.error = $0 }
        // Echo time follows the deck tempo.
        for d in [deckA, deckB] {
            d.objectWillChange
                .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
                .sink { [weak mixer] in mixer?.applyFX() }
                .store(in: &subscriptions)
        }
        installKeyboardShortcuts()
        startBenchIfRequested()
        engine.onRestart = { [weak self] in
            self?.deckA.engineRestarted()
            self?.deckB.engineRestarted()
        }
    }

    func deck(_ id: DeckID) -> DeckState { id == .a ? deckA : deckB }

    /// SYNC on `id`: match its tempo and beat phase to the other deck.
    func sync(_ id: DeckID) {
        if let message = deck(id).sync(to: deck(id == .a ? .b : .a)) { error = message }
    }

    // MARK: Keyboard

    /// One key per control, two hands: deck A on the left of the keyboard, deck B on the
    /// right. Ignored while a text field has focus. See README "Keyboard".
    private func installKeyboardShortcuts() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSTextView),
                  let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
            return self.handleKey(key, down: event.type == .keyDown, isRepeat: event.isARepeat) ? nil : event
        }
    }

    /// Returns true when the key is a shortcut.
    private func handleKey(_ key: String, down: Bool, isRepeat: Bool) -> Bool {
        let a = deckA, b = deckB
        // Bends act on down and up, and ignore key repeat.
        let bends: [String: (DeckState, Double)] = ["a": (a, -0.04), "s": (a, 0.04), "k": (b, -0.04), "l": (b, 0.04)]
        if let (deck, amount) = bends[key] {
            if !isRepeat { deck.bend = down ? amount : 0 }
            return true
        }
        let actions: [String: () -> Void] = [
            "z": { a.toggleCue() }, "x": { a.togglePlay() }, "c": { self.sync(.a) }, "q": { Self.toggleLoop(a) },
            "n": { b.toggleCue() }, "m": { b.togglePlay() }, ",": { self.sync(.b) }, "p": { Self.toggleLoop(b) },
            "1": { Self.pad(a, 0) }, "2": { Self.pad(a, 1) }, "3": { Self.pad(a, 2) }, "4": { Self.pad(a, 3) },
            "7": { Self.pad(b, 0) }, "8": { Self.pad(b, 1) }, "9": { Self.pad(b, 2) }, "0": { Self.pad(b, 3) },
            "[": { self.mixer.crossfader = max(0, self.mixer.crossfader - 0.05) },
            "]": { self.mixer.crossfader = min(1, self.mixer.crossfader + 0.05) },
            "\\": { self.mixer.crossfader = 0.5 },
        ]
        guard let action = actions[key] else { return false }
        if down, !isRepeat { action() }
        return true
    }

    private static func pad(_ d: DeckState, _ i: Int) {
        d.hotCues[i] == nil ? d.setHotCue(i) : d.fireHotCue(i)
    }

    private static func toggleLoop(_ d: DeckState) {
        d.loop == nil ? d.beatLoop() : d.exitLoop()
    }

    // MARK: Benchmark

    /// `PLATTER_BENCH=1`: play a downloaded track on both decks with the channels at zero (no
    /// sound) and bring the window to the front, to measure CPU. See scripts/bench.sh.
    private func startBenchIfRequested() {
        guard ProcessInfo.processInfo.environment["PLATTER_BENCH"] != nil else { return }
        for d in [deckA, deckB] { d.onFirstPlay = nil } // a benchmark is not a play
        mixer.setLevel(0, deck: .a)
        mixer.setLevel(0, deck: .b)
        // PLATTER_BENCH=hidden leaves the window behind others: no drawing, so the CPU is the audio.
        if ProcessInfo.processInfo.environment["PLATTER_BENCH"] != "hidden" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NSApp.windows.forEach { $0.orderFrontRegardless() }
            }
        }
        Task {
            guard let track = library.tracks.first(where: \.isCached) else {
                self.error = "Bench: no downloaded track in the selected list."
                return
            }
            for d in [deckA, deckB] {
                await d.load(track, from: library)
                d.play()
            }
        }
    }

    /// Load a track onto a deck (download and analysis happen first when needed).
    func load(_ track: Track, onto deck: DeckID) {
        Task { await self.deck(deck).load(track, from: library) }
    }

    /// Load onto the deck that is not playing; deck A when both are free or both play.
    func loadOnFreeDeck(_ track: Track) {
        load(track, onto: deckA.isPlaying && !deckB.isPlaying ? .b : .a)
    }
}

@main
struct PlatterApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            PlatterRootView(model: model)
                .frame(minWidth: 1240, minHeight: 800)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
    }
}

/// Top: both decks' close-up waveforms. Middle: turntable A, mixer, turntable B.
/// Bottom (resizable): the library.
struct PlatterRootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                ZoomStrip(deckA: model.deckA, deckB: model.deckB)
                    .frame(height: 96)
                HStack(spacing: 0) {
                    DeckView(state: model.deckA, sync: { model.sync(.a) })
                    MixerView(mixer: model.mixer, meters: model.engine.meters, masterMeter: model.engine.masterMeter,
                              deckA: model.deckA, deckB: model.deckB)
                        .frame(width: 270)
                    DeckView(state: model.deckB, sync: { model.sync(.b) })
                }
            }
            .frame(minHeight: 520, idealHeight: 600)
            LibraryBrowser(model: model)
                .frame(minHeight: 170, idealHeight: 260)
        }
        .background(Theme.background)
        .overlay(alignment: .top) {
            if let e = model.error {
                ErrorBanner(message: e) { model.error = nil }
            }
        }
    }
}

struct ErrorBanner: View {
    let message: String
    var dismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .font(.system(size: 12))
                .lineLimit(2)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color.red.opacity(0.85))
        .foregroundColor(.white)
        .cornerRadius(6)
        .padding(8)
        .transition(.move(edge: .top))
    }
}
