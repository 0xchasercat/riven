import Foundation

/// Installs and uninstalls Bento's optional zsh shell integration.
///
/// The model is intentionally low-magic:
///
/// 1. **Source files** ship in the app bundle under
///    `Resources/shell-integration/` (zsh config + vendored plugins).
/// 2. **Install** copies the bundle tree to
///    `~/.config/bento/shell/` and appends a fenced source block to
///    `~/.zshrc` so the user's interactive shells pick up Bento's
///    config without conflicting with whatever else they have.
/// 3. **Uninstall** removes the fenced block from `~/.zshrc` and
///    deletes the destination directory. The user's own data
///    (`~/.zsh_history`, `~/.z`, `~/.zshrc` itself) is left alone.
/// 4. **isInstalled** detects the fenced block by its marker
///    comment so we never edit a partially-modified `.zshrc`.
///
/// Idempotent on every operation. Multiple installs collapse to
/// one source line; uninstalling when not installed is a no-op.
public struct ShellIntegrationInstaller: Sendable {
    public enum InstallError: Error, CustomStringConvertible {
        case missingBundleResources
        case zshrcWriteFailed(String)
        case copyFailed(String)

        public var description: String {
            switch self {
            case .missingBundleResources:
                return "Bento's shell-integration resources are missing from the app bundle"
            case let .zshrcWriteFailed(reason):
                return "Couldn't update ~/.zshrc: \(reason)"
            case let .copyFailed(reason):
                return "Couldn't copy shell integration files: \(reason)"
            }
        }
    }

    /// Marker comment that fences the block we own inside `.zshrc`.
    /// Pinned across versions so the uninstaller can find old
    /// installations. **Do not change.**
    public static let beginMarker = "# >>> Bento shell integration >>>"
    public static let endMarker   = "# <<< Bento shell integration <<<"

    /// Path the source files get copied to. Visible to the user so
    /// they can `bat` it, edit it (overrides survive the next
    /// install — see `install(force:)`), or remove it entirely.
    public let destinationDirectory: URL
    /// Path to the user's `.zshrc`. Configurable for tests.
    public let zshrcPath: URL
    /// Where we read the bundled source files from. Defaults to
    /// `Bundle.module.url(forResource: "shell-integration", …)`.
    public let bundleSourceDirectory: URL?

    public init(
        destinationDirectory: URL? = nil,
        zshrcPath: URL? = nil,
        bundleSourceDirectory: URL? = nil
    ) {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        self.destinationDirectory = destinationDirectory
            ?? home.appendingPathComponent(".config/bento/shell", isDirectory: true)
        self.zshrcPath = zshrcPath
            ?? home.appendingPathComponent(".zshrc")
        self.bundleSourceDirectory = bundleSourceDirectory
            ?? Bundle.module.url(forResource: "shell-integration", withExtension: nil)
    }

    /// True iff the marker block is currently present in `.zshrc`
    /// AND the destination directory's entry point exists. Either
    /// half alone counts as "needs reinstall."
    public func isInstalled() -> Bool {
        guard zshrcContainsMarker() else { return false }
        let entry = destinationDirectory.appendingPathComponent("bento.zsh")
        return FileManager.default.fileExists(atPath: entry.path)
    }

    /// Copy bundled files to `destinationDirectory` and append the
    /// fenced source block to `.zshrc`. Idempotent — running twice
    /// in a row produces the same on-disk state as running once.
    ///
    /// `force` rewrites the destination tree from the bundle even if
    /// it already exists; useful when shipping a new integration
    /// version. User-edited files there will be overwritten — we
    /// don't try to merge.
    public func install(force: Bool = false) throws {
        guard let source = bundleSourceDirectory,
              FileManager.default.fileExists(atPath: source.path) else {
            throw InstallError.missingBundleResources
        }

        try copyResources(from: source, force: force)
        try ensureZshrcBlock()
    }

    /// Remove the fenced block from `.zshrc` and delete
    /// `destinationDirectory`. Leaves `~/.zsh_history` + `~/.z`
    /// alone — those are user data, not ours to touch.
    public func uninstall() throws {
        try removeZshrcBlock()
        if FileManager.default.fileExists(atPath: destinationDirectory.path) {
            try FileManager.default.removeItem(at: destinationDirectory)
        }
    }

    // MARK: - Internals

    /// Recursively copy `source` → `destinationDirectory`. When
    /// `force` is true (or the destination doesn't exist), wipes
    /// the destination first so stale files from a previous version
    /// don't linger.
    private func copyResources(from source: URL, force: Bool) throws {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: destinationDirectory.path) {
                if force {
                    try fm.removeItem(at: destinationDirectory)
                } else {
                    // Idempotent path: still refresh files in case
                    // the bundle changed. We don't preserve user
                    // edits inside our destination — the contract is
                    // "Bento owns this directory."
                    try fm.removeItem(at: destinationDirectory)
                }
            }
            try fm.createDirectory(
                at: destinationDirectory.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fm.copyItem(at: source, to: destinationDirectory)
        } catch {
            throw InstallError.copyFailed(String(describing: error))
        }
    }

    /// Write the marker block into `.zshrc`. If a block already
    /// exists (any version) it's replaced. If `.zshrc` doesn't
    /// exist, create it with just our block.
    private func ensureZshrcBlock() throws {
        let block = renderedZshrcBlock()
        do {
            let current: String
            if FileManager.default.fileExists(atPath: zshrcPath.path) {
                current = (try? String(contentsOf: zshrcPath, encoding: .utf8)) ?? ""
            } else {
                current = ""
            }
            let updated = inject(block: block, into: current)
            guard updated != current else { return }
            try updated.write(to: zshrcPath, atomically: true, encoding: .utf8)
        } catch {
            throw InstallError.zshrcWriteFailed(String(describing: error))
        }
    }

    private func removeZshrcBlock() throws {
        guard FileManager.default.fileExists(atPath: zshrcPath.path) else { return }
        do {
            let current = (try? String(contentsOf: zshrcPath, encoding: .utf8)) ?? ""
            let stripped = strip(from: current)
            if stripped != current {
                try stripped.write(to: zshrcPath, atomically: true, encoding: .utf8)
            }
        } catch {
            throw InstallError.zshrcWriteFailed(String(describing: error))
        }
    }

    /// The block of text we own inside `.zshrc`. Built fresh each
    /// time so the embedded path always matches the live
    /// `destinationDirectory` (which a test may have relocated).
    private func renderedZshrcBlock() -> String {
        let entry = destinationDirectory.appendingPathComponent("bento.zsh").path
        return """
        \(Self.beginMarker)
        # Bento provides an optional zsh integration. Sourced only when
        # the file is present (so uninstalls don't break this shell).
        [[ -r "\(entry)" ]] && source "\(entry)"
        \(Self.endMarker)
        """
    }

    /// Returns true if `.zshrc` currently contains our begin marker.
    /// Doesn't check `end` separately — a half-removed block still
    /// counts as "needs reinstall" so we'll rewrite it cleanly.
    private func zshrcContainsMarker() -> Bool {
        guard let body = try? String(contentsOf: zshrcPath, encoding: .utf8) else {
            return false
        }
        return body.contains(Self.beginMarker)
    }

    /// Append `block` to `body`, replacing any existing fenced
    /// block. Public-ish so we can test it independently.
    internal func inject(block: String, into body: String) -> String {
        let stripped = strip(from: body)
        // Make sure there's exactly one trailing newline before our
        // block so the resulting file ends cleanly.
        var prefix = stripped
        while prefix.hasSuffix("\n\n") { prefix.removeLast() }
        if !prefix.hasSuffix("\n"), !prefix.isEmpty { prefix.append("\n") }
        return prefix + "\n" + block + "\n"
    }

    /// Remove any existing marker block from `body`, including the
    /// markers themselves. Returns the body unchanged if no block
    /// is present.
    internal func strip(from body: String) -> String {
        guard let beginRange = body.range(of: Self.beginMarker) else { return body }
        // Walk forward to the end marker (or EOF if the user trimmed
        // half of it manually).
        let after = body.index(beginRange.upperBound, offsetBy: 0)
        if let endRange = body.range(of: Self.endMarker, range: after..<body.endIndex) {
            // Include the newline after the end marker so we don't
            // leave a dangling blank line.
            var stop = endRange.upperBound
            if stop < body.endIndex, body[stop] == "\n" {
                stop = body.index(after: stop)
            }
            // Also walk the begin index back to the preceding newline
            // so we don't strand the marker block on a line continuation.
            var start = beginRange.lowerBound
            if start > body.startIndex {
                let prev = body.index(before: start)
                if body[prev] == "\n" { start = prev }
            }
            return String(body[..<start] + body[stop...])
        }
        // Half-removed block — drop everything from the begin marker
        // onward as a best-effort cleanup.
        return String(body[..<beginRange.lowerBound])
    }
}
