import Foundation

/// Pure / functional operations on `PaneGraph`.
///
/// The existing `mutating` API on `PaneGraph` (split / flip) is preserved
/// for the call sites that already rely on it (snapshot resurrection,
/// existing unit tests). The view layer prefers value-returning helpers
/// so a mutation can be threaded through `onGraphChange(newGraph)` without
/// shared mutable state — those live here.
public extension PaneGraph {
    // MARK: - Inspection

    /// All leaves of the pane tree in left-to-right / top-to-bottom traversal
    /// order. This is also the order used for `nextFocus()` cycling.
    func leaves() -> [PaneDescriptor] {
        Self.leafIDsInOrder(rootNode).compactMap { panes[$0] }
    }

    /// The descriptor currently marked as focused, if any.
    func focused() -> PaneDescriptor? {
        panes[focusedPaneID]
    }

    // MARK: - Mutations (pure)

    /// Returns a new graph in which the leaf identified by `id` has been
    /// split with `newPane` as its sibling. Focus moves to the new pane.
    ///
    /// `direction == .right` creates a *horizontal* `NSSplitView` (panes
    /// side-by-side); `direction == .down` creates a *vertical* one.
    func split(_ id: PaneID, direction: SplitDirection, newPane: PaneDescriptor) -> PaneGraph {
        guard panes[id] != nil else { return self }

        var newPanes = panes
        var inserted = newPane
        inserted.isFocused = true
        newPanes[id]?.isFocused = false
        newPanes[inserted.id] = inserted

        let newRoot = Self.replacingLeaf(
            id,
            in: rootNode,
            with: .split(direction, .leaf(id), .leaf(inserted.id))
        )

        return PaneGraph(panes: newPanes, rootNode: newRoot, focusedPaneID: inserted.id)
    }

    /// Convenience: split using a fresh terminal pane that inherits the cwd
    /// of `id`. Returns a brand-new graph (the existing `mutating`
    /// `split(_:direction:)` on `PaneGraph` is kept for callers that need
    /// to know the new pane's `PaneID` synchronously). The view layer uses
    /// `splittingInheriting(...)` so it can thread the result through
    /// `onGraphChange`.
    func splittingInheriting(_ id: PaneID, direction: SplitDirection) -> PaneGraph {
        guard let parent = panes[id] else { return self }
        let child = PaneDescriptor(
            id: PaneID(),
            name: "\(parent.name) copy",
            kind: .terminal(TerminalPane(command: nil, cwd: parent.restorableCWD ?? NSHomeDirectory())),
            isFocused: true
        )
        return split(id, direction: direction, newPane: child)
    }

    /// Closes the given leaf. If `id` was the last leaf in the tree this
    /// returns `nil` (callers must keep at least one pane on screen). If
    /// the closed pane was part of a split, the surviving sibling collapses
    /// up into the parent so the tree never contains single-child splits.
    func close(_ id: PaneID) -> PaneGraph? {
        guard panes[id] != nil else { return self }

        // Last leaf -> refuse to close.
        if case let .leaf(only) = rootNode, only == id {
            return nil
        }

        guard let trimmed = Self.removingLeaf(id, from: rootNode) else {
            return nil
        }

        var newPanes = panes
        newPanes.removeValue(forKey: id)

        // Move focus to a sensible neighbour: prefer the leaf at the same
        // traversal index as the one we just removed, otherwise the last
        // remaining leaf.
        let remaining = Self.leafIDsInOrder(trimmed)
        let originalOrder = Self.leafIDsInOrder(rootNode)
        let originalIndex = originalOrder.firstIndex(of: id) ?? 0
        let candidate: PaneID = {
            if remaining.isEmpty { return id }
            let idx = min(originalIndex, remaining.count - 1)
            return remaining[idx]
        }()

        for leafID in remaining {
            newPanes[leafID]?.isFocused = (leafID == candidate)
        }
        return PaneGraph(panes: newPanes, rootNode: trimmed, focusedPaneID: candidate)
    }

    /// Returns a new graph with focus moved to `id`. No-op if the id is
    /// unknown or already focused.
    func focus(_ id: PaneID) -> PaneGraph {
        guard panes[id] != nil, id != focusedPaneID else { return self }

        var newPanes = panes
        for leafID in Self.leafIDsInOrder(rootNode) {
            newPanes[leafID]?.isFocused = (leafID == id)
        }
        return PaneGraph(panes: newPanes, rootNode: rootNode, focusedPaneID: id)
    }

    /// Returns a new graph with focus moved to the next leaf in traversal
    /// order (wrapping at the end). No-op for a single-leaf tree.
    func nextFocus() -> PaneGraph {
        let order = Self.leafIDsInOrder(rootNode)
        guard order.count > 1 else { return self }
        let current = order.firstIndex(of: focusedPaneID) ?? -1
        let next = order[(current + 1) % order.count]
        return focus(next)
    }

    // MARK: - Helpers

    private static func leafIDsInOrder(_ node: PaneNode) -> [PaneID] {
        switch node {
        case let .leaf(id):
            return [id]
        case let .split(_, first, second):
            return leafIDsInOrder(first) + leafIDsInOrder(second)
        }
    }

    private static func replacingLeaf(_ id: PaneID, in node: PaneNode, with replacement: PaneNode) -> PaneNode {
        switch node {
        case let .leaf(existing):
            return existing == id ? replacement : node
        case let .split(direction, first, second):
            return .split(
                direction,
                replacingLeaf(id, in: first, with: replacement),
                replacingLeaf(id, in: second, with: replacement)
            )
        }
    }

    /// Returns the node with the leaf `id` removed, collapsing any split
    /// that ends up with a single child. Returns `nil` if the result would
    /// be empty (i.e. `id` *was* the entire tree).
    private static func removingLeaf(_ id: PaneID, from node: PaneNode) -> PaneNode? {
        switch node {
        case let .leaf(existing):
            return existing == id ? nil : node
        case let .split(direction, first, second):
            let newFirst = removingLeaf(id, from: first)
            let newSecond = removingLeaf(id, from: second)
            switch (newFirst, newSecond) {
            case (nil, nil): return nil
            case (let f?, nil): return f
            case (nil, let s?): return s
            case let (f?, s?): return .split(direction, f, s)
            }
        }
    }
}
