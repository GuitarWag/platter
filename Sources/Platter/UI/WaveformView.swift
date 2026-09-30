import SwiftUI

/// The whole track at a glance: played part dimmed, hot cues and the cue point marked.
/// Click or drag to seek.
struct OverviewWaveform: View {
    @ObservedObject var state: DeckState

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !state.isPlaying)) { _ in
                Canvas { ctx, size in
                    let dur = state.duration
                    let progress = dur > 0 ? CGFloat(state.position / dur) : 0
                    let peaks = state.track?.peaks ?? []
                    let mid = size.height / 2
                    if peaks.isEmpty {
                        var line = Path()
                        line.move(to: CGPoint(x: 0, y: mid))
                        line.addLine(to: CGPoint(x: size.width, y: mid))
                        ctx.stroke(line, with: .color(.white.opacity(0.12)), lineWidth: 1)
                    } else {
                        // One bar per 2 points, the max of the peaks it covers.
                        var played = Path(), ahead = Path()
                        let cols = Int(size.width / 2)
                        for col in 0..<cols {
                            let lo = col * peaks.count / cols
                            let hi = max(lo + 1, (col + 1) * peaks.count / cols)
                            let p = CGFloat(peaks[lo..<min(hi, peaks.count)].max() ?? 0)
                            let h = max(1, p * (size.height - 2))
                            let x = CGFloat(col) * 2
                            let rect = CGRect(x: x, y: mid - h / 2, width: 1.4, height: h)
                            if x / size.width <= progress { played.addRect(rect) } else { ahead.addRect(rect) }
                        }
                        ctx.fill(played, with: .color(Theme.wave.opacity(0.35)))
                        ctx.fill(ahead, with: .color(Theme.wave))
                    }
                    if dur > 0 {
                        if let l = state.loop {
                            let x0 = CGFloat(l.lowerBound / dur) * size.width, x1 = CGFloat(l.upperBound / dur) * size.width
                            ctx.fill(Path(CGRect(x: x0, y: 0, width: max(2, x1 - x0), height: size.height)),
                                     with: .color(Theme.playGreen.opacity(0.35)))
                        }
                        for (i, t) in state.hotCues.enumerated() {
                            guard let t else { continue }
                            let x = CGFloat(t / dur) * size.width
                            ctx.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)),
                                     with: .color(Theme.cueColors[i]))
                        }
                        if let c = state.cuePoint {
                            let x = CGFloat(c / dur) * size.width
                            var tri = Path()
                            tri.move(to: CGPoint(x: x - 4, y: size.height))
                            tri.addLine(to: CGPoint(x: x + 4, y: size.height))
                            tri.addLine(to: CGPoint(x: x, y: size.height - 6))
                            ctx.fill(tri, with: .color(Theme.amber))
                        }
                    }
                    ctx.fill(Path(CGRect(x: progress * size.width - 1, y: 0, width: 2, height: size.height)),
                             with: .color(.white))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { v in
                    guard state.hasTrack, geo.size.width > 0 else { return }
                    state.seek(to: Double(min(1, max(0, v.location.x / geo.size.width))) * state.duration)
                }
            )
        }
        .background(Color.black.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .help("Click to jump")
    }
}

/// A scrolling close-up around the playhead (`window` seconds wide), for beatmatching.
/// The playhead stays in the middle and the audio moves past it.
struct ZoomWaveform: View {
    @ObservedObject var state: DeckState
    var window: Double = 8

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !state.isPlaying)) { _ in
            Canvas { ctx, size in
                let mid = size.height / 2
                let center = size.width / 2
                let color = Theme.deck(state.deck)
                if let wave = state.track?.wave, !wave.isEmpty {
                    let pos = state.position
                    let secondsPerPoint = window / Double(size.width)
                    let visible = (pos - window / 2)...(pos + window / 2)
                    func x(_ t: Double) -> CGFloat { center + CGFloat((t - pos) / secondsPerPoint) }
                    if let l = state.loop, l.upperBound > visible.lowerBound, l.lowerBound < visible.upperBound {
                        ctx.fill(Path(CGRect(x: x(l.lowerBound), y: 0, width: x(l.upperBound) - x(l.lowerBound),
                                             height: size.height)), with: .color(Theme.playGreen.opacity(0.18)))
                    }
                    // Beat grid: a thin line per beat, a brighter one every 4 beats (the bar).
                    if let grid = state.grid {
                        for t in grid.beats(in: visible) {
                            let bar = Int(((t - grid.firstBeat) / grid.period).rounded()) % 4 == 0
                            ctx.fill(Path(CGRect(x: x(t) - 0.5, y: 0, width: 1, height: size.height)),
                                     with: .color(.white.opacity(bar ? 0.45 : 0.15)))
                        }
                    }
                    let rate = Analysis.waveRate
                    var played = Path(), ahead = Path()
                    var x: CGFloat = 0
                    while x < size.width {
                        let t0 = pos + Double(x - center) * secondsPerPoint
                        let t1 = t0 + 2 * secondsPerPoint
                        let lo = Int(t0 * rate), hi = max(lo + 1, Int(t1 * rate))
                        if hi > 0, lo < wave.count {
                            let p = CGFloat(wave[max(0, lo)..<min(hi, wave.count)].max() ?? 0)
                            let h = max(1, p * (size.height - 4))
                            let rect = CGRect(x: x, y: mid - h / 2, width: 1.5, height: h)
                            if x < center { played.addRect(rect) } else { ahead.addRect(rect) }
                        }
                        x += 2
                    }
                    ctx.fill(played, with: .color(color.opacity(0.45)))
                    ctx.fill(ahead, with: .color(color))
                    // Hot cues in view.
                    for (i, t) in state.hotCues.enumerated() {
                        guard let t else { continue }
                        let cx = center + CGFloat((t - pos) / secondsPerPoint)
                        guard cx >= 0, cx <= size.width else { continue }
                        ctx.fill(Path(CGRect(x: cx - 1, y: 0, width: 2, height: size.height)),
                                 with: .color(Theme.cueColors[i]))
                    }
                } else {
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: mid))
                    line.addLine(to: CGPoint(x: size.width, y: mid))
                    ctx.stroke(line, with: .color(color.opacity(0.2)), lineWidth: 1)
                }
                ctx.fill(Path(CGRect(x: center - 1, y: 0, width: 2, height: size.height)), with: .color(.white))
            }
        }
        .background(Color.black.opacity(0.55))
    }
}

/// The strip across the top: both decks' close-up waveforms, one above the other, so the
/// beats can be lined up by eye.
struct ZoomStrip: View {
    @ObservedObject var deckA: DeckState
    @ObservedObject var deckB: DeckState

    var body: some View {
        VStack(spacing: 1) {
            row(deckA)
            row(deckB)
        }
        .background(Theme.line)
    }

    private func row(_ deck: DeckState) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 1) {
                Text(deck.deck.label)
                    .font(.system(size: 14, weight: .heavy, design: .monospaced))
                    .foregroundColor(Theme.deck(deck.deck))
                Text(deck.effectiveBPM.map { String(format: "%.1f", $0) } ?? "--")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Theme.textDim)
            }
            .frame(width: 46)
            .frame(maxHeight: .infinity)
            .background(Theme.panel)
            ZoomWaveform(state: deck)
        }
    }
}
