import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import PlatterCore

private enum LCD {
    static let green = Color(red: 0.35, green: 1.0, blue: 0.45)
    static let dim = Color(red: 0.2, green: 0.55, blue: 0.25)
    static let screen = Color(red: 0.02, green: 0.05, blue: 0.03)
    static let body = LinearGradient(colors: [Color(white: 0.24), Color(white: 0.14)], startPoint: .top, endPoint: .bottom)
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// The music player window: a main panel, an EQ panel, and a playlist, stacked and docked
/// like a classic desktop player. Each can be shown or hidden; "shade" folds the window into
/// one bar.
struct PlayerWindowView: View {
    let model: PlayerAppModel
    @ObservedObject private var player: PlayerState
    @AppStorage("player.showEQ") private var showEQ = true
    @AppStorage("player.showPlaylist") private var showPlaylist = true
    @AppStorage("player.shade") private var shade = false
    @AppStorage("player.showLibrary") private var showLibrary = false

    init(model: PlayerAppModel) {
        self.model = model
        player = model.player
    }

    var body: some View {
        VStack(spacing: 0) {
            if shade {
                ShadeBar(player: player, shade: $shade)
            } else {
                MainPanel(player: player, engine: model.engine, showEQ: $showEQ, showPlaylist: $showPlaylist,
                          showLibrary: $showLibrary, shade: $shade)
                if showEQ { EQPanel(player: player) }
                if showLibrary { LibraryPanel(model: model) }
                if showPlaylist { PlaylistPanel(model: model, player: player) }
            }
        }
        .frame(width: 560)
        .frame(minHeight: shade ? 34 : nil, maxHeight: (showPlaylist || showLibrary) && !shade ? .infinity : nil)
        .fixedSize(horizontal: false, vertical: !(showPlaylist || showLibrary) || shade)
        .background(Color(white: 0.1))
        .background(WindowAccessor { model.playerWindow = $0 })
        .preferredColorScheme(.dark)
    }
}

// MARK: Main panel

private struct MainPanel: View {
    @ObservedObject var player: PlayerState
    let engine: AudioEngine
    @Binding var showEQ: Bool
    @Binding var showPlaylist: Bool
    @Binding var showLibrary: Bool
    @Binding var shade: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                TimeScreen(player: player, engine: engine)
                VStack(alignment: .leading, spacing: 6) {
                    Marquee(text: titleText)
                        .frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 3).fill(LCD.screen))
                    FormatLine(player: player)
                    HStack(spacing: 10) {
                        LabeledSlider(label: "VOL", value: $player.prefs.volume, range: 0...1, center: nil)
                            .accessibilityLabel("Volume")
                        LabeledSlider(label: "BAL", value: $player.prefs.balance, range: -1...1, center: 0)
                            .accessibilityLabel("Balance")
                    }
                }
            }
            SeekBar(player: player)
            HStack(spacing: 4) {
                TransportButton(system: "backward.end.fill", label: "Previous") { player.previous() }
                TransportButton(system: player.isPlaying ? "pause.fill" : "play.fill",
                                label: player.isPlaying ? "Pause" : "Play") { player.togglePlay() }
                TransportButton(system: "stop.fill", label: "Stop") { player.stop() }
                TransportButton(system: "forward.end.fill", label: "Next") { player.next() }
                Spacer(minLength: 8)
                Toggle(isOn: $player.prefs.shuffle) { Image(systemName: "shuffle") }
                    .toggleStyle(.button).controlSize(.small).help("Shuffle")
                    .accessibilityLabel("Shuffle")
                Button { player.prefs.repeatMode = player.prefs.repeatMode.next } label: {
                    Image(systemName: player.prefs.repeatMode == .one ? "repeat.1" : "repeat")
                        .foregroundColor(player.prefs.repeatMode == .off ? .secondary : LCD.green)
                }
                .controlSize(.small)
                .help("Repeat: \(player.prefs.repeatMode.rawValue)")
                .accessibilityLabel("Repeat \(player.prefs.repeatMode.rawValue)")
                Menu {
                    ForEach([0.0, 2, 4, 6, 8, 12], id: \.self) { s in
                        Button(s == 0 ? "Gapless (no crossfade)" : "Crossfade \(Int(s)) s") { player.prefs.crossfade = s }
                    }
                    Divider()
                    Toggle("Level volume between tracks", isOn: $player.prefs.leveling)
                    Toggle("Pause the other app when one starts", isOn: $player.prefs.exclusive)
                } label: {
                    Text(player.prefs.crossfade == 0 ? "GAPLESS" : "XF \(Int(player.prefs.crossfade))s")
                        .font(LCD.mono(10, .bold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Crossfade, volume leveling, and DJ deck options")
                Toggle("EQ", isOn: $showEQ).toggleStyle(.button).controlSize(.small).help("Show the equalizer")
                Toggle("LIB", isOn: $showLibrary).toggleStyle(.button).controlSize(.small).help("Browse albums and artists")
                Toggle("PL", isOn: $showPlaylist).toggleStyle(.button).controlSize(.small).help("Show the playlist")
                Button { shade = true } label: { Image(systemName: "rectangle.compress.vertical") }
                    .controlSize(.small).help("Shade: fold into one bar")
                    .accessibilityLabel("Shade mode")
            }
        }
        .padding(10)
        .background(LCD.body)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black).frame(height: 1) }
    }

    private var titleText: String {
        if let l = player.loadingTitle { return "Loading \(l)…" }
        guard let t = player.current, let i = player.currentIndex else {
            return player.queue.isEmpty ? "Platter — add tracks to the playlist" : "\(player.queue.count) tracks — press play"
        }
        return "\(i + 1). \(t.artist.isEmpty ? "" : t.artist + " - ")\(t.title) (\(formatTime(t.duration ?? 0)))"
    }
}

/// The big time display and the visualizer.
private struct TimeScreen: View {
    @ObservedObject var player: PlayerState
    let engine: AudioEngine
    @AppStorage("player.showRemaining") private var remaining = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: player.isPlaying ? "play.fill" : player.current == nil ? "stop.fill" : "pause.fill")
                    .font(.system(size: 10))
                    .foregroundColor(LCD.green)
                TimelineView(.animation(minimumInterval: 0.25, paused: !player.isPlaying)) { timeline in
                    // A Canvas, so the ticking digits never trigger a layout pass.
                    Canvas { ctx, size in
                        _ = timeline.date // redraw on each tick (see ZoomWaveform)
                        let t = remaining ? player.duration - player.position : player.position
                        let s = max(0, Int(t))
                        let text = (remaining ? "-" : " ") + String(format: "%02d:%02d", s / 60, s % 60)
                        ctx.draw(Text(text).font(LCD.mono(34, .bold)).foregroundColor(LCD.green),
                                 at: CGPoint(x: size.width, y: size.height / 2), anchor: .trailing)
                    }
                }
                .frame(width: 130, height: 40)
                .onTapGesture { remaining.toggle() }
                .help("Click for elapsed or remaining time")
            }
            Visualizer(player: player, engine: engine)
                .frame(width: 150, height: 34)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 4).fill(LCD.screen))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.black, lineWidth: 1))
    }
}

/// Spectrum bars with peak hold, or an oscilloscope. Click to change: spectrum, scope, off.
struct Visualizer: View {
    @ObservedObject var player: PlayerState
    let engine: AudioEngine
    @AppStorage("player.visualizer") private var mode = 0 // 0 spectrum, 1 scope, 2 off
    @State private var peaks = PeakHold()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !player.isPlaying || mode == 2)) { ctx in
            frame(ctx.date).drawingGroup()
        }
        .background(Color.black.opacity(0.3))
        .contentShape(Rectangle())
        .onTapGesture { mode = (mode + 1) % 3 }
        .onAppear { engine.playerViz.enabled = mode != 2 }
        .onChange(of: mode) { _, m in engine.playerViz.enabled = m != 2 }
        .help("Click: spectrum, oscilloscope, or off")
        .accessibilityLabel("Visualizer")
    }

    /// `date` is read in the drawing, so each tick is a new view value and SwiftUI redraws
    /// (see ZoomWaveform).
    private func frame(_ date: Date) -> some View {
            Canvas { ctx, size in
                _ = date
                switch mode {
                case 0:
                    let bars = Spectrum.bars(engine.playerViz.snapshot(Spectrum.fftSize), sampleRate: engine.playerVizRate)
                    let held = peaks.update(bars)
                    let w = size.width / CGFloat(bars.count)
                    for (i, v) in bars.enumerated() {
                        let h = CGFloat(player.isPlaying ? v : 0) * size.height
                        let x = CGFloat(i) * w
                        ctx.fill(Path(CGRect(x: x + 1, y: size.height - h, width: w - 2, height: h)),
                                 with: .linearGradient(Gradient(colors: [LCD.green, Color.yellow, Color.orange]),
                                                       startPoint: CGPoint(x: 0, y: size.height), endPoint: CGPoint(x: 0, y: 0)))
                        guard held[i] > 0.01 else { continue }
                        let py = size.height - CGFloat(held[i]) * size.height
                        ctx.fill(Path(CGRect(x: x + 1, y: py - 1, width: w - 2, height: 1.5)), with: .color(.white.opacity(0.8)))
                    }
                case 1:
                    let s = engine.playerViz.snapshot(Int(engine.playerVizRate * 0.02))
                    var path = Path()
                    for (i, v) in s.enumerated() {
                        let p = CGPoint(x: CGFloat(i) / CGFloat(max(1, s.count - 1)) * size.width,
                                        y: size.height / 2 - CGFloat(v) * size.height / 2)
                        i == 0 ? path.move(to: p) : path.addLine(to: p)
                    }
                    ctx.stroke(path, with: .color(LCD.green), lineWidth: 1)
                default:
                    break
                }
            }
    }
}

/// Peak markers that hold, then fall at a steady rate.
final class PeakHold {
    private var values: [Float] = []

    func update(_ bars: [Float]) -> [Float] {
        if values.count != bars.count { values = bars }
        for i in bars.indices { values[i] = max(bars[i], values[i] - 0.012) }
        return values
    }
}

private struct FormatLine: View {
    @ObservedObject var player: PlayerState
    @State private var info = ""

    var body: some View {
        Text(info)
            .font(LCD.mono(10))
            .foregroundColor(LCD.dim)
            .task(id: player.player.url) { info = Self.describe(player.player.url) }
    }

    /// "48 kHz · stereo · 256 kbps".
    static func describe(_ url: URL?) -> String {
        guard let url, let f = try? AVAudioFile(forReading: url) else { return " " }
        let sr = f.fileFormat.sampleRate, ch = f.fileFormat.channelCount
        let seconds = Double(f.length) / sr
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
        let kbps = seconds > 0 ? Int(Double(bytes) * 8 / seconds / 1000) : 0
        return String(format: "%.0f kHz · %@ · %d kbps", sr / 1000, ch == 1 ? "mono" : "stereo", kbps)
    }
}

private struct Marquee: View {
    let text: String

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { ctx in
                Canvas { g, size in
                    let resolved = g.resolve(Text(text).font(LCD.mono(12)).foregroundColor(LCD.green))
                    let w = resolved.measure(in: CGSize(width: 10_000, height: size.height)).width
                    if w <= size.width - 8 {
                        g.draw(resolved, at: CGPoint(x: 6, y: size.height / 2), anchor: .leading)
                    } else {
                        // Scroll at 30 pt/s with a gap, like a car stereo.
                        let loop = w + 60
                        let x = CGFloat(ctx.date.timeIntervalSinceReferenceDate * 30).truncatingRemainder(dividingBy: loop)
                        g.draw(resolved, at: CGPoint(x: 6 - x, y: size.height / 2), anchor: .leading)
                        g.draw(resolved, at: CGPoint(x: 6 - x + loop, y: size.height / 2), anchor: .leading)
                    }
                }
            }
            .frame(width: geo.size.width)
        }
        .clipped()
        .accessibilityLabel(text)
    }
}

private struct SeekBar: View {
    @ObservedObject var player: PlayerState
    @State private var dragging: Double?

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 0.25, paused: !player.isPlaying)) { _ in
                let dur = max(0.001, player.duration)
                let frac = CGFloat((dragging ?? player.position) / dur)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black).frame(height: 6)
                    Capsule().fill(LCD.green.opacity(0.7)).frame(width: max(0, frac * geo.size.width), height: 6)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: [Color(white: 0.85), Color(white: 0.5)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 22, height: 12)
                        .offset(x: min(geo.size.width - 22, max(0, frac * geo.size.width - 11)))
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
        .frame(height: 16)
        .accessibilityLabel("Position")
        .accessibilityValue(formatTime(player.position))
    }
}

private struct TransportButton: View {
    let system: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 12))
                .frame(width: 34, height: 22)
                .background(RoundedRectangle(cornerRadius: 3).fill(
                    LinearGradient(colors: [Color(white: 0.42), Color(white: 0.24)], startPoint: .top, endPoint: .bottom)))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.black.opacity(0.6)))
        }
        .buttonStyle(PressableStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let center: Double?

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(LCD.mono(9, .bold)).foregroundColor(.secondary)
            Slider(value: $value, in: range)
                .controlSize(.mini)
                .onTapGesture(count: 2) { if let center { value = center } }
        }
    }
}

// MARK: Shade bar

private struct ShadeBar: View {
    @ObservedObject var player: PlayerState
    @Binding var shade: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button { player.previous() } label: { Image(systemName: "backward.end.fill") }.accessibilityLabel("Previous")
            Button { player.togglePlay() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill") }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Button { player.next() } label: { Image(systemName: "forward.end.fill") }.accessibilityLabel("Next")
            Marquee(text: player.current.map { "\($0.artist.isEmpty ? "" : $0.artist + " - ")\($0.title)" } ?? "Platter")
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 3).fill(LCD.screen))
            TimelineView(.animation(minimumInterval: 0.5, paused: !player.isPlaying)) { _ in
                Text(formatTime(player.position)).font(LCD.mono(11, .bold)).foregroundColor(LCD.green)
                    .frame(width: 48, height: 20)
                    .background(RoundedRectangle(cornerRadius: 3).fill(LCD.screen))
            }
            Button { shade = false } label: { Image(systemName: "rectangle.expand.vertical") }
                .help("Unfold").accessibilityLabel("Leave shade mode")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(LCD.body)
    }
}

// MARK: EQ panel

private struct EQPanel: View {
    @ObservedObject var player: PlayerState

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Button { player.prefs.eqOn.toggle() } label: {
                    Text("ON").font(LCD.mono(11, .bold))
                        .foregroundColor(player.prefs.eqOn ? .black : .secondary)
                        .frame(width: 40, height: 20)
                        .background(RoundedRectangle(cornerRadius: 3).fill(player.prefs.eqOn ? LCD.green : Color(white: 0.3)))
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Equalizer")
                .accessibilityValue(player.prefs.eqOn ? "on" : "off")
                Menu("Presets") {
                    ForEach(PlayerEQ.presets, id: \.name) { p in
                        Button(p.name) { player.prefs.eqGains = p.gains }
                    }
                    Divider()
                    Button("Reset") { player.prefs.eqGains = PlayerEQ.presets[0].gains; player.prefs.preamp = 0 }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .controlSize(.small)
                EQResponse(gains: player.prefs.eqGains, preamp: player.prefs.preamp, on: player.prefs.eqOn)
                    .frame(width: 96, height: 44)
                    .background(RoundedRectangle(cornerRadius: 3).fill(LCD.screen))
            }
            BandSlider(label: "PRE", value: $player.prefs.preamp)
            Rectangle().fill(Color.black.opacity(0.5)).frame(width: 1)
            ForEach(PlayerEQ.labels.indices, id: \.self) { i in
                BandSlider(label: PlayerEQ.labels[i], value: Binding(
                    get: { player.prefs.eqGains[i] },
                    set: { player.prefs.eqGains[i] = $0 }))
            }
        }
        .padding(10)
        .frame(height: 140)
        .background(LCD.body)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black).frame(height: 1) }
        .opacity(player.prefs.eqOn ? 1 : 0.75)
    }
}

/// A vertical ±12 dB slider; it clicks at 0 and double-click resets.
private struct BandSlider: View {
    let label: String
    @Binding var value: Double
    @State private var dragStart: Double?

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                let h = geo.size.height, knob: CGFloat = 10
                let y = (1 - CGFloat((value + 12) / 24)) * (h - knob)
                ZStack(alignment: .top) {
                    Capsule().fill(Color.black).frame(width: 4)
                    Rectangle().fill(Color.white.opacity(0.25)).frame(width: 12, height: 1).offset(y: h / 2)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: [LCD.green, LCD.dim], startPoint: .top, endPoint: .bottom))
                        .frame(width: 18, height: knob)
                        .offset(y: y)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragStart == nil { dragStart = value }
                        var v = (dragStart ?? 0) - Double(g.translation.height / (h - knob)) * 24
                        v = min(12, max(-12, v))
                        if abs(v) < 0.6 { v = 0 }
                        value = (v * 2).rounded() / 2
                    }
                    .onEnded { _ in dragStart = nil })
                .onTapGesture(count: 2) { value = 0 }
            }
            Text(label).font(LCD.mono(8, .bold)).foregroundColor(.secondary)
        }
        .frame(width: 26)
        .accessibilityElement()
        .accessibilityLabel("\(label) band")
        .accessibilityValue(String(format: "%+.1f dB", value))
        .accessibilityAdjustableAction { dir in value = min(12, max(-12, value + (dir == .increment ? 1 : -1))) }
    }
}

/// The EQ curve: the sum of each band's peaking-filter response (RBJ biquad), plus preamp.
private struct EQResponse: View {
    let gains: [Double]
    let preamp: Double
    let on: Bool

    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            for px in stride(from: 0, through: size.width, by: 2) {
                let f = 20 * pow(1000, Double(px / size.width)) // 20 Hz ... 20 kHz
                var db = preamp
                for (g, fc) in zip(gains, PlayerEQ.frequencies) where g != 0 {
                    db += Self.peakResponse(f: f, fc: Double(fc), gain: g)
                }
                let y = size.height / 2 - CGFloat(db / 18) * size.height / 2
                px == 0 ? path.move(to: CGPoint(x: px, y: y)) : path.addLine(to: CGPoint(x: px, y: y))
            }
            ctx.stroke(Path { p in p.move(to: CGPoint(x: 0, y: size.height / 2)); p.addLine(to: CGPoint(x: size.width, y: size.height / 2)) },
                       with: .color(LCD.dim.opacity(0.4)), lineWidth: 0.5)
            ctx.stroke(path, with: .color(on ? LCD.green : LCD.dim), lineWidth: 1.2)
        }
    }

    /// Magnitude (dB) of a one-octave peaking EQ at `fc` and `gain` dB, at `f`, for 44.1 kHz.
    static func peakResponse(f: Double, fc: Double, gain: Double, sr: Double = 44_100) -> Double {
        let a = pow(10, gain / 40), w0 = 2 * Double.pi * fc / sr
        let alpha = sin(w0) * sinh(log(2) / 2 * 1 * w0 / sin(w0))
        let b0 = 1 + alpha * a, b1 = -2 * cos(w0), b2 = 1 - alpha * a
        let a0 = 1 + alpha / a, a1 = -2 * cos(w0), a2 = 1 - alpha / a
        let w = 2 * Double.pi * f / sr
        func mag(_ c0: Double, _ c1: Double, _ c2: Double) -> Double {
            let re = c0 + c1 * cos(w) + c2 * cos(2 * w), im = -(c1 * sin(w) + c2 * sin(2 * w))
            return (re * re + im * im).squareRoot()
        }
        return 20 * log10(mag(b0, b1, b2) / mag(a0, a1, a2))
    }
}

// MARK: Playlist

private struct PlaylistPanel: View {
    let model: PlayerAppModel
    @ObservedObject var player: PlayerState
    @ObservedObject private var library: Library
    @State private var search = ""
    @State private var selection: Set<QueueEntry.ID> = []
    @State private var askingURL = false
    @State private var urlDraft = ""

    init(model: PlayerAppModel, player: PlayerState) {
        self.model = model
        self.player = player
        library = model.library
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Find in playlist", text: $search).textFieldStyle(.plain).font(.system(size: 11))
                Spacer()
                Text("\(player.queue.count) tracks · \(formatTime(player.totalDuration))")
                    .font(LCD.mono(10)).foregroundColor(LCD.dim)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color(white: 0.13))
            List(selection: $selection) {
                ForEach(rows, id: \.entry.id) { row in
                    let i = row.index, entry = row.entry
                    PlaylistRow(number: i + 1, entry: entry, isCurrent: i == player.currentIndex,
                                isPlaying: player.isPlaying)
                        .tag(entry.id)
                        .onTapGesture(count: 2) { player.play(index: i) }
                        .contextMenu {
                            Button("Play") { player.play(index: i) }
                            Button("Remove") { player.remove(at: IndexSet(integer: i)) }
                            RatingMenu(rating: entry.track.rating) { library.setRating(entry.track, $0) }
                        }
                }
                .onMove(perform: moveRows)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(LCD.screen)
            .onDeleteCommand { removeSelected() }
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL), web = urls.filter { !$0.isFileURL }
                guard !files.isEmpty || !web.isEmpty else { return false }
                Task {
                    if !files.isEmpty { player.enqueue(await library.importFiles(files, select: false)) }
                    for u in web { player.enqueue(await library.resolvePlaylistTracks(url: u.absoluteString)) }
                }
                return true
            }
            .overlay {
                if player.queue.isEmpty {
                    Text("Drop audio files here, or add an album below.").font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            HStack(spacing: 6) {
                Menu {
                    Section("Albums") {
                        ForEach(library.albums) { a in
                            Button(a.name) { addAlbum(a.id) }
                        }
                    }
                    Divider()
                    Button("Files…") { addFiles() }
                    Button("YouTube playlist URL…") { urlDraft = ""; askingURL = true }
                } label: { Label("Add", systemImage: "plus") }
                .menuStyle(.borderlessButton).fixedSize()
                Button("Remove") { removeSelected() }.disabled(selection.isEmpty)
                Button("Clear") { player.clear() }.disabled(player.queue.isEmpty)
                Spacer()
            }
            .controlSize(.small)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color(white: 0.13))
        }
        .frame(minHeight: 180)
        .alert("Add a YouTube playlist", isPresented: $askingURL) {
            TextField("https://music.youtube.com/playlist?list=…", text: $urlDraft)
            Button("Add") {
                let u = urlDraft
                Task { player.enqueue(await library.resolvePlaylistTracks(url: u)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its tracks go straight into the queue, without making an album.")
        }
    }

    private var rows: [(index: Int, entry: QueueEntry)] {
        let all = player.queue.enumerated().map { (index: $0.offset, entry: $0.element) }
        guard !search.trimmed.isEmpty else { return all }
        return all.filter { "\($0.entry.track.artist) \($0.entry.track.title)".localizedStandardContains(search.trimmed) }
    }

    /// Drag to reorder, only on the full list (not while a search filters it).
    private var moveRows: ((IndexSet, Int) -> Void)? {
        search.trimmed.isEmpty ? { player.move(from: $0, to: $1) } : nil
    }

    private func removeSelected() {
        player.remove(at: IndexSet(player.queue.indices.filter { selection.contains(player.queue[$0].id) }))
        selection = []
    }

    private func addAlbum(_ id: Int64) {
        player.enqueue(library.tracks(inAlbum: id))
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { player.enqueue(await library.importFiles(urls, select: false)) }
    }
}

private struct PlaylistRow: View {
    let number: Int
    let entry: QueueEntry
    let isCurrent: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text("\(number).").font(LCD.mono(11)).frame(width: 32, alignment: .trailing)
            Text(entry.track.artist.isEmpty ? entry.track.title : "\(entry.track.artist) - \(entry.track.title)")
                .font(LCD.mono(11)).lineLimit(1)
            Spacer(minLength: 4)
            if isCurrent { Image(systemName: isPlaying ? "speaker.wave.2.fill" : "pause.fill").font(.system(size: 9)) }
            Text(entry.track.duration.map(formatTime) ?? "").font(LCD.mono(11))
        }
        .foregroundColor(isCurrent ? .white : LCD.green)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
    }
}

// MARK: Menu bar

/// The menu bar mini player: the track, its art, and the transport.
struct MiniPlayerView: View {
    let model: PlayerAppModel
    @ObservedObject private var player: PlayerState
    @Environment(\.openWindow) private var openWindow
    @State private var art: NSImage?

    init(model: PlayerAppModel) {
        self.model = model
        player = model.player
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Group {
                    if let art {
                        Image(nsImage: art).resizable().scaledToFill().scaleEffect(player.current?.isLocal == false ? 1.34 : 1)
                    } else { LCD.screen }
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.current?.title ?? "Nothing playing").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(player.current?.artist ?? "Platter").font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 18) {
                Button { player.previous() } label: { Image(systemName: "backward.end.fill") }.accessibilityLabel("Previous")
                Button { player.togglePlay() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 20)) }
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button { player.next() } label: { Image(systemName: "forward.end.fill") }.accessibilityLabel("Next")
            }
            .buttonStyle(.borderless)
            Divider()
            HStack {
                Button("Open Player") { openWindow(id: "player"); NSApp.activate() }
                Spacer()
                Button("Open DJ") { openWindow(id: "dj"); NSApp.activate() }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 280)
        .task(id: player.current?.id) {
            art = nil
            if let t = player.current { art = await Artwork.image(for: t, audioDirectory: model.library.audioDirectory) }
        }
    }
}

// MARK: Library browser

/// Albums (with cover art) and artists, to play or queue.
private struct LibraryPanel: View {
    let model: PlayerAppModel
    @ObservedObject private var library: Library
    @AppStorage("player.libraryTab") private var tab = 0
    @State private var tracks: [Track] = []

    init(model: PlayerAppModel) {
        self.model = model
        library = model.library
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Albums").tag(0)
                Text("Artists").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            .padding(6)
            ScrollView {
                if tab == 0 {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                        ForEach(library.albums) { album in
                            AlbumTile(model: model, album: album, tracks: library.tracks(inAlbum: album.id))
                        }
                    }
                    .padding(10)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(artists, id: \.name) { a in
                            HStack {
                                Text(a.name.isEmpty ? "Unknown artist" : a.name).font(.system(size: 12))
                                Spacer()
                                Text("\(a.tracks.count)").font(LCD.mono(10)).foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { model.player.playAll(a.tracks) }
                            .contextMenu { QueueMenu(player: model.player, tracks: a.tracks) }
                            Divider().opacity(0.3)
                        }
                    }
                }
            }
        }
        .frame(minHeight: 200)
        .background(Color(white: 0.12))
        .task(id: library.albums) { tracks = library.allTracks() }
    }

    private var artists: [(name: String, tracks: [Track])] {
        Dictionary(grouping: tracks, by: \.artist)
            .map { ($0.key, $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private struct AlbumTile: View {
    let model: PlayerAppModel
    let album: Album
    let tracks: [Track]
    @State private var art: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                LCD.screen
                if let art {
                    // YouTube thumbnails are letterboxed; zoom in to the art.
                    Image(nsImage: art).resizable().scaledToFill().scaleEffect(tracks.first?.isLocal == false ? 1.34 : 1)
                } else {
                    Image(systemName: "opticaldisc").font(.system(size: 28)).foregroundColor(LCD.dim)
                }
            }
            .frame(width: 120, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(album.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            Text("\(album.trackCount) tracks").font(.system(size: 10)).foregroundColor(.secondary)
        }
        .frame(width: 120)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.player.playAll(tracks) }
        .contextMenu { QueueMenu(player: model.player, tracks: tracks) }
        .help("Double-click to play")
        .task(id: tracks.first?.id) {
            if let t = tracks.first { art = await Artwork.image(for: t, audioDirectory: model.library.audioDirectory) }
        }
    }
}

/// Play, play next, add to the queue.
struct QueueMenu: View {
    let player: PlayerState
    let tracks: [Track]

    var body: some View {
        Button("Play") { player.playAll(tracks) }
        Button("Play Next") { player.enqueue(tracks, next: true) }
        Button("Add to Queue") { player.enqueue(tracks) }
    }
}

