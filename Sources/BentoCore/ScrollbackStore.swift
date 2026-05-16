import Foundation

public struct ScrollbackMatch: Equatable, Codable, Sendable {
    public var paneID: PaneID
    public var lineNumber: Int
    public var line: String

    public init(paneID: PaneID, lineNumber: Int, line: String) {
        self.paneID = paneID
        self.lineNumber = lineNumber
        self.line = line
    }
}

public struct ScrollbackStore: Sendable {
    public var root: URL

    public init(root: URL) {
        self.root = root
    }

    public func append(_ text: String, to paneID: PaneID) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = fileURL(for: paneID)
        let data = Data(text.utf8)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    public func search(_ query: String) throws -> [ScrollbackMatch] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var matches: [ScrollbackMatch] = []

        for file in files where file.pathExtension == "log" {
            let paneID = PaneID(file.deletingPathExtension().lastPathComponent)
            let content = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if line.localizedCaseInsensitiveContains(query) {
                    matches.append(ScrollbackMatch(paneID: paneID, lineNumber: index + 1, line: String(line)))
                }
            }
        }

        return matches
    }

    private func fileURL(for paneID: PaneID) -> URL {
        root.appendingPathComponent(paneID.rawValue).appendingPathExtension("log")
    }
}
