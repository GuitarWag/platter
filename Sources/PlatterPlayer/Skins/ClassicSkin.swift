import SwiftUI
import AppKit
import PlatterCore

// Sprite positions follow the skin map of Webamp (github.com/captbaritone/webamp, MIT license).

/// A classic Winamp 2 skin (.wsz): a zip of BMP sprite sheets, `viscolor.txt` for the
/// visualizer colors, and `region.txt` for the window outline.
@MainActor
final class ClassicSkin {
    struct LoadError: LocalizedError { let errorDescription: String? }

    private let sheets: [String: CGImage]
    private var crops: [String: Image] = [:]
    let visColors: [Color]
    let region: [[CGPoint]]

    init(url: URL) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("platter-skin-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // -j drops the folders inside the zip, so no entry can land outside `dir`.
        // -C matches the patterns in any case (MAIN.BMP, Main.bmp).
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-qq", "-o", "-j", "-C", url.path, "*.bmp", "*.txt", "-d", dir.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        try unzip.run()
        unzip.waitUntilExit()

        var sheets: [String: CGImage] = [:]
        var texts: [String: String] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
            let file = dir.appendingPathComponent(name)
            let key = name.lowercased()
            if key.hasSuffix(".bmp") {
                sheets[String(key.dropLast(4))] = (try? Data(contentsOf: file)).flatMap { NSBitmapImageRep(data: $0)?.cgImage }
            } else {
                texts[key] = try? String(contentsOf: file, encoding: .isoLatin1)
            }
        }
        guard sheets["main"] != nil else {
            throw LoadError(errorDescription: "\(url.lastPathComponent) is not a classic skin (no main.bmp).")
        }
        self.sheets = sheets
        visColors = Self.parseVisColors(texts["viscolor.txt"] ?? "").map {
            Color(red: Double($0[0]) / 255, green: Double($0[1]) / 255, blue: Double($0[2]) / 255)
        }
        region = Self.parseRegion(texts["region.txt"] ?? "")
    }

    /// A w×h piece of a sheet, or nil when the skin does not have it.
    func sprite(_ sheet: String, _ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Image? {
        let key = "\(sheet) \(x) \(y) \(w) \(h)"
        if let hit = crops[key] { return hit }
        guard let cg = sheets[sheet]?.cropping(to: CGRect(x: x, y: y, width: w, height: h)),
              cg.width == w, cg.height == h else { return nil }
        let image = Image(decorative: cg, scale: 1).interpolation(.none)
        crops[key] = image
        return image
    }

    func has(_ sheet: String) -> Bool { sheets[sheet] != nil }

    // MARK: Parsing

    /// 24 "r,g,b" lines; text after the third number is a comment. Winamp's colors when
    /// the file is missing or short.
    nonisolated static func parseVisColors(_ text: String) -> [[Int]] {
        let parsed = text.split(whereSeparator: \.isNewline).compactMap { line -> [Int]? in
            let n = line.split(whereSeparator: { !$0.isNumber }).prefix(3).compactMap { Int($0) }
            return n.count == 3 ? n.map { min(255, $0) } : nil
        }
        return parsed.count >= 24 ? Array(parsed.prefix(24)) : defaultVisColors
    }

    nonisolated static let defaultVisColors: [[Int]] = [
        [0, 0, 0], [24, 33, 41], [239, 49, 16], [206, 41, 16], [214, 90, 0], [214, 102, 0],
        [214, 115, 0], [198, 123, 8], [222, 165, 24], [214, 181, 33], [189, 222, 41], [148, 222, 33],
        [41, 206, 16], [50, 190, 16], [57, 181, 16], [49, 156, 8], [41, 148, 0], [24, 132, 8],
        [255, 255, 255], [214, 214, 222], [181, 189, 189], [160, 170, 175], [148, 156, 165], [150, 150, 150],
    ]

    /// The [Normal] section: `NumPoints` (the point count of each polygon) and `PointList`
    /// (x,y pairs). No polygons means a plain rectangle.
    nonisolated static func parseRegion(_ text: String) -> [[CGPoint]] {
        var section = "", counts: [Int] = [], values: [Double] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line.lowercased(); continue }
            guard section == "[normal]", let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let nums = line[line.index(after: eq)...].split(whereSeparator: { !$0.isNumber && $0 != "-" }).compactMap { Double($0) }
            if key == "numpoints" { counts = nums.map { Int($0) } }
            if key == "pointlist" { values = nums }
        }
        var polygons: [[CGPoint]] = [], i = 0
        for c in counts {
            guard c > 0, i + c * 2 <= values.count else { break }
            if c > 2 { polygons.append(stride(from: i, to: i + c * 2, by: 2).map { CGPoint(x: values[$0], y: values[$0 + 1]) }) }
            i += c * 2
        }
        return polygons
    }

    /// The cell (row, column) of a character in text.bmp, which has 5×6 cells.
    nonisolated static func glyph(_ c: Character) -> (row: Int, col: Int) {
        let rows = [Array("abcdefghijklmnopqrstuvwxyz\"@"), Array("0123456789….:()-'!_+\\/[]^&%,=$#"), Array("ÅÖÄ?*")]
        if let col = rows[2].firstIndex(where: { String($0) == String(c).uppercased() }) { return (2, col) }
        let folded = String(c).folding(options: .diacriticInsensitive, locale: nil).lowercased()
        let k: Character = ["<": "[", ">": "]", "{": "[", "}": "]"][folded.first ?? " "] ?? folded.first ?? " "
        for r in 0...1 { if let col = rows[r].firstIndex(of: k) { return (r, col) } }
        return (0, 30) // space
    }
}

/// The window outline from region.txt, at the window's scale.
private struct RegionShape: Shape {
    let polygons: [[CGPoint]]
    let scale: CGFloat

    func path(in rect: CGRect) -> Path {
        guard !polygons.isEmpty else { return Path(rect) }
        var p = Path()
        for poly in polygons { p.addLines(poly.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }); p.closeSubpath() }
        return p
    }
}

/// Loads a classic skin from the skins folder. A file that does not load switches back to
/// the Platter skin and shows why.
struct ClassicSkinView: View {
    let model: PlayerAppModel
    let file: String
    @AppStorage("player.skin") private var skinKey = "platter"
    @State private var skin: ClassicSkin?

    var body: some View {
        Group {
            if let skin {
                ClassicMainWindow(model: model, skin: skin)
            } else {
                Color.clear.frame(width: 550, height: 232)
            }
        }
        .task(id: file) {
            do {
                skin = try ClassicSkin(url: SkinLibrary.folder.appendingPathComponent(file))
            } catch {
                model.error = "Skin: \(error.localizedDescription)"
                skinKey = "platter"
            }
        }
    }
}

/// The classic main window at double size: title bar, time, scrolling title, spectrum,
/// position and volume sliders, transport, shuffle and repeat.
struct ClassicMainWindow: View {
    let model: PlayerAppModel
    let skin: ClassicSkin
    @ObservedObject private var player: PlayerState
    @AppStorage("player.skin") private var skinKey = "platter"
    @State private var peaks = PeakHold()
    static let scale: CGFloat = 2

    init(model: PlayerAppModel, skin: ClassicSkin) {
        self.model = model
        self.skin = skin
        player = model.player
    }

    var body: some View {
        let s = Self.scale
        ZStack(alignment: .topLeading) {
            // Clicks on the artwork fall through to the drag area and move the window.
            WindowDragArea()
            Group {
                skin.sprite("main", 0, 0, 275, 116)?.resizable()
                place(skin.sprite("titlebar", 27, 0, 275, 14), 0, 0, 275, 14)
                TimelineView(.animation(minimumInterval: player.isPlaying ? 1.0 / 30 : 0.25)) { t in
                    Canvas { ctx, _ in
                        ctx.scaleBy(x: s, y: s)
                        display(&ctx, t.date)
                    }
                }
            }
            .allowsHitTesting(false)

            // Title bar buttons.
            button("titlebar", 0, 0, 0, 9, 9, 9, at: 6, 3, "Full player (playlist, EQ, library)") { skinKey = "platter" }
            button("titlebar", 9, 0, 9, 9, 9, 9, at: 244, 3, "Minimize") { model.playerWindow?.miniaturize(nil) }
            button("titlebar", 18, 0, 18, 9, 9, 9, at: 264, 3, "Close (keeps playing; reopen from the menu bar)") {
                model.playerWindow?.close()
            }

            // Transport.
            button("cbuttons", 0, 0, 0, 18, 23, 18, at: 16, 88, "Previous") { player.previous() }
            button("cbuttons", 23, 0, 23, 18, 23, 18, at: 39, 88, "Play") {
                player.isPlaying ? player.seek(to: 0) : player.togglePlay()
            }
            button("cbuttons", 46, 0, 46, 18, 23, 18, at: 62, 88, "Pause") { if player.current != nil { player.togglePlay() } }
            button("cbuttons", 69, 0, 69, 18, 23, 18, at: 85, 88, "Stop") { player.stop() }
            button("cbuttons", 92, 0, 92, 18, 22, 18, at: 108, 88, "Next") { player.next() }
            button("cbuttons", 114, 0, 114, 16, 22, 16, at: 136, 89, "Full player (library)") { skinKey = "platter" }

            // Shuffle, repeat, and the EQ and playlist toggles (both open the full player).
            let shuffle = player.prefs.shuffle ? 30 : 0, rep = player.prefs.repeatMode != .off ? 30 : 0
            button("shufrep", 28, shuffle, 28, shuffle + 15, 47, 15, at: 164, 89, "Shuffle") { player.prefs.shuffle.toggle() }
            button("shufrep", 0, rep, 0, rep + 15, 28, 15, at: 210, 89,
                   player.prefs.repeatMode == .one ? "Repeat one" : "Repeat") {
                player.prefs.repeatMode = player.prefs.repeatMode.next
            }
            button("shufrep", 0, 61, 46, 61, 23, 12, at: 219, 58, "Equalizer (full player)") { skinKey = "platter" }
            button("shufrep", 23, 61, 69, 61, 23, 12, at: 242, 58, "Playlist (full player)") { skinKey = "platter" }

            ClassicSlider(skin: skin, kind: .volume, value: $player.prefs.volume)
                .frame(width: 68 * s, height: 13 * s).offset(x: 107 * s, y: 57 * s)
            ClassicSlider(skin: skin, kind: .position, value: Binding(
                get: { player.duration > 0 ? player.position / player.duration : 0 },
                set: { player.seek(to: $0 * player.duration) }), live: player.isPlaying, enabled: player.current != nil)
                .frame(width: 248 * s, height: 10 * s).offset(x: 16 * s, y: 72 * s)
        }
        .frame(width: 275 * s, height: 116 * s)
        .clipShape(RegionShape(polygons: skin.region, scale: s))
    }

    // MARK: Display

    /// The parts that change each frame: play state, time, title, spectrum, stereo.
    private func display(_ ctx: inout GraphicsContext, _ date: Date) {
        let state = player.isPlaying ? 0 : player.current != nil ? 9 : 18
        draw(&ctx, skin.sprite("playpaus", state, 0, 9, 9), 26, 28, 9, 9)
        draw(&ctx, skin.sprite("monoster", 0, player.isPlaying ? 0 : 12, 29, 12), 239, 41, 29, 12)
        draw(&ctx, skin.sprite("monoster", 29, 12, 27, 12), 212, 41, 27, 12)
        // Balance has no control in Platter: drawn centered.
        draw(&ctx, skin.sprite("balance", 9, 0, 38, 13), 177, 57, 38, 13)
        draw(&ctx, skin.sprite("balance", 15, 422, 14, 11), 189, 58, 14, 11)

        if player.current != nil {
            let t = max(0, Int(player.position))
            let digits = [min(99, t / 60) / 10, min(99, t / 60) % 10, t % 60 / 10, t % 10]
            for (d, x) in zip(digits, [48, 60, 78, 90]) {
                let sheet = skin.has("numbers") ? "numbers" : "nums_ex"
                draw(&ctx, skin.sprite(sheet, d * 9, 0, 9, 13), CGFloat(x), 26, 9, 13)
            }
        }

        // Title: scrolls when longer than the 31 cells of the box.
        let chars = Array(marqueeText)
        let offset = chars.count > 31 ? Int(date.timeIntervalSinceReferenceDate / 0.2) % chars.count : 0
        for i in 0..<min(31, chars.count) {
            let g = ClassicSkin.glyph(chars[(i + offset) % chars.count])
            draw(&ctx, skin.sprite("text", g.col * 5, g.row * 6, 5, 6), CGFloat(111 + i * 5), 27, 5, 6)
        }

        // Spectrum: 19 bars, 3 px wide, 16 px high, colored by row from viscolor.txt.
        guard player.isPlaying else { return }
        let bars = Spectrum.bars(model.engine.playerViz.snapshot(Spectrum.fftSize),
                                 sampleRate: model.engine.playerVizRate, bands: 19)
        let held = peaks.update(bars)
        for (i, v) in bars.enumerated() {
            let x = CGFloat(24 + i * 4), h = Int((v * 16).rounded())
            for row in 0..<min(16, h) {
                ctx.fill(Path(CGRect(x: x, y: CGFloat(58 - row), width: 3, height: 1)), with: .color(skin.visColors[17 - row]))
            }
            let peak = Int((held[i] * 16).rounded())
            if peak > 0 {
                ctx.fill(Path(CGRect(x: x, y: CGFloat(59 - min(16, peak)), width: 3, height: 1)), with: .color(skin.visColors[23]))
            }
        }
    }

    private var marqueeText: String {
        if let l = player.loadingTitle { return "Loading \(l)..." }
        guard let t = player.current else { return "Platter Player" }
        let n = (player.currentIndex ?? 0) + 1
        let line = "\(n). \(t.artist.isEmpty ? "" : t.artist + " - ")\(t.title) (\(formatTime(player.duration)))"
        return line.count > 31 ? line + "  ***  " : line
    }

    private func draw(_ ctx: inout GraphicsContext, _ image: Image?, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
        if let image { ctx.draw(image, in: CGRect(x: x, y: y, width: w, height: h)) }
    }

    // MARK: Controls

    private func place(_ image: Image?, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> some View {
        let s = Self.scale
        return image?.resizable().frame(width: w * s, height: h * s).offset(x: x * s, y: y * s)
    }

    /// A sprite button: the normal sprite at (nx, ny), the pressed one at (px, py).
    private func button(_ sheet: String, _ nx: Int, _ ny: Int, _ px: Int, _ py: Int, _ w: Int, _ h: Int,
                        at x: CGFloat, _ y: CGFloat, _ label: String, action: @escaping () -> Void) -> some View {
        let s = Self.scale
        return Button(action: action) { EmptyView() }
            .buttonStyle(SpriteButtonStyle(normal: skin.sprite(sheet, nx, ny, w, h), pressed: skin.sprite(sheet, px, py, w, h)))
            .frame(width: CGFloat(w) * s, height: CGFloat(h) * s)
            .offset(x: x * s, y: y * s)
            .help(label)
            .accessibilityLabel(label)
    }
}

private struct SpriteButtonStyle: ButtonStyle {
    let normal: Image?
    let pressed: Image?

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            Color.clear
            (configuration.isPressed ? pressed ?? normal : normal)?.resizable()
        }
        .contentShape(Rectangle())
    }
}

/// The volume and position sliders, drawn from volume.bmp and posbar.bmp.
private struct ClassicSlider: View {
    enum Kind { case volume, position }
    let skin: ClassicSkin
    let kind: Kind
    @Binding var value: Double
    var live = false
    var enabled = true
    @State private var dragging: Double?

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / (kind == .volume ? 68 : 248)
            TimelineView(.animation(minimumInterval: 0.25, paused: !live || dragging != nil)) { t in
                let _ = t.date
                let v = min(1, max(0, dragging ?? value))
                ZStack(alignment: .topLeading) {
                    switch kind {
                    case .volume:
                        skin.sprite("volume", 0, Int((v * 27).rounded()) * 15, 68, 13)?.resizable()
                        skin.sprite("volume", dragging != nil ? 0 : 15, 422, 14, 11)?.resizable()
                            .frame(width: 14 * s, height: 11 * s).offset(x: v * 54 * s, y: 1 * s)
                    case .position:
                        skin.sprite("posbar", 0, 0, 248, 10)?.resizable()
                        if enabled {
                            skin.sprite("posbar", dragging != nil ? 278 : 248, 0, 29, 10)?.resizable()
                                .frame(width: 29 * s, height: 10 * s).offset(x: v * 219 * s)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard enabled else { return }
                    dragging = min(1, max(0, g.location.x / geo.size.width))
                    if kind == .volume, let d = dragging { value = d }
                }
                .onEnded { _ in
                    if let d = dragging { value = d }
                    dragging = nil
                })
        }
        .accessibilityElement()
        .accessibilityLabel(kind == .volume ? "Volume" : "Position")
        .accessibilityValue("\(Int(value * 100))%")
    }
}
