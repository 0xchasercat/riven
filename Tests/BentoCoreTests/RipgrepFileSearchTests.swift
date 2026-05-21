import Foundation
import Testing
@testable import BentoCore

@Suite("RipgrepFileSearch")
struct RipgrepFileSearchTests {
    private func freshRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bento-rg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("bundled() resolves the vendored Universal2 binary")
    func bundledResolves() throws {
        let rg = try #require(RipgrepFileSearch.bundled())
        // The binary must be marked executable to be runnable via `Process`.
        #expect(FileManager.default.isExecutableFile(atPath: rg.binaryURL.path))
    }

    @Test("returns matches with line numbers and context")
    func returnsMatches() throws {
        let rg = try #require(RipgrepFileSearch.bundled())
        let root = try freshRoot()
        let body = "intro\nlet needle = 42\noutro\n"
        try body.write(to: root.appendingPathComponent("file.swift"), atomically: true, encoding: .utf8)

        let hits = try rg.search(query: "needle", root: root)
        let hit = try #require(hits.first)
        #expect(hit.lineNumber == 2)
        #expect(hit.line.contains("needle"))
        #expect(hit.contextBefore == "intro")
        #expect(hit.contextAfter == "outro")
        #expect(hit.projectRoot == root.path)
    }

    @Test("honours .gitignore (no hits inside ignored dirs)")
    func honoursGitignore() throws {
        let rg = try #require(RipgrepFileSearch.bundled())
        let root = try freshRoot()
        try ".build/\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        let buildDir = root.appendingPathComponent(".build")
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        try "let ignored_marker = 1\n".write(to: buildDir.appendingPathComponent("ignored.swift"), atomically: true, encoding: .utf8)
        try "let tracked_marker = 1\n".write(to: root.appendingPathComponent("tracked.swift"), atomically: true, encoding: .utf8)

        let hits = try rg.search(query: "ignored_marker", root: root)
        #expect(hits.isEmpty)

        let tracked = try rg.search(query: "tracked_marker", root: root)
        #expect(tracked.count == 1)
    }
}
