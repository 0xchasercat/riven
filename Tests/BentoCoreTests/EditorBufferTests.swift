import Foundation
import Testing
@testable import BentoCore

@Suite("Editor buffer")
struct EditorBufferTests {
    @Test("loading a new URL replaces buffer and clears dirty")
    func loadReplacesBufferAndClearsDirty() {
        var buffer = EditorBuffer()
        let url = URL(fileURLWithPath: "/tmp/example.swift")

        buffer.load(url: url, text: "let answer = 42\n")

        #expect(buffer.url == url)
        #expect(buffer.text == "let answer = 42\n")
        #expect(buffer.isDirty == false)

        // Loading another URL discards the prior buffer entirely.
        let other = URL(fileURLWithPath: "/tmp/other.swift")
        buffer.recordEdit(text: "let answer = 42\n// dirty\n")
        #expect(buffer.isDirty == true)
        buffer.load(url: other, text: "fresh\n")
        #expect(buffer.url == other)
        #expect(buffer.text == "fresh\n")
        #expect(buffer.isDirty == false)
    }

    @Test("marking dirty then loading the same URL preserves the dirty buffer")
    func reconcileSameURLPreservesDirty() {
        let url = URL(fileURLWithPath: "/tmp/keep.swift")
        var buffer = EditorBuffer()
        buffer.load(url: url, text: "original\n")
        buffer.recordEdit(text: "original + unsaved\n")
        #expect(buffer.isDirty == true)

        let outcome = buffer.reconcile(targetURL: url)

        #expect(outcome == .noChange)
        #expect(buffer.url == url)
        #expect(buffer.text == "original + unsaved\n")
        #expect(buffer.isDirty == true)
    }

    @Test("marking dirty then loading a different URL discards the dirty buffer")
    func reconcileDifferentURLDiscardsDirty() {
        let original = URL(fileURLWithPath: "/tmp/a.swift")
        let next = URL(fileURLWithPath: "/tmp/b.swift")
        var buffer = EditorBuffer()
        buffer.load(url: original, text: "a contents\n")
        buffer.recordEdit(text: "a contents + edits\n")
        #expect(buffer.isDirty == true)

        let outcome = buffer.reconcile(targetURL: next)

        #expect(outcome == .needsLoad(next))
        #expect(buffer.url == next)
        #expect(buffer.text == "")
        #expect(buffer.isDirty == false)
    }

    @Test("reconciling to nil clears the buffer to a scratch state")
    func reconcileToNilClearsToScratch() {
        let url = URL(fileURLWithPath: "/tmp/scratch.swift")
        var buffer = EditorBuffer()
        buffer.load(url: url, text: "content\n")
        buffer.recordEdit(text: "edited\n")

        let outcome = buffer.reconcile(targetURL: nil)

        #expect(outcome == .clearedToScratch)
        #expect(buffer.url == nil)
        #expect(buffer.text == "")
        #expect(buffer.isDirty == false)
    }

    @Test("save clears dirty")
    func saveClearsDirty() {
        let url = URL(fileURLWithPath: "/tmp/save.swift")
        var buffer = EditorBuffer()
        buffer.load(url: url, text: "v1\n")
        buffer.recordEdit(text: "v2\n")
        #expect(buffer.isDirty == true)

        buffer.markSaved()

        #expect(buffer.isDirty == false)
        // Saving does not move the URL or the in-memory text.
        #expect(buffer.url == url)
        #expect(buffer.text == "v2\n")
    }

    @Test("recordEdit with identical text does not flip dirty")
    func recordEditWithSameTextStaysClean() {
        let url = URL(fileURLWithPath: "/tmp/idempotent.swift")
        var buffer = EditorBuffer()
        buffer.load(url: url, text: "stable\n")

        buffer.recordEdit(text: "stable\n")

        #expect(buffer.isDirty == false)
    }
}
