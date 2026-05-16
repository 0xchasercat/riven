import Foundation
import Testing
@testable import BentoCore

@Suite("Project file tree")
struct ProjectFileTreeTests {
    @Test("scans directories before files and skips hidden/build folders")
    func scansProjectTree() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/Bento"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".build"), withIntermediateDirectories: true)
        try "app".write(to: root.appendingPathComponent("Sources/Bento/App.swift"), atomically: true, encoding: .utf8)
        try "readme".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "ignored".write(to: root.appendingPathComponent(".build/output.txt"), atomically: true, encoding: .utf8)

        let tree = try ProjectFileTree.scan(root: root)

        #expect(tree.name == root.lastPathComponent)
        #expect(tree.children.map(\.name) == ["Sources", "README.md"])
        #expect(tree.children[0].children.map(\.name) == ["Bento"])
        #expect(tree.children[0].children[0].children.map(\.name) == ["App.swift"])
    }

    @Test("limits depth to keep huge trees responsive")
    func depthLimit() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a/b/c"), withIntermediateDirectories: true)
        try "leaf".write(to: root.appendingPathComponent("a/b/c/file.txt"), atomically: true, encoding: .utf8)

        let tree = try ProjectFileTree.scan(root: root, maxDepth: 1)

        #expect(tree.children.map(\.name) == ["a"])
        #expect(tree.children[0].children.isEmpty)
    }
}
