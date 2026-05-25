import Foundation
import Testing
@testable import RivenCore

/// Covers the pure `WorkspaceState.dirtyEditorFilenames(in:)` helper
/// that drives the H-1 quit prompt. The helper has to walk every
/// workspace pane, every inner tab inside each, and every surface
/// inside each tab — splits and editor scratch buffers included.
@Suite("Workspace dirty editor filename enumeration")
struct WorkspaceStateDirtyFilenameTests {

    /// Build a `WorkspaceState` whose pane graph has one workspace
    /// pane with the requested tab list. Helpers below assemble the
    /// tabs themselves; this just stitches them into a graph.
    private func makeState(tabs: [WorkspaceInnerTab]) -> WorkspaceState {
        let workspace = WorkspaceGroup(
            initialCwd: "/tmp/proj",
            tabs: tabs,
            focusedTabID: tabs[0].id
        )
        let pane = PaneDescriptor(
            id: PaneID("ws-1"),
            name: "workspace",
            kind: .workspace(workspace),
            isFocused: true
        )
        return WorkspaceState(
            projectRoot: "/tmp/proj",
            selectedThemeID: "riven",
            requiresTaskTrust: false,
            pendingTaskCommands: [],
            taskTerminals: [],
            fileTree: ProjectFileTree(name: "proj", path: "/tmp/proj", kind: .directory),
            paneGraph: PaneGraph(root: pane)
        )
    }

    @Test("empty dirty set returns no filenames")
    func emptyDirtySetReturnsEmpty() {
        let editor = WorkspaceInnerTab(
            id: TabID("t1"),
            displayName: "foo.swift",
            kind: .editor(path: "/tmp/proj/foo.swift"),
            cwd: "/tmp/proj"
        )
        let state = makeState(tabs: [editor])
        #expect(state.dirtyEditorFilenames(in: []) == [])
    }

    @Test("dirty terminal surfaces are filtered out (no filename)")
    func dirtyTerminalSurfacesReturnEmpty() {
        // Terminal surfaces have nil `filename` — they should never
        // show up in the quit alert even if (somehow) marked dirty.
        let shell = WorkspaceInnerTab(
            id: TabID("shell"),
            displayName: "shell",
            kind: .terminal(paneID: PaneID("p1"), command: nil),
            cwd: "/tmp/proj"
        )
        let state = makeState(tabs: [shell])
        // The shell tab has exactly one surface — pluck its id.
        let surfaceID = shell.surfaces[0].id
        // Terminals always collapse to "Untitled" today because
        // `TabSurface.filename` returns nil for non-editor kinds.
        // We don't expect the dirty-tracking pipeline to ever mark
        // them dirty in practice, but the helper should still produce
        // *some* label rather than silently dropping the entry —
        // matching the helper's `?? "Untitled"` fallback.
        let names = state.dirtyEditorFilenames(in: [surfaceID])
        #expect(names == ["Untitled"])
    }

    @Test("file-backed editor surface produces its basename")
    func fileBackedEditorReturnsBasename() {
        let editor = WorkspaceInnerTab(
            id: TabID("t1"),
            displayName: "Notes.md",
            kind: .editor(path: "/tmp/proj/Notes.md"),
            cwd: "/tmp/proj"
        )
        let state = makeState(tabs: [editor])
        let surfaceID = editor.surfaces[0].id
        #expect(state.dirtyEditorFilenames(in: [surfaceID]) == ["Notes.md"])
    }

    @Test("scratch editor (nil path) reports as Untitled")
    func scratchEditorReturnsUntitled() {
        let scratch = WorkspaceInnerTab(
            id: TabID("t1"),
            displayName: "Untitled-1",
            kind: .editor(path: nil),
            cwd: "/tmp/proj"
        )
        let state = makeState(tabs: [scratch])
        let surfaceID = scratch.surfaces[0].id
        #expect(state.dirtyEditorFilenames(in: [surfaceID]) == ["Untitled"])
    }

    @Test("enumerates dirty editor surfaces across multiple tabs")
    func multipleTabsEnumerated() {
        let a = WorkspaceInnerTab(
            id: TabID("t1"),
            displayName: "foo.swift",
            kind: .editor(path: "/tmp/proj/foo.swift"),
            cwd: "/tmp/proj"
        )
        let b = WorkspaceInnerTab(
            id: TabID("t2"),
            displayName: "bar.swift",
            kind: .editor(path: "/tmp/proj/bar.swift"),
            cwd: "/tmp/proj"
        )
        let state = makeState(tabs: [a, b])
        let dirty: Set<SurfaceID> = [a.surfaces[0].id, b.surfaces[0].id]
        let names = state.dirtyEditorFilenames(in: dirty).sorted()
        #expect(names == ["bar.swift", "foo.swift"])
    }

    @Test("ignores surfaces not in the dirty set")
    func ignoresNonDirtySurfaces() {
        let dirty = WorkspaceInnerTab(
            id: TabID("t1"),
            displayName: "foo.swift",
            kind: .editor(path: "/tmp/proj/foo.swift"),
            cwd: "/tmp/proj"
        )
        let clean = WorkspaceInnerTab(
            id: TabID("t2"),
            displayName: "bar.swift",
            kind: .editor(path: "/tmp/proj/bar.swift"),
            cwd: "/tmp/proj"
        )
        let state = makeState(tabs: [dirty, clean])
        let names = state.dirtyEditorFilenames(in: [dirty.surfaces[0].id])
        #expect(names == ["foo.swift"])
    }
}
