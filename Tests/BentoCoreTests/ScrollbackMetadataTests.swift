import Foundation
import Testing
@testable import BentoCore

@Suite("Scrollback metadata sidecar")
struct ScrollbackMetadataTests {
    private func freshStore() -> ScrollbackStore {
        ScrollbackStore(
            root: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("bento-meta-\(UUID().uuidString)")
        )
    }

    @Test("writeMetadata + readMetadata roundtrip preserves every field")
    func roundtrip() throws {
        let store = freshStore()
        let paneID = PaneID("alpha")
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let meta = ScrollbackMetadata(
            paneID: paneID,
            sessionID: "session-x",
            projectRoot: "/Users/jp/foo",
            workspaceName: "foo",
            cwd: "/Users/jp/foo/src",
            paneLabel: "bench run",
            createdAt: created,
            lastWriteAt: created,
            byteCount: 1024
        )

        try store.writeMetadata(meta)
        let loaded = try #require(try store.readMetadata(paneID))

        #expect(loaded == meta)
    }

    @Test("readMetadata returns nil when no sidecar exists (legacy log)")
    func legacyLogHasNilMetadata() throws {
        let store = freshStore()
        let paneID = PaneID("legacy")
        try store.append("hello\n", to: paneID)

        #expect(try store.readMetadata(paneID) == nil)
    }

    @Test("touchMetadata updates lastWriteAt and accumulates byteCount")
    func touchAccumulates() throws {
        let store = freshStore()
        let paneID = PaneID("beta")
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        try store.writeMetadata(
            ScrollbackMetadata(
                paneID: paneID,
                sessionID: "s",
                projectRoot: nil,
                workspaceName: nil,
                cwd: "/tmp",
                paneLabel: nil,
                createdAt: created,
                lastWriteAt: created,
                byteCount: 0
            )
        )

        let later = created.addingTimeInterval(60)
        try store.touchMetadata(paneID: paneID, addingBytes: 256, at: later)
        try store.touchMetadata(paneID: paneID, addingBytes: 128, at: later.addingTimeInterval(30))

        let final = try #require(try store.readMetadata(paneID))
        #expect(final.byteCount == 384)
        #expect(final.lastWriteAt == later.addingTimeInterval(30))
    }

    @Test("touchMetadata is a no-op when sidecar is missing")
    func touchMissingIsNoOp() throws {
        let store = freshStore()
        try store.touchMetadata(paneID: PaneID("nope"), addingBytes: 999)
        #expect(try store.readMetadata(PaneID("nope")) == nil)
    }

    @Test("updateMetadataCwd patches cwd in place without touching other fields")
    func updateCwd() throws {
        let store = freshStore()
        let paneID = PaneID("gamma")
        let original = ScrollbackMetadata(
            paneID: paneID,
            sessionID: "s",
            projectRoot: "/a",
            workspaceName: "a",
            cwd: "/a",
            paneLabel: "tab",
            byteCount: 42
        )
        try store.writeMetadata(original)

        try store.updateMetadataCwd(paneID: paneID, cwd: "/a/b")
        let updated = try #require(try store.readMetadata(paneID))
        #expect(updated.cwd == "/a/b")
        #expect(updated.byteCount == 42)
        #expect(updated.workspaceName == "a")
    }

    @Test("listMetadata enumerates every sidecar under root")
    func listAll() throws {
        let store = freshStore()
        try store.writeMetadata(.init(paneID: PaneID("one"), sessionID: "s", projectRoot: nil, workspaceName: nil, cwd: "/", paneLabel: nil))
        try store.writeMetadata(.init(paneID: PaneID("two"), sessionID: "s", projectRoot: nil, workspaceName: nil, cwd: "/", paneLabel: nil))
        // A log without a sidecar shouldn't appear.
        try store.append("noise\n", to: PaneID("three"))

        let all = try store.listMetadata().map(\.paneID.rawValue).sorted()
        #expect(all == ["one", "two"])
    }

    @Test("deleteMetadata removes only the sidecar, not the log")
    func deleteJustSidecar() throws {
        let store = freshStore()
        let paneID = PaneID("delta")
        try store.append("payload\n", to: paneID)
        try store.writeMetadata(.init(paneID: paneID, sessionID: "s", projectRoot: nil, workspaceName: nil, cwd: "/", paneLabel: nil))

        try store.deleteMetadata(paneID)
        #expect(try store.readMetadata(paneID) == nil)
        // Log still readable.
        let body = try store.read(paneID)
        #expect(String(decoding: body, as: UTF8.self) == "payload\n")
    }
}
