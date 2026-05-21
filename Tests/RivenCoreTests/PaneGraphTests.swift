import Testing
@testable import RivenCore

@Suite("Pane graph")
struct PaneGraphTests {
    @Test("splitting a pane creates a child that inherits cwd and focus")
    func splitInheritsContext() throws {
        let root = PaneDescriptor(
            id: PaneID("root"),
            name: "api",
            kind: .terminal(TerminalPane(command: nil, cwd: "/repo/backend")),
            isFocused: true
        )

        var graph = PaneGraph(root: root)
        let child = try graph.split(PaneID("root"), direction: .right)

        #expect(graph.panes.count == 2)
        #expect(graph.pane(child)?.terminal?.cwd == "/repo/backend")
        #expect(graph.focusedPaneID == child)
        #expect(graph.rootNode == .split(.right, .leaf(PaneID("root")), .leaf(child)))
    }

    @Test("flipping terminal to editor preserves pane identity and cwd")
    func flipTerminalToEditor() throws {
        let root = PaneDescriptor(
            id: PaneID("root"),
            name: "api",
            kind: .terminal(TerminalPane(command: "cargo run", cwd: "/repo/backend")),
            isFocused: true
        )

        var graph = PaneGraph(root: root)
        try graph.flip(PaneID("root"), to: .editor(EditorPane(path: "/repo/backend/Sources/App.swift", cursorLine: 14, cursorColumn: 8)))

        let pane = try #require(graph.pane(PaneID("root")))
        #expect(pane.id == PaneID("root"))
        #expect(pane.editor?.path == "/repo/backend/Sources/App.swift")
        #expect(pane.restorableCWD == "/repo/backend")
    }
}
