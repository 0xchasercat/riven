import Foundation
import GhosttyVt

public final class GhosttySessionHandle: @unchecked Sendable {
    public let paneID: PaneID
    fileprivate var terminal: GhosttyTerminal?

    fileprivate init(paneID: PaneID, terminal: GhosttyTerminal) {
        self.paneID = paneID
        self.terminal = terminal
    }

    deinit {
        if let terminal {
            ghostty_terminal_free(terminal)
        }
    }
}

public struct GhosttyRenderFrame: Equatable, Sendable {
    public var dirtyRectCount: Int

    public init(dirtyRectCount: Int = 0) {
        self.dirtyRectCount = dirtyRectCount
    }
}

public struct GhosttyBridge: Sendable {
    public init() {}

    public func createSession(id: PaneID, cwd: String, command: String?) throws -> GhosttySessionHandle {
        try createSession(id: id, cwd: cwd, command: command, cols: 80, rows: 24, maxScrollback: 10_000)
    }

    public func createSession(
        id: PaneID,
        cwd: String,
        command: String?,
        cols: UInt16,
        rows: UInt16,
        maxScrollback: Int = 10_000
    ) throws -> GhosttySessionHandle {
        var terminal: GhosttyTerminal?
        let options = GhosttyTerminalOptions(cols: cols, rows: rows, max_scrollback: maxScrollback)
        let result = ghostty_terminal_new(nil, &terminal, options)
        guard result == GHOSTTY_SUCCESS, let terminal else {
            throw GhosttyBridgeError.createFailed(Int32(result.rawValue))
        }
        let handle = GhosttySessionHandle(paneID: id, terminal: terminal)
        if let command, !command.isEmpty {
            try writeInput(Array(command.utf8), to: handle)
        }
        return handle
    }

    public func resize(_ handle: GhosttySessionHandle, columns: Int, rows: Int) throws {
        try resize(handle, columns: columns, rows: rows, cellWidthPx: 8, cellHeightPx: 16)
    }

    public func resize(
        _ handle: GhosttySessionHandle,
        columns: Int,
        rows: Int,
        cellWidthPx: UInt32,
        cellHeightPx: UInt32
    ) throws {
        guard columns > 0, rows > 0 else {
            throw GhosttyBridgeError.invalidSize(columns: columns, rows: rows)
        }
        guard let terminal = handle.terminal else {
            throw GhosttyBridgeError.closedSession
        }
        let result = ghostty_terminal_resize(terminal, UInt16(columns), UInt16(rows), cellWidthPx, cellHeightPx)
        guard result == GHOSTTY_SUCCESS else {
            throw GhosttyBridgeError.resizeFailed(Int32(result.rawValue))
        }
    }

    public func writeInput(_ bytes: [UInt8], to handle: GhosttySessionHandle) throws {
        guard !bytes.isEmpty else {
            throw GhosttyBridgeError.emptyInput
        }
        guard let terminal = handle.terminal else {
            throw GhosttyBridgeError.closedSession
        }
        bytes.withUnsafeBufferPointer { buffer in
            ghostty_terminal_vt_write(terminal, buffer.baseAddress, buffer.count)
        }
    }

    /// Feed raw bytes captured from a PTY (or any other VT byte source) into
    /// the terminal emulator. Unlike ``writeInput(_:to:)`` this accepts an
    /// empty buffer (no-op) and takes a `Data` for convenience at call sites.
    public func feed(_ data: Data, to handle: GhosttySessionHandle) throws {
        guard let terminal = handle.terminal else {
            throw GhosttyBridgeError.closedSession
        }
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            ghostty_terminal_vt_write(terminal, base, data.count)
        }
    }

    /// Snapshot the current viewport as plain text (one row per element).
    ///
    /// Trailing whitespace on each row is preserved as spaces so callers can
    /// match exact column positions. The grid is read via
    /// `ghostty_terminal_grid_ref` / `ghostty_grid_ref_cell`, walking each
    /// `(x, y)` in the active screen. This is only meant for tests and
    /// debugging — a real render path should use the render-state API.
    public func readGridText(_ handle: GhosttySessionHandle) throws -> [String] {
        guard let terminal = handle.terminal else {
            throw GhosttyBridgeError.closedSession
        }
        var cols: UInt16 = 0
        var rows: UInt16 = 0
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLS, &cols) == GHOSTTY_SUCCESS,
              ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ROWS, &rows) == GHOSTTY_SUCCESS else {
            throw GhosttyBridgeError.gridReadFailed
        }
        var lines: [String] = []
        lines.reserveCapacity(Int(rows))
        for y in 0..<rows {
            var rowChars: [Character] = []
            rowChars.reserveCapacity(Int(cols))
            for x in 0..<cols {
                let point = GhosttyPoint(
                    tag: GHOSTTY_POINT_TAG_ACTIVE,
                    value: GhosttyPointValue(coordinate: GhosttyPointCoordinate(x: x, y: UInt32(y)))
                )
                var ref = GhosttyGridRef(size: MemoryLayout<GhosttyGridRef>.size, node: nil, x: 0, y: 0)
                guard ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS else {
                    rowChars.append(" ")
                    continue
                }
                var cell: GhosttyCell = 0
                guard ghostty_grid_ref_cell(&ref, &cell) == GHOSTTY_SUCCESS else {
                    rowChars.append(" ")
                    continue
                }
                var hasText: Bool = false
                _ = ghostty_cell_get(cell, GHOSTTY_CELL_DATA_HAS_TEXT, &hasText)
                if !hasText {
                    rowChars.append(" ")
                    continue
                }
                var codepoint: UInt32 = 0
                _ = ghostty_cell_get(cell, GHOSTTY_CELL_DATA_CODEPOINT, &codepoint)
                if codepoint == 0 {
                    rowChars.append(" ")
                } else if let scalar = Unicode.Scalar(codepoint) {
                    rowChars.append(Character(scalar))
                } else {
                    rowChars.append("?")
                }
            }
            lines.append(String(rowChars))
        }
        return lines
    }

    /// Snapshot of cursor state useful for rendering. All values are
    /// read from the terminal via `ghostty_terminal_get`.
    public struct CursorSnapshot: Sendable {
        public var x: UInt16
        public var y: UInt16
        public var visible: Bool
    }

    public func readCursor(_ handle: GhosttySessionHandle) throws -> CursorSnapshot {
        guard let terminal = handle.terminal else {
            throw GhosttyBridgeError.closedSession
        }
        var x: UInt16 = 0
        var y: UInt16 = 0
        var visible: Bool = true
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_X, &x)
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &y)
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE, &visible)
        return CursorSnapshot(x: x, y: y, visible: visible)
    }

    public func isAlive(_ handle: GhosttySessionHandle) -> Bool {
        handle.terminal != nil
    }

    public func renderFrame(for handle: GhosttySessionHandle) throws -> GhosttyRenderFrame {
        GhosttyRenderFrame()
    }

    public func close(_ handle: GhosttySessionHandle) throws {
        if let terminal = handle.terminal {
            ghostty_terminal_free(terminal)
            handle.terminal = nil
        }
    }
}

public enum GhosttyBridgeError: Error, Equatable {
    case createFailed(Int32)
    case resizeFailed(Int32)
    case closedSession
    case invalidSize(columns: Int, rows: Int)
    case emptyInput
    case gridReadFailed
}
