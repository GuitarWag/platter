import SwiftUI
import AppKit
import PlatterCore

/// The music player app: the shared engine (player chain only), the shared library and
/// store, the queue, and Now Playing.
@MainActor
final class PlayerAppModel: ObservableObject {
    let engine: AudioEngine
    let library: Library
    let player: PlayerState
    private(set) var nowPlaying: NowPlaying!
    /// The player window. AppKit owns it (see PlayerWindow); nil until first shown.
    private(set) var playerWindow: PlayerWindow?
    @Published var error: String?
    let events = StoreEvents()
    private var keyMonitor: Any?

    /// Tests pass their own library and an offline engine; the app opens the shared store.
    init(library testLibrary: Library? = nil, engine testEngine: AudioEngine? = nil) {
        engine = testEngine ?? AudioEngine(decks: false) // the DJ decks are the other app
        var startError: String?
        if testEngine == nil {
            do { try engine.start() } catch { startError = "Audio engine failed to start: \(error.localizedDescription)" }
        }
        let store = testLibrary.map { (library: $0, error: nil as String?) } ?? LibraryStore.open()
        library = store.library
        player = PlayerState(engine: engine, library: library)
        error = startError ?? store.error
        nowPlaying = NowPlaying(player: player, library: library)
        player.onError = { [weak self] in self?.error = $0 }
        engine.onRestart = { [weak self] in self?.player.engineRestarted() }
        // Live sync with the DJ app: one store, two apps.
        player.prefs.exclusive = library.setting(StoreEvents.exclusiveKey) != "0"
        library.onStoreChanged = { [events] in events.post(.libraryChanged) }
        events.observe(.libraryChanged) { [weak library] in library?.reloadFromStore() }
        player.onWillPlay = { [weak self] in
            guard let self, self.player.prefs.exclusive else { return }
            self.events.post(.willPlay)
        }
        events.observe(.willPlay) { [weak self] in
            guard let self, self.player.prefs.exclusive else { return }
            self.player.pause()
        }
        installKeyboardShortcuts()
        startBenchIfRequested()
    }

    func showPlayerWindow() {
        if playerWindow == nil {
            let w = PlayerWindow(model: self)
            w.apply(shaped: Skin(key: UserDefaults.standard.string(forKey: "player.skin") ?? "").isShaped)
            playerWindow = w
        }
        playerWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Open the DJ app: installed, or next to this app.
    func openDJ() {
        let sibling = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Platter.app")
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "local.platter")
                ?? (FileManager.default.fileExists(atPath: sibling.path) ? sibling : nil) else {
            error = "Platter is not installed. Build it with ./run.sh."
            return
        }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// A `platter-player://queue` link from the DJ app.
    func open(_ url: URL) {
        guard let link = PlayerLink.parse(url) else { return }
        let tracks = library.tracks(ids: link.ids)
        guard !tracks.isEmpty else { return } // unknown ids must not clear the queue
        switch link.mode {
        case .play: player.playAll(tracks)
        case .next: player.enqueue(tracks, next: true)
        case .add: player.enqueue(tracks)
        }
    }

    /// Replace the queue with an album and play it.
    func playAlbum(_ id: Int64) {
        player.playAll(library.tracks(inAlbum: id))
    }

    // MARK: Keyboard

    /// The classic keys: Z previous, X play, C pause, V stop, B next; space; arrows seek
    /// 5 s and set the volume. Ignored while a text field has focus.
    private func installKeyboardShortcuts() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSTextView),
                  let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
            return self.handleKey(key, code: event.keyCode) ? nil : event
        }
    }

    private func handleKey(_ key: String, code: UInt16) -> Bool {
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
        action()
        return true
    }

    // MARK: Benchmark

    /// `PLATTER_BENCH=1`: play a downloaded track at volume 0, with no history, queue, or
    /// settings saved. `PLATTER_BENCH_VIZ` picks the visualizer: 0 spectrum, 1 scope, 2 off.
    private func startBenchIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["PLATTER_BENCH"] != nil else { return }
        player.recordsHistory = false
        player.persists = false
        UserDefaults.standard.set(Int(env["PLATTER_BENCH_VIZ"] ?? "0") ?? 0, forKey: "player.visualizer")
        player.prefs.volume = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.playerWindow?.orderFrontRegardless() // a covered window is not drawn
        }
        Task {
            guard let track = library.allTracks().first(where: \.isCached) else {
                error = "Bench: no downloaded track in the library."
                return
            }
            player.playAll([track])
        }
    }
}

/// Owns the model and the player window, the Dock menu, and playing on after the last
/// window closes.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = PlayerAppModel()

    func applicationDidFinishLaunching(_ notification: Notification) { model.showPlayerWindow() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A Dock click with no window open shows the player.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { model.showPlayerWindow() }
        return false
    }

    /// Links from the DJ app ("Play in Platter Player").
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { model.open($0) }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
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
                menu.addItem(DockAction(a.name) { [model] in model.playAlbum(a.id) })
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

/// The player window is AppKit (PlayerWindow, opened by AppDelegate); the scenes here are
/// the menu bar player and the menus.
@main
struct PlatterPlayerApp: App {
    @StateObject private var skins = SkinLibrary()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MiniPlayerView(model: delegate.model)
        } label: {
            MenuBarIcon(player: delegate.model.player)
        }
        .menuBarExtraStyle(.window)
        .commands {
            SkinCommands(library: skins)
            CommandGroup(before: .windowList) {
                Button("Player") { delegate.model.showPlayerWindow() }.keyboardShortcut("1")
                Button("Close Window") { NSApp.keyWindow?.close() }.keyboardShortcut("w")
                Divider()
            }
        }
    }
}

private struct MenuBarIcon: View {
    @ObservedObject var player: PlayerState

    var body: some View { Image(systemName: player.isPlaying ? "music.note" : "music.note.list") }
}
