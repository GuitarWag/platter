import XCTest
@testable import PlatterCore

@MainActor
final class StoreEventsTests: XCTestCase {
    func testPlayerLinkRoundTrip() throws {
        let ids = ["IBy7TCSY2wk", "-dash-first", "local-1a2b"]
        for mode in [PlayerLink.Mode.play, .next, .add] {
            let url = try XCTUnwrap(PlayerLink.url(ids, mode: mode))
            XCTAssertEqual(url.scheme, "platter-player")
            let parsed = try XCTUnwrap(PlayerLink.parse(url))
            XCTAssertEqual(parsed.mode, mode)
            XCTAssertEqual(parsed.ids, ids)
        }
        XCTAssertNil(PlayerLink.parse(URL(string: "platter-player://queue?mode=play&ids=")!))
        XCTAssertNil(PlayerLink.parse(URL(string: "platter-player://queue?mode=dance&ids=a")!))
        XCTAssertNil(PlayerLink.parse(URL(string: "https://queue?mode=play&ids=a")!))
    }

    func testLibraryTellsTheOtherAppOnceAndNotBack() throws {
        let db = try LibraryDB(path: ":memory:")
        let dir = FileManager.default.temporaryDirectory
        let library = Library(db: db, audioDirectory: dir)
        var posts = 0
        library.onStoreChanged = { posts += 1 }
        library.createAlbum(named: "Mine")
        XCTAssertGreaterThanOrEqual(posts, 1, "a local change is announced")
        let before = posts
        // The other app added an album straight into the store.
        try db.createAlbum(name: "Theirs", sourceURL: nil)
        library.reloadFromStore()
        XCTAssertEqual(posts, before, "reloading for the other app does not echo back")
        XCTAssertEqual(Set(library.albums.map(\.name)), ["Mine", "Theirs"])
    }

    func testReceivesOtherSendersOnly() async throws {
        let events = StoreEvents()
        var got = 0
        events.observe(.libraryChanged) { got += 1 }
        let center = DistributedNotificationCenter.default()
        let name = Notification.Name(StoreEvents.Event.libraryChanged.rawValue)
        center.postNotificationName(name, object: "another-process", userInfo: nil, deliverImmediately: true)
        center.postNotificationName(name, object: String(ProcessInfo.processInfo.processIdentifier),
                                    userInfo: nil, deliverImmediately: true)
        for _ in 0..<40 where got == 0 { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(got, 1, "one from the other app; its own is ignored")
    }
}
