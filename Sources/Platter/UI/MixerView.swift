import SwiftUI

/// The center mixer, laid out like a two-channel club mixer: per channel HI/MID/LOW, a
/// filter, an effect, headphone cue, and a long fader with an LED meter; then the master
/// level, headphones, recording, and a horizontal crossfader.
struct MixerView: View {
    @ObservedObject var mixer: MixerState
    let meters: [DeckID: LevelMeter]
    let masterMeter: LevelMeter
    @ObservedObject var deckA: DeckState
    @ObservedObject var deckB: DeckState

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                PanelLabel("MIXER")
                Spacer()
                RecordButton(mixer: mixer)
            }
            HStack(alignment: .top, spacing: 12) {
                ChannelStrip(mixer: mixer, deck: .a, meter: meters[.a], playing: deckA.isPlaying)
                ChannelStrip(mixer: mixer, deck: .b, meter: meters[.b], playing: deckB.isPlaying)
            }
            .frame(maxHeight: .infinity)
            MasterSection(mixer: mixer, meter: masterMeter, playing: deckA.isPlaying || deckB.isPlaying)
            VStack(spacing: 4) {
                HStack {
                    PanelLabel("A", color: Theme.deck(.a))
                    Spacer()
                    PanelLabel("CROSSFADER")
                    Spacer()
                    PanelLabel("B", color: Theme.deck(.b))
                }
                HFader(value: mixer.crossfader) { mixer.crossfader = $0 }
                    .frame(height: 26)
                    .onTapGesture(count: 2) { mixer.crossfader = 0.5 }
                    .help("Double-click to center")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxHeight: .infinity)
        .background(
            LinearGradient(colors: [Color(white: 0.13), Color(white: 0.09)], startPoint: .top, endPoint: .bottom)
        )
        .overlay(alignment: .leading) { Rectangle().fill(Color.black).frame(width: 1) }
        .overlay(alignment: .trailing) { Rectangle().fill(Color.black).frame(width: 1) }
    }
}

private struct ChannelStrip: View {
    @ObservedObject var mixer: MixerState
    let deck: DeckID
    let meter: LevelMeter?
    let playing: Bool

    var body: some View {
        let eq = mixer.eq[deck] ?? (0, 0, 0)
        let accent = Theme.deck(deck)
        VStack(spacing: 4) {
            Text(deck.label)
                .font(.system(size: 13, weight: .heavy, design: .monospaced))
                .foregroundColor(accent)
            Grid(horizontalSpacing: 4, verticalSpacing: 2) {
                GridRow {
                    eqKnob(.high, eq.high)
                    eqKnob(.mid, eq.mid)
                }
                GridRow {
                    eqKnob(.low, eq.low)
                    Knob(value: mixer.filter[deck] ?? 0, label: "FILTER", accent: .white, range: -1...1,
                         text: { $0 == 0 ? "OFF" : $0 < 0 ? "LPF" : "HPF" }) { mixer.filter[deck] = $0 }
                        .help("Filter: left is low-pass, right is high-pass. Double-click turns it off.")
                }
                GridRow {
                    Knob(value: mixer.fxAmount[deck] ?? 0, label: "FX", accent: Theme.amber, range: 0...1, detent: nil,
                         text: { String(format: "%.0f%%", $0 * 100) }) { mixer.fxAmount[deck] = $0 }
                        .help("Effect amount")
                    VStack(spacing: 4) {
                        MixerKey(label: (mixer.fx[deck] ?? .off).label, lit: (mixer.fxAmount[deck] ?? 0) > 0 && mixer.fx[deck] != .off) {
                            mixer.fx[deck] = (mixer.fx[deck] ?? .off).next
                        }
                        .help("Effect type: echo (half a beat) or reverb")
                        MixerKey(label: "CUE", systemImage: "headphones", lit: mixer.pfl[deck] ?? false) {
                            mixer.pfl[deck] = !(mixer.pfl[deck] ?? false)
                        }
                        .help("Headphone cue (PFL): hear this channel in the headphones, before its fader")
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                if let meter { LEDMeter(meter: meter, active: playing) }
                VFader(value: mixer.level[deck] ?? 1) { mixer.setLevel($0, deck: deck) }
                    .frame(width: 28)
            }
            .frame(minHeight: 60, maxHeight: 190)
        }
    }

    private func eqKnob(_ band: EQBand, _ value: Double) -> some View {
        Knob(value: value, label: band.label, accent: Theme.deck(deck),
             text: { $0 == 0 ? "0" : String(format: "%+.0f", $0) }) {
            mixer.setEQBand($0, band: band, deck: deck)
        }
    }
}

/// Master level and meter, and the headphone device and level.
private struct MasterSection: View {
    @ObservedObject var mixer: MixerState
    let meter: LevelMeter
    let playing: Bool
    @State private var devices: [CueOutput.Device] = []

    var body: some View {
        HStack(spacing: 8) {
            Knob(value: mixer.master, label: "MASTER", accent: .white, range: 0...1, detent: nil, size: 26,
                 text: { String(format: "%.0f", $0 * 10) }) { mixer.master = $0 }
            LEDMeter(meter: meter, active: playing, compact: true)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                Menu {
                    Button("Off") { mixer.setHeadphones(nil) }
                    Divider()
                    ForEach(devices) { d in
                        Button(d.name) { mixer.setHeadphones(d) }
                    }
                } label: {
                    Label(mixer.headphones?.name ?? "Phones off", systemImage: "headphones")
                        .font(.system(size: 10))
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .onAppear { devices = CueOutput.outputDevices() }
                .help("Headphone output for CUE (PFL). Pick a second device, like USB headphones.")
                Knob(value: mixer.phonesLevel, label: "PHONES", accent: .white, range: 0...1, detent: nil, size: 26,
                     text: { String(format: "%.0f", $0 * 10) }) { mixer.phonesLevel = $0 }
            }
        }
    }
}

private struct RecordButton: View {
    @ObservedObject var mixer: MixerState

    var body: some View {
        Button { mixer.toggleRecording() } label: {
            HStack(spacing: 4) {
                Circle().fill(mixer.recordingSince != nil ? Color.red : Color.red.opacity(0.35)).frame(width: 8, height: 8)
                if let since = mixer.recordingSince {
                    TimelineView(.periodic(from: since, by: 1)) { ctx in
                        Text(formatTime(ctx.date.timeIntervalSince(since)))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                    }
                } else {
                    Text("REC").font(.system(size: 9, weight: .heavy))
                }
            }
            .foregroundColor(.white.opacity(0.85))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(PressableStyle())
        .help(mixer.recordingSince == nil ? "Record the master output to ~/Music/Platter" : "Stop recording and show the file")
    }
}

private struct MixerKey: View {
    let label: String
    var systemImage: String? = nil
    let lit: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let systemImage { Image(systemName: systemImage) }
                Text(label)
            }
            .font(.system(size: 8, weight: .heavy))
            .foregroundColor(lit ? .black : .white.opacity(0.8))
            .frame(width: 50, height: 18)
            .background(RoundedRectangle(cornerRadius: 3).fill(lit ? Theme.amber : Color.white.opacity(0.1)))
        }
        .buttonStyle(PressableStyle())
    }
}

private extension EQBand {
    var label: String {
        switch self {
        case .high: return "HI"
        case .mid: return "MID"
        case .low: return "LOW"
        }
    }
}

/// A rotary knob. Drag up or down; it clicks at `detent` (when set); double-click resets to
/// the detent, or to the bottom of the range. The colored arc runs from the detent (or the
/// bottom) to the value.
struct Knob: View {
    let value: Double
    let label: String
    let accent: Color
    var range: ClosedRange<Double> = -12...12
    var detent: Double? = 0
    var size: CGFloat = 30
    var text: (Double) -> String = { String(format: "%+.0f", $0) }
    let onChange: (Double) -> Void

    @State private var dragStart: Double?

    var body: some View {
        let span = range.upperBound - range.lowerBound
        let frac = (value - range.lowerBound) / span
        let origin = ((detent ?? range.lowerBound) - range.lowerBound) / span
        VStack(spacing: 2) {
            ZStack {
                ForEach(0..<11, id: \.self) { i in
                    Rectangle()
                        .fill(Color.white.opacity(i == 5 ? 0.7 : 0.3))
                        .frame(width: 1, height: i == 5 ? 4 : 2.5)
                        .offset(y: -size / 2 - 4)
                        .rotationEffect(.degrees(-135 + 27 * Double(i)))
                }
                Circle()
                    .trim(from: min(origin, frac) * 0.75, to: max(origin, frac) * 0.75)
                    .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .frame(width: size + 4, height: size + 4)
                Circle().fill(Color(white: 0.08))
                    .frame(width: size, height: size)
                    .shadow(color: .black.opacity(0.8), radius: 3, y: 2)
                Circle()
                    .fill(RadialGradient(colors: [Color(white: 0.4), Color(white: 0.16)],
                                         center: UnitPoint(x: 0.4, y: 0.3), startRadius: 1, endRadius: size * 0.45))
                    .frame(width: size * 0.74, height: size * 0.74)
                Capsule()
                    .fill(Color.white)
                    .frame(width: 2.5, height: size * 0.28)
                    .offset(y: -size * 0.24)
                    .rotationEffect(.degrees(-135 + 270 * frac))
            }
            .frame(width: size + 12, height: size + 12)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragStart == nil { dragStart = value }
                        var v = (dragStart ?? 0) - Double(g.translation.height) / 80 * span
                        v = min(range.upperBound, max(range.lowerBound, v))
                        if let d = detent, abs(v - d) < span * 0.025 { v = d } // the click
                        onChange(v)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(count: 2) { onChange(detent ?? range.lowerBound) }

            HStack(spacing: 3) {
                Text(label).font(.system(size: 7, weight: .heavy)).foregroundColor(Theme.textDim)
                Text(text(value))
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundColor(value == (detent ?? range.lowerBound) ? Theme.textDim : .white)
            }
            .lineLimit(1)
        }
    }
}

/// A 12-segment peak meter: green up to -9 dB, amber to -3 dB, red above.
private struct LEDMeter: View {
    let meter: LevelMeter
    /// Off while the deck is stopped, so an idle mixer does not redraw 30 times a second.
    let active: Bool
    /// Short version for the master: 4 pt segments.
    var compact = false
    private static let thresholds: [Float] = [-36, -30, -24, -20, -16, -12, -9, -6, -4, -2, -1, 0]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { _ in
            // A Canvas, not a stack of shapes: redrawing it does not trigger a layout pass.
            // The segments fit the height the meter gets.
            Canvas { ctx, size in
                let db = active ? 20 * log10(max(meter.level, 1e-5)) : -100
                let step = min(compact ? 4 : 9, size.height / CGFloat(Self.thresholds.count))
                let top = size.height - step * CGFloat(Self.thresholds.count)
                for (row, t) in Self.thresholds.reversed().enumerated() {
                    let color: Color = t >= -2 ? .red : t >= -6 ? Theme.amber : Theme.playGreen
                    let rect = CGRect(x: 0, y: top + CGFloat(row) * step, width: 6, height: max(1, step - 2))
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(db >= t ? color : color.opacity(0.12)))
                }
            }
        }
        .frame(width: 6)
        .frame(maxHeight: compact ? CGFloat(Self.thresholds.count) * 4 : .infinity)
    }
}

/// A long channel fader: up is louder.
struct VFader: View {
    let value: Double           // 0...1
    let onChange: (Double) -> Void
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height, w = geo.size.width
            let capH: CGFloat = 26
            let usable = h - capH
            let y = capH / 2 + CGFloat(1 - value) * usable
            ZStack(alignment: .topLeading) {
                ForEach(0...10, id: \.self) { i in
                    Rectangle().fill(Color.white.opacity(i % 5 == 0 ? 0.5 : 0.22))
                        .frame(width: i % 5 == 0 ? 7 : 4, height: 1)
                        .position(x: 3, y: capH / 2 + usable * CGFloat(i) / 10)
                }
                Capsule().fill(Color.black)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.6))
                    .frame(width: 4, height: usable)
                    .position(x: w / 2 + 3, y: h / 2)
                FaderCap(vertical: true)
                    .frame(width: w - 6, height: capH)
                    .position(x: w / 2 + 3, y: y)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragStart == nil { dragStart = value }
                        onChange(min(1, max(0, (dragStart ?? 0) - Double(g.translation.height / usable))))
                    }
                    .onEnded { _ in dragStart = nil }
            )
        }
        .help("Channel level")
    }
}

/// The crossfader: 0 = deck A only, 1 = deck B only.
struct HFader: View {
    let value: Double
    let onChange: (Double) -> Void
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let capW: CGFloat = 18
            let usable = w - capW
            let x = capW / 2 + CGFloat(value) * usable
            ZStack(alignment: .topLeading) {
                ForEach(0...10, id: \.self) { i in
                    Rectangle().fill(Color.white.opacity(i % 5 == 0 ? 0.5 : 0.22))
                        .frame(width: 1, height: i % 5 == 0 ? 7 : 4)
                        .position(x: capW / 2 + usable * CGFloat(i) / 10, y: 3)
                }
                Capsule().fill(Color.black)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.6))
                    .frame(width: usable, height: 4)
                    .position(x: w / 2, y: h / 2 + 3)
                FaderCap(vertical: false)
                    .frame(width: capW, height: h - 8)
                    .position(x: x, y: h / 2 + 3)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragStart == nil { dragStart = value }
                        onChange(min(1, max(0, (dragStart ?? 0) + Double(g.translation.width / usable))))
                    }
                    .onEnded { _ in dragStart = nil }
            )
        }
    }
}

/// A fader cap: dark plastic with a white center line.
private struct FaderCap: View {
    let vertical: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(LinearGradient(colors: [Color(white: 0.34), Color(white: 0.14), Color(white: 0.26)],
                                 startPoint: vertical ? .top : .leading, endPoint: vertical ? .bottom : .trailing))
            .overlay(
                Rectangle().fill(Color.white.opacity(0.9))
                    .frame(width: vertical ? nil : 1.5, height: vertical ? 1.5 : nil)
            )
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white.opacity(0.15), lineWidth: 0.6))
            .shadow(color: .black.opacity(0.8), radius: 3, y: 2)
    }
}
