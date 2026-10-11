import XCTest
import SwiftUI
import AVFoundation
@testable import PlatterCore
@testable import PlatterPlayer

@MainActor
final class ClassicSkinTests: XCTestCase {
    func testParseVisColors() {
        let text = (0..<24).map { "\($0),\($0 + 1),300, // color \($0)" }.joined(separator: "\r\n")
        let c = ClassicSkin.parseVisColors(text)
        XCTAssertEqual(c.count, 24)
        XCTAssertEqual(c[5], [5, 6, 255], "clamped, comment ignored")
        XCTAssertEqual(ClassicSkin.parseVisColors("1,2,3"), ClassicSkin.defaultVisColors, "short file: defaults")
    }

    func testParseRegion() {
        let text = """
        ; a comment
        [Normal]
        NumPoints = 4, 2, 3
        PointList = 0,0, 275,0, 275,116, 0,116,  1,1, 2,2,  10,10 20,10 15,20
        [WindowShade]
        NumPoints=4
        PointList=0,0,1,0,1,1,0,1
        """
        let r = ClassicSkin.parseRegion(text)
        XCTAssertEqual(r.count, 2, "the 2-point polygon is skipped, WindowShade ignored")
        XCTAssertEqual(r[0][2], CGPoint(x: 275, y: 116))
        XCTAssertEqual(r[1], [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 10), CGPoint(x: 15, y: 20)])
        XCTAssertTrue(ClassicSkin.parseRegion("").isEmpty)
        XCTAssertEqual(ClassicSkin.parseRegion("[Normal]\nNumPoints=4\nPointList=0,0,1").count, 0, "too few points")
    }

    func testGlyphs() {
        XCTAssertEqual(ClassicSkin.glyph("A").row, 0)
        XCTAssertEqual(ClassicSkin.glyph("z").col, 25)
        XCTAssertEqual(ClassicSkin.glyph("7").col, 7)
        XCTAssertEqual(ClassicSkin.glyph("#").col, 30)
        XCTAssertEqual(ClassicSkin.glyph("é").col, 4, "accents fold")
        XCTAssertEqual(ClassicSkin.glyph("ä").row, 2)
        XCTAssertEqual(ClassicSkin.glyph("?").row, 2)
        XCTAssertEqual(ClassicSkin.glyph("<").col, 22)
        XCTAssertEqual(ClassicSkin.glyph("€").col, 30, "unknown: space")
        XCTAssertEqual(ClassicSkin.glyph("ß").col, 30, "upper case is two letters: no trap")
    }

    /// A generated skin: upper-case names in a folder inside the zip, as many real skins have.
    func testLoadAndRender() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inner = dir.appendingPathComponent("src/MySkin")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sheets: [(String, Int, Int, NSColor)] = [
            ("MAIN.BMP", 275, 116, .darkGray), ("Titlebar.bmp", 344, 87, .systemBlue), ("CBUTTONS.BMP", 136, 36, .lightGray),
            ("NUMBERS.BMP", 99, 13, .green), ("TEXT.BMP", 155, 18, .green), ("POSBAR.BMP", 307, 10, .gray),
            ("VOLUME.BMP", 68, 433, .orange), ("SHUFREP.BMP", 92, 85, .lightGray),
        ]
        for (name, w, h, color) in sheets {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            color.setFill()
            NSRect(x: 0, y: 0, width: w, height: h).fill()
            NSColor.black.setStroke()
            NSBezierPath(rect: NSRect(x: 0.5, y: 0.5, width: CGFloat(w - 1), height: CGFloat(h - 1))).stroke()
            NSGraphicsContext.restoreGraphicsState()
            try rep.representation(using: .bmp, properties: [:])!.write(to: inner.appendingPathComponent(name))
        }
        // A window with the top-right corner cut off.
        try "[Normal]\nNumPoints=5\nPointList=0,0, 255,0, 275,20, 275,116, 0,116\n"
            .write(to: inner.appendingPathComponent("REGION.TXT"), atomically: true, encoding: .ascii)
        let wsz = dir.appendingPathComponent("Test.wsz")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = dir.appendingPathComponent("src")
        zip.arguments = ["-qr", wsz.path, "MySkin"]
        try zip.run()
        zip.waitUntilExit()

        let skin = try ClassicSkin(url: wsz)
        XCTAssertNotNil(skin.sprite("main", 0, 0, 275, 116))
        XCTAssertNotNil(skin.sprite("cbuttons", 23, 18, 23, 18))
        XCTAssertNil(skin.sprite("cbuttons", 130, 30, 23, 18), "past the edge of the sheet")
        XCTAssertNil(skin.sprite("eqmain", 0, 0, 10, 10), "missing sheet")
        XCTAssertEqual(skin.region.count, 1)
        XCTAssertEqual(skin.visColors.count, 24, "no viscolor.txt: defaults")

        let notSkin = dir.appendingPathComponent("Empty.wsz")
        try Data("not a zip".utf8).write(to: notSkin)
        XCTAssertThrowsError(try ClassicSkin(url: notSkin))

        let library = Library(db: try LibraryDB(path: ":memory:"), audioDirectory: dir)
        let engine = AudioEngine(decks: false, offline: AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!)
        let model = PlayerAppModel(library: library, engine: engine)
        model.player.persists = false
        model.player.recordsHistory = false
        // With the EQ and playlist windows docked, a queue, and an EQ curve.
        model.player.enqueue([Track(id: "t1", title: "Café del Mar", artist: "Energy 52", duration: 400),
                              Track(id: "t2", title: "Strobe", artist: "deadmau5", duration: 600)])
        model.player.prefs.eqGains = [6, 4, 2, 0, -2, -4, -2, 0, 3, 6]
        UserDefaults.standard.set(true, forKey: "classic.eq")
        UserDefaults.standard.set(true, forKey: "classic.pl")
        defer { ["classic.eq", "classic.pl"].forEach(UserDefaults.standard.removeObject(forKey:)) }

        // PLATTER_TEST_WSZ: also render a real skin, for a look.
        let env = ProcessInfo.processInfo.environment
        let real = try env["PLATTER_TEST_WSZ"].map { try ClassicSkin(url: URL(fileURLWithPath: $0)) }
        for (name, s) in [("classic", skin), ("classic-real", real)] {
            guard let s else { continue }
            let image = try XCTUnwrap(ImageRenderer(content: ClassicMainWindow(model: model, skin: s)).cgImage)
            XCTAssertEqual(image.width, 550)
            XCTAssertEqual(image.height, 2 * (116 + 116 + 174), "main, EQ, and playlist")
            if let out = env["PLATTER_RENDER_DIR"],
               let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name).png"))
            }
        }
    }
}
