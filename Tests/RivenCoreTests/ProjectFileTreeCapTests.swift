import Foundation
import Testing
@testable import RivenCore

@Suite("ProjectFileTree cap (H-12)")
struct ProjectFileTreeCapTests {
    private func makeDirectory(fileCount: Int) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("riven-cap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<fileCount {
            // Zero-pad so default name sort matches the cap's pre-sort.
            let name = "file-\(String(format: "%05d", i)).txt"
            try Data("noise\n".utf8).write(to: root.appendingPathComponent(name))
        }
        return root
    }

    @Test("scan truncates child arrays past the cap")
    func capsLargeDirectory() throws {
        let root = try makeDirectory(fileCount: 25)
        defer { try? FileManager.default.removeItem(at: root) }

        let tree = try ProjectFileTree.scan(root: root, maxDepth: 2, maxChildrenPerDirectory: 10)
        #expect(tree.children.count == 10)
        #expect(tree.truncatedChildren == 15)
    }

    @Test("scan keeps every child when the directory fits under the cap")
    func underCapNoTruncation() throws {
        let root = try makeDirectory(fileCount: 8)
        defer { try? FileManager.default.removeItem(at: root) }

        let tree = try ProjectFileTree.scan(root: root, maxDepth: 2, maxChildrenPerDirectory: 100)
        #expect(tree.children.count == 8)
        #expect(tree.truncatedChildren == 0)
    }

    @Test("legacy snapshot JSON without truncatedChildren still decodes")
    func legacyDecode() throws {
        // Mirrors what older snapshots wrote: no `truncatedChildren` key.
        let json = """
        {
          "name": "old",
          "path": "/old",
          "kind": "directory",
          "children": []
        }
        """
        let decoded = try JSONDecoder().decode(ProjectFileTree.self, from: Data(json.utf8))
        #expect(decoded.truncatedChildren == 0)
        #expect(decoded.name == "old")
    }
}
