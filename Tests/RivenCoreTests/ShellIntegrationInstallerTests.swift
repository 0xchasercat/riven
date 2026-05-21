import Foundation
import Testing
@testable import RivenCore

@Suite("Shell integration installer")
struct ShellIntegrationInstallerTests {
    /// Build an installer pointed at a temp working dir + temp
    /// fake .zshrc + a fake bundle source layout.
    private func makeInstaller(
        prepopulateZshrc: String? = nil,
        bundleContents: [String: String] = [:]
    ) throws -> ShellIntegrationInstaller {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("riven-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let dest = root.appendingPathComponent(".config/riven/shell", isDirectory: true)
        let zshrc = root.appendingPathComponent(".zshrc")
        let bundle = root.appendingPathComponent("bundle/shell-integration", isDirectory: true)

        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        // Always include riven.zsh — that's the entry-point file
        // isInstalled() checks for after the marker.
        var files = bundleContents
        files["riven.zsh"] = files["riven.zsh"] ?? "# Riven entry\n"
        for (name, body) in files {
            try body.write(
                to: bundle.appendingPathComponent(name),
                atomically: true,
                encoding: .utf8
            )
        }

        if let prepopulateZshrc {
            try prepopulateZshrc.write(to: zshrc, atomically: true, encoding: .utf8)
        }

        return ShellIntegrationInstaller(
            destinationDirectory: dest,
            zshrcPath: zshrc,
            bundleSourceDirectory: bundle
        )
    }

    @Test("install copies files and appends a fenced block to .zshrc")
    func freshInstall() throws {
        let installer = try makeInstaller()

        #expect(installer.isInstalled() == false)
        try installer.install()
        #expect(installer.isInstalled() == true)

        // .zshrc carries both markers + the source line.
        let zshrcBody = try String(contentsOf: installer.zshrcPath, encoding: .utf8)
        #expect(zshrcBody.contains(ShellIntegrationInstaller.beginMarker))
        #expect(zshrcBody.contains(ShellIntegrationInstaller.endMarker))
        #expect(zshrcBody.contains("riven.zsh"))

        // riven.zsh landed in the destination.
        let entry = installer.destinationDirectory.appendingPathComponent("riven.zsh")
        #expect(FileManager.default.fileExists(atPath: entry.path))
    }

    @Test("install is idempotent: running twice leaves exactly one marker block")
    func idempotentInstall() throws {
        let installer = try makeInstaller()
        try installer.install()
        try installer.install()
        let body = try String(contentsOf: installer.zshrcPath, encoding: .utf8)
        let occurrences = body.components(separatedBy: ShellIntegrationInstaller.beginMarker).count - 1
        #expect(occurrences == 1)
    }

    @Test("install preserves the user's existing .zshrc content")
    func preservesExistingZshrc() throws {
        let existing = """
        # my zsh config
        export PATH="$HOME/.local/bin:$PATH"
        alias gs='git status'
        """
        let installer = try makeInstaller(prepopulateZshrc: existing)
        try installer.install()

        let body = try String(contentsOf: installer.zshrcPath, encoding: .utf8)
        #expect(body.contains("# my zsh config"))
        #expect(body.contains("alias gs='git status'"))
        #expect(body.contains(ShellIntegrationInstaller.beginMarker))
    }

    @Test("uninstall removes the block + destination, leaves user content alone")
    func uninstall() throws {
        let existing = """
        # my zsh config
        export PATH="$HOME/.local/bin:$PATH"
        """
        let installer = try makeInstaller(prepopulateZshrc: existing)
        try installer.install()
        try installer.uninstall()

        let body = try String(contentsOf: installer.zshrcPath, encoding: .utf8)
        #expect(body.contains("# my zsh config"))
        #expect(body.contains(ShellIntegrationInstaller.beginMarker) == false)
        #expect(FileManager.default.fileExists(atPath: installer.destinationDirectory.path) == false)
        #expect(installer.isInstalled() == false)
    }

    @Test("uninstall when not installed is a no-op (no throw)")
    func uninstallWhenAbsent() throws {
        let installer = try makeInstaller(prepopulateZshrc: "# unchanged\n")
        try installer.uninstall()
        let body = try String(contentsOf: installer.zshrcPath, encoding: .utf8)
        #expect(body == "# unchanged\n")
    }

    @Test("inject collapses a previous block to a single fresh block")
    func injectReplacesPrevious() throws {
        let installer = try makeInstaller()
        let stale = """
        # head
        \(ShellIntegrationInstaller.beginMarker)
        source /old/path/riven.zsh
        \(ShellIntegrationInstaller.endMarker)
        # tail
        """
        let fresh = """
        \(ShellIntegrationInstaller.beginMarker)
        source /new/path/riven.zsh
        \(ShellIntegrationInstaller.endMarker)
        """
        let result = installer.inject(block: fresh, into: stale)
        // Old source line is gone, new one is in.
        #expect(result.contains("/old/path") == false)
        #expect(result.contains("/new/path") == true)
        // Surrounding user content survives.
        #expect(result.contains("# head"))
        #expect(result.contains("# tail"))
        // Exactly one block.
        let count = result.components(separatedBy: ShellIntegrationInstaller.beginMarker).count - 1
        #expect(count == 1)
    }
}
