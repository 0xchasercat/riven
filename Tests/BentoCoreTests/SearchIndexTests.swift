import Foundation
import Testing
@testable import BentoCore

@Suite("Unified search")
struct SearchIndexTests {
    @Test("combines file matches and scrollback matches")
    func combinedSearch() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "let migration = true\n".write(to: root.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
        let scrollback = ScrollbackStore.temporary()
        try scrollback.append("ran migration 2026\n", to: PaneID("api"))

        let index = UnifiedSearchIndex(projectRoot: root, scrollbackStore: scrollback)
        let results = try index.search("migration")

        #expect(results.contains(.file(path: root.appendingPathComponent("App.swift").path, lineNumber: 1, line: "let migration = true")))
        #expect(results.contains(.scrollback(ScrollbackMatch(paneID: PaneID("api"), lineNumber: 1, line: "ran migration 2026"))))
    }
}
