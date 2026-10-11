import XCTest
import SwiftUI
import AVFoundation
@testable import PlatterCore
@testable import PlatterPlayer

/// Renders each built-in skin offscreen. Catches layout crashes; set PLATTER_RENDER_DIR to
/// keep the PNGs for a look.
@MainActor
final class SkinRenderTests: XCTestCase {
    func testBuiltInSkinsRender() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = Library(db: try LibraryDB(path: ":memory:"), audioDirectory: dir)
        let engine = AudioEngine(decks: false, offline: AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!)
        let model = PlayerAppModel(library: library, engine: engine)
        model.player.persists = false
        model.player.recordsHistory = false

        let views: [(String, AnyView)] = [
            ("platter", AnyView(PlatterSkinView(model: model))),
            ("chrome", AnyView(PodSkinView(model: model, palette: .chrome))),
            ("ruby", AnyView(PodSkinView(model: model, palette: .ruby))),
        ]
        let out = ProcessInfo.processInfo.environment["PLATTER_RENDER_DIR"].map(URL.init(fileURLWithPath:))
        for (name, view) in views {
            let r = ImageRenderer(content: view.environment(\.colorScheme, .dark))
            r.scale = 2
            let image = try XCTUnwrap(r.nsImage, name)
            XCTAssertGreaterThan(image.size.width, 100, name)
            if let out, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: out.appendingPathComponent("\(name).png"))
            }
        }
    }
}
