import Foundation
import Testing
@testable import RivenCore

/// Covers the pure `WorkspaceGroup.appendingTab` / `removingTab` /
/// `focusingTab` mutators. These exist precisely so the controller's
/// tab plumbing can be unit-tested without spinning up the full
/// @MainActor RivenRootController (which does file I/O at init).
@Suite("Workspace inner tab mutators")
struct WorkspaceInnerTabMutationTests {

    private func freshWorkspace() -> WorkspaceGroup {
        // Default init seeds one shell tab — covered elsewhere. We pin
        // an explicit tab list here so tests can reason about ids
        // without depending on UUID generation.
        let shell = WorkspaceInnerTab(
            id: TabID("shell"),
            displayName: "shell",
            kind: .terminal(paneID: PaneID("pane-shell"), command: nil),
            cwd: "/tmp/proj"
        )
        return WorkspaceGroup(
            initialCwd: "/tmp/proj",
            tabs: [shell],
            focusedTabID: shell.id
        )
    }

    // MARK: - appendingTab

    @Test("appendingTab appends and focuses the new tab")
    func appendFocusesNewTab() {
        let base = freshWorkspace()
        let editor = WorkspaceInnerTab(
            id: TabID("editor-1"),
            displayName: "Notes.md",
            kind: .editor(path: "/tmp/proj/Notes.md"),
            cwd: "/tmp/proj"
        )
        let updated = base.appendingTab(editor)
        #expect(updated.tabs.count == 2)
        #expect(updated.tabs[1].id == TabID("editor-1"))
        // Focus moved to the new tab.
        #expect(updated.focusedTabID == TabID("editor-1"))
        // Original is unchanged (pure).
        #expect(base.tabs.count == 1)
        #expect(base.focusedTabID == TabID("shell"))
    }

    // MARK: - removingTab

    @Test("removingTab refuses to drop the last tab")
    func removeKeepsAtLeastOneTab() {
        let base = freshWorkspace()
        let updated = base.removingTab(TabID("shell"))
        // No-op when only one tab remains — workspaces never go empty.
        #expect(updated == base)
    }

    @Test("removingTab drops the matching tab and preserves focus when unrelated")
    func removeKeepsFocusWhenUnrelated() {
        let base = freshWorkspace()
        let editor = WorkspaceInnerTab(
            id: TabID("editor-1"),
            displayName: "Notes.md",
            kind: .editor(path: "/tmp/proj/Notes.md"),
            cwd: "/tmp/proj"
        )
        let withEditor = base.appendingTab(editor) // focus on editor-1
        let again = withEditor.appendingTab(
            WorkspaceInnerTab(
                id: TabID("shell-2"),
                displayName: "shell",
                kind: .terminal(paneID: PaneID("pane-shell-2"), command: nil),
                cwd: "/tmp/proj"
            )
        ) // focus on shell-2
        // Drop editor-1 (not focused) — shell-2 stays focused.
        let dropped = again.removingTab(TabID("editor-1"))
        #expect(dropped.tabs.map(\.id) == [TabID("shell"), TabID("shell-2")])
        #expect(dropped.focusedTabID == TabID("shell-2"))
    }

    @Test("removingTab moves focus to the left neighbour when the focused tab is dropped")
    func removeFocusedFallsLeft() {
        let base = freshWorkspace()
        let middle = WorkspaceInnerTab(
            id: TabID("middle"),
            displayName: "build",
            kind: .terminal(paneID: PaneID("pane-build"), command: "swift build"),
            cwd: "/tmp/proj"
        )
        let last = WorkspaceInnerTab(
            id: TabID("last"),
            displayName: "test",
            kind: .terminal(paneID: PaneID("pane-test"), command: "swift test"),
            cwd: "/tmp/proj"
        )
        let three = base.appendingTab(middle).appendingTab(last)
        // Focus is on "last"; drop it — focus should fall to "middle".
        let dropLast = three.removingTab(TabID("last"))
        #expect(dropLast.tabs.map(\.id) == [TabID("shell"), TabID("middle")])
        #expect(dropLast.focusedTabID == TabID("middle"))

        // Now drop "middle" (focused) — focus should fall to "shell".
        let dropMiddle = dropLast.removingTab(TabID("middle"))
        #expect(dropMiddle.tabs.map(\.id) == [TabID("shell")])
        #expect(dropMiddle.focusedTabID == TabID("shell"))
    }

    @Test("removingTab the leftmost focused tab keeps focus inside the array (idx-1 floored at 0)")
    func removeLeftmostFocusedStaysInBounds() {
        let base = freshWorkspace()
        let second = WorkspaceInnerTab(
            id: TabID("second"),
            displayName: "second",
            kind: .terminal(paneID: PaneID("pane-2"), command: nil),
            cwd: "/tmp/proj"
        )
        let two = base.appendingTab(second) // focus on "second"
        let movedBack = two.focusingTab(TabID("shell")) // focus on "shell" (leftmost)
        let dropped = movedBack.removingTab(TabID("shell"))
        #expect(dropped.tabs.map(\.id) == [TabID("second")])
        // max(0, idx - 1) for idx=0 stays at 0 — which is "second" now
        // that "shell" is gone.
        #expect(dropped.focusedTabID == TabID("second"))
    }

    @Test("removingTab a non-existent id is a no-op")
    func removeUnknownIsNoop() {
        let base = freshWorkspace()
        let result = base.removingTab(TabID("does-not-exist"))
        #expect(result == base)
    }

    // MARK: - focusingTab

    @Test("focusingTab moves focus to the requested tab")
    func focusMovesToRequested() {
        let base = freshWorkspace()
        let other = WorkspaceInnerTab(
            id: TabID("other"),
            displayName: "other",
            kind: .terminal(paneID: PaneID("pane-other"), command: nil),
            cwd: "/tmp/proj"
        )
        let two = base.appendingTab(other) // focus on "other"
        let focusShell = two.focusingTab(TabID("shell"))
        #expect(focusShell.focusedTabID == TabID("shell"))
        // Tab list is unchanged.
        #expect(focusShell.tabs.map(\.id) == two.tabs.map(\.id))
    }

    @Test("focusingTab the already-focused tab is a no-op")
    func focusingFocusedIsNoop() {
        let base = freshWorkspace()
        let result = base.focusingTab(TabID("shell"))
        #expect(result == base)
    }

    @Test("focusingTab a non-existent id is a no-op")
    func focusUnknownIsNoop() {
        let base = freshWorkspace()
        let result = base.focusingTab(TabID("does-not-exist"))
        #expect(result == base)
    }

    // MARK: - renamed (workspace customName)

    @Test("renamed sets customName when given a non-empty value")
    func renameSetsCustomName() {
        let base = freshWorkspace()
        let updated = base.renamed(to: "deploy box")
        #expect(updated.customName == "deploy box")
        // Tab list is untouched.
        #expect(updated.tabs == base.tabs)
    }

    @Test("renamed normalizes whitespace-only input back to nil")
    func renameWhitespaceClearsCustomName() {
        let base = freshWorkspace().renamed(to: "current name")
        let cleared = base.renamed(to: "   ")
        #expect(cleared.customName == nil)
    }

    @Test("renamed with the same value is a no-op")
    func renameSameIsNoop() {
        let base = freshWorkspace().renamed(to: "deploy box")
        let again = base.renamed(to: "deploy box")
        #expect(again == base)
    }

    // MARK: - renamingTab (inner-tab displayName)

    @Test("renamingTab sets displayName on the matching tab")
    func renameInnerSetsDisplayName() {
        let base = freshWorkspace()
        let updated = base.renamingTab(TabID("shell"), to: "build")
        #expect(updated.tabs.first?.displayName == "build")
    }

    @Test("renamingTab with empty input resets a terminal tab to 'shell'")
    func renameInnerEmptyTerminalResets() {
        let base = freshWorkspace().renamingTab(TabID("shell"), to: "build")
        let cleared = base.renamingTab(TabID("shell"), to: "")
        #expect(cleared.tabs.first?.displayName == "shell")
    }

    @Test("renamingTab with empty input resets an editor tab to its file basename")
    func renameInnerEmptyEditorResetsToBasename() {
        let editor = WorkspaceInnerTab(
            id: TabID("editor"),
            displayName: "renamed",
            kind: .editor(path: "/tmp/proj/Notes.md"),
            cwd: "/tmp/proj"
        )
        let workspace = freshWorkspace().appendingTab(editor)
        let cleared = workspace.renamingTab(TabID("editor"), to: "  ")
        let restored = cleared.tabs.first(where: { $0.id == TabID("editor") })
        #expect(restored?.displayName == "Notes.md")
    }

    @Test("renamingTab with empty input resets a scratch editor tab to 'Untitled'")
    func renameInnerEmptyScratchResetsToUntitled() {
        let scratch = WorkspaceInnerTab(
            id: TabID("scratch"),
            displayName: "my-draft",
            kind: .editor(path: nil),
            cwd: "/tmp/proj"
        )
        let workspace = freshWorkspace().appendingTab(scratch)
        let cleared = workspace.renamingTab(TabID("scratch"), to: "")
        let restored = cleared.tabs.first(where: { $0.id == TabID("scratch") })
        #expect(restored?.displayName == "Untitled")
    }

    @Test("renamingTab with an unknown id is a no-op")
    func renameInnerUnknownIsNoop() {
        let base = freshWorkspace()
        let result = base.renamingTab(TabID("does-not-exist"), to: "x")
        #expect(result == base)
    }
}
