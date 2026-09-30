import SwiftUI

/// Layout of the turntable, in points, from the plinth height. Modeled on a Technics
/// SL-1200: platter on the left, tonearm pivot top right, pitch fader bottom right,
/// START/STOP bottom left, strobe lamp at the platter's lower-left edge.
struct TurntableGeometry {
    let height: CGFloat
    static let aspect: CGFloat = 1.3

    var width: CGFloat { height * Self.aspect }
    var center: CGPoint { CGPoint(x: height * 0.52, y: height * 0.5) }
    var platterRadius: CGFloat { height * 0.455 }
    var recordRadius: CGFloat { height * 0.43 }
    var labelRadius: CGFloat { recordRadius * 0.34 }
    var pivot: CGPoint { CGPoint(x: height * 1.11, y: height * 0.2) }
    /// Pivot to stylus tip.
    var armLength: CGFloat { height * 0.70 }
    var outerGroove: CGFloat { recordRadius * 0.95 }
    var innerGroove: CGFloat { recordRadius * 0.37 }

    /// Arm direction (radians, screen coordinates) when parked on its rest.
    static let restAngle = Double.pi / 2 + 0.13

    /// Arm direction that puts the stylus on the groove at `progress` (0 = lead-in, 1 = run-out).
    /// Law of cosines on the triangle pivot, platter center, stylus.
    func playAngle(progress: Double) -> Double {
        let p = min(1, max(0, progress))
        let r = Double(outerGroove - (outerGroove - innerGroove) * p)
        let dx = Double(center.x - pivot.x), dy = Double(center.y - pivot.y)
        let d = (dx * dx + dy * dy).squareRoot()
        let l = Double(armLength)
        let cosT = min(1, max(-1, (l * l + d * d - r * r) / (2 * l * d)))
        return atan2(dy, dx) - acos(cosT)
    }

    /// Strobe lamp, just outside the platter at its lower-left.
    var lamp: CGPoint {
        let a = Double.pi * 0.78
        let r = platterRadius + height * 0.04
        return CGPoint(x: center.x + r * CGFloat(cos(a)), y: center.y + r * CGFloat(sin(a)))
    }
}

/// One deck's turntable. The record turns at 33 1/3 RPM from the audio clock (so it follows
/// pitch, pause, and seeks exactly), and the tonearm tracks the playhead across the grooves.
/// Drag the record to hold it and scrub.
struct TurntableView: View {
    @ObservedObject var state: DeckState

    var body: some View {
        GeometryReader { geo in
            let g = TurntableGeometry(height: min(geo.size.height, geo.size.width / TurntableGeometry.aspect))
            ZStack(alignment: .topLeading) {
                Plinth(g: g)
                PlatterView(state: state, g: g)
                    .frame(width: g.platterRadius * 2, height: g.platterRadius * 2)
                    .position(g.center)
                StrobeLamp(on: true)
                    .frame(width: g.height * 0.06, height: g.height * 0.06)
                    .position(g.lamp)
                TonearmBase(g: g)
                TonearmView(state: state, g: g)
                StartStopButton(state: state, fontSize: g.height * 0.018)
                    .frame(width: g.height * 0.15, height: g.height * 0.075)
                    .position(x: g.height * 0.1, y: g.height * 0.925)
                PitchSlider(state: state)
                    .frame(width: g.height * 0.13, height: g.height * 0.5)
                    .position(x: g.height * 1.235, y: g.height * 0.68)
            }
            .frame(width: g.width, height: g.height)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .aspectRatio(TurntableGeometry.aspect, contentMode: .fit)
    }
}

// MARK: Plinth

private struct Plinth: View {
    let g: TurntableGeometry

    var body: some View {
        let corner = g.height * 0.035
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: corner)
                .fill(Theme.plinth)
                .shadow(color: .black.opacity(0.7), radius: g.height * 0.03, y: g.height * 0.015)
            // Machined top edge catching the light.
            RoundedRectangle(cornerRadius: corner)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.03)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1.2)
            VStack(alignment: .leading, spacing: 1) {
                Text("PLATTER")
                    .font(.system(size: g.height * 0.034, weight: .heavy))
                    .tracking(1.5)
                Text("DIRECT DRIVE")
                    .font(.system(size: g.height * 0.017, weight: .semibold))
                    .tracking(1)
            }
            .foregroundColor(.white.opacity(0.32))
            .padding(.leading, g.height * 0.035)
            .padding(.top, g.height * 0.03)
            // Four corner screws.
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .fill(Theme.brushedMetal)
                    .overlay(Rectangle().fill(.black.opacity(0.5)).frame(height: 0.8).rotationEffect(.degrees(35)))
                    .frame(width: g.height * 0.018, height: g.height * 0.018)
                    .position(x: i % 2 == 0 ? g.height * 0.025 : g.width - g.height * 0.025,
                              y: i < 2 ? g.height * 0.025 : g.height * 0.975)
            }
        }
        .frame(width: g.width, height: g.height)
    }
}

// MARK: Platter and record

private struct PlatterView: View {
    @ObservedObject var state: DeckState
    let g: TurntableGeometry

    /// While the hand is on the record: whether it was playing, the last pointer angle, and
    /// where the record is now (seconds).
    @State private var hold: (wasPlaying: Bool, angle: Double, position: Double)?

    /// 33 1/3 RPM = 200 degrees of rotation per second of audio.
    fileprivate static let degreesPerSecond = 200.0

    var body: some View {
        let pr = g.platterRadius, rr = g.recordRadius
        ZStack {
            // Platter: machined aluminium ring around the record.
            Circle().fill(RadialGradient(colors: [Color(white: 0.42), Color(white: 0.22), Color(white: 0.3)],
                                         center: .center, startRadius: rr * 0.98, endRadius: pr))
            Circle().strokeBorder(Color.black.opacity(0.7), lineWidth: 1)

            StrobeDots(radius: pr)
                .modifier(Spin(state: state, active: spinning))

            // The record. Grooves are round, so they are drawn once and do not turn.
            VinylSurface(seed: state.track?.id ?? "", radius: rr)
                .frame(width: rr * 2, height: rr * 2)
                .shadow(color: .black.opacity(0.6), radius: 2, y: 1)

            // Glints and label turn together as one layer. The sheen covers only the grooves,
            // never the label, so it can sit on top without turning.
            ZStack {
                RecordGlints(seed: state.track?.id ?? "", radius: rr)
                RecordLabel(track: state.track, deck: state.deck, radius: g.labelRadius)
            }
            .frame(width: rr * 2, height: rr * 2)
            .modifier(Spin(state: state, active: spinning))
            VinylSheen(inner: g.labelRadius, outer: rr)
                .frame(width: rr * 2, height: rr * 2)

            // Spindle.
            Circle()
                .fill(RadialGradient(colors: [.white, Color(white: 0.55), Color(white: 0.3)],
                                     center: UnitPoint(x: 0.35, y: 0.35), startRadius: 0, endRadius: g.height * 0.014))
                .frame(width: g.height * 0.024, height: g.height * 0.024)
                .shadow(color: .black.opacity(0.6), radius: 1, y: 1)
        }
        .contentShape(Circle().scale(rr / pr))
        .gesture(holdGesture)
        .help(state.hasTrack ? "Drag the record to scrub. Holding it stops it, like vinyl." : "")
    }

    private var spinning: Bool { state.isPlaying || hold != nil }

    /// Drag on the record: the record follows the hand (1 turn = 1.8 s of audio) and you hear
    /// it, forward and backward. Holding it still stops it; letting go restarts it if it was
    /// playing.
    private var holdGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                guard state.hasTrack else { return }
                let c = CGPoint(x: g.platterRadius, y: g.platterRadius)
                let a = atan2(Double(v.location.y - c.y), Double(v.location.x - c.x))
                guard var h = hold else {
                    let wasPlaying = state.isPlaying
                    state.beginScratch()
                    hold = (wasPlaying, a, state.position)
                    return
                }
                var delta = a - h.angle
                if delta > .pi { delta -= 2 * .pi }
                if delta < -.pi { delta += 2 * .pi }
                h.angle = a
                h.position = min(state.duration, max(0, h.position + delta / (2 * .pi) * 360 / Self.degreesPerSecond))
                hold = h
                state.scratch(to: h.position)
            }
            .onEnded { _ in
                state.endScratch(resume: hold?.wasPlaying == true)
                hold = nil
            }
    }
}

/// Turns its content with the record, 33 1/3 RPM = 200 degrees per second of audio. Only the
/// rotation is updated each frame: the content (a Canvas, the label) is drawn once, so
/// SwiftUI just rotates the layer.
private struct Spin: ViewModifier {
    @ObservedObject var state: DeckState
    let active: Bool

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !active)) { _ in
            content.rotationEffect(.degrees(state.position * PlatterView.degreesPerSecond))
        }
    }
}

/// Rows of strobe dots on the platter rim.
private struct StrobeDots: View {
    let radius: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            for (row, count) in [(0, 120), (1, 96)] {
                let r = radius * (0.982 - CGFloat(row) * 0.03)
                let dot = radius * 0.012
                for i in 0..<count {
                    let a = Double(i) / Double(count) * 2 * .pi
                    let p = CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - dot / 2, y: p.y - dot / 2, width: dot, height: dot)),
                             with: .color(Color(white: 0.85).opacity(0.8)))
                }
            }
        }
    }
}

/// The black vinyl: lead-in, grooves with a few track gaps, and the run-out area. Seeded by
/// the track id, so each record has its own groove pattern.
private struct VinylSurface: View {
    let seed: String
    let radius: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let R = min(size.width, size.height) / 2
            func circle(_ r: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            }
            func ring(_ r: CGFloat, _ width: CGFloat, _ color: Color) {
                ctx.stroke(circle(r), with: .color(color), lineWidth: width)
            }
            var rng = SeededRandom(seed)

            ctx.fill(circle(R), with: .radialGradient(
                Gradient(colors: [Color(white: 0.1), Color(white: 0.045), Color(white: 0.03)]),
                center: c, startRadius: 0, endRadius: R))

            // Grooves.
            var r = R * 0.36
            while r < R * 0.955 {
                ring(r, 0.55, .white.opacity(Double.random(in: 0.015...0.055, using: &rng)))
                r += CGFloat.random(in: 0.8...1.5, using: &rng)
            }
            // Track gaps: smooth dark bands with a bright edge.
            for _ in 0..<Int.random(in: 4...7, using: &rng) {
                let gr = R * CGFloat.random(in: 0.42...0.92, using: &rng)
                ring(gr, 2.2, Color(white: 0.015))
                ring(gr + 1.4, 0.6, .white.opacity(0.09))
            }
            // Lead-in and the raised outer edge.
            ring(R * 0.972, R * 0.03, Color(white: 0.055))
            ring(R * 0.994, 1.2, .white.opacity(0.14))
            // Run-out area around the label.
            ring(R * 0.35, R * 0.03, Color(white: 0.07))
            ring(R * 0.365, 0.6, .white.opacity(0.1))
        }
    }
}

/// Small irregular highlights on the grooves. They turn with the record, so rotation is
/// visible even on a plain label.
private struct RecordGlints: View {
    let seed: String
    let radius: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            var rng = SeededRandom(seed + "glint")
            for _ in 0..<5 {
                let r = radius * CGFloat.random(in: 0.45...0.9, using: &rng)
                let start = Double.random(in: 0...(2 * .pi), using: &rng)
                var p = Path()
                p.addArc(center: c, radius: r, startAngle: .radians(start),
                         endAngle: .radians(start + Double.random(in: 0.2...0.6, using: &rng)), clockwise: false)
                ctx.stroke(p, with: .color(.white.opacity(0.07)), lineWidth: CGFloat.random(in: 1...3, using: &rng))
            }
        }
    }
}

/// The light on the vinyl: two opposite soft wedges, fixed to the room, not the record.
private struct VinylSheen: View {
    let inner: CGFloat
    let outer: CGFloat

    var body: some View {
        let stops: [Gradient.Stop] = [
            .init(color: .white.opacity(0), location: 0),
            .init(color: .white.opacity(0.16), location: 0.09),
            .init(color: .white.opacity(0), location: 0.2),
            .init(color: .white.opacity(0), location: 0.5),
            .init(color: .white.opacity(0.12), location: 0.59),
            .init(color: .white.opacity(0), location: 0.7),
            .init(color: .white.opacity(0), location: 1),
        ]
        Circle()
            .fill(AngularGradient(gradient: Gradient(stops: stops), center: .center, angle: .degrees(-35)))
            .mask(
                Circle().strokeBorder(Color.white, lineWidth: outer - inner)
            )
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
    }
}

/// The paper label: the track's artwork (from YouTube), the title, and a marker stripe.
private struct RecordLabel: View {
    let track: Track?
    let deck: DeckID
    let radius: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Theme.deck(deck), Theme.deck(deck).opacity(0.6)],
                                         startPoint: .top, endPoint: .bottom))
            if let id = track?.id, let url = URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg") {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        // hqdefault is 4:3 with letterbox bars; zoom in to the art.
                        image.resizable().scaledToFill().scaleEffect(1.36)
                    }
                }
                .frame(width: radius * 2, height: radius * 2)
                .clipShape(Circle())
            }
            // Printed rim and a dark band for the text.
            Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: radius * 0.06)
            Text(track?.title ?? "PLATTER")
                .font(.system(size: radius * 0.14, weight: .bold))
                .lineLimit(1)
                .foregroundColor(.white)
                .padding(.horizontal, radius * 0.1)
                .padding(.vertical, radius * 0.03)
                .background(Capsule().fill(.black.opacity(0.45)))
                .frame(maxWidth: radius * 1.4)
                .offset(y: radius * 0.5)
            Text("33⅓")
                .font(.system(size: radius * 0.12, weight: .heavy))
                .foregroundColor(.white.opacity(0.85))
                .shadow(radius: 1)
                .offset(x: radius * 0.5, y: -radius * 0.18)
            // White marker stripe, the DJ's trick to see the rotation.
            Capsule()
                .fill(Color.white.opacity(0.9))
                .frame(width: radius * 0.07, height: radius * 0.32)
                .offset(y: -radius * 0.74)
        }
        .frame(width: radius * 2, height: radius * 2)
    }
}

private struct StrobeLamp: View {
    let on: Bool
    var body: some View {
        ZStack {
            Circle().fill(Theme.brushedMetal)
            Circle().fill(on ? Theme.amber : Color(white: 0.25)).padding(3)
                .shadow(color: on ? Theme.amber : .clear, radius: 6)
        }
    }
}

// MARK: Tonearm

/// The parts that do not move: the base ring, the arm rest, and the cue lever.
private struct TonearmBase: View {
    let g: TurntableGeometry

    var body: some View {
        let h = g.height
        let restDir = CGPoint(x: cos(TurntableGeometry.restAngle), y: sin(TurntableGeometry.restAngle))
        // Under the straight part of the parked tube.
        let restPos = CGPoint(x: g.pivot.x + restDir.x * g.armLength * 0.38,
                              y: g.pivot.y + restDir.y * g.armLength * 0.38)
        ZStack(alignment: .topLeading) {
            // Base: machined ring, height-adjust ring, dark center.
            Circle()
                .fill(AngularGradient(colors: [Color(white: 0.75), Color(white: 0.4), Color(white: 0.8),
                                               Color(white: 0.45), Color(white: 0.75)], center: .center))
                .frame(width: h * 0.18, height: h * 0.18)
                .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
                .position(g.pivot)
            Circle()
                .fill(Color(white: 0.12))
                .overlay(Circle().strokeBorder(Color(white: 0.5), lineWidth: 1))
                .frame(width: h * 0.12, height: h * 0.12)
                .position(g.pivot)
            // Arm rest: a post with a rubber cradle.
            Circle()
                .fill(Theme.brushedMetal)
                .frame(width: h * 0.045, height: h * 0.045)
                .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                .position(restPos)
            RoundedRectangle(cornerRadius: h * 0.004)
                .fill(Color(white: 0.08))
                .frame(width: h * 0.05, height: h * 0.016)
                .position(restPos)
            // Cue lever.
            Capsule()
                .fill(Theme.brushedMetal)
                .frame(width: h * 0.075, height: h * 0.018)
                .rotationEffect(.degrees(-20))
                .position(x: g.pivot.x - h * 0.02, y: g.pivot.y + h * 0.18)
        }
        .frame(width: g.width, height: g.height)
        .allowsHitTesting(false)
    }
}

/// The S-shaped arm, counterweight, headshell, and cartridge. Parked on its rest when the
/// deck is empty; otherwise its angle follows the playhead from the lead-in to the run-out.
private struct TonearmView: View {
    @ObservedObject var state: DeckState
    let g: TurntableGeometry

    var body: some View {
        let side = (g.armLength + g.height * 0.25) * 2
        ArmDrawing(g: g, cartridge: Theme.deck(state.deck))
            .frame(width: side, height: side)
            .modifier(ArmSwing(state: state, g: g))
            .position(g.pivot)
            .frame(width: g.width, height: g.height)
        .allowsHitTesting(false)
    }
}

/// Swings the arm to the playhead's groove, or to the rest when the deck is empty. Only the
/// angle changes over time; the arm drawing itself is not redrawn.
private struct ArmSwing: ViewModifier {
    @ObservedObject var state: DeckState
    let g: TurntableGeometry

    func body(content: Content) -> some View {
        // The stylus crosses the record once per track, so 2 updates a second are enough.
        // Only lowering onto the record and parking are animated.
        TimelineView(.animation(minimumInterval: 0.5, paused: !state.isPlaying)) { _ in
            let progress = state.duration > 0 ? state.position / state.duration : 0
            let angle = state.hasTrack ? g.playAngle(progress: progress) : TurntableGeometry.restAngle
            content
                .rotationEffect(.radians(angle))
                .animation(.easeInOut(duration: 0.9), value: state.hasTrack)
        }
    }
}

/// The arm, drawn pointing along +x from the canvas center (the pivot). The stylus tip is
/// at `armLength` on the x axis.
private struct ArmDrawing: View {
    let g: TurntableGeometry
    let cartridge: Color

    var body: some View {
        Canvas { ctx, size in
            let h = g.height, L = g.armLength
            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            // The arm's shadow on the record, drawn once with the arm (not a live layer shadow).
            ctx.addFilter(.shadow(color: .black.opacity(0.55), radius: h * 0.01, x: h * 0.012, y: h * 0.022))

            // Counterweight with machined rings.
            let cw = CGRect(x: -h * 0.2, y: -h * 0.042, width: h * 0.11, height: h * 0.084)
            ctx.fill(Path(roundedRect: cw, cornerRadius: h * 0.012), with: .linearGradient(
                Gradient(colors: [Color(white: 0.3), Color(white: 0.85), Color(white: 0.45), Color(white: 0.25)]),
                startPoint: CGPoint(x: 0, y: cw.minY), endPoint: CGPoint(x: 0, y: cw.maxY)))
            for i in 1..<6 {
                let x = cw.minX + cw.width * CGFloat(i) / 6
                var p = Path()
                p.move(to: CGPoint(x: x, y: cw.minY + 1))
                p.addLine(to: CGPoint(x: x, y: cw.maxY - 1))
                ctx.stroke(p, with: .color(.black.opacity(0.35)), lineWidth: 0.8)
            }
            // Rear shaft.
            ctx.fill(Path(CGRect(x: -h * 0.09, y: -h * 0.008, width: h * 0.08, height: h * 0.016)),
                     with: .color(Color(white: 0.55)))

            // S-shaped tube, shaded like a cylinder.
            let end = CGPoint(x: L - h * 0.1, y: -h * 0.012)
            var tube = Path()
            tube.move(to: CGPoint(x: h * 0.02, y: 0))
            tube.addLine(to: CGPoint(x: L * 0.42, y: 0))
            tube.addCurve(to: end,
                          control1: CGPoint(x: L * 0.62, y: 0),
                          control2: CGPoint(x: L * 0.66, y: h * 0.07))
            ctx.stroke(tube, with: .color(Color(white: 0.35)), style: StrokeStyle(lineWidth: h * 0.02, lineCap: .round))
            ctx.stroke(tube, with: .color(Color(white: 0.72)), style: StrokeStyle(lineWidth: h * 0.012, lineCap: .round))
            var hi = ctx
            hi.translateBy(x: 0, y: -h * 0.004)
            hi.stroke(tube, with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: h * 0.003, lineCap: .round))

            // Headshell, from the tube end to just past the stylus.
            let tip = CGPoint(x: L, y: 0)
            var shell = ctx
            shell.translateBy(x: end.x, y: end.y)
            shell.rotate(by: .radians(atan2(tip.y - end.y, tip.x - end.x)))
            let len = hypot(tip.x - end.x, tip.y - end.y)
            let body = CGRect(x: -h * 0.01, y: -h * 0.028, width: len + h * 0.035, height: h * 0.056)
            shell.fill(Path(roundedRect: body, cornerRadius: h * 0.008), with: .linearGradient(
                Gradient(colors: [Color(white: 0.55), Color(white: 0.2)]),
                startPoint: CGPoint(x: 0, y: body.minY), endPoint: CGPoint(x: 0, y: body.maxY)))
            shell.stroke(Path(roundedRect: body, cornerRadius: h * 0.008), with: .color(.white.opacity(0.3)), lineWidth: 0.6)
            // Cartridge body and finger lift.
            shell.fill(Path(roundedRect: CGRect(x: len * 0.45, y: -h * 0.02, width: len * 0.55, height: h * 0.04),
                            cornerRadius: h * 0.004), with: .color(cartridge))
            var lift = Path()
            lift.move(to: CGPoint(x: len * 0.9, y: -h * 0.028))
            lift.addLine(to: CGPoint(x: len * 1.02, y: -h * 0.07))
            shell.stroke(lift, with: .color(Color(white: 0.75)), style: StrokeStyle(lineWidth: h * 0.008, lineCap: .round))

            // Gimbal on the pivot.
            let gim = CGRect(x: -h * 0.035, y: -h * 0.035, width: h * 0.07, height: h * 0.07)
            ctx.fill(Path(ellipseIn: gim), with: .radialGradient(
                Gradient(colors: [Color(white: 0.9), Color(white: 0.45)]),
                center: CGPoint(x: -h * 0.01, y: -h * 0.01), startRadius: 0, endRadius: h * 0.04))
            ctx.stroke(Path(ellipseIn: gim), with: .color(.black.opacity(0.4)), lineWidth: 0.8)
        }
    }
}

// MARK: Controls on the plinth

private struct StartStopButton: View {
    @ObservedObject var state: DeckState
    let fontSize: CGFloat

    var body: some View {
        Button { state.togglePlay() } label: {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: [Color(white: 0.3), Color(white: 0.16)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white.opacity(0.2), lineWidth: 0.8))
                    .shadow(color: .black.opacity(0.7), radius: 2, y: 2)
                Text("START·STOP")
                    .font(.system(size: fontSize, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundColor(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .buttonStyle(PressableStyle())
        .disabled(!state.hasTrack)
        .help("Start or stop the platter")
    }
}

/// Technics-style pitch fader: minus at the top, plus toward you, a click at zero, and the
/// green lamp that lights at exactly 0%. Double-click to reset.
struct PitchSlider: View {
    @ObservedObject var state: DeckState
    @State private var dragStart: Double?

    private let range = Pitch.minFader...Pitch.maxFader

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height, w = geo.size.width
            let knobH = h * 0.08
            let usable = h - knobH
            let frac = (state.pitch - range.lowerBound) / (range.upperBound - range.lowerBound)
            let knobY = knobH / 2 + CGFloat(frac) * usable

            ZStack(alignment: .topLeading) {
                // Scale: a tick every 1%, long at 0 and the ends.
                ForEach(0...16, id: \.self) { i in
                    let y = knobH / 2 + usable * CGFloat(i) / 16
                    let major = i % 8 == 0
                    Rectangle()
                        .fill(Color.white.opacity(major ? 0.6 : 0.3))
                        .frame(width: major ? w * 0.22 : w * 0.12, height: 1)
                        .position(x: w * 0.2, y: y)
                }
                Text("−").position(x: w * 0.85, y: knobH / 2)
                Text("+").position(x: w * 0.85, y: h - knobH / 2)
                Circle()
                    .fill(state.pitch == 0 ? Theme.playGreen : Color(white: 0.2))
                    .shadow(color: state.pitch == 0 ? Theme.playGreen : .clear, radius: 3)
                    .frame(width: 5, height: 5)
                    .position(x: w * 0.85, y: h / 2)
                // Slot.
                Capsule()
                    .fill(Color.black)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6))
                    .frame(width: w * 0.12, height: usable)
                    .position(x: w * 0.52, y: h / 2)
                // Knob with a ridge.
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(colors: [Color(white: 0.85), Color(white: 0.45), Color(white: 0.7)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(Rectangle().fill(Color.black.opacity(0.6)).frame(height: 1.2))
                    .frame(width: w * 0.5, height: knobH)
                    .shadow(color: .black.opacity(0.7), radius: 2, y: 2)
                    .position(x: w * 0.52, y: knobY)
            }
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.white.opacity(0.55))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if dragStart == nil { dragStart = state.pitch }
                        let span = range.upperBound - range.lowerBound
                        var p = (dragStart ?? 0) + Double(v.translation.height / usable) * span
                        p = min(range.upperBound, max(range.lowerBound, p))
                        if abs(p) < 0.0025 { p = 0 } // the click at zero
                        state.pitch = p
                        state.applyPitch()
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(count: 2) {
                state.pitch = 0
                state.applyPitch()
            }
        }
        .help("Pitch ±8%. Double-click resets to 0.")
    }
}

/// A button that sinks a little while pressed.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
    }
}

/// Deterministic random numbers from a string (SplitMix64 over an FNV-1a hash), so a record
/// looks the same every launch.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(_ seed: String) {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        state = h
    }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}
