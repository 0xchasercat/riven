import AppKit
import GhosttyKit

// Top-level @convention(c) runtime callbacks. They reference the
// shared app + recover per-surface views via ghostty_surface_userdata.
// libghostty invokes these on the main thread (during app_tick /
// surface_draw), so the MainActor.assumeIsolated hops are sound.

private let ghosttyWakeupCb: @convention(c) (UnsafeMutableRawPointer?) -> Void = { _ in
    DispatchQueue.main.async { GhosttyApp.shared.tick() }
}

private let ghosttyActionCb: @convention(c) (ghostty_app_t?, ghostty_target_s, ghostty_action_s) -> Bool = { _, target, action in
    MainActor.assumeIsolated { GhosttyApp.handleAction(target: target, action: action) }
}

private let ghosttyReadClipboardCb: @convention(c) (UnsafeMutableRawPointer?, ghostty_clipboard_e, UnsafeMutableRawPointer?) -> Bool = { _, _, _ in false }

private let ghosttyConfirmReadClipboardCb: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?, ghostty_clipboard_request_e) -> Void = { _, _, _, _ in }

private let ghosttyWriteClipboardCb: @convention(c) (UnsafeMutableRawPointer?, ghostty_clipboard_e, UnsafePointer<ghostty_clipboard_content_s>?, Int, Bool) -> Void = { _, _, _, _, _ in }

private let ghosttyCloseSurfaceCb: @convention(c) (UnsafeMutableRawPointer?, Bool) -> Void = { _, _ in }

/// Process-wide libghostty app. Owns the `ghostty_app_t` + config,
/// installs the runtime callbacks, and pumps the tick loop. Spike
/// scope: minimal but real. `@unchecked Sendable` + nonisolated
/// singleton because all access is on the main thread (the spike is
/// single-window, main-actor-driven); a production version would
/// formalize the isolation.
final class GhosttyApp: @unchecked Sendable {
    nonisolated(unsafe) static let shared = GhosttyApp()

    private(set) var app: ghostty_app_t!
    private var config: ghostty_config_t!

    private init() {
        let argv = CommandLine.unsafeArgv
        ghostty_init(UInt(CommandLine.argc), argv)

        config = ghostty_config_new()
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)

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

    @MainActor
    static func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_RENDER:
            if target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface {
                paneView(for: surface)?.requestDraw()
            }
            return true
        case GHOSTTY_ACTION_SET_TITLE:
            if let c = action.action.set_title.title {
                NSLog("[ghostty] title: \(String(cString: c))")
            }
            return true
        case GHOSTTY_ACTION_RING_BELL:
            NSSound.beep()
            return true
        default:
            return true
        }
    }

    @MainActor
    static func paneView(for surface: ghostty_surface_t) -> SurfacePaneView? {
        guard let ud = ghostty_surface_userdata(surface) else { return nil }
        return Unmanaged<SurfacePaneView>.fromOpaque(ud).takeUnretainedValue()
    }
}
