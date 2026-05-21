import RivenCore
import Foundation

/// High-level UI actions the Riven window can dispatch in response to a
/// `Command` selection in the palette, a keyboard shortcut, or a menu item.
///
/// This enum is intentionally distinct from `RivenCore.CommandAction` (which
/// is just the static identifier on `Command`). The cases here carry the
/// payloads needed by the orchestrator to actually perform the action.
public enum CommandAction: Equatable, Sendable {
    /// Split the focused pane horizontally, placing the new pane to the right.
    case splitRight
    /// Split the focused pane vertically, placing the new pane below.
    case splitDown
    /// Close the currently focused pane.
    case closePane
    /// Move focus to the next pane in the grid.
    case cycleFocus
    /// Open the supplied file in the editor surface.
    case openFile(URL)
    /// Open `NSOpenPanel` to let the user pick a file, then dispatch
    /// `.openFile(url)`. The dispatcher does the panel work; we just carry
    /// the intent through the palette.
    case openFilePicker
    /// Open `NSOpenPanel` constrained to directories so the user can
    /// choose another project to open as a new workspace tab. The
    /// dispatcher runs the panel and adds the result to the pane graph.
    case openProjectPicker
    /// Rotate to the next built-in theme in `ThemeSpec.builtIns`.
    case cycleTheme
    /// Open the theme picker overlay so the user can choose a theme
    /// from a swatch grid. Dispatcher posts `.rivenShowThemePicker`.
    case pickTheme
    /// Reveal the search overlay.
    case showSearch
    /// Reveal the trust prompt for the currently open project.
    case showTrustPrompt
    /// Flip the command bar's Enter / Cmd+Enter binding. The dispatcher
    /// asks the controller to update the persisted preference; live
    /// command bars re-render with the new mode on the next refresh.
    case toggleSubmitOnEnter
    /// Z-4: install Riven's optional zsh shell integration. The
    /// dispatcher routes this to `RivenRootController.installShellIntegration`.
    case installShellIntegration
    /// Reverse of the install action. Removes the fenced source
    /// block from `~/.zshrc` and deletes `~/.config/riven/shell/`.
    case uninstallShellIntegration
}

public extension CommandAction {
    /// Maps a palette `Command` to its corresponding dispatchable action.
    ///
    /// Some palette entries (for example `.openProject`, `.flipPane`,
    /// `.zoomPane`, `.restoreSession`) do not yet have an action defined in
    /// this slice; they return `nil` and the caller should log + no-op.
    static func from(_ command: Command) -> CommandAction? {
        switch command.id {
        case .splitRight:
            return .splitRight
        case .splitDown:
            return .splitDown
        case .closePane:
            return .closePane
        case .search:
            return .showSearch
        case .openFile:
            return .openFilePicker
        case .trustProject:
            return .showTrustPrompt
        case .openProject:
            return .openProjectPicker
        case .toggleSubmitOnEnter:
            return .toggleSubmitOnEnter
        case .pickTheme:
            return .pickTheme
        case .cycleTheme:
            return .cycleTheme
        case .installShellIntegration:
            return .installShellIntegration
        case .uninstallShellIntegration:
            return .uninstallShellIntegration
        case .flipPane, .zoomPane, .restoreSession:
            return nil
        }
    }
}
