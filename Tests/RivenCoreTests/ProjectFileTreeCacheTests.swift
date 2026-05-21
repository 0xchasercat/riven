import Foundation
import Testing
@testable import RivenCore

@Suite("ProjectFileTreeCache")
struct ProjectFileTreeCacheTests {
    private func tempRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("riven-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("snapshot returns nil before any store")
    func snapshotEmpty() async throws {
        let cache = ProjectFileTreeCache()
        #expect(await cache.snapshot(for: "/tmp/never-stored") == nil)
    }

    @Test("loadAndCache populates the cache; subsequent snapshot is instant")
    func loadAndCacheRoundTrip() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("a\n".utf8).write(to: root.appendingPathComponent("a.txt"))

        let cache = ProjectFileTreeCache()
        let loaded = await cache.loadAndCache(path: root.path)
        #expect(loaded != nil)
        #expect(loaded?.children.contains(where: { $0.name == "a.txt" }) == true)

        // Snapshot should now hit synchronously — the cache returns
        // the same tree shape.
        let cached = await cache.snapshot(for: root.path)
        #expect(cached?.path == loaded?.path)
        #expect(cached?.children.count == loaded?.children.count)
    }

    @Test("store overrides a prior snapshot for the same path")
    func storeOverwrites() async throws {
        let cache = ProjectFileTreeCache()
        let first = ProjectFileTree(name: "first", path: "/x", kind: .directory)
        let second = ProjectFileTree(
            name: "second",
            path: "/x",
            kind: .directory,
            children: [ProjectFileTree(name: "f.txt", path: "/x/f.txt", kind: .file)]
        )
        await cache.store(first, for: "/x")
        await cache.store(second, for: "/x")
        let got = await cache.snapshot(for: "/x")
        #expect(got?.name == "second")
        #expect(got?.children.count == 1)
    }

    @Test("clear drops every entry")
    func clearWipes() async throws {
        let cache = ProjectFileTreeCache()
        await cache.store(
            ProjectFileTree(name: "a", path: "/a", kind: .directory),
            for: "/a"
        )
        await cache.store(
            ProjectFileTree(name: "b", path: "/b", kind: .directory),
            for: "/b"
        )
        await cache.clear()
        #expect(await cache.snapshot(for: "/a") == nil)
        #expect(await cache.snapshot(for: "/b") == nil)
    }
}
