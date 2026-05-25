import Foundation
@testable import RivenCore

extension ScrollbackStore {
    /// Test helper: a store rooted at a fresh, unique temp directory.
    /// Previously lived on the (now-removed) in-process agent service;
    /// kept here since several controller tests inject a throwaway store.
    static func temporary() -> ScrollbackStore {
        ScrollbackStore(
            root: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString)
        )
    }
}
