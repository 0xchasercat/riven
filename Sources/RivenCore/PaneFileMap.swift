import Combine
import Foundation
import SwiftUI

/// Tracks which file is open in each editor pane.
///
/// Earlier alpha builds shared a single `Binding<URL?>` across every editor
/// pane, which meant opening a file in one pane mirrored it across all of
/// them. `PaneFileMap` replaces that shared binding with a `PaneID`-keyed
/// dictionary so each pane can host its own file independently.
///
/// The orchestrator typically holds one instance in `RivenRootController`
/// and passes it down to every `EditorPaneView`. Views interact with it
/// via `binding(for:)`, which returns a SwiftUI `Binding<URL?>` that reads
/// and writes through this object.
///
/// This is an `ObservableObject` (not `@Observable`) so it composes
/// naturally with the existing `@Published`-driven controllers in the
/// app. It is the only file in `RivenCore` that imports SwiftUI; the
/// dependency is justified by `binding(for:)` returning a `Binding`.
///
/// `PaneFileMap` is pinned to the main actor because it vends SwiftUI
/// bindings and publishes observable changes — both of which expect to
/// run on the main thread. It is intentionally not `Sendable`: moving an
/// instance across actor boundaries would defeat the main-actor
/// isolation that keeps the publisher safe to drive UI updates.
@MainActor
public final class PaneFileMap: ObservableObject {
    @Published private var files: [PaneID: URL] = [:]

    public init(initial: [PaneID: URL] = [:]) {
        self.files = initial
    }

    /// Read the URL currently associated with `paneID`. Returns nil for
    /// panes that have never had a file set, or whose entry was cleared.
    public func file(for paneID: PaneID) -> URL? {
        files[paneID]
    }

    /// Assign `url` to `paneID`. Passing `nil` removes the entry entirely
    /// so `file(for:)` will return nil afterward. Setting the same value
    /// twice is a no-op: `@Published` still emits, but the stored state
    /// is unchanged so observers can safely re-render.
    public func setFile(_ url: URL?, for paneID: PaneID) {
        if let url {
            files[paneID] = url
        } else {
            files.removeValue(forKey: paneID)
        }
    }

    /// A SwiftUI `Binding<URL?>` whose reads and writes go through this
    /// map for the given pane id. Convenient for handing to subviews
    /// (e.g. `EditorPaneView`) that expect a binding-shaped open-file
    /// channel.
    ///
    /// The binding captures `self` strongly; callers should hold the
    /// binding only as long as they hold the map.
    public func binding(for paneID: PaneID) -> Binding<URL?> {
        Binding<URL?>(
            get: { [weak self] in self?.file(for: paneID) },
            set: { [weak self] newValue in self?.setFile(newValue, for: paneID) }
        )
    }

    /// All paneID → URL pairs currently tracked. Useful for snapshotting
    /// or for diagnostics; mutations should go through `setFile(_:for:)`.
    public var snapshot: [PaneID: URL] { files }
}
