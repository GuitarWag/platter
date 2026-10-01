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
    let player: PlayerState
    private(set) var nowPlaying: NowPlaying!
    /// The player window, so DJ shortcuts stay out of it.
    weak var playerWindow: NSWindow?
    /// Ask the DJ window to open the player window (used by the player benchmark).
    @Published var openPlayerWindow = false

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
        let player = PlayerState(engine: engine, library: library)
        self.player = player
        self.error = startError

        nowPlaying = NowPlaying(player: player, library: library)
        // One plays at a time (unless turned off): the player pauses the decks, a deck the player.
        player.onError = { [weak self] in self?.error = $0 }
        player.onWillPlay = { [weak self] in
            guard let self, self.player.prefs.exclusive else { return }
            self.autoDJ.stop()
            self.deckA.pause()
            self.deckB.pause()
        }
        for deck in [deckA, deckB] {
            deck.onPlay = { [weak self] in
                guard let self, self.player.prefs.exclusive else { return }
                self.player.pause()
            }
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
        AppDelegate.model = self
        startBenchIfRequested()
        engine.onRestart = { [weak self] in
            self?.deckA.engineRestarted()
            self?.deckB.engineRestarted()
        }
    }

    func deck(_ id: DeckID) -> DeckState { id == .a ? deckA : deckB }

    /// Replace the player's queue with an album and play it.
    func playAlbum(_ id: Int64) {
        let previous = library.source
        library.source = .album(id)
        let tracks = library.tracks
        library.source = previous
        player.playAll(tracks)
    }

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
            if let w = NSApp.keyWindow, w === self.playerWindow {
                return self.handlePlayerKey(key, code: event.keyCode, down: event.type == .keyDown) ? nil : event
            }
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

    /// The player window's keys: the classic Z X C V B, space, arrows to seek and set volume.
    private func handlePlayerKey(_ key: String, code: UInt16, down: Bool) -> Bool {
        let p = player
        let byCode: [UInt16: () -> Void] = [
            123: { p.seek(to: p.position - 5) }, 124: { p.seek(to: p.position + 5) },
            126: { p.prefs.volume = min(1, p.prefs.volume + 0.05) }, 125: { p.prefs.volume = max(0, p.prefs.volume - 0.05) },
        ]
        let byKey: [String: () -> Void] = [
            "z": { p.previous() }, "x": { p.isPlaying ? p.seek(to: 0) : p.togglePlay() },
            "c": { p.togglePlay() }, "v": { p.stop() }, "b": { p.next() }, " ": { p.togglePlay() },
        ]
        guard let action = byCode[code] ?? byKey[key] else { return false }
        if down { action() }
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
        let env = ProcessInfo.processInfo.environment
        guard let bench = env["PLATTER_BENCH"] else { return }
        for d in [deckA, deckB] { d.onFirstPlay = nil } // a benchmark is not a play
        player.recordsHistory = false
        player.persists = false
        if bench == "player" {
            // The player window plays a downloaded track at volume 0. PLATTER_BENCH_VIZ picks
            // the visualizer: 0 spectrum, 1 scope, 2 off.
            UserDefaults.standard.set(Int(env["PLATTER_BENCH_VIZ"] ?? "0") ?? 0, forKey: "player.visualizer")
            openPlayerWindow = true
            player.prefs.volume = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                // Only the player window in front: a covered window is not drawn.
                NSApp.windows.filter { $0 !== self?.playerWindow }.forEach { $0.orderOut(nil) }
                self?.playerWindow?.orderFrontRegardless()
            }
            Task {
                let tracks = library.tracks.filter(\.isCached)
                guard !tracks.isEmpty else { self.error = "Bench: no downloaded track in the selected list."; return }
                player.playAll(Array(tracks.prefix(1)))
            }
            return
        }
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

/// The Dock menu, and playing on after the last window closes.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @MainActor
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let model = Self.model else { return nil }
        let p = model.player
        let menu = NSMenu()
        if let t = p.current {
            let now = NSMenuItem(title: "\(t.artist.isEmpty ? "" : t.artist + " - ")\(t.title)", action: nil, keyEquivalent: "")
            now.isEnabled = false
            menu.addItem(now)
        }
        menu.addItem(DockAction(p.isPlaying ? "Pause" : "Play") { p.togglePlay() })
        menu.addItem(DockAction("Next") { p.next() })
        menu.addItem(DockAction("Previous") { p.previous() })
        let albums = model.library.albums.prefix(5)
        if !albums.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Play Album", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for a in albums {
                menu.addItem(DockAction(a.name) { model.playAlbum(a.id) })
            }
        }
        return menu
    }
}

/// A menu item that runs a closure.
final class DockAction: NSMenuItem {
    private let run: @MainActor () -> Void

    init(_ title: String, _ run: @escaping @MainActor () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @MainActor @objc private func fire() { run() }
}

@main
struct PlatterApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Platter", id: "dj") {
            PlatterRootView(model: model)
                .frame(minWidth: 1240, minHeight: 800)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands { ModeCommands() }

        Window("Platter Player", id: "player") {
            PlayerWindowView(model: model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            MiniPlayerView(model: model)
        } label: {
            Image(systemName: model.player.isPlaying ? "music.note" : "music.note.list")
        }
        .menuBarExtraStyle(.window)
    }
}

/// ⌘1 opens the DJ rig, ⌘2 the music player. Both share the engine and the library.
struct ModeCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Mode") {
            Button("DJ") { openWindow(id: "dj") }.keyboardShortcut("1")
            Button("Player") { openWindow(id: "player") }.keyboardShortcut("2")
        }
    }
}

/// Top: both decks' close-up waveforms. Middle: turntable A, mixer, turntable B.
/// Bottom (resizable): the library.
struct PlatterRootView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

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
        .onChange(of: model.openPlayerWindow, initial: true) { _, open in
            if open { openWindow(id: "player"); model.openPlayerWindow = false }
        }
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
