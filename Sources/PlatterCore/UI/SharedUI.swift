import SwiftUI
import AppKit

/// "m:ss", or "h:mm:ss" from one hour.
package func formatTime(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}

/// "m:ss.t" for the deck display.
package func formatTimeTenths(_ seconds: Double) -> String {
    let t = max(0, seconds)
    let s = Int(t)
    return String(format: "%d:%02d.%d", s / 60, s % 60, Int((t - Double(s)) * 10))
}

/// A button that sinks a little while pressed.
package struct PressableStyle: ButtonStyle {
    package init() {}

    package func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
    }
}

/// Hands the hosting `NSWindow` to a closure.
package struct WindowAccessor: NSViewRepresentable {
    package let onWindow: (NSWindow?) -> Void

    package init(onWindow: @escaping (NSWindow?) -> Void) { self.onWindow = onWindow }

    package func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onWindow(v.window) }
        return v
    }

    package func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(v.window) }
    }
}

/// Set a rating: none to five stars.
package struct RatingMenu: View {
    package let rating: Int
    package let set: (Int) -> Void

    package init(rating: Int, set: @escaping (Int) -> Void) {
        self.rating = rating
        self.set = set
    }

    package var body: some View {
        Menu("Rating") {
            ForEach(0...5, id: \.self) { n in
                Button(n == 0 ? "None" : String(repeating: "★", count: n)) { set(n) }
                    .disabled(n == rating)
            }
        }
    }
}
