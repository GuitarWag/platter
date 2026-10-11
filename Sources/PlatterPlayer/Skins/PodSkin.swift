import SwiftUI
import AppKit
import PlatterCore

/// Colors of a pod skin.
enum PodPalette: Hashable {
    case chrome, ruby

    var key: String { self == .chrome ? "chrome" : "ruby" }

    var body: [Color] {
        switch self {
        case .chrome: return [Color(white: 0.94), Color(white: 0.62), Color(white: 0.86), Color(white: 0.48)]
        case .ruby: return [Color(red: 0.7, green: 0.07, blue: 0.1), Color(red: 0.3, green: 0.01, blue: 0.04),
                            Color(red: 0.55, green: 0.04, blue: 0.08), Color(red: 0.18, green: 0.0, blue: 0.02)]
        }
    }

    var edge: Color { self == .chrome ? Color(white: 0.25) : Color(red: 0.08, green: 0, blue: 0.01) }
    var lcd: [Color] {
        self == .chrome ? [Color(red: 0.66, green: 0.75, blue: 0.8), Color(red: 0.5, green: 0.6, blue: 0.66)]
                        : [Color(red: 0.14, green: 0.02, blue: 0.03), Color(red: 0.06, green: 0, blue: 0.01)]
    }
    var lcdInk: Color { self == .chrome ? Color(red: 0.05, green: 0.09, blue: 0.15) : Color(red: 1, green: 0.25, blue: 0.2) }
    var lcdDim: Color { lcdInk.opacity(0.5) }
    /// Unlit LCD segments.
    var ghost: Color { lcdInk.opacity(self == .chrome ? 0.09 : 0.12) }
    var button: [Color] {
        self == .chrome ? [Color(white: 0.98), Color(white: 0.58)]
                        : [Color(red: 0.8, green: 0.2, blue: 0.22), Color(red: 0.3, green: 0.02, blue: 0.05)]
    }
    var glyph: Color { self == .chrome ? Color(white: 0.15) : Color(red: 1, green: 0.88, blue: 0.85) }
    /// Rings, screws, and the knob: silver on Chrome, gold on Ruby.
    var trim: [Color] {
        self == .chrome ? [Color(white: 0.92), Color(white: 0.42)]
                        : [Color(red: 1, green: 0.86, blue: 0.5), Color(red: 0.42, green: 0.27, blue: 0.06)]
    }
    /// LEDs and the seek fill.
    var accent: Color { self == .chrome ? Color(red: 0.2, green: 0.78, blue: 1) : Color(red: 1, green: 0.7, blue: 0.2) }
    var engrave: Color { self == .chrome ? Color(white: 0.3) : Color(red: 0.12, green: 0, blue: 0.02) }
}

private let hubCenter = CGPoint(x: 111, y: 125)
private let lcdRect = CGRect(x: 176, y: 62, width: 228, height: 108)

private func disc(_ c: CGPoint, _ r: CGFloat) -> CGRect { CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2) }

/// The pod outline: a round hub on the left, a rounded body, and an "ear" for the volume
/// knob. One shape (a union), so the edge has no seams inside.
private struct PodShape: Shape {
    func path(in r: CGRect) -> Path {
        let hub = Path(ellipseIn: disc(hubCenter, 105))
        let body = Path(roundedRect: CGRect(x: 110, y: 44, width: 322, height: 176), cornerRadius: 52)
        let ear = Path(ellipseIn: disc(CGPoint(x: 405, y: 47), 33))
        return hub.union(body).union(ear)
    }
}

/// A futuristic freeform player in the style of the year-2000 skins: a brushed body with a
/// spun-metal hub for the transport, an LCD with time, spectrum, status, title, and the next
/// tracks, a seek groove, and a knurled volume knob. Original artwork, drawn in code.
struct PodSkinView: View {
    let model: PlayerAppModel
    let palette: PodPalette
    @ObservedObject private var player: PlayerState
    @AppStorage("player.skin") private var skinKey = "platter"

    init(model: PlayerAppModel, palette: PodPalette) {
        self.model = model
        self.palette = palette
        player = model.player
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Clicks on the artwork fall through to the drag area and move the window.
            WindowDragArea()
            PodChassis(palette: palette).allowsHitTesting(false)
            PodLED(on: player.isPlaying, palette: palette).position(x: 196, y: 52).allowsHitTesting(false)
            PodLCD(model: model, player: player, palette: palette)
                .frame(width: lcdRect.width, height: lcdRect.height)
                .position(x: lcdRect.midX, y: lcdRect.midY)
                .allowsHitTesting(false)
            hub.position(hubCenter)
            PodSeek(player: player, palette: palette).frame(width: 226, height: 16).position(x: 291, y: 186)
            PodKnob(value: $player.prefs.volume, palette: palette)
                .frame(width: 58, height: 58).position(x: 405, y: 47)
                .help("Volume")
            HStack(spacing: 5) {
                tiny("square.stack", "Full player (playlist, EQ, library)") { skinKey = "platter" }
                tiny("minus", "Minimize") { model.playerWindow?.miniaturize(nil) }
                tiny("xmark", "Close (keeps playing; reopen from the menu bar)") { model.playerWindow?.close() }
            }
            .position(x: 330, y: 52)
        }
        .frame(width: 444, height: 236)
        .onAppear { model.engine.playerViz.enabled = true }
    }

    // MARK: Hub

    private var hub: some View {
        ZStack {
            PodButton(system: player.isPlaying ? "pause.fill" : "play.fill", size: 66, palette: palette,
                      label: player.isPlaying ? "Pause" : "Play") { player.togglePlay() }
            ForEach(Array(arcButtons.enumerated()), id: \.offset) { _, b in
                PodButton(system: b.icon, size: 28, palette: palette, label: b.label, led: b.led, action: b.action)
                    .offset(x: 66 * cos(b.angle * .pi / 180), y: 66 * sin(b.angle * .pi / 180))
            }
        }
    }

    private var arcButtons: [(icon: String, label: String, angle: Double, led: Bool?, action: () -> Void)] {
        [
            ("backward.end.fill", "Previous", 180, nil, { player.previous() }),
            ("stop.fill", "Stop", 225, nil, { player.stop() }),
            ("forward.end.fill", "Next", 270, nil, { player.next() }),
            ("shuffle", "Shuffle", 135, player.prefs.shuffle, { player.prefs.shuffle.toggle() }),
            (player.prefs.repeatMode == .one ? "repeat.1" : "repeat", "Repeat", 90,
             player.prefs.repeatMode != .off, { player.prefs.repeatMode = player.prefs.repeatMode.next }),
        ]
    }

    private func tiny(_ system: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(LinearGradient(colors: palette.trim.reversed(), startPoint: .top, endPoint: .bottom))
                Circle().fill(LinearGradient(colors: palette.button, startPoint: .top, endPoint: .bottom)).padding(1.5)
                Engraved(Image(systemName: system).font(.system(size: 7, weight: .black)), color: palette.glyph)
            }
            .frame(width: 15, height: 15)
            .shadow(color: .black.opacity(0.4), radius: 1, y: 1)
        }
        .buttonStyle(PressableStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: Chassis

/// Everything that does not move: brushed body, spun hub, seams, perforations, screws,
/// vents, and engraving. Drawn once into one layer.
private struct PodChassis: View {
    let palette: PodPalette

    var body: some View {
        ZStack(alignment: .topLeading) {
            PodShape().fill(LinearGradient(colors: palette.body, startPoint: .topLeading, endPoint: .bottomTrailing))
            Canvas { ctx, size in brushing(&ctx, size) }
            // Spun-metal hub: a conic sheen over the circular brushing.
            Circle()
                .fill(AngularGradient(colors: [.white.opacity(0.5), .clear, .white.opacity(0.35), .clear,
                                               .white.opacity(0.45), .clear, .white.opacity(0.5)], center: .center))
                .blendMode(.overlay)
                .frame(width: 194, height: 194).position(hubCenter)
            // Top gloss, then the bevel (light top-left, dark bottom-right) and the rim.
            PodShape().fill(LinearGradient(colors: [.white.opacity(0.4), .clear], startPoint: .top, endPoint: .center))
            PodShape()
                .stroke(LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0.1), .black.opacity(0.55)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 6)
                .clipShape(PodShape())
            PodShape().stroke(palette.edge, lineWidth: 1.5)
            Canvas { ctx, _ in details(&ctx) }
            // LCD bezel: a recessed frame.
            RoundedRectangle(cornerRadius: 19)
                .fill(LinearGradient(colors: [.black.opacity(0.55), .white.opacity(0.45)], startPoint: .top, endPoint: .bottom))
                .frame(width: lcdRect.width + 10, height: lcdRect.height + 10)
                .position(x: lcdRect.midX, y: lcdRect.midY)
            engraving
        }
        .frame(width: 444, height: 236)
        .compositingGroup()
        .shadow(color: .black.opacity(0.5), radius: 7, y: 5)
        .drawingGroup()
    }

    /// Horizontal brushing on the body, circular brushing on the hub disc.
    private func brushing(_ ctx: inout GraphicsContext, _ size: CGSize) {
        var rng = SeededRandom("pod-brush")
        ctx.clip(to: PodShape().path(in: .zero))
        for y in stride(from: 0.0, to: size.height, by: 1) {
            let tone: Color = Bool.random(using: &rng) ? .white : .black
            ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 0.7)),
                     with: .color(tone.opacity(Double.random(in: 0...0.07, using: &rng))))
        }
        ctx.fill(Path(ellipseIn: disc(hubCenter, 97)),
                 with: .linearGradient(Gradient(colors: palette.body.reversed()),
                                       startPoint: CGPoint(x: 14, y: 28), endPoint: CGPoint(x: 208, y: 222)))
        for r in stride(from: 2.0, to: 97, by: 1.1) {
            let tone: Color = Bool.random(using: &rng) ? .white : .black
            ctx.stroke(Path(ellipseIn: disc(hubCenter, r)),
                       with: .color(tone.opacity(Double.random(in: 0...0.09, using: &rng))), lineWidth: 0.6)
        }
    }

    /// Seams, perforations, screws, and vents.
    private func details(_ ctx: inout GraphicsContext) {
        // The hub sits in a recess: dark lip on top, light lip below.
        ctx.stroke(Path(ellipseIn: disc(hubCenter, 98)),
                   with: .linearGradient(Gradient(colors: [.black.opacity(0.6), .white.opacity(0.7)]),
                                         startPoint: CGPoint(x: 0, y: 27), endPoint: CGPoint(x: 0, y: 223)), lineWidth: 2.5)
        // A ring of perforations.
        for i in 0..<48 {
            let a = Double(i) / 48 * 2 * .pi
            let p = CGPoint(x: hubCenter.x + 89 * cos(a), y: hubCenter.y + 89 * sin(a))
            ctx.fill(Path(ellipseIn: disc(CGPoint(x: p.x, y: p.y + 0.6), 1.7)), with: .color(.white.opacity(0.45)))
            ctx.fill(Path(ellipseIn: disc(p, 1.6)), with: .color(.black.opacity(0.6)))
        }
        // Panel seam along the bottom strip.
        var seam = Path()
        seam.move(to: CGPoint(x: 216, y: 197))
        seam.addLine(to: CGPoint(x: 410, y: 197))
        ctx.stroke(seam, with: .color(.black.opacity(0.35)), lineWidth: 1)
        ctx.stroke(seam.offsetBy(dx: 0, dy: 1), with: .color(.white.opacity(0.4)), lineWidth: 1)
        // Vents: slanted slots.
        for i in 0..<6 {
            let x = 372 + CGFloat(i) * 6
            var slot = Path(roundedRect: CGRect(x: -1.2, y: -7, width: 2.4, height: 14), cornerRadius: 1.2)
            slot = slot.applying(CGAffineTransform(rotationAngle: 0.35)).offsetBy(dx: x, dy: 208)
            ctx.fill(slot.offsetBy(dx: 0, dy: 0.8), with: .color(.white.opacity(0.4)))
            ctx.fill(slot, with: .color(.black.opacity(0.65)))
        }
        for p in [CGPoint(x: 419, y: 98), CGPoint(x: 419, y: 152), CGPoint(x: 223, y: 207)] { screw(&ctx, p) }
    }

    private func screw(_ ctx: inout GraphicsContext, _ p: CGPoint) {
        ctx.fill(Path(ellipseIn: disc(CGPoint(x: p.x, y: p.y + 0.8), 4.4)), with: .color(.white.opacity(0.5)))
        ctx.fill(Path(ellipseIn: disc(p, 4.2)), with: .color(.black.opacity(0.5)))
        ctx.fill(Path(ellipseIn: disc(p, 3.6)), with: .linearGradient(Gradient(colors: palette.trim),
                                                                         startPoint: CGPoint(x: p.x - 3, y: p.y - 3),
                                                                         endPoint: CGPoint(x: p.x + 3, y: p.y + 3)))
        for angle in [0.5, 0.5 + .pi / 2] {
            let slot = Path(CGRect(x: -2.8, y: -0.5, width: 5.6, height: 1))
                .applying(CGAffineTransform(rotationAngle: angle)).offsetBy(dx: p.x, dy: p.y)
            ctx.fill(slot, with: .color(.black.opacity(0.6)))
        }
    }

    private var engraving: some View {
        ZStack(alignment: .topLeading) {
            Engraved(Text("PLATTER").font(.system(size: 11, weight: .heavy, design: .rounded)).tracking(3.5),
                     color: palette.engrave)
                .position(x: 238, y: 52)
            Engraved(Text("P-2000  ·  DIGITAL AUDIO").font(.system(size: 6.5, weight: .bold)).tracking(1.4),
                     color: palette.engrave)
                .position(x: 298, y: 208)
        }
    }
}

/// Text or an icon cut into the metal: dark, with a light lip below.
private struct Engraved<Content: View>: View {
    let content: Content
    let color: Color

    init(_ content: Content, color: Color) {
        self.content = content
        self.color = color
    }

    var body: some View {
        ZStack {
            content.foregroundColor(.white.opacity(0.5)).offset(y: 0.8)
            content.foregroundColor(color)
        }
    }
}

/// A small round LED.
private struct PodLED: View {
    let on: Bool
    let palette: PodPalette

    var body: some View {
        Circle()
            .fill(on ? RadialGradient(colors: [.white, palette.accent], center: .init(x: 0.4, y: 0.35), startRadius: 0, endRadius: 3.5)
                     : RadialGradient(colors: [Color(white: 0.35), Color(white: 0.12)], center: .center, startRadius: 0, endRadius: 3.5))
            .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 0.6))
            .frame(width: 6, height: 6)
            .shadow(color: on ? palette.accent : .clear, radius: 3)
    }
}

// MARK: LCD

private struct PodLCD: View {
    let model: PlayerAppModel
    @ObservedObject var player: PlayerState
    let palette: PodPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 5) {
                Image(systemName: player.isPlaying ? "play.fill" : player.current != nil ? "pause.fill" : "stop.fill")
                    .font(.system(size: 8))
                    .foregroundColor(palette.lcdInk)
                    .frame(width: 9)
                TimelineView(.animation(minimumInterval: 0.25, paused: !player.isPlaying)) { t in
                    let _ = t.date
                    let s = max(0, Int(player.position))
                    ZStack(alignment: .leading) {
                        Text("88:88").foregroundColor(palette.ghost)
                        Text(String(format: "%02d:%02d", min(99, s / 60), s % 60)).foregroundColor(palette.lcdInk)
                    }
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                }
                Spacer(minLength: 2)
                PodSpectrum(model: model, player: player, palette: palette).frame(width: 82, height: 28)
            }
            HStack(spacing: 4) {
                chip(trackLabel, player.current != nil)
                chip("STEREO", player.isPlaying)
                chip("SHUF", player.prefs.shuffle)
                chip(player.prefs.repeatMode == .one ? "RPT 1" : "RPT", player.prefs.repeatMode != .off)
                chip("XF", player.prefs.crossfade > 0)
            }
            Marquee(text: titleText, color: palette.lcdInk, size: 11).frame(height: 15).padding(.leading, -6)
            Rectangle().fill(palette.lcdDim).frame(height: 0.7)
            ForEach(upcoming, id: \.offset) { item in
                Text(item.line)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(palette.lcdDim)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 14).fill(LinearGradient(colors: palette.lcd, startPoint: .top, endPoint: .bottom)))
        .overlay(glass)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.black.opacity(0.7), lineWidth: 1.5))
    }

    /// Pixel grid, a soft vignette, and glare across the top left.
    private var glass: some View {
        ZStack {
            Canvas { ctx, size in
                for y in stride(from: 0.0, to: size.height, by: 2) {
                    ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 0.6)), with: .color(.black.opacity(0.06)))
                }
                for x in stride(from: 0.0, to: size.width, by: 2) {
                    ctx.fill(Path(CGRect(x: x, y: 0, width: 0.5, height: size.height)), with: .color(.black.opacity(0.03)))
                }
            }
            RadialGradient(colors: [.clear, .black.opacity(0.25)], center: .center, startRadius: 60, endRadius: 150)
            LinearGradient(stops: [.init(color: .white.opacity(0.22), location: 0), .init(color: .white.opacity(0.06), location: 0.45),
                                   .init(color: .clear, location: 0.46)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .allowsHitTesting(false)
    }

    private func chip(_ text: String, _ lit: Bool) -> some View {
        Text(text)
            .font(.system(size: 6.5, weight: .heavy, design: .monospaced))
            .foregroundColor(lit ? palette.lcdInk : palette.ghost)
            .padding(.horizontal, 2.5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(lit ? palette.lcdInk : palette.ghost, lineWidth: 0.7))
    }

    private var trackLabel: String {
        guard let i = player.currentIndex else { return "TRK --/\(String(format: "%02d", player.queue.count))" }
        return String(format: "TRK %02d/%02d", i + 1, player.queue.count)
    }

    private var titleText: String {
        if let l = player.loadingTitle { return "Loading \(l)…" }
        guard let t = player.current else { return player.queue.isEmpty ? "PLATTER" : "\(player.queue.count) TRACKS" }
        return (t.artist.isEmpty ? "" : t.artist + " - ") + t.title
    }

    /// The next two tracks: "› 08 Daphne Descends".
    private var upcoming: [(offset: Int, line: String)] {
        guard !player.queue.isEmpty else { return [(0, "drop tracks in the full player")] }
        let start = (player.currentIndex ?? -1) + 1
        return (start..<min(start + 2, player.queue.count)).enumerated().map { k, i in
            (k, String(format: "› %02d %@", i + 1, player.queue[i].track.title))
        }
    }
}

/// LCD spectrum: 16 bars of 8 segments; unlit segments show faintly, the peak holds.
private struct PodSpectrum: View {
    let model: PlayerAppModel
    @ObservedObject var player: PlayerState
    let palette: PodPalette
    @State private var peaks = PeakHold()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !player.isPlaying)) { t in
            Canvas { ctx, size in
                _ = t.date
                let bars = player.isPlaying
                    ? Spectrum.bars(model.engine.playerViz.snapshot(Spectrum.fftSize), sampleRate: model.engine.playerVizRate, bands: 16)
                    : [Float](repeating: 0, count: 16)
                let held = peaks.update(bars)
                let w = size.width / 16, h = size.height / 8
                for i in 0..<16 {
                    let lit = Int((bars[i] * 8).rounded()), peak = Int((held[i] * 8).rounded())
                    for s in 0..<8 {
                        let r = CGRect(x: CGFloat(i) * w + 0.5, y: size.height - CGFloat(s + 1) * h + 0.5, width: w - 1.5, height: h - 1.2)
                        let on = s < lit || (s == peak - 1 && peak > 0)
                        ctx.fill(Path(r), with: .color(on ? palette.lcdInk : palette.ghost))
                    }
                }
            }
        }
    }
}

// MARK: Controls

/// A domed button in a metal bezel; `led` adds a status light above it.
private struct PodButton: View {
    let system: String
    let size: CGFloat
    let palette: PodPalette
    let label: String
    var led: Bool?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(LinearGradient(colors: palette.trim.reversed(), startPoint: .top, endPoint: .bottom))
                    .frame(width: size + 7, height: size + 7)
                Circle().fill(Color.black.opacity(0.5)).frame(width: size + 1.5, height: size + 1.5)
                Circle().fill(LinearGradient(colors: palette.button, startPoint: .top, endPoint: .bottom))
                    .frame(width: size, height: size)
                Circle().fill(RadialGradient(colors: [.white.opacity(0.75), .clear], center: UnitPoint(x: 0.36, y: 0.24),
                                             startRadius: 0, endRadius: size * 0.42))
                    .frame(width: size, height: size)
                Engraved(Image(systemName: system).font(.system(size: size * 0.34, weight: .heavy)), color: palette.glyph)
                if let led {
                    PodLED(on: led, palette: palette).scaleEffect(0.8).offset(y: -(size / 2 + 8))
                }
            }
            .frame(width: size + 7, height: size + 7)
            .shadow(color: .black.opacity(0.45), radius: size / 14, y: size / 18)
        }
        .buttonStyle(PressableStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The seek groove: drag the jewel to move through the track.
private struct PodSeek: View {
    @ObservedObject var player: PlayerState
    let palette: PodPalette
    @State private var dragging: Double?

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 0.25, paused: !player.isPlaying)) { t in
                let _ = t.date
                let frac = CGFloat(min(1, (dragging ?? player.position) / max(0.001, player.duration)))
                let x = frac * (geo.size.width - 14)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.55)).frame(height: 7)
                        .overlay(Capsule().stroke(LinearGradient(colors: [.black.opacity(0.6), .white.opacity(0.6)],
                                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1))
                    Capsule().fill(LinearGradient(colors: [palette.accent.opacity(0.6), palette.accent], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, x + 7), height: 3)
                        .padding(.leading, 2)
                        .shadow(color: palette.accent, radius: 3)
                    ZStack {
                        Circle().fill(LinearGradient(colors: palette.trim, startPoint: .top, endPoint: .bottom))
                        Circle().stroke(palette.edge, lineWidth: 0.8)
                        Circle().fill(RadialGradient(colors: [.white, palette.accent, palette.accent.opacity(0.4)],
                                                     center: .init(x: 0.4, y: 0.35), startRadius: 0, endRadius: 4))
                            .frame(width: 7, height: 7)
                            .shadow(color: player.current != nil ? palette.accent : .clear, radius: 2)
                    }
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.5), radius: 1.5, y: 1)
                    .offset(x: x)
                }
                .frame(maxHeight: .infinity)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in dragging = Double(min(1, max(0, v.location.x / geo.size.width))) * player.duration }
                .onEnded { _ in
                    if let d = dragging { player.seek(to: d) }
                    dragging = nil
                })
        }
        .accessibilityLabel("Position")
    }
}

/// A knurled rotary knob with a scale, 0 ... 1. Drag up or down.
private struct PodKnob: View {
    @Binding var value: Double
    let palette: PodPalette
    @State private var start: Double?

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height), r = side / 2 - 9
            ZStack {
                Canvas { ctx, size in
                    let c = CGPoint(x: size.width / 2, y: size.height / 2)
                    // Scale: 11 ticks from -135° to +135°.
                    for i in 0...10 {
                        let a = (-135 + 27 * Double(i) - 90) * .pi / 180
                        var tick = Path()
                        tick.move(to: CGPoint(x: c.x + (r + 3) * cos(a), y: c.y + (r + 3) * sin(a)))
                        tick.addLine(to: CGPoint(x: c.x + (r + (i % 5 == 0 ? 8 : 6)) * cos(a), y: c.y + (r + (i % 5 == 0 ? 8 : 6)) * sin(a)))
                        ctx.stroke(tick, with: .color(palette.engrave.opacity(0.8)), lineWidth: 1)
                    }
                    // Knurled edge.
                    ctx.fill(Path(ellipseIn: disc(c, r)), with: .linearGradient(Gradient(colors: palette.trim),
                                                                                  startPoint: CGPoint(x: c.x, y: c.y - r), endPoint: CGPoint(x: c.x, y: c.y + r)))
                    for i in 0..<40 {
                        let a = Double(i) / 40 * 2 * .pi
                        var line = Path()
                        line.move(to: CGPoint(x: c.x + (r - 3) * cos(a), y: c.y + (r - 3) * sin(a)))
                        line.addLine(to: CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a)))
                        ctx.stroke(line, with: .color(.black.opacity(0.35)), lineWidth: 0.8)
                    }
                    ctx.stroke(Path(ellipseIn: disc(c, r)), with: .color(palette.edge), lineWidth: 1)
                }
                Circle()
                    .fill(AngularGradient(colors: [palette.trim[0], palette.trim[1], palette.trim[0], palette.trim[1], palette.trim[0]],
                                          center: .center))
                    .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 0.8))
                    .frame(width: (r - 4) * 2, height: (r - 4) * 2)
                PodLED(on: true, palette: palette).scaleEffect(0.7)
                    .offset(y: -(r - 9))
                    .rotationEffect(.degrees(-135 + 270 * value))
            }
            .frame(width: side, height: side)
        }
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                if start == nil { start = value }
                value = min(1, max(0, (start ?? 0) - Double(g.translation.height) / 120))
            }
            .onEnded { _ in start = nil })
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(value * 100))%")
        .accessibilityAdjustableAction { d in value = min(1, max(0, value + (d == .increment ? 0.05 : -0.05))) }
    }
}

/// A view that lets the window move when its area is dragged (for frameless skins).
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
