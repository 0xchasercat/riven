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
}
