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
    /// pledit.txt: Normal, Current, NormalBG, SelectedBG (lower-cased keys).
    let playlistStyle: [String: String]

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
        playlistStyle = Self.parseKeyValues(texts["pledit.txt"] ?? "")
    }

    /// A pledit.txt color ("#00FF00"), or `fallback`.
    func playlistColor(_ key: String, _ fallback: Color) -> Color {
        guard let hex = playlistStyle[key]?.trimmingCharacters(in: CharacterSet(charactersIn: "# ")),
              hex.count >= 6, let v = UInt32(hex.prefix(6), radix: 16) else { return fallback }
        return Color(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
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

    /// "Key=Value" lines; keys lower-cased.
    nonisolated static func parseKeyValues(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            out[line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        return out
    }

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
    @AppStorage("classic.eq") private var showEQ = false
    @AppStorage("classic.pl") private var showPL = false
    static let scale: CGFloat = 2

    init(model: PlayerAppModel, skin: ClassicSkin) {
        self.model = model
        self.skin = skin
        player = model.player
    }

    var body: some View {
        VStack(spacing: 0) {
            main
            if showEQ { ClassicEQWindow(skin: skin, player: player, shown: $showEQ) }
            if showPL { ClassicPlaylistWindow(skin: skin, player: player, shown: $showPL) }
        }
        .onAppear { model.engine.playerViz.enabled = true }
    }

    private var main: some View {
        let s = Self.scale
        return ZStack(alignment: .topLeading) {
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

            // Shuffle, repeat, and the EQ and playlist windows.
            let shuffle = player.prefs.shuffle ? 30 : 0, rep = player.prefs.repeatMode != .off ? 30 : 0
            button("shufrep", 28, shuffle, 28, shuffle + 15, 47, 15, at: 164, 89, "Shuffle") { player.prefs.shuffle.toggle() }
            button("shufrep", 0, rep, 0, rep + 15, 28, 15, at: 210, 89,
                   player.prefs.repeatMode == .one ? "Repeat one" : "Repeat") {
                player.prefs.repeatMode = player.prefs.repeatMode.next
            }
            let eq = showEQ ? 73 : 61, pl = showPL ? 73 : 61
            button("shufrep", 0, eq, 46, eq, 23, 12, at: 219, 58, "Equalizer") { showEQ.toggle() }
            button("shufrep", 23, pl, 69, pl, 23, 12, at: 242, 58, "Playlist") { showPL.toggle() }

            ClassicSlider(skin: skin, kind: .volume, value: $player.prefs.volume)
                .frame(width: 68 * s, height: 13 * s).offset(x: 107 * s, y: 57 * s)
            ClassicSlider(skin: skin, kind: .balance, value: Binding(
                get: { (player.prefs.balance + 1) / 2 }, set: { player.prefs.balance = abs($0 - 0.5) < 0.04 ? 0 : $0 * 2 - 1 }))
                .frame(width: 38 * s, height: 13 * s).offset(x: 177 * s, y: 57 * s)
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
        spriteButton(skin.sprite(sheet, nx, ny, w, h), skin.sprite(sheet, px, py, w, h), w, h, at: x, y, label, action: action)
    }
}

/// A sprite button at (x, y) in skin pixels: the normal sprite, and the pressed one.
private func spriteButton(_ normal: Image?, _ pressed: Image?, _ w: Int, _ h: Int, at x: CGFloat, _ y: CGFloat,
                          _ label: String, action: @escaping () -> Void) -> some View {
    let s = ClassicMainWindow.scale
    return Button(action: action) { EmptyView() }
        .buttonStyle(SpriteButtonStyle(normal: normal, pressed: pressed))
        .frame(width: CGFloat(w) * s, height: CGFloat(h) * s)
        .offset(x: x * s, y: y * s)
        .help(label)
        .accessibilityLabel(label)
}

/// Draws `text` in the skin's text.bmp font at (x, y) in skin pixels.
@MainActor
private func drawText(_ ctx: inout GraphicsContext, _ skin: ClassicSkin, _ text: String, _ x: CGFloat, _ y: CGFloat) {
    for (i, c) in text.enumerated() {
        let g = ClassicSkin.glyph(c)
        if let img = skin.sprite("text", g.col * 5, g.row * 6, 5, 6) { ctx.draw(img, in: CGRect(x: x + CGFloat(i * 5), y: y, width: 5, height: 6)) }
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
    enum Kind { case volume, balance, position }
    let skin: ClassicSkin
    let kind: Kind
    @Binding var value: Double
    var live = false
    var enabled = true
    @State private var dragging: Double?

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / (kind == .volume ? 68 : kind == .balance ? 38 : 248)
            TimelineView(.animation(minimumInterval: 0.25, paused: !live || dragging != nil)) { t in
                let _ = t.date
                let v = min(1, max(0, dragging ?? value))
                ZStack(alignment: .topLeading) {
                    switch kind {
                    case .volume:
                        skin.sprite("volume", 0, Int((v * 27).rounded()) * 15, 68, 13)?.resizable()
                        skin.sprite("volume", dragging != nil ? 0 : 15, 422, 14, 11)?.resizable()
                            .frame(width: 14 * s, height: 11 * s).offset(x: v * 54 * s, y: 1 * s)
                    case .balance:
                        skin.sprite("balance", 9, Int((abs(v * 2 - 1) * 27).rounded()) * 15, 38, 13)?.resizable()
                        skin.sprite("balance", dragging != nil ? 0 : 15, 422, 14, 11)?.resizable()
                            .frame(width: 14 * s, height: 11 * s).offset(x: v * 24 * s, y: 1 * s)
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
                    if kind != .position, let d = dragging { value = d }
                }
                .onEnded { _ in
                    if let d = dragging { value = d }
                    dragging = nil
                })
        }
        .accessibilityElement()
        .accessibilityLabel(kind == .volume ? "Volume" : kind == .balance ? "Balance" : "Position")
        .accessibilityValue("\(Int(value * 100))%")
    }
}

// MARK: Equalizer window

/// The classic EQ window (eqmain.bmp): on, presets, the curve, preamp, and 10 bands.
private struct ClassicEQWindow: View {
    let skin: ClassicSkin
    @ObservedObject var player: PlayerState
    @Binding var shown: Bool

    var body: some View {
        let s = ClassicMainWindow.scale
        let on = player.prefs.eqOn ? 69 : 10
        ZStack(alignment: .topLeading) {
            WindowDragArea()
            Group {
                skin.sprite("eqmain", 0, 0, 275, 116)?.resizable()
                skin.sprite("eqmain", 0, 134, 275, 14)?.resizable().frame(width: 275 * s, height: 14 * s)
                Canvas { ctx, _ in
                    ctx.scaleBy(x: s, y: s)
                    graph(&ctx)
                }
            }
            .allowsHitTesting(false)
            spriteButton(skin.sprite("eqmain", on, 119, 26, 12), skin.sprite("eqmain", on + 118, 119, 26, 12), 26, 12,
                         at: 14, 18, "Equalizer on") { player.prefs.eqOn.toggle() }
            Menu {
                ForEach(PlayerEQ.presets, id: \.name) { p in
                    Button(p.name) { player.prefs.eqGains = p.gains; player.prefs.eqOn = true }
                }
                Divider()
                Button("Reset") { player.prefs.eqGains = PlayerEQ.presets[0].gains; player.prefs.preamp = 0 }
            } label: {
                skin.sprite("eqmain", 224, 164, 44, 12)?.resizable()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(width: 44 * s, height: 12 * s)
            .offset(x: 217 * s, y: 18 * s)
            .help("Presets")
            spriteButton(nil, skin.sprite("eqmain", 0, 125, 9, 9), 9, 9, at: 264, 3, "Close equalizer") { shown = false }
            ClassicEQSlider(skin: skin, value: $player.prefs.preamp, label: "Preamp")
                .frame(width: 14 * s, height: 63 * s).offset(x: 21 * s, y: 38 * s)
            ForEach(0..<PlayerEQ.frequencies.count, id: \.self) { i in
                ClassicEQSlider(skin: skin, value: Binding(get: { player.prefs.eqGains[i] }, set: { player.prefs.eqGains[i] = $0 }),
                                label: "\(PlayerEQ.labels[i]) Hz")
                    .frame(width: 14 * s, height: 63 * s).offset(x: CGFloat(78 + i * 18) * s, y: 38 * s)
            }
        }
        .frame(width: 275 * s, height: 116 * s)
    }

    /// The response graph: preamp line, then the band gains joined, each pixel colored from
    /// the skin's line color strip.
    private func graph(_ ctx: inout GraphicsContext) {
        guard let bg = skin.sprite("eqmain", 0, 294, 113, 19) else { return }
        ctx.draw(bg, in: CGRect(x: 86, y: 17, width: 113, height: 19))
        let yOf = { (db: Double) in Int((9 - db / 12 * 9).rounded()) }
        if let line = skin.sprite("eqmain", 0, 314, 113, 1) {
            ctx.draw(line, in: CGRect(x: 86, y: 17 + CGFloat(yOf(player.prefs.preamp)), width: 113, height: 1))
        }
        let g = player.prefs.eqGains
        for x in 0..<113 {
            let t = Double(x) / 112 * Double(g.count - 1), i = min(g.count - 2, Int(t))
            let y = min(18, max(0, yOf(g[i] + (g[i + 1] - g[i]) * (t - Double(i)))))
            if let px = skin.sprite("eqmain", 115, 294 + y, 1, 1) {
                ctx.draw(px, in: CGRect(x: 86 + CGFloat(x), y: 17 + CGFloat(y), width: 1, height: 1))
            }
        }
    }
}

/// One EQ slider, -12 ... +12 dB; drag up or down, double-click for 0 dB.
private struct ClassicEQSlider: View {
    let skin: ClassicSkin
    @Binding var value: Double
    let label: String
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.height / 63
            let f = (min(12, max(-12, value)) + 12) / 24
            let frame = Int((f * 27).rounded())
            ZStack(alignment: .topLeading) {
                skin.sprite("eqmain", 13 + frame % 14 * 15, 164 + frame / 14 * 65, 14, 63)?.resizable()
                skin.sprite("eqmain", 0, dragging ? 176 : 164, 11, 11)?.resizable()
                    .frame(width: 11 * s, height: 11 * s).offset(x: 1 * s, y: (1 - f) * 51 * s)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    dragging = true
                    let v = (1 - min(1, max(0, (g.location.y - 5.5 * s) / (51 * s)))) * 24 - 12
                    value = abs(v) < 0.6 ? 0 : (v * 2).rounded() / 2
                }
                .onEnded { _ in dragging = false })
            .onTapGesture(count: 2) { value = 0 }
        }
        .help(label)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(String(format: "%+.1f dB", value))
        .accessibilityAdjustableAction { d in value = min(12, max(-12, value + (d == .increment ? 1 : -1))) }
    }
}

// MARK: Playlist window

/// The classic playlist window (pledit.bmp frame, pledit.txt colors): the queue, the current
/// track marked, double-click to play, and the running time.
private struct ClassicPlaylistWindow: View {
    let skin: ClassicSkin
    @ObservedObject var player: PlayerState
    @Binding var shown: Bool
    @State private var selected: Int?
    static let rows = 4 // middle tiles of 29 px

    var body: some View {
        let s = ClassicMainWindow.scale
        let h = CGFloat(20 + Self.rows * 29 + 38)
        ZStack(alignment: .topLeading) {
            WindowDragArea()
            Canvas { ctx, _ in
                ctx.scaleBy(x: s, y: s)
                frame(&ctx, height: h)
            }
            .allowsHitTesting(false)
            list
                .frame(width: 243 * s, height: CGFloat(Self.rows * 29) * s)
                .background(skin.playlistColor("normalbg", .black))
                .offset(x: 12 * s, y: 20 * s)
            spriteButton(nil, skin.sprite("pledit", 52, 42, 9, 9), 9, 9, at: 264, 3, "Close playlist") { shown = false }
        }
        .frame(width: 275 * s, height: h * s)
    }

    private var list: some View {
        let s = ClassicMainWindow.scale
        let font = Font.custom(skin.playlistStyle["font"] ?? "Arial", size: 9 * s)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(player.queue.enumerated()), id: \.offset) { i, entry in
                        HStack(spacing: 4) {
                            Text("\(i + 1). \(entry.track.artist.isEmpty ? "" : entry.track.artist + " - ")\(entry.track.title)")
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(entry.track.duration.map(formatTime) ?? "")
                        }
                        .font(font)
                        .foregroundColor(i == player.currentIndex ? skin.playlistColor("current", .white)
                                                                  : skin.playlistColor("normal", .green))
                        .padding(.horizontal, 2 * s)
                        .frame(height: 13 * s)
                        .background(i == selected ? skin.playlistColor("selectedbg", .blue) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { player.play(index: i) }
                        .onTapGesture { selected = i }
                        .id(i)
                    }
                }
            }
            .scrollIndicators(.never)
            .onChange(of: player.currentIndex) { _, i in if let i { withAnimation { proxy.scrollTo(i) } } }
        }
    }

    /// The tiled frame, and the running time in the bottom bar.
    private func frame(_ ctx: inout GraphicsContext, height h: CGFloat) {
        func put(_ x: Int, _ y: Int, _ w: Int, _ hh: Int, at px: CGFloat, _ py: CGFloat) {
            if let img = skin.sprite("pledit", x, y, w, hh) { ctx.draw(img, in: CGRect(x: px, y: py, width: CGFloat(w), height: CGFloat(hh))) }
        }
        put(0, 0, 25, 20, at: 0, 0)
        for x in stride(from: 25, to: 250, by: 25) { put(127, 0, 25, 20, at: CGFloat(x), 0) }
        put(26, 0, 100, 20, at: 87, 0)
        put(153, 0, 25, 20, at: 250, 0)
        for r in 0..<Self.rows {
            put(0, 42, 12, 29, at: 0, CGFloat(20 + r * 29))
            put(31, 42, 20, 29, at: 255, CGFloat(20 + r * 29))
        }
        put(0, 72, 125, 38, at: 0, h - 38)
        put(126, 72, 150, 38, at: 125, h - 38)
        let elapsed = player.queue.prefix(player.currentIndex ?? 0).reduce(0) { $0 + ($1.track.duration ?? 0) }
        drawText(&ctx, skin, "\(formatTime(elapsed))/\(formatTime(player.totalDuration))", 132, h - 28)
    }
}
