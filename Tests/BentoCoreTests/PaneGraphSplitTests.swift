import Testing
@testable import BentoCore

@Suite("Pane graph splits, focus, and close")
struct PaneGraphSplitTests {
    // MARK: - Test fixtures

    private func makeRoot(id: String = "root", cwd: String = "/repo") -> PaneDescriptor {
        PaneDescriptor(
            id: PaneID(id),
            name: "shell",
            kind: .terminal(TerminalPane(command: nil, cwd: cwd)),
            isFocused: true
        )
    }

    private func makeLeaf(id: String, cwd: String = "/repo") -> PaneDescriptor {
        PaneDescriptor(
            id: PaneID(id),
            name: "pane-\(id)",
            kind: .terminal(TerminalPane(command: nil, cwd: cwd)),
            isFocused: false
        )
    }

    // MARK: - split right

    @Test("split right inserts a sibling and keeps focus on the new pane")
    func splitRightFocusesNewPane() {
        let root = makeRoot()
        let graph = PaneGraph(root: root)
        let sibling = makeLeaf(id: "right")

        let next = graph.split(PaneID("root"), direction: .right, newPane: sibling)

        #expect(next.panes.count == 2)
        #expect(next.focusedPaneID == PaneID("right"))
        #expect(next.pane(PaneID("right"))?.isFocused == true)
        #expect(next.pane(PaneID("root"))?.isFocused == false)
        #expect(next.rootNode == .split(.right, .leaf(PaneID("root")), .leaf(PaneID("right"))))
        // Original graph must be untouched (pure function).
        #expect(graph.panes.count == 1)
        #expect(graph.focusedPaneID == PaneID("root"))
    }

    // MARK: - split down

    @Test("split down nests under a vertical split node")
    func splitDownNestsVertically() {
        let root = makeRoot()
        let graph = PaneGraph(root: root)
        let sibling = makeLeaf(id: "bottom")

        let next = graph.split(PaneID("root"), direction: .down, newPane: sibling)

        guard case let .split(direction, first, second) = next.rootNode else {
            Issue.record("expected root to be a split after split-down")
            return
        }
        #expect(direction == .down)
        #expect(first == .leaf(PaneID("root")))
        #expect(second == .leaf(PaneID("bottom")))
        #expect(next.focusedPaneID == PaneID("bottom"))
    }

    @Test("nested split places the new pane next to its sibling, not at the root")
    func nestedSplitStaysLocal() {
        let root = makeRoot()
        var graph = PaneGraph(root: root)
        graph = graph.split(PaneID("root"), direction: .right, newPane: makeLeaf(id: "right"))
        graph = graph.split(PaneID("right"), direction: .down, newPane: makeLeaf(id: "br"))

        // Tree should be:  split(right, leaf(root), split(down, leaf(right), leaf(br)))
        guard case let .split(topDir, topFirst, topSecond) = graph.rootNode else {
            Issue.record("expected outer split"); return
        }
        #expect(topDir == .right)
        #expect(topFirst == .leaf(PaneID("root")))
        guard case let .split(innerDir, innerFirst, innerSecond) = topSecond else {
            Issue.record("expected inner split under the right column"); return
        }
        #expect(innerDir == .down)
        #expect(innerFirst == .leaf(PaneID("right")))
        #expect(innerSecond == .leaf(PaneID("br")))
        #expect(graph.focusedPaneID == PaneID("br"))
    }

    // MARK: - close

    @Test("close removes the leaf and collapses single-child splits")
    func closeCollapsesSplit() {
        let root = makeRoot()
        var graph = PaneGraph(root: root)
        graph = graph.split(PaneID("root"), direction: .right, newPane: makeLeaf(id: "right"))

        let result = graph.close(PaneID("right"))
        let closed = try? #require(result)

        #expect(closed?.panes.count == 1)
        #expect(closed?.rootNode == .leaf(PaneID("root")))
        #expect(closed?.focusedPaneID == PaneID("root"))
        #expect(closed?.pane(PaneID("root"))?.isFocused == true)
        #expect(closed?.pane(PaneID("right")) == nil)
    }

    @Test("close returns nil when the last leaf is closed")
    func closeLastLeafIsNoOp() {
        let root = makeRoot()
        let graph = PaneGraph(root: root)
        #expect(graph.close(PaneID("root")) == nil)
    }

    @Test("close collapses deeply nested single-child splits up to the root")
    func closeCollapsesNestedSplits() {
        let root = makeRoot()
        var graph = PaneGraph(root: root)
        graph = graph.split(PaneID("root"), direction: .right, newPane: makeLeaf(id: "right"))
        graph = graph.split(PaneID("right"), direction: .down, newPane: makeLeaf(id: "br"))
        // Tree: split(right, root, split(down, right, br))

        // Close `right`: collapses inner split, leaving split(right, root, br)
        let next = graph.close(PaneID("right"))
        let after = try? #require(next)
        #expect(after?.rootNode == .split(.right, .leaf(PaneID("root")), .leaf(PaneID("br"))))
        #expect(after?.panes.count == 2)
    }

    // MARK: - focus / nextFocus

    @Test("next focus cycles through leaves in tree order")
    func nextFocusCyclesInOrder() {
        let root = makeRoot()
        var graph = PaneGraph(root: root)
        graph = graph.split(PaneID("root"), direction: .right, newPane: makeLeaf(id: "right"))
        graph = graph.split(PaneID("right"), direction: .down, newPane: makeLeaf(id: "br"))
        // Order: root, right, br. After last split, focus is on br.

        let g1 = graph.nextFocus()
        #expect(g1.focusedPaneID == PaneID("root"))
        let g2 = g1.nextFocus()
        #expect(g2.focusedPaneID == PaneID("right"))
        let g3 = g2.nextFocus()
        #expect(g3.focusedPaneID == PaneID("br"))
        let g4 = g3.nextFocus()
        #expect(g4.focusedPaneID == PaneID("root"))
    }

    @Test("next focus is a no-op for a single-leaf graph")
    func nextFocusNoOpForSingleLeaf() {
        let graph = PaneGraph(root: makeRoot())
        let next = graph.nextFocus()
        #expect(next.focusedPaneID == PaneID("root"))
        #expect(next == graph)
    }

    @Test("focusing a non-focused leaf moves the focus marker")
    func focusMovesMarker() {
        let root = makeRoot()
        var graph = PaneGraph(root: root)
        graph = graph.split(PaneID("root"), direction: .right, newPane: makeLeaf(id: "right"))
        // After split, focus is on "right".
        #expect(graph.focusedPaneID == PaneID("right"))

        let refocused = graph.focus(PaneID("root"))
        #expect(refocused.focusedPaneID == PaneID("root"))
        #expect(refocused.pane(PaneID("root"))?.isFocused == true)
        #expect(refocused.pane(PaneID("right"))?.isFocused == false)
    }

    @Test("focus is a no-op when the target is unknown")
    func focusUnknownIsNoOp() {
        let graph = PaneGraph(root: makeRoot())
        let next = graph.focus(PaneID("ghost"))
        #expect(next == graph)
    }

    // MARK: - inspection

    @Test("leaves returns descriptors in traversal order")
    func leavesAreInTraversalOrder() {
        var graph = PaneGraph(root: makeRoot())
        graph = graph.split(PaneID("root"), direction: .right, newPane: makeLeaf(id: "right"))
        graph = graph.split(PaneID("right"), direction: .down, newPane: makeLeaf(id: "br"))

        let leafIDs = graph.leaves().map(\.id)
        #expect(leafIDs == [PaneID("root"), PaneID("right"), PaneID("br")])
    }

    @Test("focused returns the descriptor flagged as focused")
    func focusedReturnsMarker() {
        var graph = PaneGraph(root: makeRoot())
        graph = graph.split(PaneID("root"), direction: .right, newPane: makeLeaf(id: "right"))
        #expect(graph.focused()?.id == PaneID("right"))
    }
}
