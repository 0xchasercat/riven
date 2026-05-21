import Foundation
import SwiftUI
import Testing
@testable import RivenCore

@MainActor
@Suite("Pane file map")
struct PaneFileMapTests {
    @Test("setFile updates the value for a specific paneID")
    func setFileUpdatesValueForPane() {
        let map = PaneFileMap()
        let paneA = PaneID("pane-a")
        let paneB = PaneID("pane-b")
        let urlA = URL(fileURLWithPath: "/tmp/a.swift")
        let urlB = URL(fileURLWithPath: "/tmp/b.swift")

        map.setFile(urlA, for: paneA)
        map.setFile(urlB, for: paneB)

        #expect(map.file(for: paneA) == urlA)
        #expect(map.file(for: paneB) == urlB)

        // Updating one pane does not disturb the other.
        let urlAPrime = URL(fileURLWithPath: "/tmp/a-prime.swift")
        map.setFile(urlAPrime, for: paneA)
        #expect(map.file(for: paneA) == urlAPrime)
        #expect(map.file(for: paneB) == urlB)

        // Setting nil removes the entry.
        map.setFile(nil, for: paneA)
        #expect(map.file(for: paneA) == nil)
        #expect(map.file(for: paneB) == urlB)
    }

    @Test("file(for:) returns nil for an unknown paneID")
    func fileForUnknownPaneIsNil() {
        let map = PaneFileMap()
        #expect(map.file(for: PaneID("never-set")) == nil)

        // Even after populating other panes, an unrelated id stays nil.
        map.setFile(URL(fileURLWithPath: "/tmp/x.swift"), for: PaneID("known"))
        #expect(map.file(for: PaneID("never-set")) == nil)
    }

    @Test("binding(for:) reads through the current map")
    func bindingReadsThroughCurrentMap() {
        let map = PaneFileMap()
        let pane = PaneID("pane")
        let url = URL(fileURLWithPath: "/tmp/read.swift")

        let binding = map.binding(for: pane)
        #expect(binding.wrappedValue == nil)

        map.setFile(url, for: pane)
        #expect(binding.wrappedValue == url)

        // Subsequent updates flow through the same binding instance.
        let next = URL(fileURLWithPath: "/tmp/next.swift")
        map.setFile(next, for: pane)
        #expect(binding.wrappedValue == next)
    }

    @Test("binding(for:) writes back into the map")
    func bindingWritesBackIntoMap() {
        let map = PaneFileMap()
        let pane = PaneID("pane")
        let binding = map.binding(for: pane)

        let url = URL(fileURLWithPath: "/tmp/write.swift")
        binding.wrappedValue = url
        #expect(map.file(for: pane) == url)

        // Writing nil through the binding clears the entry.
        binding.wrappedValue = nil
        #expect(map.file(for: pane) == nil)
    }

    @Test("setFile to the same value is a no-op for stored state")
    func setFileSameValueIsNoOp() {
        let map = PaneFileMap()
        let pane = PaneID("stable")
        let url = URL(fileURLWithPath: "/tmp/stable.swift")

        map.setFile(url, for: pane)
        map.setFile(url, for: pane)

        #expect(map.file(for: pane) == url)
    }
}
