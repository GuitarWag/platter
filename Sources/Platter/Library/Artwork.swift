import AppKit
import AVFoundation

/// Cover art for a track: the art embedded in an imported file, or the YouTube thumbnail.
/// Cached on disk in Application Support/Platter/artwork, and in memory.
@MainActor
enum Artwork {
    private static var memory: [String: NSImage] = [:]
    private static var directory: URL {
        let d = AppPaths.support.appendingPathComponent("artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func image(for track: Track, audioDirectory: URL) async -> NSImage? {
        if let m = memory[track.id] { return m }
        let file = directory.appendingPathComponent("\(track.id).jpg")
        if let data = try? Data(contentsOf: file), let img = NSImage(data: data) {
            memory[track.id] = img
            return img
        }
        var data: Data?
        if track.isLocal, let name = track.fileName {
            data = await embedded(audioDirectory.appendingPathComponent(name))
        } else if !track.isLocal, let url = URL(string: "https://i.ytimg.com/vi/\(track.id)/hqdefault.jpg") {
            data = try? await URLSession.shared.data(from: url).0
        }
        guard let data, let img = NSImage(data: data) else { return nil }
        try? data.write(to: file)
        memory[track.id] = img
        return img
    }

    private static func embedded(_ url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let md = try? await asset.load(.commonMetadata),
              let item = AVMetadataItem.metadataItems(from: md, filteredByIdentifier: .commonIdentifierArtwork).first
        else { return nil }
        return try? await item.load(.dataValue)
    }
}
