import SwiftUI

/// Colors and small shared pieces of the hardware look.
enum Theme {
    static let background = Color(red: 0.055, green: 0.055, blue: 0.06)
    static let panel = Color(red: 0.09, green: 0.09, blue: 0.10)
    static let panelRaised = Color(red: 0.13, green: 0.13, blue: 0.14)
    static let screen = Color(red: 0.02, green: 0.03, blue: 0.04)
    static let line = Color.white.opacity(0.08)
    static let textDim = Color.white.opacity(0.45)
    static let amber = Color(red: 1.0, green: 0.62, blue: 0.1)
    static let playGreen = Color(red: 0.25, green: 0.9, blue: 0.45)
    static let wave = Color(red: 0.25, green: 0.6, blue: 1.0)

    static func deck(_ id: DeckID) -> Color {
        id == .a ? Color(red: 0.2, green: 0.8, blue: 1.0) : Color(red: 1.0, green: 0.5, blue: 0.15)
    }

    /// Hot cue pad colors, like DJ player pads.
    static let cueColors: [Color] = [
        .green, .cyan, .blue, .purple, .pink, .red, .orange, .yellow,
    ]

    /// Anodized dark aluminium: a soft top-left light over graphite.
    static let plinth = LinearGradient(
        colors: [Color(white: 0.24), Color(white: 0.15), Color(white: 0.11)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let brushedMetal = LinearGradient(
        colors: [Color(white: 0.78), Color(white: 0.55), Color(white: 0.82), Color(white: 0.5)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Small caps label used on panels.
struct PanelLabel: View {
    let text: String
    var color: Color = Theme.textDim
    init(_ text: String, color: Color = Theme.textDim) {
        self.text = text
        self.color = color
    }
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .heavy))
            .tracking(0.8)
            .foregroundColor(color)
    }
}

/// "m:ss", or "h:mm:ss" from one hour.
func formatTime(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}

/// "m:ss.t" for the deck display.
func formatTimeTenths(_ seconds: Double) -> String {
    let t = max(0, seconds)
    let s = Int(t)
    return String(format: "%d:%02d.%d", s / 60, s % 60, Int((t - Double(s)) * 10))
}
