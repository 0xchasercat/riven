import Foundation
import Testing
@testable import RivenCore

@Suite("Theme preference")
struct ThemePreferenceTests {
    @Test("defaults to bento until user selects a built-in theme")
    func defaultAndSelect() throws {
        let defaults = UserDefaults(suiteName: "RivenTests-\(UUID().uuidString)")!
        let preference = ThemePreferenceStore(defaults: defaults)

        #expect(preference.selectedTheme.id == "bento")
        try preference.selectTheme(id: "carbon")
        #expect(preference.selectedTheme.id == "carbon")
    }

    @Test("rejects unknown themes")
    func rejectsUnknownTheme() {
        let defaults = UserDefaults(suiteName: "RivenTests-\(UUID().uuidString)")!
        let preference = ThemePreferenceStore(defaults: defaults)

        #expect(throws: ThemePreferenceError.unknownTheme("unknown")) {
            try preference.selectTheme(id: "unknown")
        }
    }
}
