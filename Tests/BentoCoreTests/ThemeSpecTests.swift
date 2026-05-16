import Testing
@testable import BentoCore

@Suite("Themes")
struct ThemeSpecTests {
    @Test("ships mockup-inspired selectable themes")
    func builtInThemes() throws {
        let themes = ThemeSpec.builtIns

        #expect(themes.map(\.id) == ["bento", "carbon", "tokyo", "paper"])
        #expect(try #require(ThemeSpec.theme(id: "bento")).terminal.foreground.hex == "#ece1cb")
        #expect(try #require(ThemeSpec.theme(id: "carbon")).syntax.keyword.hex == "#c8c8c8")
        #expect(ThemeSpec.theme(id: "missing") == nil)
    }
}
