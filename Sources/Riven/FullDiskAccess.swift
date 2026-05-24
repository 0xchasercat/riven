import AppKit

/// Full Disk Access onboarding for Riven.
///
/// Riven is a terminal — the user navigates anywhere on disk and
/// expects to read files there. macOS Mojave+ gates a growing set of
/// locations (Documents, Desktop, Downloads, removable + network
/// volumes, other apps' data) behind per-folder TCC prompts. The
/// `NSxxxFolderUsageDescription` keys in Info.plist make those prompts
/// at least *appear* instead of silently failing, but a prompt on
/// every `cd` into a new protected directory is its own kind of
/// broken.
///
/// Full Disk Access supersedes all of them — grant it once and the
/// per-folder interruptions stop entirely. The catch: FDA is NOT
/// programmatically requestable. There's no API that pops the grant
/// dialog (by design — it's the most powerful permission macOS
/// hands out). The only path is the user toggling Riven on in
/// System Settings → Privacy & Security → Full Disk Access. So the
/// best we can do is detect the missing grant, explain why we want
/// it, and deep-link straight to the right pane. (This is exactly
/// what iTerm2 + Warp + every other serious terminal do.)
enum FullDiskAccess {
    /// True when Riven can read TCC-gated paths. Probes the per-user
    /// TCC database, which is only `open()`-able with Full Disk
    /// Access — the community-standard FDA check.
    ///
    /// A missing TCC.db (ENOENT) is treated as "granted" so we don't
    /// nag on an unusual setup where the probe file doesn't exist.
    static var isGranted: Bool {
        let probe = NSHomeDirectory()
            + "/Library/Application Support/com.apple.TCC/TCC.db"
        let fd = open(probe, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return true
        }
        // EACCES / EPERM ⇒ the file exists but TCC blocked us ⇒ no FDA.
        // ENOENT ⇒ probe absent ⇒ can't tell, assume fine.
        return errno == ENOENT
    }

    /// UserDefaults gate so the launch-time prompt is one-shot.
    static let promptDismissedKey = "Riven.fullDiskAccessPromptDismissed"

    /// Deep-link to the Full Disk Access settings pane. Works on
    /// Ventura / Sonoma / Sequoia (the classic preferences URL scheme
    /// still resolves to the new System Settings layout).
    static func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Show the onboarding alert at launch IF Riven lacks FDA and the
    /// user hasn't checked "Don't ask again." No-op otherwise.
    @MainActor
    static func promptIfNeeded() {
        guard !isGranted else { return }
        guard !UserDefaults.standard.bool(forKey: promptDismissedKey) else { return }
        present(isReprompt: false)
    }

    /// Present the FDA explainer. `isReprompt` distinguishes the
    /// launch-time one-shot (offers "Don't ask again") from the
    /// menu-triggered re-invocation (always available, no suppression).
    @MainActor
    static func present(isReprompt: Bool) {
        let alert = NSAlert()
        alert.messageText = "Grant Riven Full Disk Access"
        alert.informativeText = """
        Riven is a terminal — it reads the files and folders you \
        navigate to. Without Full Disk Access, macOS interrupts you \
        for permission every time you cd into a new protected folder \
        (Documents, Desktop, Downloads, external drives, and more).

        Grant Full Disk Access once and those interruptions stop.

        Click Open Settings, switch on Riven in the list, then \
        relaunch Riven.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: isReprompt ? "Cancel" : "Not Now")
        if !isReprompt {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't ask again"
        }

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openSystemSettings()
        }
        if !isReprompt, alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: promptDismissedKey)
        }
    }
}
