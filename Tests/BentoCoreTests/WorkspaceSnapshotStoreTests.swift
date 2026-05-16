import Foundation
import Testing
@testable import BentoCore

@Suite("Workspace snapshots")
struct WorkspaceSnapshotStoreTests {
    @Test("saves and loads snapshots per project")
    func saveLoadSnapshot() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = WorkspaceSnapshotStore(root: root)
        let pane = PaneDescriptor(
            id: PaneID("root"),
            name: "editor",
            kind: .editor(EditorPane(path: "/repo/Package.swift")),
            isFocused: true
        )
        let snapshot = WorkspaceSnapshot(
            projectRoot: "/repo",
            selectedThemeID: "bento",
            paneGraph: PaneGraph(root: pane),
            openFiles: ["/repo/Package.swift"]
        )

        try store.save(snapshot)

        #expect(try store.load(projectRoot: "/repo") == snapshot)
    }
}
