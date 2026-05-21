import Foundation

/// Sidecar metadata describing a scrollback log: where the PTY was spawned,
/// what label the user saw on its tab, when it last wrote, etc. Lives
/// alongside the `<paneID>.log` file as `<paneID>.meta.json`.
///
/// The metadata is best-effort decoration for the search UI ("this hit came
/// from the `~/foo` project, yesterday at 14:22, in a tab labelled `bench
/// run`"). All consumers must tolerate `nil` — a legacy log without a
/// sidecar (anything pre-S-1) still searches, just without the chrome.
///
/// Update cadence:
///   - `create(_:)` writes the full record atomically on PTY spawn.
///   - `touch(...)` is a hot path — debounce in the caller (5 s is the
///     baseline in RivenAgent's record loop). One read + one write per
///     debounce window, no fsync.
///   - `update*(...)` mutators are rare (cwd changes on OSC 7, label
///     changes on inner-tab rename). Single read+write each.
public struct ScrollbackMetadata: Equatable, Codable, Sendable {
    public var paneID: PaneID
    public var sessionID: String
    public var projectRoot: String?
    public var workspaceName: String?
    public var cwd: String
    public var paneLabel: String?
    public var createdAt: Date
    public var lastWriteAt: Date
    public var byteCount: Int

    public init(
        paneID: PaneID,
        sessionID: String,
        projectRoot: String?,
        workspaceName: String?,
        cwd: String,
        paneLabel: String?,
        createdAt: Date = Date(),
        lastWriteAt: Date? = nil,
        byteCount: Int = 0
    ) {
        self.paneID = paneID
        self.sessionID = sessionID
        self.projectRoot = projectRoot
        self.workspaceName = workspaceName
        self.cwd = cwd
        self.paneLabel = paneLabel
        self.createdAt = createdAt
        self.lastWriteAt = lastWriteAt ?? createdAt
        self.byteCount = byteCount
    }
}

extension ScrollbackStore {
    /// Persist a metadata sidecar for `metadata.paneID`. Overwrites any
    /// previous sidecar — callers that want to preserve `createdAt` should
    /// read first and propagate. Atomic; safe to call from any thread.
    public func writeMetadata(_ metadata: ScrollbackMetadata) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = metadataURL(for: metadata.paneID)
        let data = try Self.metadataEncoder.encode(metadata)
        try data.write(to: url, options: .atomic)
    }

    /// Load the sidecar for `paneID`. Returns `nil` when no sidecar exists
    /// (legacy logs, or a pane that never wrote). Returns `nil` (not throws)
    /// on decode failure too — a corrupted sidecar shouldn't crash search.
    public func readMetadata(_ paneID: PaneID) throws -> ScrollbackMetadata? {
        let url = metadataURL(for: paneID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try? Self.metadataDecoder.decode(ScrollbackMetadata.self, from: data)
    }

    /// Read-modify-write: update `lastWriteAt` and bump `byteCount` by the
    /// delta of the latest append. The broker calls this from its debounced
    /// record loop; callers don't need to coalesce themselves.
    ///
    /// If no sidecar exists yet (someone wrote to the log before metadata
    /// was created), this is a no-op — callers should ensure `writeMetadata`
    /// has been called once at pane creation.
    public func touchMetadata(paneID: PaneID, addingBytes delta: Int, at when: Date = Date()) throws {
        guard var meta = try readMetadata(paneID) else { return }
        meta.lastWriteAt = when
        meta.byteCount &+= max(0, delta)
        try writeMetadata(meta)
    }

    /// Patch the `cwd` field. Called from the OSC 7 pipeline whenever a
    /// shell reports a new pwd. No-op if no sidecar exists.
    public func updateMetadataCwd(paneID: PaneID, cwd: String) throws {
        guard var meta = try readMetadata(paneID) else { return }
        guard meta.cwd != cwd else { return }
        meta.cwd = cwd
        try writeMetadata(meta)
    }

    /// Patch the `paneLabel` field. Called when an inner tab is renamed.
    public func updateMetadataLabel(paneID: PaneID, label: String?) throws {
        guard var meta = try readMetadata(paneID) else { return }
        guard meta.paneLabel != label else { return }
        meta.paneLabel = label
        try writeMetadata(meta)
    }

    /// List every metadata sidecar under `root`. Skips files whose JSON
    /// fails to decode — a corrupted sidecar shouldn't prevent the rest
    /// from showing up in search.
    public func listMetadata() throws -> [ScrollbackMetadata] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        return files.compactMap { url -> ScrollbackMetadata? in
            guard url.pathExtension == "json", url.lastPathComponent.hasSuffix(".meta.json") else {
                return nil
            }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? Self.metadataDecoder.decode(ScrollbackMetadata.self, from: data)
        }
    }

    /// Remove the sidecar for `paneID`. No-op if it doesn't exist. The
    /// `.log` deletion is handled by the existing `delete(_:)` method;
    /// callers that want a full purge should invoke both.
    public func deleteMetadata(_ paneID: PaneID) throws {
        let url = metadataURL(for: paneID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func metadataURL(for paneID: PaneID) -> URL {
        root.appendingPathComponent(paneID.rawValue).appendingPathExtension("meta.json")
    }

    fileprivate static let metadataEncoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()

    fileprivate static let metadataDecoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()
}
