import Foundation
import Testing
@testable import BentoCore

@Suite("Unified search")
struct SearchIndexTests {
    private func freshProjectRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bento-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("combines file hits and scrollback hits using the v2 schema")
    func combinedSearch() throws {
        let root = try freshProjectRoot()
        try "let migration = true\nlet other = false\n"
            .write(to: root.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
        let scrollback = ScrollbackStore.temporary()
        try scrollback.append("ran migration 2026\n", to: PaneID("api"))

        let index = UnifiedSearchIndex(projectRoot: root, scrollbackStore: scrollback)
        let results = try index.search("migration")

        let fileHits = results.compactMap { result -> FileSearchHit? in
            if case .file(let hit) = result { return hit } else { return nil }
        }
        #expect(fileHits.contains(where: { $0.path.hasSuffix("App.swift") && $0.lineNumber == 1 && $0.line == "let migration = true" }))

        let scrollbackHits = results.compactMap { result -> ScrollbackMatch? in
            if case .scrollback(let match, _) = result { return match } else { return nil }
        }
        #expect(scrollbackHits.contains(ScrollbackMatch(paneID: PaneID("api"), lineNumber: 1, line: "ran migration 2026")))
    }

    @Test("file hits carry surrounding context lines")
    func fileHitsCarryContext() throws {
        let root = try freshProjectRoot()
        let body = "line one\nlet migration = true\nline three\n"
        try body.write(to: root.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
        let scrollback = ScrollbackStore.temporary()

        let index = UnifiedSearchIndex(projectRoot: root, scrollbackStore: scrollback)
        let results = try index.search("migration")

        let hit = try #require(results.compactMap { result -> FileSearchHit? in
            if case .file(let hit) = result { return hit } else { return nil }
        }.first)

        #expect(hit.contextBefore == "line one")
        #expect(hit.contextAfter == "line three")
    }

    @Test("scrollback hits include sidecar context when present")
    func scrollbackHitsCarryMetadata() throws {
        let root = try freshProjectRoot()
        let scrollback = ScrollbackStore.temporary()
        let paneID = PaneID("api")
        try scrollback.append("ran migration 2026\n", to: paneID)
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        try scrollback.writeMetadata(
            ScrollbackMetadata(
                paneID: paneID,
                sessionID: "s",
                projectRoot: "/tmp/proj",
                workspaceName: "proj",
                cwd: "/tmp/proj/src",
                paneLabel: "bench run",
                createdAt: created,
                lastWriteAt: created.addingTimeInterval(120),
                byteCount: 42
            )
        )

        let index = UnifiedSearchIndex(projectRoot: root, scrollbackStore: scrollback)
        let results = try index.search("migration")

        let (_, context) = try #require(results.compactMap { result -> (ScrollbackMatch, ScrollbackMatchContext?)? in
            if case .scrollback(let match, let ctx) = result, match.paneID == paneID {
                return (match, ctx)
            }
            return nil
        }.first)

        let resolved = try #require(context)
        #expect(resolved.projectRoot == "/tmp/proj")
        #expect(resolved.workspaceName == "proj")
        #expect(resolved.paneLabel == "bench run")
        #expect(resolved.cwd == "/tmp/proj/src")
        #expect(resolved.firstSeenAt == created)
        #expect(resolved.lastWriteAt == created.addingTimeInterval(120))
    }

    @Test("scrollback hits with no sidecar still appear with nil context")
    func scrollbackWithoutSidecarStillAppears() throws {
        let root = try freshProjectRoot()
        let scrollback = ScrollbackStore.temporary()
        try scrollback.append("legacy migration trail\n", to: PaneID("legacy"))

        let index = UnifiedSearchIndex(projectRoot: root, scrollbackStore: scrollback)
        let results = try index.search("migration")

        let entry = try #require(results.compactMap { result -> (ScrollbackMatch, ScrollbackMatchContext?)? in
            if case .scrollback(let match, let ctx) = result, match.paneID == PaneID("legacy") {
                return (match, ctx)
            }
            return nil
        }.first)

        #expect(entry.1 == nil)
    }

    @Test("allProjects scope walks every project root referenced by sidecars")
    func allProjectsScope() throws {
        let projectA = try freshProjectRoot()
        try "let alpha_marker = 1\n"
            .write(to: projectA.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)

        let projectB = try freshProjectRoot()
        try "let alpha_marker = 2\n"
            .write(to: projectB.appendingPathComponent("B.swift"), atomically: true, encoding: .utf8)

        let scrollback = ScrollbackStore.temporary()
        // Sidecar pointing at projectB so allProjects discovers it.
        try scrollback.writeMetadata(
            ScrollbackMetadata(
                paneID: PaneID("p-b"),
                sessionID: "s",
                projectRoot: projectB.path,
                workspaceName: "b",
                cwd: projectB.path,
                paneLabel: nil
            )
        )

        let index = UnifiedSearchIndex(projectRoot: projectA, scrollbackStore: scrollback)

        let scoped = try index.search("alpha_marker", scope: .thisProject)
        let scopedRoots = Set(scoped.compactMap { result -> String? in
            if case .file(let hit) = result { return hit.projectRoot } else { return nil }
        })
        #expect(scopedRoots == [projectA.path])

        let all = try index.search("alpha_marker", scope: .allProjects)
        let allRoots = Set(all.compactMap { result -> String? in
            if case .file(let hit) = result { return hit.projectRoot } else { return nil }
        })
        #expect(allRoots.contains(projectA.path))
        #expect(allRoots.contains(projectB.path))
    }
}
