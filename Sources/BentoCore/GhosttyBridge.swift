import Foundation
import GhosttyVt

public final class GhosttySessionHandle: @unchecked Sendable {
    public let paneID: PaneID
    fileprivate var terminal: GhosttyTerminal?
    /// Lazily-created render state, owned by this handle. Created on first
    /// `snapshotFrame` call, freed on `close`/`deinit`.
    fileprivate var renderState: GhosttyRenderState?

    fileprivate init(paneID: PaneID, terminal: GhosttyTerminal) {
        self.paneID = paneID
        self.terminal = terminal
    }

    deinit {
        if let renderState {
            ghostty_render_state_free(renderState)
        }
        if let terminal {
            ghostty_terminal_free(terminal)
        }
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

    public func close(_ handle: GhosttySessionHandle) throws {
        if let renderState = handle.renderState {
            ghostty_render_state_free(renderState)
            handle.renderState = nil
        }
        if let terminal = handle.terminal {
            ghostty_terminal_free(terminal)
            handle.terminal = nil
        }
    }

    // MARK: - Render-state snapshot

    /// Build a fully-resolved `GhosttyRenderFrame` for the current viewport
    /// using the libghostty-vt **Render State API** (`render.h`). This is
    /// the production-grade path the renderer should use every redraw —
    /// unlike `readGridText`, which uses `ghostty_terminal_grid_ref` and is
    /// documented as not built for render-loop framerates.
    ///
    /// The render state is owned by `handle` and lives as long as the
    /// session. It is created lazily on first call.
    ///
    /// After taking the snapshot we clear the render state's "dirty" flag
    /// so libghostty's internal accounting stays consistent for the next
    /// `update` (we currently re-snapshot the whole frame on every call;
    /// dirty-region rendering is a future optimization for the renderer).
    public func snapshotFrame(_ handle: GhosttySessionHandle) throws -> GhosttyRenderFrame {
        guard let terminal = handle.terminal else {
            throw GhosttyBridgeError.closedSession
        }

        // Lazy-create the render state.
        let state: GhosttyRenderState
        if let existing = handle.renderState {
            state = existing
        } else {
            var created: GhosttyRenderState?
            let result = ghostty_render_state_new(nil, &created)
            guard result == GHOSTTY_SUCCESS, let created else {
                throw GhosttyBridgeError.snapshotFailed("render_state_new=\(result.rawValue)")
            }
            handle.renderState = created
            state = created
        }

        // Sync from terminal.
        let updateResult = ghostty_render_state_update(state, terminal)
        guard updateResult == GHOSTTY_SUCCESS else {
            throw GhosttyBridgeError.snapshotFailed("render_state_update=\(updateResult.rawValue)")
        }

        // Viewport dimensions.
        var cols: UInt16 = 0
        var rows: UInt16 = 0
        guard ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLS, &cols) == GHOSTTY_SUCCESS,
              ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows) == GHOSTTY_SUCCESS else {
            throw GhosttyBridgeError.snapshotFailed("render_state_get(cols/rows)")
        }

        // Default colors. The struct uses the sized-struct ABI: we MUST
        // initialize `size` ourselves since `GHOSTTY_INIT_SIZED` is a C macro
        // that doesn't bridge to Swift.
        var colors = GhosttyRenderStateColors()
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        var defaultFG = GhosttyRGB(r: 220, g: 220, b: 220)
        var defaultBG = GhosttyRGB(r: 18, g: 18, b: 18)
        if ghostty_render_state_colors_get(state, &colors) == GHOSTTY_SUCCESS {
            defaultFG = GhosttyRGB(r: colors.foreground.r, g: colors.foreground.g, b: colors.foreground.b)
            defaultBG = GhosttyRGB(r: colors.background.r, g: colors.background.g, b: colors.background.b)
        }

        // Cursor state.
        let cursor = readCursorState(state: state)

        // Cells.
        let cellGrid = try readCells(state: state, cols: Int(cols), rows: Int(rows))

        // Clear dirty so libghostty's tracking doesn't accumulate forever.
        var dirtyOff = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        _ = ghostty_render_state_set(state, GHOSTTY_RENDER_STATE_OPTION_DIRTY, &dirtyOff)

        return GhosttyRenderFrame(
            cols: cols,
            rows: rows,
            defaultForeground: defaultFG,
            defaultBackground: defaultBG,
            cursor: cursor,
            cells: cellGrid
        )
    }

    private func readCursorState(state: GhosttyRenderState) -> GhosttyCursorState {
        var visibleMode: Bool = false
        var blinking: Bool = false
        var styleRaw: GhosttyRenderStateCursorVisualStyle = GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK
        var hasViewport: Bool = false
        var x: UInt16 = 0
        var y: UInt16 = 0
        var wideTail: Bool = false

        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &visibleMode)
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING, &blinking)
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &styleRaw)
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &hasViewport)
        if hasViewport {
            _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &x)
            _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &y)
            _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_WIDE_TAIL, &wideTail)
        }

        return GhosttyCursorState(
            visible: visibleMode && hasViewport,
            blinking: blinking,
            style: GhosttyCursorVisualStyle.from(Int32(styleRaw.rawValue)),
            x: x,
            y: y,
            isOnWideTail: wideTail
        )
    }

    private func readCells(
        state: GhosttyRenderState,
        cols: Int,
        rows: Int
    ) throws -> [[GhosttyResolvedCell]] {
        let blankRow = Array(repeating: GhosttyResolvedCell.blank, count: cols)
        var grid = Array(repeating: blankRow, count: rows)

        guard cols > 0, rows > 0 else { return grid }

        // Allocate the row iterator + a reusable cells container.
        var rowIterOpt: GhosttyRenderStateRowIterator?
        guard ghostty_render_state_row_iterator_new(nil, &rowIterOpt) == GHOSTTY_SUCCESS,
              let rowIter = rowIterOpt else {
            throw GhosttyBridgeError.snapshotFailed("row_iterator_new")
        }
        defer { ghostty_render_state_row_iterator_free(rowIter) }

        // Populate the iterator from the render state. The C call writes the
        // handle pointer back into our local; pass an inout copy so we can
        // satisfy Swift's mutability check on the immutable `rowIter`.
        var rowIterMutable: GhosttyRenderStateRowIterator? = rowIter
        guard ghostty_render_state_get(
            state,
            GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
            &rowIterMutable
        ) == GHOSTTY_SUCCESS else {
            throw GhosttyBridgeError.snapshotFailed("row_iterator populate")
        }

        var cellsHandleOpt: GhosttyRenderStateRowCells?
        guard ghostty_render_state_row_cells_new(nil, &cellsHandleOpt) == GHOSTTY_SUCCESS,
              let cellsHandle = cellsHandleOpt else {
            throw GhosttyBridgeError.snapshotFailed("row_cells_new")
        }
        defer { ghostty_render_state_row_cells_free(cellsHandle) }

        var rowIndex = 0
        while rowIndex < rows && ghostty_render_state_row_iterator_next(rowIter) {
            // Populate cells container for the current row.
            var localCells: GhosttyRenderStateRowCells? = cellsHandle
            let cellsResult = ghostty_render_state_row_get(
                rowIter,
                GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
                &localCells
            )
            if cellsResult != GHOSTTY_SUCCESS {
                rowIndex += 1
                continue
            }

            var rowCells = blankRow
            var col = 0
            while col < cols && ghostty_render_state_row_cells_next(cellsHandle) {
                rowCells[col] = readOneCell(cells: cellsHandle)
                col += 1
            }
            grid[rowIndex] = rowCells
            rowIndex += 1
        }

        return grid
    }

    private func readOneCell(cells: GhosttyRenderStateRowCells) -> GhosttyResolvedCell {
        // Raw cell value (a uint64_t typedef — value, not pointer).
        var rawCell: GhosttyCell = 0
        _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &rawCell)

        var hasText: Bool = false
        _ = ghostty_cell_get(rawCell, GHOSTTY_CELL_DATA_HAS_TEXT, &hasText)

        var wide: GhosttyCellWide = GHOSTTY_CELL_WIDE_NARROW
        _ = ghostty_cell_get(rawCell, GHOSTTY_CELL_DATA_WIDE, &wide)
        let isWideTail = (wide == GHOSTTY_CELL_WIDE_SPACER_TAIL)

        // Build the grapheme-cluster text for this cell.
        var text: String
        if isWideTail || !hasText {
            text = isWideTail ? "" : " "
        } else {
            var graphemeLen: UInt32 = 0
            _ = ghostty_render_state_row_cells_get(
                cells,
                GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN,
                &graphemeLen
            )
            if graphemeLen <= 1 {
                var codepoint: UInt32 = 0
                _ = ghostty_cell_get(rawCell, GHOSTTY_CELL_DATA_CODEPOINT, &codepoint)
                if codepoint == 0 {
                    text = " "
                } else if let scalar = Unicode.Scalar(codepoint) {
                    text = String(scalar)
                } else {
                    text = " "
                }
            } else {
                var buffer = [UInt32](repeating: 0, count: Int(graphemeLen))
                let rc: GhosttyResult = buffer.withUnsafeMutableBufferPointer { buf -> GhosttyResult in
                    var ptr: UnsafeMutablePointer<UInt32>? = buf.baseAddress
                    return ghostty_render_state_row_cells_get(
                        cells,
                        GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF,
                        &ptr
                    )
                }
                if rc == GHOSTTY_SUCCESS {
                    var scalars = String.UnicodeScalarView()
                    for cp in buffer {
                        if let s = Unicode.Scalar(cp) { scalars.append(s) }
                    }
                    text = String(scalars)
                    if text.isEmpty { text = " " }
                } else {
                    text = " "
                }
            }
        }

        // Style (bold, italic, underline, etc.).
        var style = GhosttyStyle()
        style.size = MemoryLayout<GhosttyStyle>.size
        _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)

        // Resolved foreground / background — INVALID_VALUE means "use default".
        var fgRgb = GhosttyColorRgb(r: 0, g: 0, b: 0)
        var bgRgb = GhosttyColorRgb(r: 0, g: 0, b: 0)
        let fgResult = ghostty_render_state_row_cells_get(
            cells,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR,
            &fgRgb
        )
        let bgResult = ghostty_render_state_row_cells_get(
            cells,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR,
            &bgRgb
        )

        let foreground: GhosttyRGB? = (fgResult == GHOSTTY_SUCCESS)
            ? GhosttyRGB(r: fgRgb.r, g: fgRgb.g, b: fgRgb.b)
            : nil
        let background: GhosttyRGB? = (bgResult == GHOSTTY_SUCCESS)
            ? GhosttyRGB(r: bgRgb.r, g: bgRgb.g, b: bgRgb.b)
            : nil

        // Underline style: maps `style.underline` (a GhosttySgrUnderline
        // enum int) to our Swift enum.
        let underlineStyle = GhosttyUnderlineStyle.from(raw: Int(style.underline))

        // Underline color: only honor RGB direct values. PALETTE would
        // require a 256-entry palette lookup that the cell-level color
        // path doesn't give us here, and NONE means "fall back to
        // foreground" — so both map to nil.
        let underlineColor: GhosttyRGB?
        if style.underline_color.tag == GHOSTTY_STYLE_COLOR_RGB {
            let rgb = style.underline_color.value.rgb
            underlineColor = GhosttyRGB(r: rgb.r, g: rgb.g, b: rgb.b)
        } else {
            underlineColor = nil
        }

        // Hyperlink URI: not exposed by the render-state row-cells API
        // (see render.h — only RAW, STYLE, GRAPHEMES_*, FG_COLOR, and
        // BG_COLOR are queryable). The only access path is
        // `ghostty_grid_ref_hyperlink_uri` on the slower grid_ref API,
        // which we deliberately moved off of. Left at nil so the data
        // model has a slot ready for the future interactive feature.
        let hyperlinkURI: String? = nil

        return GhosttyResolvedCell(
            text: text,
            foreground: foreground,
            background: background,
            bold: style.bold,
            italic: style.italic,
            underline: underlineStyle != .none,
            strikethrough: style.strikethrough,
            inverse: style.inverse,
            isWideTail: isWideTail,
            faint: style.faint,
            blink: style.blink,
            invisible: style.invisible,
            overline: style.overline,
            underlineStyle: underlineStyle,
            underlineColor: underlineColor,
            hyperlinkURI: hyperlinkURI
        )
    }
}

public enum GhosttyBridgeError: Error, Equatable {
    case createFailed(Int32)
    case resizeFailed(Int32)
    case closedSession
    case invalidSize(columns: Int, rows: Int)
    case emptyInput
    case gridReadFailed
    case snapshotFailed(String)
}
