import Foundation
import Testing
@testable import RivenCore

/// Covers the pure split-surface mutators on `WorkspaceInnerTab` and
/// their `WorkspaceGroup` wrappers. The renderer and chrome are
/// exercised manually — these tests pin the data-layer invariants:
/// surfaces ↔ layout consistency, single-child split collapse on
/// remove, DFS focus cycling, and snapshot roundtrip.
@Suite("Workspace tab splits")
struct WorkspaceTabSplitTests {

    private func singleSurfaceTab() -> WorkspaceInnerTab {
        // Use the kind-based init so the surface gets a fresh
        // SurfaceID and a leaf layout — the most common starting
        // shape, and the one we'll split from.
        WorkspaceInnerTab(
            id: TabID("tab"),
            displayName: "shell",
            kind: .terminal(paneID: PaneID("pane-a"), command: nil),
            cwd: "/tmp/proj"
        )
    }

    private func freshWorkspace(with tab: WorkspaceInnerTab) -> WorkspaceGroup {
        WorkspaceGroup(
            initialCwd: "/tmp/proj",
            tabs: [tab],
            focusedTabID: tab.id
        )
    }

    // MARK: - splittingFocusedSurface

    @Test("splittingFocusedSurface adds a sibling surface and focuses it")
    func splitAddsSiblingFocused() {
        let base = singleSurfaceTab()
        let originalID = base.focusedSurfaceID

        let newSurface = TabSurface(
            id: SurfaceID("surface-b"),
            kind: .terminal(paneID: PaneID("pane-b"), command: nil)
        )
        let split = base.splittingFocusedSurface(direction: .right, newSurface: newSurface)

        // Both surfaces present.
        #expect(split.surfaces.count == 2)
        #expect(split.surfaces.map(\.id).contains(originalID))
        #expect(split.surfaces.map(\.id).contains(SurfaceID("surface-b")))

        // Layout flipped from .leaf(originalID) to .split(.right, .leaf(originalID), .leaf(newSurface))
        switch split.layout {
        case let .split(direction, .leaf(lhs), .leaf(rhs)):
            #expect(direction == .right)
            #expect(lhs == originalID)
            #expect(rhs == SurfaceID("surface-b"))
        default:
            Issue.record("expected .split(.right, .leaf, .leaf) layout, got \(split.layout)")
        }

        // Focus moved to the new surface so the user can immediately
        // type into the just-created split.
        #expect(split.focusedSurfaceID == SurfaceID("surface-b"))
        // isSplit reflects the new shape.
        #expect(split.isSplit == true)
        // Original tab unchanged (pure).
        #expect(base.surfaces.count == 1)
        #expect(base.isSplit == false)
    }

    @Test("splittingFocusedSurface preserves nested structure when called on a split tab")
    func splitNestsCorrectly() {
        let a = singleSurfaceTab()
        let b = TabSurface(id: SurfaceID("b"), kind: .terminal(paneID: PaneID("pane-b"), command: nil))
        let c = TabSurface(id: SurfaceID("c"), kind: .terminal(paneID: PaneID("pane-c"), command: nil))

        let firstSplit = a.splittingFocusedSurface(direction: .right, newSurface: b)
        // First split: focus is now on b. Split b downward with c → the
        // layout should be `.split(.right, .leaf(originalA), .split(.down, .leaf(b), .leaf(c)))`.
        let secondSplit = firstSplit.splittingFocusedSurface(direction: .down, newSurface: c)

        #expect(secondSplit.surfaces.count == 3)
        #expect(secondSplit.focusedSurfaceID == c.id)
        switch secondSplit.layout {
        case let .split(.right, .leaf(lhs), .split(.down, .leaf(mid), .leaf(rhs))):
            #expect(lhs == a.focusedSurfaceID)
            #expect(mid == b.id)
            #expect(rhs == c.id)
        default:
            Issue.record("expected nested .split layout, got \(secondSplit.layout)")
        }
    }

    // MARK: - removingSurface

    @Test("removingSurface refuses to drop the last surface")
    func removeKeepsAtLeastOne() {
        let base = singleSurfaceTab()
        let result = base.removingSurface(base.focusedSurfaceID)
        #expect(result == base)
    }

    @Test("removingSurface collapses single-child splits")
    func removeCollapsesSplit() {
        let a = singleSurfaceTab()
        let b = TabSurface(id: SurfaceID("b"), kind: .terminal(paneID: PaneID("pane-b"), command: nil))
        let split = a.splittingFocusedSurface(direction: .right, newSurface: b)

        // Drop b (the focused one). The .split should collapse back to .leaf(a).
        let collapsed = split.removingSurface(b.id)
        #expect(collapsed.surfaces.count == 1)
        #expect(collapsed.surfaces[0].id == a.focusedSurfaceID)
        #expect(collapsed.focusedSurfaceID == a.focusedSurfaceID)
        if case .leaf(let id) = collapsed.layout {
            #expect(id == a.focusedSurfaceID)
        } else {
            Issue.record("expected .leaf layout after collapse, got \(collapsed.layout)")
        }
        #expect(collapsed.isSplit == false)
    }

    @Test("removingSurface from a 3-way split keeps the remaining branch intact")
    func remove3WaySplitKeepsBranch() {
        let a = singleSurfaceTab()
        let b = TabSurface(id: SurfaceID("b"), kind: .terminal(paneID: PaneID("pane-b"), command: nil))
        let c = TabSurface(id: SurfaceID("c"), kind: .terminal(paneID: PaneID("pane-c"), command: nil))
        // Build .split(.right, .leaf(a), .split(.down, .leaf(b), .leaf(c)))
        let three = a
            .splittingFocusedSurface(direction: .right, newSurface: b)
            .splittingFocusedSurface(direction: .down, newSurface: c)

        // Drop the middle surface b. The inner .split(.down, b, c) should
        // collapse to .leaf(c), giving outer .split(.right, .leaf(a), .leaf(c)).
        let dropped = three.removingSurface(b.id)
        #expect(dropped.surfaces.count == 2)
        switch dropped.layout {
        case let .split(.right, .leaf(lhs), .leaf(rhs)):
            #expect(lhs == a.focusedSurfaceID)
            #expect(rhs == c.id)
        default:
            Issue.record("expected .split(.right, .leaf(a), .leaf(c)) after removing b, got \(dropped.layout)")
        }
    }

    @Test("removingSurface moves focus when the focused surface is dropped")
    func removeFocusedShiftsFocus() {
        let a = singleSurfaceTab()
        let b = TabSurface(id: SurfaceID("b"), kind: .terminal(paneID: PaneID("pane-b"), command: nil))
        let split = a.splittingFocusedSurface(direction: .right, newSurface: b)
        // Focus is on b after the split; drop b.
        let dropped = split.removingSurface(b.id)
        #expect(dropped.focusedSurfaceID == a.focusedSurfaceID)
    }

    @Test("removingSurface with an unknown id is a no-op")
    func removeUnknownIsNoop() {
        let base = singleSurfaceTab()
        let b = TabSurface(id: SurfaceID("b"), kind: .terminal(paneID: PaneID("pane-b"), command: nil))
        let split = base.splittingFocusedSurface(direction: .right, newSurface: b)
        let result = split.removingSurface(SurfaceID("does-not-exist"))
        #expect(result == split)
    }

    // MARK: - focusingSurface

    @Test("focusingSurface moves focus to the requested surface")
    func focusMovesToRequested() {
        let a = singleSurfaceTab()
        let b = TabSurface(id: SurfaceID("b"), kind: .terminal(paneID: PaneID("pane-b"), command: nil))
        let split = a.splittingFocusedSurface(direction: .right, newSurface: b)
        // After split, focus is on b. Move it to a.
        let backToA = split.focusingSurface(a.focusedSurfaceID)
        #expect(backToA.focusedSurfaceID == a.focusedSurfaceID)
    }

    @Test("focusingSurface with an unknown id is a no-op")
    func focusUnknownIsNoop() {
        let base = singleSurfaceTab()
        let result = base.focusingSurface(SurfaceID("does-not-exist"))
        #expect(result == base)
    }

    @Test("focusingNextSurface cycles through layout DFS order")
    func focusCyclesDFS() {
        let a = singleSurfaceTab()
        let b = TabSurface(id: SurfaceID("b"), kind: .terminal(paneID: PaneID("pane-b"), command: nil))
        let c = TabSurface(id: SurfaceID("c"), kind: .terminal(paneID: PaneID("pane-c"), command: nil))
        // .split(.right, .leaf(a), .split(.down, .leaf(b), .leaf(c)))
        let three = a
            .splittingFocusedSurface(direction: .right, newSurface: b)
            .splittingFocusedSurface(direction: .down, newSurface: c)
        // DFS order: a, b, c. Focus is currently on c (the most-recently
        // created surface). Cycling should land on a → b → c → a → ...
        let next1 = three.focusingNextSurface()
        #expect(next1.focusedSurfaceID == a.focusedSurfaceID)
        let next2 = next1.focusingNextSurface()
        #expect(next2.focusedSurfaceID == b.id)
        let next3 = next2.focusingNextSurface()
        #expect(next3.focusedSurfaceID == c.id)
    }

    // MARK: - WorkspaceGroup wrappers

    @Test("WorkspaceGroup.splittingFocusedSurface only acts on the focused tab")
    func groupSplitOnlyFocusedTab() {
        let tabA = WorkspaceInnerTab(
            id: TabID("a"),
            displayName: "a",
            kind: .terminal(paneID: PaneID("pane-a"), command: nil),
            cwd: "/tmp/proj"
        )
        let tabB = WorkspaceInnerTab(
            id: TabID("b"),
            displayName: "b",
            kind: .terminal(paneID: PaneID("pane-b"), command: nil),
            cwd: "/tmp/proj"
        )
        let group = WorkspaceGroup(
            initialCwd: "/tmp/proj",
            tabs: [tabA, tabB],
            focusedTabID: tabB.id
        )
        let newSurface = TabSurface(
            id: SurfaceID("new"),
            kind: .terminal(paneID: PaneID("pane-new"), command: nil)
        )
        let split = group.splittingFocusedSurface(direction: .right, newSurface: newSurface)
        // Tab a unchanged.
        #expect(split.tabs[0].surfaces.count == 1)
        // Tab b now has the new surface.
        #expect(split.tabs[1].surfaces.count == 2)
        #expect(split.tabs[1].focusedSurfaceID == newSurface.id)
    }

    // MARK: - Codable

    @Test("snapshot of a split tab round-trips through Codable")
    func snapshotRoundtripsSplitTab() throws {
        let a = singleSurfaceTab()
        let b = TabSurface(
            id: SurfaceID("b"),
            kind: .editor(path: "/tmp/proj/Notes.md")
        )
        let split = a.splittingFocusedSurface(direction: .right, newSurface: b)
        let group = freshWorkspace(with: split)

        let data = try JSONEncoder().encode(group)
        let decoded = try JSONDecoder().decode(WorkspaceGroup.self, from: data)
        let decodedTab = decoded.tabs[0]
        #expect(decodedTab.surfaces.count == 2)
        #expect(decodedTab.focusedSurfaceID == b.id)
        switch decodedTab.layout {
        case let .split(direction, .leaf(lhs), .leaf(rhs)):
            #expect(direction == .right)
            #expect(lhs == a.focusedSurfaceID)
            #expect(rhs == b.id)
        default:
            Issue.record("expected .split layout after roundtrip, got \(decodedTab.layout)")
        }
        // Surface kinds preserved across roundtrip.
        let bSurface = decodedTab.surfaces.first(where: { $0.id == b.id })
        if case let .editor(path) = bSurface?.kind {
            #expect(path == "/tmp/proj/Notes.md")
        } else {
            Issue.record("expected b surface to be .editor after roundtrip")
        }
    }

    @Test("legacy single-surface snapshot decodes into a one-surface tab")
    func legacySingleSurfaceDecodes() throws {
        // Pre-#23 shape: tab carries a flat `kind` + no surfaces/layout.
        let json = #"""
        {
          "id": { "rawValue": "shell-tab" },
          "displayName": "shell",
          "cwd": "/tmp/proj",
          "kind": {
            "terminal": {
              "paneID": { "rawValue": "pane-shell" },
              "command": null
            }
          }
        }
        """#
        let decoded = try JSONDecoder().decode(WorkspaceInnerTab.self, from: Data(json.utf8))
        #expect(decoded.surfaces.count == 1)
        #expect(decoded.isSplit == false)
        #expect(decoded.terminalPaneID == PaneID("pane-shell"))
        // Layout should be a leaf pointing at the synthesized surface.
        if case let .leaf(id) = decoded.layout {
            #expect(id == decoded.surfaces[0].id)
            #expect(decoded.focusedSurfaceID == id)
        } else {
            Issue.record("expected .leaf layout after legacy decode, got \(decoded.layout)")
        }
    }
}
