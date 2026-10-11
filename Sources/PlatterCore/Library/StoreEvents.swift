import Foundation

/// Messages between Platter and Platter Player, which share one store. Distributed
/// notifications, so they work between two processes.
///   - libraryChanged: the store changed (albums, tracks, downloads, history); reload it.
///   - willPlay: one app starts playing; the other pauses when "exclusive" is on.
@MainActor
package final class StoreEvents {
    package enum Event: String {
        case libraryChanged = "local.platter.library-changed"
        case willPlay = "local.platter.will-play"
    }

    /// Sender id: the process, so an app ignores its own messages.
    private let me = String(ProcessInfo.processInfo.processIdentifier)
    private let center = DistributedNotificationCenter.default()
    private var observers: [NSObjectProtocol] = []
    private var pending: Task<Void, Never>?
    /// Appended to the notification names. Tests use their own, so the running apps do not
    /// hear them.
    private let channel: String

    package init(channel: String = "") { self.channel = channel }

    private func name(_ event: Event) -> Notification.Name { Notification.Name(event.rawValue + channel) }

    /// Post now (willPlay), or after 300 ms of quiet (libraryChanged: a burst of writes,
    /// like a playlist import, sends one message).
    package func post(_ event: Event) {
        guard event == .libraryChanged else {
            center.postNotificationName(name(event), object: me, userInfo: nil, deliverImmediately: true)
            return
        }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            self.center.postNotificationName(self.name(event), object: self.me, userInfo: nil, deliverImmediately: true)
        }
    }

    /// Run `handler` when the other app posts `event`.
    package func observe(_ event: Event, _ handler: @escaping @MainActor () -> Void) {
        let me = self.me
        observers.append(center.addObserver(forName: name(event), object: nil, queue: .main) { note in
            guard (note.object as? String) != me else { return }
            MainActor.assumeIsolated { handler() }
        })
    }

    /// Whether starting one app pauses the other. One setting for both, in the store.
    package static let exclusiveKey = "apps.exclusive"
}

/// `platter-player://queue?mode=play&ids=a,b,c`: the DJ app hands tracks to the player.
package enum PlayerLink {
    package enum Mode: String { case play, next, add }

    package static let bundleID = "local.platter.player"

    package static func url(_ ids: [String], mode: Mode) -> URL? {
        var c = URLComponents()
        c.scheme = "platter-player"
        c.host = "queue"
        c.queryItems = [URLQueryItem(name: "mode", value: mode.rawValue),
                        URLQueryItem(name: "ids", value: ids.joined(separator: ","))]
        return c.url
    }

    package static func parse(_ url: URL) -> (mode: Mode, ids: [String])? {
        guard url.scheme == "platter-player", url.host == "queue",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let mode = items.first(where: { $0.name == "mode" })?.value.flatMap(Mode.init(rawValue:)),
              let ids = items.first(where: { $0.name == "ids" })?.value?.split(separator: ",").map(String.init),
              !ids.isEmpty else { return nil }
        return (mode, ids)
    }
}
