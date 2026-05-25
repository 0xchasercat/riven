# Phase 1 — libghostty surface migration (EXECUTION DOC)

**This doc is the source of truth for post-compaction execution. Read it fully, then execute top-to-bottom until complete. Commit per logical step on branch `spike/libghostty-surface`. Do NOT push to `main`. Build gate after each step.**

---

## Mission

Replace Riven's hand-rolled terminal engine with the **full libghostty embedding** (GhosttyKit: Ghostty's Metal renderer + input + PTY + control-sequence callbacks). Keep ~70% of Riven (workspace/tabs/snapshots, sidebar, search, editor, themes, shell-integration, command bar). Delete the buggy engine layer.

**Decision rationale (settled with the user):** the own-renderer path kept generating render+input bugs we can't match Ghostty's thousands of commits on. The user wants Ghostty as the backend (prestige + quality). Stability of the "internal" C API is a non-issue (it's the code Ghostty ships; pin + rebase). The ONE accepted tradeoff: **no out-of-process broker** — PTYs run in-process and die with the UI (session *restore* via snapshots is unaffected; only "live procs survive a UI crash" is lost; the user is fine with this and was annoyed by session-restore anyway).

## Phase 0 results — ALL PROVEN ✅ (don't redo)

- GhosttyKit.xcframework **builds** via `zig build -Demit-xcframework -Dxcframework-target=native` (trailing app-bundle step fails, harmless; artifact lands at `External/ghostty/macos/GhosttyKit.xcframework`). Reproducible: `RIVEN_BUILD_GHOSTTY_KIT=1 scripts/setup-ghostty.sh`. Vendored at `External/ghostty-kit-install/lib/GhosttyKit.xcframework` (gitignored, 134MB).
- **Links** into SwiftPM with: `libc++` + frameworks Metal, MetalKit, QuartzCore, CoreText, CoreGraphics, CoreVideo, AppKit, Carbon, IOSurface, UniformTypeIdentifiers.
- **Runs**: the spike (`Sources/GhosttySpike/`) opens a window with a live Ghostty Metal surface, spawns the shell, renders, takes keyboard/mouse, command-bar injection (`ghostty_surface_text`) works, copy/paste (NSPasteboard) works. User confirmed "worked."
- Module name is `GhosttyKit`. Header: `External/ghostty-kit-install/lib/GhosttyKit.xcframework/macos-arm64/Headers/ghostty.h`.

## Spike code to PROMOTE into the Riven target (already written, working)

These live in `Sources/GhosttySpike/` and are the reference implementation. Promote/adapt into the `Riven` target:

- `GhosttyApp.swift` — process-wide app singleton. `ghostty_init` + `ghostty_config` + `ghostty_app_new` with runtime callbacks:
  - `wakeup_cb` → `DispatchQueue.main.async { tick() }` (calls `ghostty_app_tick`)
  - `action_cb` → `GHOSTTY_ACTION_RENDER` drives `surface_draw` on target surface (recovered via `ghostty_surface_userdata`); `SET_TITLE` → post a title notification; `RING_BELL` → NSSound.beep(); add `PWD`, `DESKTOP_NOTIFICATION`, `PROGRESS_REPORT`, `OPEN_URL` (hyperlink) handlers during integration.
  - clipboard cbs → NSPasteboard (read completes via `ghostty_surface_complete_clipboard_request`; state token passed as `UInt` bit-pattern across the main-actor hop).
  - `@unchecked Sendable`, `nonisolated(unsafe) static let shared`. Callbacks are top-level `@convention(c)` funcs.
- `SurfacePaneView.swift` — `NSView` (layer-backed) hosting one surface. `cfg.platform_tag = GHOSTTY_PLATFORM_MACOS`, `cfg.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()`, `cfg.userdata = self`, `cfg.scale_factor`, `cfg.working_directory`. libghostty attaches its own CAMetalLayer. Forwards: `keyDown/keyUp` → `ghostty_surface_key` (keycode + mods via `ghosttyMods` + text=characters); mouse button/pos/scroll; `setFrameSize`/`viewDidChangeBackingProperties` → `ghostty_surface_set_size`/`set_content_scale`; focus → `ghostty_surface_set_focus`. `requestDraw()` → `ghostty_surface_draw`. `injectText(_:)` → `ghostty_surface_text` (command-bar path). `surface` is `nonisolated(unsafe)` so `deinit` can free it.

## Current architecture (what exists, to swap/delete)

- `Sources/Riven/BrokeredTerminalView.swift` — the CURRENT terminal NSView: libghostty-vt parsing + own CoreText render + hand-rolled input (OSC-133 focus routing, CR/LF, Ctrl-keys, alt-screen detection, bell/title via vt callbacks, selection). **REPLACE with SurfacePaneView.** This is the bulk of the deletion.
- `Sources/Riven/TerminalPaneView.swift` — SwiftUI `NSViewRepresentable` wrapping `BrokeredTerminalView`, built in `PaneGridView`/`WorkspaceGroupView`. **Rewrite to wrap `SurfacePaneView`.**
- `Sources/RivenCore/GhosttyBridge.swift` — libghostty-vt wrapper (createSession, snapshotFrame, isInAltScreen, readTitle, setBellHandler, etc.). **DELETE** (superseded by GhosttyApp/SurfacePaneView).
- `Sources/Riven/GhosttyRenderer.swift` — the CoreText cell renderer. **DELETE.**
- `Sources/RivenCore/GhosttyRenderTypes.swift` and render-frame types. **DELETE** (or trim to anything still referenced).
- `RivenAgent` target + `Sources/RivenCore/AgentClient.swift` + `PseudoTerminalSession.swift` + the IPC layer — the out-of-process broker. **DELETE** (PTY now in-process via libghostty). Remove the `RivenAgent` executable target + `AgentLauncher.swift`. This is a large deletion; do it carefully — many call sites reference `agentClient`/`writeInput`.
- `Package.swift` — `Riven` target currently depends on nothing ghostty (RivenCore has `GhosttyVt`). **Change:** `Riven` target links `GhosttyKit` + the frameworks/libc++ (copy from the `GhosttySpike` target linkerSettings). RivenCore drops `GhosttyVt`. Remove `GhosttyVt` binaryTarget + `RivenAgent` product/target + the `GhosttySpike` throwaway product (fold its code into Riven).

## What CARRIES OVER unchanged (do not touch)

Workspace/tab/split model + `WorkspaceGroup` + snapshots (`WorkspaceSnapshotStore`), sidebar (`WorkspaceSidebarView` + `SidebarTreeModel`, shallow-lazy + FS-watch), search (ripgrep + scrollback), editor panes (STTextView), themes (`ThemeSpec` — UI chrome stays; terminal colors now map to ghostty_config), command palette, menus, the app shell (`RivenApp`/`RivenRootController`/`RootView`), shell integration installer + the `~/.config/riven/shell` zsh files (still useful — OSC 7/133 still consumed by ghostty natively).

## Execution steps (ordered)

**STEP 1 — Promote the binding into Riven.**
- Move `Sources/GhosttySpike/{GhosttyApp,SurfacePaneView}.swift` → `Sources/Riven/`. Keep `GhosttyApp` as the process-wide singleton (init it from `RivenApplication.applicationDidFinishLaunching` BEFORE building panes).
- `Package.swift`: add `GhosttyKit` dependency + the linkerSettings (libc++ + the 10 frameworks) to the `Riven` executableTarget. Keep `GhosttySpike` building for now (delete at the end).
- Build gate: `swift build`.

**STEP 2 — Rewrite TerminalPaneView to host SurfacePaneView.**
- `TerminalPaneView` (NSViewRepresentable) makes/returns a `SurfacePaneView` instead of `BrokeredTerminalView`. Pass cwd + command (from the tab) into the surface config. Drop the `agentClient` param (no broker).
- Theme → ghostty_config: see "Theming" below. For the first build, default config is fine; theming is STEP 5.
- Build gate.

**STEP 3 — Command bar → injectText.**
- In `WorkspaceGroupView` the command bar `onSubmit` currently does `agentClient.writeInput(paneID, text + "\r")`. Change it to call the focused `SurfacePaneView.injectText(text + "\r")`. Need a way to reach the focused surface view — likely via a registry keyed by paneID on `GhosttyApp` or the controller, OR have the command bar post a notification the focused SurfacePaneView observes. Mirror how focus is tracked today.
- Keep the command bar's history + ghost-text autosuggestions (pure SwiftUI, unchanged).
- Build gate.

**STEP 4 — Rip out the broker + old engine.**
- Delete `BrokeredTerminalView.swift`, `GhosttyRenderer.swift`, `GhosttyBridge.swift`, `GhosttyRenderTypes.swift`, the `RivenAgent` target + `AgentClient.swift` + `PseudoTerminalSession.swift` + `AgentLauncher.swift` + IPC types. Remove `GhosttyVt` binaryTarget + `RivenAgent` product from `Package.swift`.
- Fix every resulting compile error: remove `agentClient`/`brokerEpoch` threading through `PaneGridView`/`WorkspaceGroupView`/`RivenRootController`/`RootView`. The `sendByteToFocusedTerminal` / global Ctrl monitor / OSC-133 focus routing / alt-screen tracking in the controller + RivenApp can mostly be DELETED (ghostty surface owns input + focus now). The double-click-raw-input, CR/LF, Ctrl-key forwarding code is gone (ghostty handles it).
- This is the big mechanical step. Build gate aggressively.

**STEP 5 — Theming: Riven ThemeSpec → ghostty_config.**
- libghostty config is set via `ghostty_config_*`. NO direct "set key" in the C API beyond `load_cli_args`/`load_file`. APPROACH: build a config string (ghostty config syntax: `foreground = RRGGBB`, `background = ...`, `cursor-color = ...`, `selection-background = ...`, `palette = 0=RRGGBB` ×16, `font-family = ...`, `font-size = N`), write to a temp file, `ghostty_config_load_file`, `finalize`, then `ghostty_app_update_config` / `ghostty_surface_update_config`. VERIFY exact key names + the load mechanism against `External/ghostty/include/ghostty.h` + Ghostty's config docs during execution. Map from `ThemeSpec.terminal` (foreground/background/cursor) + the ANSI palette. Re-apply on theme switch via `ghostty_surface_update_config`.
- Build + visually verify a themed pane.

**STEP 6 — Action callbacks → Riven features.**
- In `GhosttyApp.action_cb`, wire: `SET_TITLE` → inner-tab label (the `.rivenTerminalTitleChanged` path already exists from the bell/title work — reuse it, keyed by paneID; recover paneID from the surface's pane view). `RING_BELL` → the bell-dot + beep (reuse `.rivenBell`). `DESKTOP_NOTIFICATION` → UNUserNotificationCenter. `OPEN_URL` (OSC 8 hyperlink) → NSWorkspace.open. `PWD` → sidebar-follows-cd (the cwd path; map to `updateWorkspaceCwd`). `PROGRESS_REPORT` → optional chrome.
- Build gate.

**STEP 7 — Cleanup + validate.**
- Delete the `GhosttySpike` product/target + `Sources/GhosttySpike/`.
- Update `setup-ghostty.sh` so GhosttyKit is built by default (not gated) since it's now required; keep vt build only if anything still needs it (it won't — drop it).
- Update `scripts/release/build-release.sh`: the .app must bundle Ghostty's resources (terminfo + shell-integration) that libghostty needs at runtime — CHECK whether the surface needs `GHOSTTY_RESOURCES_DIR` set or resources bundled (Ghostty installs a resources tree; the spike worked without it for basic shell, but terminfo/shell-integration may need it). Link frameworks + libc++ in the release build too.
- Full validation: multiple tabs/splits, vim/nano/htop, claude code, ssh, copy/paste, theme switch, command bar, sidebar-follows-cd, session restore, perf (cat big file). Run the curated test suite.
- Update README + CHANGELOG ("now powered by libghostty / Ghostty's renderer").

## Risks / gotchas (resolve during execution)

1. **The tick/render loop in the real app.** The spike relied on `wakeup_cb → ghostty_app_tick`. Confirm rendering is continuous + correct in the multi-pane SwiftUI app (NSViewRepresentable lifecycle). May need to ensure `ghostty_app_tick` is driven + surfaces redraw on `RENDER` actions. Watch for surfaces not drawing when offscreen/occluded — use `ghostty_surface_set_occlusion`.
2. **Focus model.** Ghostty surface owns input. The command-bar-as-default-input model SIMPLIFIES: click pane → it has focus → type goes to PTY natively. Command bar is an overlay that injects. DELETE the OSC-133/alt-screen/CR-LF/Ctrl-key focus routing — it's all ghostty's job now. Verify Tab-to-command-bar still works as a deliberate gesture if desired.
3. **Theming injection mechanism** (STEP 5) — the exact `ghostty_config` set path needs verifying; budget time.
4. **Resources at runtime** (STEP 7) — terminfo/shell-integration; the release .app may need Ghostty's resources tree + possibly `GHOSTTY_RESOURCES_DIR`. The spike ran from the build dir; a bundled .app may differ.
5. **Per-surface userdata** must be set so action_cb can recover the pane view + its paneID (for title/bell/cwd routing). Add a `paneID` to SurfacePaneView + a registry or use userdata.
6. **Sendable/strict-concurrency** friction with the C callbacks (saw it with the clipboard state token — pass pointers as UInt bit-patterns across actor hops).

## Validation plan (final gate)

Run `.app`: open shell, vim, nano, htop, `claude` (the inline-TUI that started all this), ssh; multiple tabs + splits; ⌘C/⌘V; theme switch; sidebar follows `cd`; command bar submit + history + ghost-text; `cat` a large file (perf); quit + relaunch (session restore via snapshot). Curated test suite: `swift test --filter 'Theme|ProjectFileTree|CommandHistory|WorkspaceController|ShellIntegration|ScrollbackMetadata|SearchIndex|RecentSearches|Ripgrep|CustomThemeLoader|EditorBuffer|CommandPalette|PaneGraph'`.

## Commit plan

One commit per STEP (1–7), clear messages. Stay on `spike/libghostty-surface`. When validated end-to-end, that branch becomes the new main line (merge or fast-forward — user's call). `main` currently has the working vt build as the fallback.

## Key API quick-reference (from ghostty.h, verified)

- App: `ghostty_init(argc, argv)`, `ghostty_config_new/load_default_files/finalize`, `ghostty_app_new(&runtime_cfg, config)`, `ghostty_app_tick`, `ghostty_app_set_focus`, `ghostty_app_update_config`.
- runtime_config_s fields: userdata, supports_selection_clipboard, wakeup_cb, action_cb, read_clipboard_cb, confirm_read_clipboard_cb, write_clipboard_cb, close_surface_cb.
- Surface: `ghostty_surface_config_new()`, `ghostty_surface_new(app, &cfg)`, `_free`, `_set_size(w,h)`, `_set_content_scale(x,y)`, `_set_focus(bool)`, `_set_occlusion(bool)`, `_draw`, `_key(ghostty_input_key_s)`, `_text(ptr,len)`, `_mouse_button(state,button,mods)`, `_mouse_pos(x,y,mods)`, `_mouse_scroll(dx,dy,mods)`, `_userdata`, `_complete_clipboard_request(surface, cstr, state, confirmed)`, `_has_selection`, `_read_selection`, `_update_config`.
- surface_config_s: platform_tag, platform.macos.nsview, userdata, scale_factor, font_size, working_directory, command, env_vars, env_var_count, initial_input, wait_after_command.
- ghostty_input_key_s: action (GHOSTTY_ACTION_PRESS/RELEASE/REPEAT), mods (GHOSTTY_MODS_SHIFT/CTRL/ALT/SUPER/CAPS bitfield), consumed_mods, keycode (uint32 = AppKit event.keyCode), text (cstr), unshifted_codepoint, composing.
- action tags: GHOSTTY_ACTION_RENDER, SET_TITLE (action.set_title.title cstr), RING_BELL, PWD, DESKTOP_NOTIFICATION, OPEN_URL, PROGRESS_REPORT, etc.
- target: ghostty_target_s { tag (GHOSTTY_TARGET_APP/SURFACE), target.surface }.
