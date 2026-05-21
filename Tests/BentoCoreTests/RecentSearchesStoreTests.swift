import Foundation
import Testing
@testable import BentoCore

@Suite("Recent searches ring")
struct RecentSearchesStoreTests {
    private func freshStore(limit: Int = 20) -> RecentSearchesStore {
        let suiteName = "bento.tests.recent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return RecentSearchesStore(defaults: defaults, key: "Bento.search.recent", limit: limit)
    }

    @Test("record + recent roundtrip in newest-first order")
    func recordAndRecall() {
        let store = freshStore()
        store.record("alpha")
        store.record("beta")
        store.record("gamma")

        #expect(store.recent() == ["gamma", "beta", "alpha"])
    }

    @Test("recording an existing entry hoists it to the head")
    func dedupePushesToHead() {
        let store = freshStore()
        store.record("alpha")
        store.record("beta")
        store.record("gamma")
        store.record("alpha")  // repeat

        #expect(store.recent() == ["alpha", "gamma", "beta"])
    }

    @Test("limit caps the ring at the configured size")
    func capRespected() {
        let store = freshStore(limit: 3)
        store.record("a")
        store.record("b")
        store.record("c")
        store.record("d")

        #expect(store.recent() == ["d", "c", "b"])
        #expect(store.recent().count == 3)
    }

    @Test("empty / whitespace-only queries are ignored")
    func ignoresEmpty() {
        let store = freshStore()
        store.record("")
        store.record("   \n\t  ")
        store.record("real")
        #expect(store.recent() == ["real"])
    }

    @Test("clear wipes the ring")
    func clearWipes() {
        let store = freshStore()
        store.record("alpha")
        store.record("beta")
        store.clear()
        #expect(store.recent() == [])
    }

    @Test("queries are trimmed before recording")
    func trimsWhitespace() {
        let store = freshStore()
        store.record("  hello world  ")
        #expect(store.recent() == ["hello world"])
    }
}
