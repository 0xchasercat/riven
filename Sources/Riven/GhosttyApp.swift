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
    nonisolated(unsafe) static let shared = GhosttyApp()

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

    /// Build a finalized `ghostty_config_t`. When a theme is supplied we
    /// translate its terminal colors + ANSI palette into ghostty config
    /// directives written to a temp file (libghostty has no set-by-key C
    /// API — only `load_file`). We deliberately skip
    /// `load_default_files` so Riven's behavior is deterministic and a
    /// user's ~/.config/ghostty keybindings can't hijack the app.
    private static func makeConfig(theme: ThemeSpec?) -> ghostty_config_t {
        guard let config = ghostty_config_new() else {
            fatalError("ghostty_config_new failed")
        }
        if let theme {
            let text = themeConfigText(theme)
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("riven-ghostty-\(UUID().uuidString).conf")
            do {
                try text.write(to: tmp, atomically: true, encoding: .utf8)
                tmp.path.withCString { ghostty_config_load_file(config, $0) }
                try? FileManager.default.removeItem(at: tmp)
            } catch {
                NSLog("[ghostty] theme config write failed: \(error)")
            }
        }
        ghostty_config_finalize(config)
        return config
    }

    private static func themeConfigText(_ theme: ThemeSpec) -> String {
        let t = theme.terminal
        let a = t.ansi
        let lines: [String] = [
            "background = \(t.background.hex)",
            "foreground = \(t.foreground.hex)",
            "cursor-color = \(t.cursor.hex)",
            // selectionBg is an 8-digit rgba token; ghostty's
            // selection-background wants an opaque color, so drop alpha.
            "selection-background = \(hex6(theme.chrome.selectionBg.hex))",
            "font-size = 13",
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
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }
}
