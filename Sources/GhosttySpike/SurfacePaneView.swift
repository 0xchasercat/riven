import AppKit
import GhosttyKit

/// NSView hosting one libghostty surface. libghostty attaches its own
/// CAMetalLayer to this view (we just need to be layer-backed) and
/// renders into it. We forward keyboard/mouse input + size/scale, and
/// draw when the app's RENDER action fires.
///
/// Spike scope: a single pane running a shell. Input is a minimal-but-
/// functional `ghostty_surface_key` path (full IME/dead-key handling
/// is a later concern).
final class SurfacePaneView: NSView {
    private nonisolated(unsafe) var surface: ghostty_surface_t?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
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
        guard window != nil, surface == nil else { return }
        createSurface()
    }

    private func createSurface() {
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        let scale = Double(window?.backingScaleFactor ?? 2.0)
        cfg.scale_factor = scale
        // Default shell, home dir. Spike: no command override.
        let home = NSHomeDirectory()
        home.withCString { cwdPtr in
            cfg.working_directory = cwdPtr
            surface = ghostty_surface_new(GhosttyApp.shared.app, &cfg)
        }
        guard let surface else {
            NSLog("[ghostty] ghostty_surface_new failed")
            return
        }
        ghostty_surface_set_content_scale(surface, scale, scale)
        pushSize()
        ghostty_surface_set_focus(surface, true)
        window?.makeFirstResponder(self)
    }

    /// Called from the app's RENDER action → drive the Metal draw.
    func requestDraw() {
        guard let surface else { return }
        ghostty_surface_draw(surface)
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

    // MARK: - Keyboard (minimal spike path)

    override func keyDown(with event: NSEvent) {
        sendKey(event, action: GHOSTTY_ACTION_PRESS)
    }

    override func keyUp(with event: NSEvent) {
        sendKey(event, action: GHOSTTY_ACTION_RELEASE)
    }

    private func sendKey(_ event: NSEvent, action: ghostty_input_action_e) {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.mods = Self.ghosttyMods(event.modifierFlags)
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.composing = false
        key.unshifted_codepoint = 0
        // `text` carries the resolved characters for printable keys;
        // ghostty encodes control keys from keycode+mods regardless.
        if action == GHOSTTY_ACTION_PRESS, let chars = event.characters, !chars.isEmpty {
            chars.withCString { ptr in
                key.text = ptr
                _ = ghostty_surface_key(surface, key)
            }
        } else {
            key.text = nil
            _ = ghostty_surface_key(surface, key)
        }
    }

    /// Inject text programmatically (the command-bar path:
    /// `ghostty_surface_text` sends straight to the PTY). Proves the
    /// differentiator survives the migration.
    func injectText(_ text: String) {
        guard let surface else { return }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(strlen(ptr)))
        }
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

    // MARK: - Mouse (minimal)

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
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
        if let surface { ghostty_surface_free(surface) }
    }
}
