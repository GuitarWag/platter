import SwiftUI
import AppKit
import PlatterCore

/// Which skin the player shows. Stored as a string in `player.skin`:
/// "platter", "chrome", "ruby", or "wsz:<file name>" for a classic skin in the skins folder.
enum Skin: Hashable {
    case platter
    case pod(PodPalette)
    case classic(String)

    init(key: String) {
        switch key {
        case "chrome": self = .pod(.chrome)
        case "ruby": self = .pod(.ruby)
        case let k where k.hasPrefix("wsz:"): self = .classic(String(k.dropFirst(4)))
        default: self = .platter
        }
    }

    var key: String {
        switch self {
        case .platter: return "platter"
        case .pod(let p): return p.key
        case .classic(let file): return "wsz:" + file
        }
    }

    /// Shaped skins draw their own outline and controls: no window frame or title buttons.
    var isShaped: Bool {
        if case .platter = self { return false }
        return true
    }
}

/// The player window: shows the chosen skin and shapes the window for it.
struct PlayerWindowView: View {
    let model: PlayerAppModel
    @AppStorage("player.skin") private var skinKey = "platter"
    @State private var window: NSWindow?

    var body: some View {
        let skin = Skin(key: skinKey)
        Group {
            switch skin {
            case .platter:
                PlatterSkinView(model: model)
            case .pod(let palette):
                PodSkinView(model: model, palette: palette)
            case .classic(let file):
                ClassicSkinView(model: model, file: file)
            }
        }
        .background(WindowAccessor { w in
            model.playerWindow = w
            window = w
            if let w { Self.style(w, shaped: skin.isShaped) }
        })
        .onChange(of: skinKey) { _, key in
            if let window { Self.style(window, shaped: Skin(key: key).isShaped) }
        }
        .preferredColorScheme(.dark)
    }

    /// A shaped skin gets a clear, frameless-looking window that moves by dragging its body;
    /// the Platter skin gets the normal window back.
    static func style(_ w: NSWindow, shaped: Bool) {
        w.isOpaque = !shaped
        w.backgroundColor = shaped ? .clear : NSColor(white: 0.1, alpha: 1)
        w.isMovableByWindowBackground = true
        w.titlebarAppearsTransparent = true
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            w.standardWindowButton(b)?.isHidden = shaped
        }
        w.hasShadow = true
        DispatchQueue.main.async { w.invalidateShadow() } // the shadow follows the new shape
    }
}

/// The Skins menu: built-in skins, classic skins from the skins folder, and adding more.
struct SkinCommands: Commands {
    @AppStorage("player.skin") private var skinKey = "platter"
    @ObservedObject var library: SkinLibrary

    var body: some Commands {
        CommandMenu("Skins") {
            Picker("Skin", selection: $skinKey) {
                Text("Platter").tag("platter")
                Text("Chrome").tag("chrome")
                Text("Ruby").tag("ruby")
                if !library.files.isEmpty {
                    Divider()
                    ForEach(library.files, id: \.self) { f in
                        Text((f as NSString).deletingPathExtension).tag("wsz:" + f)
                    }
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Add Classic Skin…") { library.add() }
            Button("Open Skins Folder") { NSWorkspace.shared.open(SkinLibrary.folder) }
            Button("Get Classic Skins (skins.webamp.org)") {
                NSWorkspace.shared.open(URL(string: "https://skins.webamp.org")!)
            }
        }
    }
}

/// Classic skins (.wsz files) the user added, in Application Support/Platter/Skins. Platter
/// ships none: classic skins are their authors' artwork.
@MainActor
final class SkinLibrary: ObservableObject {
    static var folder: URL {
        let d = AppPaths.support.appendingPathComponent("Skins", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Published private(set) var files: [String] = []

    init() { refresh() }

    func refresh() {
        files = ((try? FileManager.default.contentsOfDirectory(atPath: Self.folder.path)) ?? [])
            .filter { ["wsz", "zip"].contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Copy .wsz files into the skins folder and switch to the first one.
    func add() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.init(filenameExtension: "wsz")!, .zip]
        guard panel.runModal() == .OK else { return }
        var first: String?
        for url in panel.urls {
            let dest = Self.folder.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.copyItem(at: url, to: dest)) != nil, first == nil { first = url.lastPathComponent }
        }
        refresh()
        if let first { UserDefaults.standard.set("wsz:" + first, forKey: "player.skin") }
    }
}
