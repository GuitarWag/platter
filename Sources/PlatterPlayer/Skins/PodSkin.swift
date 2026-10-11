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
        case .ruby: return [Color(red: 0.62, green: 0.08, blue: 0.1), Color(red: 0.25, green: 0.02, blue: 0.04),
                            Color(red: 0.5, green: 0.05, blue: 0.08), Color(red: 0.16, green: 0.0, blue: 0.02)]
        }
    }

    var edge: Color { self == .chrome ? Color(white: 0.28) : Color(red: 0.08, green: 0, blue: 0.01) }
    var lcd: Color { self == .chrome ? Color(red: 0.62, green: 0.7, blue: 0.74) : Color(red: 0.12, green: 0.01, blue: 0.02) }
    var lcdInk: Color { self == .chrome ? Color(red: 0.06, green: 0.1, blue: 0.16) : Color(red: 1, green: 0.22, blue: 0.2) }
    var lcdDim: Color { lcdInk.opacity(0.45) }
    var button: [Color] {
        self == .chrome ? [Color(white: 0.98), Color(white: 0.6)]
                        : [Color(red: 0.75, green: 0.18, blue: 0.2), Color(red: 0.3, green: 0.02, blue: 0.05)]
    }
    var glyph: Color { self == .chrome ? Color(white: 0.15) : Color(red: 1, green: 0.85, blue: 0.85) }
}

/// The pod outline: a round hub on the left, a rounded body, and an "ear" for the volume
/// knob. One shape (a union), so the edge has no seams inside.
private struct PodShape: Shape {
    func path(in r: CGRect) -> Path {
        let hub = Path(ellipseIn: CGRect(x: 6, y: 20, width: 210, height: 210))
        let body = Path(roundedRect: CGRect(x: 110, y: 44, width: 322, height: 176), cornerRadius: 52)
        let ear = Path(ellipseIn: CGRect(x: 372, y: 14, width: 66, height: 66))
        return hub.union(body).union(ear)
    }
}

/// A futuristic freeform player in the style of the year-2000 skins: chrome (or ruby)
/// body, a round hub with the transport, an LCD with time, spectrum, title, and the next
/// tracks, a seek groove, and a volume knob. Original artwork, drawn in code.
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
            // Clicks on the body fall through the artwork to the drag area and move the window.
            WindowDragArea()
            // Body: brushed gradient, a specular highlight on the top half, a dark edge.
            PodShape()
                .fill(LinearGradient(colors: palette.body, startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(PodShape().fill(LinearGradient(colors: [.white.opacity(0.45), .clear],
                                                        startPoint: .top, endPoint: .center)))
                .overlay(PodShape().stroke(palette.edge, lineWidth: 2))
                .shadow(color: .black.opacity(0.5), radius: 8, y: 5)
                .allowsHitTesting(false)

            hub.position(x: 111, y: 125)
            lcd.allowsHitTesting(false).frame(width: 238, height: 118).position(x: 297, y: 120)
            PodSeek(player: player, palette: palette).frame(width: 232, height: 18).position(x: 297, y: 198)
            PodKnob(value: $player.prefs.volume, palette: palette)
                .frame(width: 46, height: 46).position(x: 405, y: 47)
                .help("Volume")
            HStack(spacing: 6) {
                tiny("square.stack", "Full player (playlist, EQ, library)") { skinKey = "platter" }
                tiny("minus", "Minimize") { model.playerWindow?.miniaturize(nil) }
                tiny("xmark", "Close (keeps playing; reopen from the menu bar)") { model.playerWindow?.close() }
            }
            .position(x: 302, y: 49)
        }
        .frame(width: 444, height: 236)
    }

    // MARK: Hub

    private var hub: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [palette.edge.opacity(0.0), palette.edge.opacity(0.35)],
                                         center: .center, startRadius: 40, endRadius: 96))
                .frame(width: 190, height: 190)
            PodButton(system: player.isPlaying ? "pause.fill" : "play.fill", size: 70, palette: palette,
                      label: player.isPlaying ? "Pause" : "Play") { player.togglePlay() }
            ForEach(Array(arcButtons.enumerated()), id: \.offset) { _, b in
                PodButton(system: b.icon, size: 30, palette: palette, label: b.label, lit: b.lit, action: b.action)
                    .offset(x: 66 * cos(b.angle * .pi / 180), y: 66 * sin(b.angle * .pi / 180))
            }
        }
    }

    private var arcButtons: [(icon: String, label: String, angle: Double, lit: Bool, action: () -> Void)] {
        [
            ("backward.end.fill", "Previous", 180, false, { player.previous() }),
            ("stop.fill", "Stop", 225, false, { player.stop() }),
            ("forward.end.fill", "Next", 270, false, { player.next() }),
            ("shuffle", "Shuffle", 135, player.prefs.shuffle, { player.prefs.shuffle.toggle() }),
            (player.prefs.repeatMode == .one ? "repeat.1" : "repeat", "Repeat", 90,
             player.prefs.repeatMode != .off, { player.prefs.repeatMode = player.prefs.repeatMode.next }),
        ]
    }

    // MARK: LCD

    private var lcd: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top) {
                TimelineView(.animation(minimumInterval: 0.25, paused: !player.isPlaying)) { t in
                    Canvas { ctx, size in
                        _ = t.date // redraw on each tick
                        let s = max(0, Int(player.position))
                        ctx.draw(Text(String(format: "%02d:%02d", s / 60, s % 60))
                                    .font(.system(size: 30, weight: .bold, design: .monospaced))
                                    .foregroundColor(palette.lcdInk),
                                 at: CGPoint(x: 0, y: size.height / 2), anchor: .leading)
                    }
                }
                .frame(width: 104, height: 34)
                Spacer(minLength: 4)
                Visualizer(player: player, engine: model.engine)
                    .frame(width: 104, height: 30)
                    .colorMultiply(palette == .chrome ? Color(white: 0.35) : .white)
            }
            Marquee(text: titleText, color: palette.lcdInk, size: 11).frame(height: 15)
            Rectangle().fill(palette.lcdDim).frame(height: 1)
            ForEach(upcoming, id: \.offset) { item in
                Text(item.line)
                    .font(.system(size: 9.5, weight: item.current ? .bold : .regular, design: .monospaced))
                    .foregroundColor(item.current ? palette.lcdInk : palette.lcdDim)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 16).fill(palette.lcd)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.black.opacity(0.55), lineWidth: 2))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.35), lineWidth: 1).padding(2))
        )
    }

    private var titleText: String {
        if let l = player.loadingTitle { return "Loading \(l)…" }
        guard let t = player.current else { return player.queue.isEmpty ? "PLATTER" : "\(player.queue.count) TRACKS" }
        return (t.artist.isEmpty ? "" : t.artist + " - ") + t.title
    }

    /// The current track and the next two: "07 Daphne Descends".
    private var upcoming: [(offset: Int, line: String, current: Bool)] {
        guard !player.queue.isEmpty else { return [(0, "drop tracks in the full player", false)] }
        let start = player.currentIndex ?? 0
        return (0..<min(3, player.queue.count - start)).map { k in
            let i = start + k
            return (k, String(format: "%02d %@", i + 1, player.queue[i].track.title), k == 0 && player.currentIndex != nil)
        }
    }

    private func tiny(_ system: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(palette.glyph)
                .frame(width: 16, height: 16)
                .background(Circle().fill(LinearGradient(colors: palette.button, startPoint: .top, endPoint: .bottom)))
                .overlay(Circle().stroke(palette.edge, lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A domed round button.
private struct PodButton: View {
    let system: String
    let size: CGFloat
    let palette: PodPalette
    let label: String
    var lit = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(LinearGradient(colors: palette.button, startPoint: .top, endPoint: .bottom))
                Circle().fill(RadialGradient(colors: [.white.opacity(0.7), .clear], center: UnitPoint(x: 0.35, y: 0.25),
                                             startRadius: 0, endRadius: size * 0.45))
                Circle().stroke(palette.edge, lineWidth: max(1, size / 30))
                Image(systemName: system)
                    .font(.system(size: size * 0.36, weight: .bold))
                    .foregroundColor(lit ? palette.lcdInk : palette.glyph)
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.45), radius: size / 14, y: size / 18)
        }
        .buttonStyle(PressableStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The seek groove: drag the bead to move through the track.
private struct PodSeek: View {
    @ObservedObject var player: PlayerState
    let palette: PodPalette
    @State private var dragging: Double?

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 0.25, paused: !player.isPlaying)) { t in
                let _ = t.date
                let frac = CGFloat((dragging ?? player.position) / max(0.001, player.duration))
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.edge.opacity(0.6)).frame(height: 6)
                    Capsule().fill(palette.lcdInk.opacity(0.7)).frame(width: max(0, frac * geo.size.width), height: 6)
                    Circle().fill(LinearGradient(colors: palette.button, startPoint: .top, endPoint: .bottom))
                        .overlay(Circle().stroke(palette.edge, lineWidth: 1))
                        .frame(width: 16, height: 16)
                        .offset(x: min(geo.size.width - 16, max(0, frac * geo.size.width - 8)))
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

/// A rotary knob, 0 ... 1. Drag up or down.
private struct PodKnob: View {
    @Binding var value: Double
    let palette: PodPalette
    @State private var start: Double?

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: palette.button, startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().stroke(palette.edge, lineWidth: 1.5)
            Capsule().fill(palette.lcdInk).frame(width: 3, height: 12).offset(y: -12)
                .rotationEffect(.degrees(-135 + 270 * value))
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
