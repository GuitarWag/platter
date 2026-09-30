import SwiftUI

/// One deck: the display (track, BPM, pitch, time, overview), the turntable, and the
/// transport row (CUE, PLAY, hot cues, pitch mode, bend).
struct DeckView: View {
    @ObservedObject var state: DeckState
    /// SYNC: match this deck to the other one.
    var sync: () -> Void = {}

    var body: some View {
        VStack(spacing: 8) {
            DeckDisplay(state: state)
            TurntableView(state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            TransportRow(state: state)
            LoopRow(state: state, sync: sync)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel)
    }
}

// MARK: Display

/// The deck's LCD, like the screen on a DJ player.
private struct DeckDisplay: View {
    @ObservedObject var state: DeckState
    @State private var showRemaining = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(state.deck.label)
                    .font(.system(size: 13, weight: .heavy, design: .monospaced))
                    .foregroundColor(.black)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.deck(state.deck)))
                if let loading = state.loadingTitle {
                    ProgressView().controlSize(.small)
                    Text("Loading \(loading)…")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.amber)
                        .lineLimit(1)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(state.track?.title ?? "No track loaded")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(state.hasTrack ? .white : Theme.textDim)
                            .lineLimit(1)
                        Text(state.track.map { $0.artist.isEmpty ? "—" : $0.artist } ?? "Load a track from the library")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textDim)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(alignment: .lastTextBaseline, spacing: 10) {
                readout(state.effectiveBPM.map { String(format: "%.1f", $0) } ?? "--.-", unit: "BPM", size: 24)
                readout(String(format: "%+.2f", (state.pitch + state.bend) * 100), unit: "%",
                        size: 15, color: state.pitch + state.bend == 0 ? .white : Theme.amber)
                Text(state.pitchMode.shortLabel)
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundColor(modeColor)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(modeColor.opacity(0.7), lineWidth: 1))
                    .fixedSize()
                if let key = state.track?.musicalKey {
                    readout(key.name, unit: key.camelot, size: 15)
                        .help("Key \(key.name), Camelot \(key.camelot)")
                }
                if state.loop != nil {
                    Text("LOOP")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundColor(.black)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Theme.playGreen))
                        .fixedSize()
                }
                Spacer(minLength: 0)
                TimelineView(.animation(minimumInterval: 0.1, paused: !state.isPlaying)) { _ in
                    let t = showRemaining ? state.duration - state.position : state.position
                    let value = !state.hasTrack ? "-:--.-" : (showRemaining ? "-" : "") + formatTimeTenths(t)
                    let warn = showRemaining && state.hasTrack && state.duration - state.position < 30 && state.isPlaying
                    // Drawn in a Canvas: a ticking Text would re-lay out the whole deck 10 times a second.
                    Canvas { ctx, size in
                        let unit = ctx.resolve(Text(showRemaining ? "REMAIN" : "TIME")
                            .font(.system(size: 8, weight: .bold)).foregroundColor(Theme.textDim))
                        let unitWidth = unit.measure(in: size).width
                        ctx.draw(unit, at: CGPoint(x: size.width, y: size.height - 4), anchor: .bottomTrailing)
                        ctx.draw(Text(value).font(.system(size: 20, weight: .semibold, design: .monospaced))
                                    .foregroundColor(warn ? .red : .white),
                                 at: CGPoint(x: size.width - unitWidth - 3, y: size.height), anchor: .bottomTrailing)
                    }
                }
                .frame(width: 150, height: 26)
                .onTapGesture { showRemaining.toggle() }
                .help("Click to switch between elapsed and remaining time")
            }

            OverviewWaveform(state: state)
                .frame(height: 34)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.screen)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        )
    }

    private func readout(_ value: String, unit: String, size: CGFloat, color: Color = .white) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 3) {
            Text(value)
                .font(.system(size: size, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
            Text(unit)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(Theme.textDim)
        }
        .lineLimit(1)
        .fixedSize()
    }

    private var modeColor: Color {
        switch state.pitchMode {
        case .varispeed: return .white
        case .keyLock: return Theme.amber
        case .bpmShift: return .cyan
        }
    }
}

// MARK: Transport

private struct TransportRow: View {
    @ObservedObject var state: DeckState

    var body: some View {
        HStack(spacing: 10) {
            RoundButton(label: "CUE", ring: Theme.amber, lit: state.isCued, size: 42) { state.toggleCue() }
                .disabled(!state.hasTrack)
                .help("Set the cue point, or jump back to it")
            RoundButton(label: state.isPlaying ? "❚❚" : "▶", ring: Theme.playGreen, lit: state.isPlaying, size: 42) {
                state.togglePlay()
            }
            .disabled(!state.hasTrack)

            HStack(spacing: 4) {
                ForEach(0..<8, id: \.self) { i in
                    HotCuePad(index: i, isSet: state.hotCues[i] != nil) {
                        state.hotCues[i] == nil ? state.setHotCue(i) : state.fireHotCue(i)
                    } clear: {
                        state.clearHotCue(i)
                    }
                }
            }
            .disabled(!state.hasTrack)

            Spacer(minLength: 0)

            VStack(spacing: 4) {
                SmallKey(label: state.pitchMode.shortLabel, lit: state.pitchMode != .varispeed) { state.cyclePitchMode() }
                    .help("Pitch mode: VAR (tempo and pitch), KEY (key lock), BPM (pitch only)")
                HStack(spacing: 3) {
                    BendKey(label: "◀", state: state, amount: -0.04)
                    BendKey(label: "▶", state: state, amount: 0.04)
                }
            }
        }
        .frame(height: 50)
    }
}

/// Loops, quantize, and sync.
private struct LoopRow: View {
    @ObservedObject var state: DeckState
    let sync: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            SmallKey(label: "IN", lit: state.loopIn != nil, width: 32) { state.setLoopIn() }
                .help("Loop in: mark the loop start")
            SmallKey(label: "OUT", lit: false, width: 36) { state.setLoopOut() }
                .help("Loop out: close the loop here")
                .disabled(state.loopIn == nil)
            SmallKey(label: "½", lit: false, width: 24) { state.resizeLoop(by: 0.5) }
                .help("Halve the loop")
            SmallKey(label: "\(beatsLabel) BEAT", lit: state.loop != nil, width: 58) {
                state.loop == nil ? state.beatLoop() : state.exitLoop()
            }
            .help("Loop \(beatsLabel) beats from the current beat. Press again to exit.")
            SmallKey(label: "×2", lit: false, width: 24) { state.resizeLoop(by: 2) }
                .help("Double the loop")
            SmallKey(label: "RELOOP", lit: false, width: 50) { state.reloop() }
                .help("Turn the last loop back on")
            Spacer(minLength: 4)
            SmallKey(label: state.vinylLevel == 0 ? "VINYL" : "VINYL \(state.vinylLevel)", lit: state.vinylLevel > 0, width: 54) {
                state.vinylLevel = (state.vinylLevel + 1) % 4
            }
            .help("Record noise: crackle, pops, a scratch that repeats every turn, hiss, and wow. Off, 1, 2, 3.")
            SmallKey(label: "QUANTIZE", lit: state.quantize, width: 62) { state.quantize.toggle() }
                .help("Snap cues and loops to the beat grid")
            SmallKey(label: "SYNC", lit: false, width: 44, action: sync)
                .help("Match tempo and beat phase to the other deck")
        }
        .disabled(!state.hasTrack)
        .frame(height: 20)
    }

    private var beatsLabel: String {
        state.loopBeats < 1 ? "1/\(Int(1 / state.loopBeats))" : "\(Int(state.loopBeats))"
    }
}

/// A round DJ-player transport button with a light ring.
private struct RoundButton: View {
    let label: String
    let ring: Color
    let lit: Bool
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.1)],
                                             startPoint: .top, endPoint: .bottom))
                Circle().strokeBorder(ring.opacity(lit ? 1 : 0.35), lineWidth: 2.5)
                    .shadow(color: lit ? ring : .clear, radius: 5)
                Text(label)
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundColor(lit ? ring : .white.opacity(0.8))
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(PressableStyle())
    }
}

/// A hot cue pad: click an empty pad to store the position, click a lit pad to jump.
/// Right-click to clear.
private struct HotCuePad: View {
    let index: Int
    let isSet: Bool
    let action: () -> Void
    let clear: () -> Void

    var body: some View {
        let color = Theme.cueColors[index]
        Button(action: action) {
            Text("\(index + 1)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(isSet ? .black : color.opacity(0.8))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 4).fill(isSet ? color : Color.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(isSet ? 0 : 0.45), lineWidth: 1))
                .shadow(color: isSet ? color.opacity(0.7) : .clear, radius: 4)
        }
        .buttonStyle(PressableStyle())
        .help(isSet ? "Jump to hot cue \(index + 1). Right-click to clear." : "Store hot cue \(index + 1) here")
        .contextMenu {
            Button("Clear hot cue \(index + 1)", action: clear).disabled(!isSet)
        }
    }
}

private struct SmallKey: View {
    let label: String
    let lit: Bool
    var width: CGFloat = 50
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 9, weight: .heavy))
                .foregroundColor(lit ? .black : .white.opacity(0.8))
                .frame(width: width, height: 18)
                .background(RoundedRectangle(cornerRadius: 3).fill(lit ? Theme.amber : Color.white.opacity(0.1)))
        }
        .buttonStyle(PressableStyle())
    }
}

/// Hold to nudge the tempo by `amount` (±4%), release to return. For beatmatching.
private struct BendKey: View {
    let label: String
    @ObservedObject var state: DeckState
    let amount: Double
    @State private var pressed = false

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .heavy))
            .foregroundColor(pressed ? .black : .white.opacity(0.8))
            .frame(width: 23, height: 18)
            .background(RoundedRectangle(cornerRadius: 3).fill(pressed ? Theme.amber : Color.white.opacity(0.1)))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        state.bend = amount
                    }
                    .onEnded { _ in
                        pressed = false
                        state.bend = 0
                    }
            )
            .help(amount < 0 ? "Hold to slow down (pitch bend)" : "Hold to speed up (pitch bend)")
    }
}
