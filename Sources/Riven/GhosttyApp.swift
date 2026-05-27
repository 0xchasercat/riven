import AppKit
import GhosttyKit
import RivenCore
import UserNotifications

// Top-level @convention(c) runtime callbacks. They reference the shared
// app + recover per-surface views via ghostty_surface_userdata.
// libghostty invokes these on the main thread (during app_tick /
// surface_draw), so the MainActor.assumeIsolated hops are sound.

private let ghosttyWakeupCb: @convention(c) (UnsafeMutableRawPointer?) -> Void = { _ in
    DispatchQueue.main.async { GhosttyApp.shared.tick() }
}

private let ghosttyActionCb: @convention(c) (ghostty_app_t?, ghostty_target_s, ghostty_action_s) -> Bool = { _, target, action in
    MainActor.assumeIsolated { GhosttyApp.handleAction(target: target, action: action) }
}

// Paste (Cmd+V / OSC 52 read): hand the macOS pasteboard's text back
// to the surface. `userdata` is the SURFACE userdata (= the
// SurfacePaneView), per libghostty's per-surface clipboard model.
private let ghosttyReadClipboardCb: @convention(c) (UnsafeMutableRawPointer?, ghostty_clipboard_e, UnsafeMutableRawPointer?) -> Bool = { userdata, location, state in
    guard location == GHOSTTY_CLIPBOARD_STANDARD,
          let userdata,
          let str = NSPasteboard.general.string(forType: .string) else { return false }
    let view = Unmanaged<SurfacePaneView>.fromOpaque(userdata).takeUnretainedValue()
    // Pass the request token as an int bit-pattern so it doesn't trip
    // the Sendable check crossing into the main actor.
    let stateBits = UInt(bitPattern: state)
    return MainActor.assumeIsolated { view.completeClipboardRead(str, stateBits: stateBits) }
}

private let ghosttyConfirmReadClipboardCb: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?, ghostty_clipboard_request_e) -> Void = { _, _, _, _ in }

// Copy (Cmd+C / OSC 52 write): write the surface's clipboard content
// to the macOS pasteboard. No surface needed — just take the text.
private let ghosttyWriteClipboardCb: @convention(c) (UnsafeMutableRawPointer?, ghostty_clipboard_e, UnsafePointer<ghostty_clipboard_content_s>?, Int, Bool) -> Void = { _, location, content, len, _ in
    guard location == GHOSTTY_CLIPBOARD_STANDARD, let content, len > 0 else { return }
    for i in 0..<len {
        guard let dataPtr = content[i].data else { continue }
        let str = String(cString: dataPtr)
        guard !str.isEmpty else { continue }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(str, forType: .string)
        return
    }
}

// The shell exited (or the surface otherwise asked to close). `userdata`
// is the SURFACE userdata. Route to a pane-exited notification so the
// controller can tear down the matching tab/surface.
private let ghosttyCloseSurfaceCb: @convention(c) (UnsafeMutableRawPointer?, Bool) -> Void = { userdata, _ in
    guard let userdata else { return }
    let view = Unmanaged<SurfacePaneView>.fromOpaque(userdata).takeUnretainedValue()
    MainActor.assumeIsolated { GhosttyApp.surfaceRequestedClose(view) }
}

/// Process-wide libghostty app. Owns the `ghostty_app_t` + config,
/// installs the runtime callbacks, pumps the tick loop, and keeps a
/// paneID → view registry so the command bar / search can reach a live
/// surface. `@unchecked Sendable` + a nonisolated singleton because all
/// access is on the main thread (AppKit-driven); the C callbacks hop
/// onto the main actor explicitly.
final class GhosttyApp: @unchecked Sendable {
    static let shared = GhosttyApp()

    private(set) var app: ghostty_app_t!
    /// The live config backing the app. We never free configs we've
    /// handed to `ghostty_app_new` / `update_config`: theme switches are
    /// rare, the struct is tiny metadata, and keeping them alive
    /// sidesteps any ambiguity about whether libghostty retains the
    /// pointer past the call. A few-bytes leak per theme switch is the
    /// conservative trade against a use-after-free crash.
    private var config: ghostty_config_t!
    private var lastAppliedThemeID: String?

    /// paneID → live SurfacePaneView. Weak so a closed pane's view can
    /// deallocate; dead entries are pruned lazily on access + register.
    private final class WeakSurfaceRef {
        weak var value: SurfacePaneView?
        init(_ v: SurfacePaneView) { value = v }
    }
    private var registry: [PaneID: WeakSurfaceRef] = [:]

    /// The pane the user DELIBERATELY double-clicked into, if any. This
    /// is the single source of truth for "the terminal owns input." The
    /// command bar — Riven's default writing surface — auto-grabs focus
    /// only while this is nil; a SurfacePaneView re-grabs first-responder
    /// on reattach only if it matches. That keeps deliberate terminal
    /// focus surviving SwiftUI subtree detach/reattach without letting an
    /// incidental AppKit first-responder assignment hijack the default.
    /// Set on double-click, cleared when the command bar takes focus or
    /// the focused pane's view is torn down (tab switch / close).
    var explicitlyFocusedPaneID: PaneID?

    private init() {
        let argv = CommandLine.unsafeArgv
        ghostty_init(UInt(CommandLine.argc), argv)

        config = Self.makeConfig(theme: nil)

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = nil
        runtime.supports_selection_clipboard = false
        runtime.wakeup_cb = ghosttyWakeupCb
        runtime.action_cb = ghosttyActionCb
        runtime.read_clipboard_cb = ghosttyReadClipboardCb
        runtime.confirm_read_clipboard_cb = ghosttyConfirmReadClipboardCb
        runtime.write_clipboard_cb = ghosttyWriteClipboardCb
        runtime.close_surface_cb = ghosttyCloseSurfaceCb

        guard let app = ghostty_app_new(&runtime, config) else {
            fatalError("ghostty_app_new failed")
        }
        self.app = app
        ghostty_app_set_focus(app, true)
    }

    func tick() {
        ghostty_app_tick(app)
    }

    // MARK: - Surface registry

    @MainActor
    func register(_ view: SurfacePaneView, for paneID: PaneID) {
        registry = registry.filter { $0.value.value != nil }
        registry[paneID] = WeakSurfaceRef(view)
    }

    @MainActor
    func unregister(_ paneID: PaneID) {
        registry[paneID] = nil
    }

    @MainActor
    func view(for paneID: PaneID) -> SurfacePaneView? {
        registry[paneID]?.value
    }

    /// Command-bar path: send text straight to the PTY of the given pane.
    @MainActor
    func injectText(_ text: String, into paneID: PaneID) {
        view(for: paneID)?.injectText(text)
    }

    /// Command-bar submit: inject the line + a real Return keypress so
    /// the shell executes it (see SurfacePaneView.submitLine).
    @MainActor
    func submitLine(_ text: String, into paneID: PaneID) {
        view(for: paneID)?.submitLine(text)
    }

    /// Cmd+K path: clear a terminal pane (Ctrl+L as a real key event).
    @MainActor
    func clearScreen(_ paneID: PaneID) {
        // kVK_ANSI_L = 37, 'l' = 0x6C.
        view(for: paneID)?.sendControlKey(keycode: 37, unshiftedCodepoint: 0x6C)
    }

    /// Cmd+I path: give a terminal pane explicit keyboard focus (the
    /// keyboard twin of double-clicking it).
    @MainActor
    func focusTerminal(_ paneID: PaneID) {
        explicitlyFocusedPaneID = paneID
        if let view = view(for: paneID) {
            view.window?.makeFirstResponder(view)
        }
    }

    /// Pull the full grid+scrollback text for a pane (search / peek).
    @MainActor
    func readScrollback(for paneID: PaneID) -> String? {
        view(for: paneID)?.readFullText()
    }

    // MARK: - Theming

    /// Rebuild the libghostty config from a Riven theme and re-apply it
    /// to the app + every live surface. No-op if the theme is unchanged.
    @MainActor
    func applyTheme(_ theme: ThemeSpec) {
        guard theme.id != lastAppliedThemeID else { return }
        lastAppliedThemeID = theme.id
        let newConfig = Self.makeConfig(theme: theme)
        ghostty_app_update_config(app, newConfig)
        for ref in registry.values { ref.value?.applyConfig(newConfig) }
        config = newConfig
    }

    /// Build a finalized `ghostty_config_t` in layers (later loads
    /// override earlier ones):
    ///   1. Riven's fallback defaults — TERM + a Nerd Font fallback.
    ///   2. The user's ghostty config (`~/.config/ghostty/config` etc.),
    ///      if any — so their font, colors, transparency, behaviors are
    ///      all respected and override our fallbacks.
    ///   3. Riven's theme colors LAST — but ONLY when the user has no
    ///      ghostty config. With a user config present, their terminal
    ///      should look exactly like their ghostty (the in-app theme
    ///      picker still drives Riven's chrome); without one, Riven's
    ///      theme drives the terminal.
    /// (libghostty has no set-by-key C API, so each Riven layer is
    /// written to a temp file and loaded via `ghostty_config_load_file`.)
    private static func makeConfig(theme: ThemeSpec?) -> ghostty_config_t {
        guard let config = ghostty_config_new() else {
            fatalError("ghostty_config_new failed")
        }
        load(config, baseConfigText())
        let hasUserConfig = userGhosttyConfigExists()
        ghostty_config_load_default_files(config)
        if !hasUserConfig, let theme { load(config, themeColorText(theme)) }
        ghostty_config_finalize(config)
        return config
    }

    /// True if the user has a ghostty config at any of the standard
    /// locations. When they do, we let it fully drive the terminal.
    private static func userGhosttyConfigExists() -> Bool {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var paths: [String] = []
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            paths.append("\(xdg)/ghostty/config")
        }
        paths.append("\(home)/.config/ghostty/config")
        paths.append("\(home)/Library/Application Support/com.mitchellh.ghostty/config")
        return paths.contains { fm.fileExists(atPath: $0) }
    }

    private static func load(_ config: ghostty_config_t, _ text: String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("riven-ghostty-\(UUID().uuidString).conf")
        do {
            try text.write(to: tmp, atomically: true, encoding: .utf8)
            tmp.path.withCString { ghostty_config_load_file(config, $0) }
            try? FileManager.default.removeItem(at: tmp)
        } catch {
            NSLog("[ghostty] config write failed: \(error)")
        }
    }

    /// Riven's fallback defaults. The user's ghostty config (loaded
    /// after this) overrides these where it sets them.
    private static func baseConfigText() -> String {
        var lines = [
            // Advertise the universally-present xterm-256color terminfo
            // to child programs rather than ghostty's own xterm-ghostty
            // (which needs its terminfo DB installed system-wide). Means
            // we don't have to ship a terminfo tree in the .app; ghostty's
            // renderer fidelity is unaffected (TERM only tells child
            // programs which escape sequences are safe to emit).
            "term = xterm-256color",
        ]
        // Default to an installed Nerd Font (glyph-rich prompts —
        // powerline, p10k, starship — expect one); fall back to ghostty's
        // built-in default if the user has none. Deliberately NOT SF Mono.
        // The user's ghostty config wins over this if it sets a font.
        if let font = fallbackNerdFont() {
            lines.append("font-family = \(font)")
        }
        lines.append("font-size = 13")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func themeColorText(_ theme: ThemeSpec) -> String {
        let t = theme.terminal
        let a = t.ansi
        let lines = [
            "background = \(t.background.hex)",
            "foreground = \(t.foreground.hex)",
            "cursor-color = \(t.cursor.hex)",
            // selectionBg is an 8-digit rgba token; ghostty's
            // selection-background wants an opaque color, so drop alpha.
            "selection-background = \(hex6(theme.chrome.selectionBg.hex))",
            // ANSI palette: Riven curates the six chromatic pairs; the
            // achromatic slots (0/7/8/15) keep ghostty's defaults.
            "palette = 1=\(a.red.hex)",
            "palette = 2=\(a.green.hex)",
            "palette = 3=\(a.yellow.hex)",
            "palette = 4=\(a.blue.hex)",
            "palette = 5=\(a.magenta.hex)",
            "palette = 6=\(a.cyan.hex)",
            "palette = 9=\(a.brightRed.hex)",
            "palette = 10=\(a.brightGreen.hex)",
            "palette = 11=\(a.brightYellow.hex)",
            "palette = 12=\(a.brightBlue.hex)",
            "palette = 13=\(a.brightMagenta.hex)",
            "palette = 14=\(a.brightCyan.hex)",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    /// The name of an installed Nerd Font to use as the default terminal
    /// face, or nil to let ghostty pick its built-in default. Checks a
    /// few common mono Nerd Fonts first, then any family advertising
    /// "Nerd Font".
    private static func fallbackNerdFont() -> String? {
        let families = NSFontManager.shared.availableFontFamilies
        let preferred = [
            "JetBrainsMono Nerd Font",
            "Hack Nerd Font",
            "FiraCode Nerd Font",
            "MesloLGS NF",
            "SauceCodePro Nerd Font",
            "Symbols Nerd Font Mono",
        ]
        for name in preferred where families.contains(name) { return name }
        return families.first { $0.localizedCaseInsensitiveContains("Nerd Font") }
    }

    /// Reduce a `#RRGGBB`/`#RRGGBBAA` token to opaque `#RRGGBB`.
    private static func hex6(_ hex: String) -> String {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        return "#" + String(digits.prefix(6))
    }

    // MARK: - Action routing

    @MainActor
    static func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_RENDER:
            surfaceView(from: target)?.requestDraw()
            return true

        case GHOSTTY_ACTION_SET_TITLE:
            if let view = surfaceView(from: target), let paneID = view.paneID {
                let title = action.action.set_title.title.map { String(cString: $0) }
                NotificationCenter.default.post(
                    name: .rivenTerminalTitleChanged,
                    object: TerminalTitleChange(paneID: paneID, title: title)
                )
            }
            return true

        case GHOSTTY_ACTION_RING_BELL:
            // Post only — the controller's `.rivenBell` observer owns the
            // audible beep, and InnerTabStrip owns the bell dot. Beeping
            // here too would double up.
            if let view = surfaceView(from: target), let paneID = view.paneID {
                NotificationCenter.default.post(name: .rivenBell, object: paneID)
            }
            return true

        case GHOSTTY_ACTION_PWD:
            if let view = surfaceView(from: target), let cstr = action.action.pwd.pwd {
                view.reportCwd(normalizePwd(String(cString: cstr)))
            }
            return true

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let n = action.action.desktop_notification
            let title = n.title.map { String(cString: $0) } ?? "Riven"
            let body = n.body.map { String(cString: $0) } ?? ""
            postDesktopNotification(title: title, body: body)
            return true

        case GHOSTTY_ACTION_OPEN_URL:
            let u = action.action.open_url
            if let urlPtr = u.url {
                let s = string(from: urlPtr, len: Int(u.len))
                if let url = URL(string: s) { NSWorkspace.shared.open(url) }
            }
            return true

        default:
            return true
        }
    }

    @MainActor
    static func surfaceRequestedClose(_ view: SurfacePaneView) {
        guard let paneID = view.paneID else { return }
        NotificationCenter.default.post(name: .rivenTerminalPaneExited, object: paneID)
    }

    @MainActor
    private static func surfaceView(from target: ghostty_target_s) -> SurfacePaneView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface else { return nil }
        guard let ud = ghostty_surface_userdata(surface) else { return nil }
        return Unmanaged<SurfacePaneView>.fromOpaque(ud).takeUnretainedValue()
    }

    private static func string(from ptr: UnsafePointer<CChar>, len: Int) -> String {
        let raw = UnsafeRawPointer(ptr)
        return String(decoding: UnsafeRawBufferPointer(start: raw, count: len), as: UTF8.self)
    }

    /// ghostty's PWD action usually hands us a bare filesystem path, but
    /// guard against a stray `file://host/path` form just in case.
    private static func normalizePwd(_ pwd: String) -> String {
        if pwd.hasPrefix("file://"), let url = URL(string: pwd) { return url.path }
        return pwd
    }

    private static func postDesktopNotification(title: String, body: String) {
        // UNUserNotificationCenter.current() requires a bundle proxy; in
        // a plain `swift run` (no .app) it would crash, so gate on a
        // bundle identifier being present.
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            // Re-fetch the singleton inside the closure rather than
            // capturing it — UNUserNotificationCenter isn't Sendable.
            UNUserNotificationCenter.current().add(request)
        }
    }
}
