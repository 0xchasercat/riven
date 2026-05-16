import Testing
@testable import BentoCore

@Suite("Command palette")
struct CommandPaletteTests {
    @Test("filters commands by title and group with stable ordering")
    func filtersCommands() {
        let palette = CommandPalette(commands: Command.bentoBuiltIns)

        let matches = palette.search("pane")

        #expect(matches.map(\.title).prefix(4) == [
            "Split pane right",
            "Split pane down",
            "Flip pane: terminal/editor",
            "Zoom active pane"
        ])
    }

    @Test("empty query returns all commands")
    func emptyQuery() {
        let palette = CommandPalette(commands: Command.bentoBuiltIns)

        #expect(palette.search("").count == Command.bentoBuiltIns.count)
    }
}
