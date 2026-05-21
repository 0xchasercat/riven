import Foundation
import Testing
@testable import BentoCore

@Suite("Scrollback store")
struct ScrollbackStoreTests {
    @Test("appends and searches pane scrollback files")
    func appendAndSearch() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let store = ScrollbackStore(root: root)
        let paneID = PaneID("api")

        try store.append("cargo run\n", to: paneID)
        try store.append("database migrated\n", to: paneID)

        let matches = try store.search("migrated")

        #expect(matches == [
            ScrollbackMatch(paneID: paneID, lineNumber: 2, line: "database migrated")
        ])
    }

    @Test("search skips files with invalid UTF-8 and returns matches from valid files")
    func searchTolersCorruptedFile() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bento-corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ScrollbackStore(root: root)

        // A valid log we expect to match.
        let validID = PaneID("valid")
        try store.append("good migration ran ok\n", to: validID)

        // A second log with invalid UTF-8 (lone continuation bytes that
        // can't be decoded as UTF-8). Search must skip it without throwing.
        let badID = PaneID("bad")
        let badURL = root.appendingPathComponent("\(badID.rawValue).log")
        let badBytes = Data([0xFF, 0xFE, 0xFD, 0x80, 0x81, 0x82, 0x0A])
        try badBytes.write(to: badURL)

        let matches = try store.search("migration")
        #expect(matches == [
            ScrollbackMatch(paneID: validID, lineNumber: 1, line: "good migration ran ok")
        ])
    }
}
