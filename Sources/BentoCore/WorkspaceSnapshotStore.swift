import Foundation

public struct WorkspaceSnapshotStore: Sendable {
    public var root: URL

    public init(root: URL) {
        self.root = root
    }

    public func save(_ snapshot: WorkspaceSnapshot) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder.bento.encode(snapshot)
        try data.write(to: url(projectRoot: snapshot.projectRoot), options: .atomic)
    }

    public func load(projectRoot: String) throws -> WorkspaceSnapshot? {
        let url = url(projectRoot: projectRoot)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder.bento.decode(WorkspaceSnapshot.self, from: data)
    }

    private func url(projectRoot: String) -> URL {
        let name = Data(projectRoot.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        return root.appendingPathComponent(name).appendingPathExtension("json")
    }
}

private extension JSONEncoder {
    static var bento: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var bento: JSONDecoder {
        JSONDecoder()
    }
}
