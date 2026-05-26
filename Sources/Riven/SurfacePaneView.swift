import AppKit
import GhosttyKit
import RivenCore

/// NSView hosting one libghostty surface — Riven's terminal pane. The
/// surface owns its PTY in-process and renders into a CAMetalLayer that
/// libghostty attaches to this (layer-backed) view. We forward keyboard
/// / mouse / size / focus, draw on RENDER actions, expose `injectText`
/// for the command bar, and pull scrollback text on demand for search.
///
/// Input is handled natively by ghostty (control keys, alt-screen,
/// IME-ish text, mouse reporting) — there is no hand-rolled key routing
/// here anymore.
final class SurfacePaneView: NSView {
    /// Stable pane identity. Drives the registry lookup (command bar +
    /// search) and keys the title/bell/cwd notifications from action_cb.
    let paneID: PaneID?
    /// Working directory the shell spawns in.
    private let cwd: String
    /// Optional command to run instead of an interactive prompt. Sent as
    /// `initial_input` into a normal login shell so the command inherits
    /// the user's full environment (PATH etc.) — matching the old
    /// `zsh -l` behavior without wrestling ghostty's command parsing.
    private let command: String?
    /// Extra environment for the spawned shell (minimal — ghostty owns
    /// TERM/COLORTERM/TERM_PROGRAM + shell integration).
    private let env: [String: String]

    /// Called when ghostty reports a new working directory (OSC 7 →
    /// PWD action). Re-bound by the SwiftUI wrapper on each update.
    var onCwdChanged: (String) -> Void = { _ in }
    private var lastReportedCwd: String?

    private nonisolated(unsafe) var surface: ghostty_surface_t?

    init(paneID: PaneID?, cwd: String, command: String?, env: [String: String]) {
        self.paneID = paneID
        self.cwd = cwd
        self.command = command
        self.env = env
        super.init(frame: .zero)
        wantsLayer = true
        // Redraw the layer on resize rather than stretch its contents.
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        if surface == nil { createSurface() }
        // Restore deliberate terminal focus after a SwiftUI subtree
        // detach/reattach: the view kept its surface but lost
        // first-responder when it left the window. Only the pane the
        // user explicitly double-clicked into re-grabs — everything else
        // leaves the command bar as the default writer.
        if let paneID, GhosttyApp.shared.explicitlyFocusedPaneID == paneID {
            window?.makeFirstResponder(self)
        }
    }

    private func createSurface() {
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        let scale = Double(window?.backingScaleFactor ?? 2.0)
        cfg.scale_factor = scale

        // C-string buffers kept alive only until ghostty_surface_new
        // returns (libghostty copies what it needs during spawn).
        let cwdC = strdup(cwd)
        cfg.working_directory = UnsafePointer(cwdC)
        var initialC: UnsafeMutablePointer<CChar>?
        if let command {
            initialC = strdup(command + "\n")
            cfg.initial_input = UnsafePointer(initialC)
        }
        var envC: [UnsafeMutablePointer<CChar>?] = []
        var envVars: [ghostty_env_var_s] = []
        for (k, v) in env {
            let kc = strdup(k)
            let vc = strdup(v)
            envC.append(kc)
            envC.append(vc)
            envVars.append(ghostty_env_var_s(key: UnsafePointer(kc), value: UnsafePointer(vc)))
        }
        envVars.withUnsafeMutableBufferPointer { buf in
            cfg.env_vars = buf.baseAddress
            cfg.env_var_count = buf.count
            surface = ghostty_surface_new(GhosttyApp.shared.app, &cfg)
        }

        free(cwdC)
        if let initialC { free(initialC) }
        for ptr in envC { free(ptr) }

        guard let surface else {
            NSLog("[ghostty] ghostty_surface_new failed")
            return
        }
        ghostty_surface_set_content_scale(surface, scale, scale)
        pushSize()
        // Start UNfocused: the command bar is Riven's default writing
        // surface. The user transfers keyboard focus to the terminal
        // with a deliberate double-click (see mouseDown), and the solid/
        // hollow cursor reflects which surface owns input.
        ghostty_surface_set_focus(surface, false)
        if let paneID { GhosttyApp.shared.register(self, for: paneID) }
    }

    /// Called from the app's RENDER action → drive the Metal draw.
    func requestDraw() {
        guard let surface else { return }
        ghostty_surface_draw(surface)
    }

    /// Re-apply a rebuilt config (theme switch) to this surface.
    func applyConfig(_ config: ghostty_config_t) {
        guard let surface else { return }
        ghostty_surface_update_config(surface, config)
    }

    /// Inject text programmatically (command-bar path:
    /// `ghostty_surface_text` sends straight to the PTY).
    func injectText(_ text: String) {
        guard let surface else { return }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(strlen(ptr)))
        }
    }

    /// Pull the entire scrollback + viewport as text (search / peek).
    /// Selects the whole SCREEN (scrollback-inclusive) top-to-bottom.
    func readFullText() -> String? {
        guard let surface else { return nil }
        var sel = ghostty_selection_s()
        sel.top_left = ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
        sel.bottom_right = ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
        sel.rectangle = false
        var out = ghostty_text_s()
        guard ghostty_surface_read_text(surface, sel, &out) else { return nil }
        defer { ghostty_surface_free_text(surface, &out) }
        guard let textPtr = out.text, out.text_len > 0 else { return nil }
        let raw = UnsafeRawPointer(textPtr)
        return String(decoding: UnsafeRawBufferPointer(start: raw, count: Int(out.text_len)), as: UTF8.self)
    }

    func reportCwd(_ path: String) {
        guard path != lastReportedCwd else { return }
        lastReportedCwd = path
        onCwdChanged(path)
    }

    /// Complete a pending paste/OSC-52-read request with pasteboard
    /// text. Returns true if handed off to the surface.
    func completeClipboardRead(_ str: String, stateBits: UInt) -> Bool {
        guard let surface else { return false }
        let state = UnsafeMutableRawPointer(bitPattern: stateBits)
        str.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, true) }
        return true
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        pushSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface, let scale = window?.backingScaleFactor else { return }
        ghostty_surface_set_content_scale(surface, scale, scale)
        pushSize()
    }

    private func pushSize() {
        guard let surface else { return }
        let scale = Double(window?.backingScaleFactor ?? 2.0)
        let w = UInt32(max(1, Double(bounds.width) * scale))
        let h = UInt32(max(1, Double(bounds.height) * scale))
        ghostty_surface_set_size(surface, w, h)
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, true) }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, false) }
        return super.resignFirstResponder()
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        sendKey(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
    }

    override func keyUp(with event: NSEvent) {
        sendKey(event, action: GHOSTTY_ACTION_RELEASE)
    }

    /// Translate an AppKit key event into ghostty's key event and send it.
    /// The field setup mirrors Ghostty's own AppKit surface and it
    /// matters: ghostty's key encoder identifies a printable key from its
    /// `unshifted_codepoint` plus the modifiers consumed by text
    /// translation. Leaving those zeroed made control combos (Ctrl+X)
    /// encode correctly — they come from keycode+mods — while plain
    /// letters produced nothing, so a TUI's single-key prompt (nano's
    /// Y/N) silently ignored input.
    ///
    /// Note: this is the non-IME path. Dead-key composition and CJK input
    /// methods (which need `interpretKeyEvents` + NSTextInputClient) are a
    /// separate follow-up; latin / US-layout input works fully here.
    private func sendKey(_ event: NSEvent, action: ghostty_input_action_e) {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.composing = false
        key.mods = Self.ghosttyMods(event.modifierFlags)
        // Control + command never contribute to text translation; assume
        // shift / option did. (Ghostty's long-standing heuristic.)
        key.consumed_mods = Self.ghosttyMods(event.modifierFlags.subtracting([.control, .command]))
        // The codepoint with NO modifiers applied — 'n' (0x6E) for the N
        // key regardless of shift. Ghostty needs this to identify the key.
        key.unshifted_codepoint = 0
        if let bare = event.characters(byApplyingModifiers: []),
           let scalar = bare.unicodeScalars.first {
            key.unshifted_codepoint = scalar.value
        }
        // Send resolved characters as `text` only for genuinely printable
        // input. A lone control char is left for ghostty's encoder (keeps
        // Ctrl+X etc. correct); function-key private-use scalars are
        // dropped (ghostty encodes arrows / F-keys from the keycode).
        if action != GHOSTTY_ACTION_RELEASE, let text = Self.keyText(event) {
            text.withCString { ptr in
                key.text = ptr
                _ = ghostty_surface_key(surface, key)
            }
        } else {
            key.text = nil
            _ = ghostty_surface_key(surface, key)
        }
    }

    /// The text to hand ghostty as the key event's `text`, mirroring
    /// Ghostty's `ghosttyCharacters`: nil for a lone control character or
    /// a function-key PUA scalar (ghostty encodes those itself), the
    /// resolved characters otherwise.
    private static func keyText(_ event: NSEvent) -> String? {
        guard let chars = event.characters, !chars.isEmpty else { return nil }
        if chars.count == 1, let scalar = chars.unicodeScalars.first {
            if scalar.value < 0x20 { return nil }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
        }
        return chars
    }

    private static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(mods)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        // Keyboard focus transfers to the terminal only on a DELIBERATE
        // double-click. Single clicks just drive selection / mouse
        // reporting, so the command bar stays the default writing
        // surface and an accidental click can't hijack input. This is
        // what makes interactive sessions usable: double-click into
        // vim / htop / claude to type directly, then a single click on
        // the command bar (or any surface outside) hands focus back.
        if event.clickCount == 2 {
            if let paneID { GhosttyApp.shared.explicitlyFocusedPaneID = paneID }
            window?.makeFirstResponder(self)
        }
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS)
    }

    override func mouseUp(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE)
    }

    override func mouseMoved(with event: NSEvent) { sendMousePos(event) }
    override func mouseDragged(with event: NSEvent) { sendMousePos(event) }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_scroll(
            surface,
            Double(event.scrollingDeltaX),
            Double(event.scrollingDeltaY),
            0
        )
    }

    private func sendMouseButton(_ event: NSEvent, state: ghostty_input_mouse_state_e) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, state, GHOSTTY_MOUSE_LEFT, Self.ghosttyMods(event.modifierFlags))
    }

    private func sendMousePos(_ event: NSEvent) {
        guard let surface else { return }
        let p = convert(event.locationInWindow, from: nil)
        let scale = Double(window?.backingScaleFactor ?? 2.0)
        ghostty_surface_mouse_pos(surface, Double(p.x) * scale, Double(p.y) * scale, Self.ghosttyMods(event.modifierFlags))
    }

    deinit {
        if let paneID {
            let pid = paneID
            DispatchQueue.main.async {
                GhosttyApp.shared.unregister(pid)
                // This pane's view is gone (tab switch / close). If it
                // held the explicit terminal focus, drop the intent so
                // the command bar resumes being the default writer.
                if GhosttyApp.shared.explicitlyFocusedPaneID == pid {
                    GhosttyApp.shared.explicitlyFocusedPaneID = nil
                }
            }
        }
        if let surface { ghostty_surface_free(surface) }
    }
}
