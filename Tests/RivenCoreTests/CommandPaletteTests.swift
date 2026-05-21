import Testing
@testable import RivenCore

@Suite("Command palette")
struct CommandPaletteTests {
    @Test("filters commands by title and group with stable ordering")
    func filtersCommands() {
        let palette = CommandPalette(commands: Command.rivenBuiltIns)

        let matches = palette.search("pane")

        // After dropping the flipPane / zoomPane entries (they mapped
        // to nil in the dispatcher post-#23 and were silently no-ops
        // from the palette), the surviving "pane" matches are the
        // three actual operations on the focused surface.
        #expect(matches.map(\.title) == [
            "Split pane right",
            "Split pane down",
            "Close active pane"
        ])
    }

    @Test("empty query returns all commands")
    func emptyQuery() {
        let palette = CommandPalette(commands: Command.rivenBuiltIns)

        #expect(palette.search("").count == Command.rivenBuiltIns.count)
    }
}
