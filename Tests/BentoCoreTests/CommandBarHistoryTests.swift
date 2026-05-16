import Testing
@testable import BentoCore

@Suite("CommandHistory")
struct CommandBarHistoryTests {
    @Test("submitting non-empty entries appends them in order")
    func submitsAndAppends() {
        var history = CommandHistory()

        #expect(history.submit("ls") == true)
        #expect(history.submit("pwd") == true)

        #expect(history.entries == ["ls", "pwd"])
    }

    @Test("empty / whitespace-only submissions are dropped")
    func dropsEmpty() {
        var history = CommandHistory()

        #expect(history.submit("") == false)
        #expect(history.submit("   \n  ") == false)
        #expect(history.entries.isEmpty)
    }

    @Test("consecutive duplicate submissions are de-duplicated")
    func dedupesConsecutive() {
        var history = CommandHistory()

        history.submit("ls")
        #expect(history.submit("ls") == false)
        // Whitespace-only differences also dedupe.
        #expect(history.submit("ls  ") == false)
        history.submit("pwd")
        // Non-consecutive duplicates are allowed (shell convention).
        #expect(history.submit("ls") == true)

        #expect(history.entries == ["ls", "pwd", "ls"])
    }

    @Test("previous walks backwards through entries")
    func walksBack() {
        var history = CommandHistory(entries: ["a", "b", "c"])

        #expect(history.previous(currentBuffer: "draft") == "c")
        #expect(history.previous(currentBuffer: "c") == "b")
        #expect(history.previous(currentBuffer: "b") == "a")
        // At the oldest entry: another previous returns nil.
        #expect(history.previous(currentBuffer: "a") == nil)
    }

    @Test("next walks forward and restores the stashed draft")
    func walksForwardRestoresDraft() {
        var history = CommandHistory(entries: ["a", "b"])

        #expect(history.previous(currentBuffer: "draft") == "b")
        #expect(history.previous(currentBuffer: "b") == "a")
        #expect(history.next(currentBuffer: "a") == "b")
        // Walking past the newest entry restores the user's draft.
        #expect(history.next(currentBuffer: "b") == "draft")
        // Already live; further next yields nil.
        #expect(history.next(currentBuffer: "draft") == nil)
    }

    @Test("submit clears cursor and stashed draft")
    func submitClearsCursor() {
        var history = CommandHistory(entries: ["a", "b"])
        _ = history.previous(currentBuffer: "draft")
        #expect(history.isNavigating == true)

        history.submit("c")
        #expect(history.isNavigating == false)
        #expect(history.entries == ["a", "b", "c"])
        // Stash should not leak into the next history walk.
        #expect(history.previous(currentBuffer: "") == "c")
    }

    @Test("reset returns to live state without modifying entries")
    func resetReturnsToLive() {
        var history = CommandHistory(entries: ["a", "b"])
        _ = history.previous(currentBuffer: "draft")
        history.reset()

        #expect(history.isNavigating == false)
        #expect(history.entries == ["a", "b"])
        // The stash is dropped: the next up-arrow stashes the new buffer.
        #expect(history.previous(currentBuffer: "freshDraft") == "b")
    }

    @Test("history honors capacity by dropping oldest entries")
    func capacityTrimsOldest() {
        var history = CommandHistory(capacity: 3)

        history.submit("a")
        history.submit("b")
        history.submit("c")
        history.submit("d")

        #expect(history.entries == ["b", "c", "d"])
    }

    @Test("seed entries beyond capacity are trimmed in init")
    func seedTrimmedInInit() {
        let history = CommandHistory(entries: ["a", "b", "c", "d"], capacity: 2)
        #expect(history.entries == ["c", "d"])
    }

    @Test("next from live state is a no-op")
    func nextFromLiveIsNoOp() {
        var history = CommandHistory(entries: ["a"])
        #expect(history.next(currentBuffer: "draft") == nil)
    }

    @Test("previous on empty history yields nil and stays live")
    func previousOnEmptyIsNil() {
        var history = CommandHistory()
        #expect(history.previous(currentBuffer: "draft") == nil)
        #expect(history.isNavigating == false)
    }
}
