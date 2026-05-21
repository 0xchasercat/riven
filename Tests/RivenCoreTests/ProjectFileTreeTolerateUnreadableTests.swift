import Foundation
import Testing
@testable import RivenCore

/// Regression coverage for the "one TCC-locked file kills the whole
/// sidebar scan" bug. Before the fix, `scanNode` used `try .map`
/// over its children — a single throw blew up the parent's entire
/// child list. After: per-child errors are swallowed silently and
/// only the unreadable subset is missing from the tree.
@Suite("ProjectFileTree tolerates unreadable children")
struct ProjectFileTreeTolerateUnreadableTests {
    private func tempRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("riven-scan-tcc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("dangling symlink doesn't abort the parent scan")
    func danglingSymlinkDoesntKillScan() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // One real file the scan should still surface.
        let real = root.appendingPathComponent("real.txt")
        try Data("hi\n".utf8).write(to: real)

        // A symlink pointing at a path that doesn't exist. macOS
        // resourceValues() returns nil for both isDirectory and
        // isRegularFile on a dangling link rather than throwing, so
        // the link itself ends up classified as a file in the scan
        // result (which matches what Finder does too). The
        // regression we're guarding against is "one throwing child
        // aborts the whole sibling list" — verified here by the
        // sibling `real.txt` appearing.
        let danglingLink = root.appendingPathComponent("dangling-link")
        try FileManager.default.createSymbolicLink(
            at: danglingLink,
            withDestinationURL: URL(fileURLWithPath: "/nonexistent/path/that/never/existed")
        )

        let tree = try ProjectFileTree.scan(root: root, maxDepth: 2)
        let names = tree.children.map(\.name)
        #expect(names.contains("real.txt"))
    }

    @Test("unreadable subdirectory becomes an empty folder, parent still scans")
    func unreadableSubdirIsEmpty() throws {
        let root = try tempRoot()
        defer {
            // Restore perms before cleanup so the test doesn't
            // leak a non-deletable temp tree on failure.
            let locked = root.appendingPathComponent("locked")
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }

        // Sibling we expect to see in the result.
        let visible = root.appendingPathComponent("visible.swift")
        try Data("ok\n".utf8).write(to: visible)

        // Directory we'll chmod to 0 so contentsOfDirectory throws.
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("nope\n".utf8).write(to: locked.appendingPathComponent("inside.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

        let tree = try ProjectFileTree.scan(root: root, maxDepth: 3)
        let names = tree.children.map(\.name)
        #expect(names.contains("visible.swift"))
        // `locked` itself appears (we can stat it) but its children
        // are empty because contentsOfDirectory threw.
        if let lockedNode = tree.children.first(where: { $0.name == "locked" }) {
            #expect(lockedNode.kind == .directory)
            #expect(lockedNode.children.isEmpty)
        } else {
            Issue.record("Expected 'locked' to appear as an empty directory")
        }
    }
}
