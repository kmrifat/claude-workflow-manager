//
//  TerminalEmulator.swift
//  workflow-manager
//
//  A screen, not a log.
//
//  The first version of this appended lines to a buffer and coloured them. That
//  works for `npm run dev` and for nothing else: a real shell addresses the
//  cursor. `oh-my-zsh` draws its prompt by moving right, writing, moving back;
//  readline redraws the line you are editing in place; `git log` clears the
//  screen. None of that is expressible as "append a line".
//
//  So this keeps what a terminal actually is — a grid of cells and a cursor —
//  and rows leaving the top are pushed into scrollback. That is the difference
//  between "output rendered in a window" and a terminal.
//
//  Implemented: SGR, cursor positioning and movement, erase in line/display,
//  insert/delete lines and characters, scroll regions (DECSTBM), the alternate
//  screen buffer, save/restore cursor, autowrap, tab stops, and reverse index.
//  That is the subset `zsh`, `vim`, `htop` and `git` actually use.
//
//  Pure Foundation, no SwiftUI, so all of it can be tested without a window.
//

import Foundation

nonisolated struct TerminalEmulator {

    // MARK: - Cells

    struct Style: Equatable, Sendable {
        var foreground: Int?
        var background: Int?
        var foregroundRGB: RGB?
        var backgroundRGB: RGB?
        var bold = false
        var faint = false
        var italic = false
        var underline = false
        var inverse = false

        struct RGB: Equatable, Sendable, Hashable {
            var red: Int, green: Int, blue: Int
        }

        static let plain = Style()
    }

    struct Cell: Equatable, Sendable {
        var character: Character = " "
        var style: Style = .plain

        static let blank = Cell()
    }

    struct Row: Identifiable, Equatable, Sendable {
        let id: Int
        var cells: [Cell]

        /// Trailing blanks are not worth rendering.
        var trimmed: [Cell] {
            var end = cells.count
            while end > 0, cells[end - 1] == .blank { end -= 1 }
            return Array(cells[0..<end])
        }

        var plainText: String {
            String(trimmed.map(\.character))
        }
    }

    // MARK: - Geometry

    private(set) var columns: Int
    private(set) var rows: Int

    /// The visible grid, top row first.
    private(set) var screen: [[Cell]]
    /// Lines that have scrolled off the top.
    private(set) var scrollback: [[Cell]] = []

    private(set) var cursorRow = 0
    private(set) var cursorColumn = 0
    private(set) var isCursorVisible = true

    let scrollbackLimit: Int

    private var style = Style.plain
    private var savedCursor: (row: Int, column: Int)?
    /// DECSTBM margins, inclusive, in screen coordinates.
    private var scrollTop = 0
    private var scrollBottom: Int
    private var autowrap = true
    /// Set when the cursor is parked past the last column, waiting to see
    /// whether the next character should wrap. Without this a line exactly as
    /// wide as the screen wraps one character early.
    private var wrapPending = false
    private var alternateScreen: [[Cell]]?
    private var alternateSaved: (row: Int, column: Int)?
    private var tabStops: Set<Int>

    /// Rows are identified by their absolute index since the session began, so
    /// SwiftUI can tell a scrolled row from a rewritten one.
    private var rowSerial = 0
    private var rowIDs: [Int]

    /// Bytes held back because a UTF-8 character or an escape was split across
    /// reads. A 4KB read lands wherever it lands.
    private var pending: [UInt8] = []

    // MARK: - Init

    init(columns: Int = 80, rows: Int = 24, scrollbackLimit: Int = 5_000) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.scrollbackLimit = scrollbackLimit
        self.screen = Array(
            repeating: Array(repeating: Cell.blank, count: self.columns),
            count: self.rows
        )
        self.scrollBottom = self.rows - 1
        self.tabStops = Set(stride(from: 0, to: self.columns, by: 8))
        self.rowIDs = Array(0..<self.rows)
        self.rowSerial = self.rows
    }

    // MARK: - Output for rendering

    /// Scrollback followed by the visible screen.
    var displayRows: [Row] {
        var result: [Row] = []
        result.reserveCapacity(scrollback.count + rows)
        let base = rowSerial - screen.count - scrollback.count
        for (offset, line) in scrollback.enumerated() {
            result.append(Row(id: base + offset, cells: line))
        }
        for index in 0..<rows {
            result.append(Row(id: rowIDs[index], cells: screen[index]))
        }
        return result
    }

    /// Where the cursor sits within `displayRows`.
    var cursorDisplayRow: Int { scrollback.count + cursorRow }

    var visibleText: String {
        screen.map { row in
            String(row.map(\.character))
                .replacingOccurrences(of: " +$", with: "", options: .regularExpression)
        }.joined(separator: "\n")
    }

    var allText: String {
        (scrollback + screen).map { line in
            String(line.map(\.character))
                .replacingOccurrences(of: " +$", with: "", options: .regularExpression)
        }.joined(separator: "\n")
    }

    // MARK: - Resizing

    /// Reflow is deliberately not attempted: re-wrapping scrollback against a
    /// new width is where terminal emulators keep their worst bugs, and the
    /// shell redraws its own prompt on SIGWINCH anyway.
    mutating func resize(columns newColumns: Int, rows newRows: Int) {
        let width = max(1, newColumns)
        let height = max(1, newRows)
        guard width != columns || height != rows else { return }

        var resized: [[Cell]] = []
        resized.reserveCapacity(height)

        // Keep the *bottom* of the screen when shrinking — that is where the
        // prompt and the newest output are.
        let keep = min(height, rows)
        let firstKept = rows - keep
        for index in 0..<height {
            if index < height - keep {
                resized.append(Array(repeating: Cell.blank, count: width))
            } else {
                var line = screen[firstKept + (index - (height - keep))]
                if line.count > width {
                    line = Array(line[0..<width])
                } else if line.count < width {
                    line += Array(repeating: Cell.blank, count: width - line.count)
                }
                resized.append(line)
            }
        }

        var ids = Array(repeating: 0, count: height)
        for index in 0..<height {
            if index < height - keep {
                ids[index] = rowSerial
                rowSerial += 1
            } else {
                ids[index] = rowIDs[firstKept + (index - (height - keep))]
            }
        }

        screen = resized
        rowIDs = ids
        columns = width
        rows = height
        scrollTop = 0
        scrollBottom = height - 1
        cursorRow = min(cursorRow, height - 1)
        cursorColumn = min(cursorColumn, width - 1)
        tabStops = Set(stride(from: 0, to: width, by: 8))
        wrapPending = false
    }

    // MARK: - Feeding bytes

    mutating func feed(_ data: Data) {
        var bytes = pending
        bytes.append(contentsOf: data)
        pending = []

        var index = 0
        while index < bytes.count {
            let byte = bytes[index]

            switch byte {
            case 0x1B:
                guard let next = consumeEscape(bytes, from: index) else {
                    pending = Array(bytes[index...])
                    return
                }
                index = next

            case 0x0A, 0x0B, 0x0C:      // LF, VT, FF
                lineFeed()
                index += 1
            case 0x0D:
                cursorColumn = 0
                wrapPending = false
                index += 1
            case 0x08:
                if cursorColumn > 0 { cursorColumn -= 1 }
                wrapPending = false
                index += 1
            case 0x09:
                advanceToNextTabStop()
                index += 1
            case 0x07:
                index += 1              // bell
            case 0x00:
                index += 1

            default:
                var end = index
                while end < bytes.count, !isControl(bytes[end]) { end += 1 }
                let slice = Array(bytes[index..<end])

                if end == bytes.count, let hold = incompleteUTF8Suffix(slice) {
                    let keep = slice.count - hold
                    if keep > 0 { put(String(decoding: slice[0..<keep], as: UTF8.self)) }
                    pending = Array(slice[keep...])
                    return
                }
                put(String(decoding: slice, as: UTF8.self))
                index = end
            }
        }
    }

    // MARK: - Writing characters

    private mutating func put(_ text: String) {
        for character in text {
            if wrapPending, autowrap {
                cursorColumn = 0
                lineFeed()
                wrapPending = false
            }
            guard cursorRow < rows, cursorColumn < columns else { continue }

            screen[cursorRow][cursorColumn] = Cell(character: character, style: style)

            if cursorColumn == columns - 1 {
                // Park, rather than wrapping now: the line may end here.
                wrapPending = autowrap
            } else {
                cursorColumn += 1
            }
        }
    }

    private mutating func lineFeed() {
        wrapPending = false
        if cursorRow == scrollBottom {
            scrollUp(1)
        } else if cursorRow < rows - 1 {
            cursorRow += 1
        }
    }

    /// Moves the scroll region up, pushing the top line into scrollback when
    /// the region is the whole screen.
    private mutating func scrollUp(_ count: Int) {
        for _ in 0..<count {
            let leaving = screen[scrollTop]
            // Only lines leaving the real top of a full-screen region are
            // history. A pane inside a scroll region is being redrawn.
            if scrollTop == 0, scrollBottom == rows - 1, alternateScreen == nil {
                scrollback.append(leaving)
                if scrollback.count > scrollbackLimit {
                    scrollback.removeFirst(scrollback.count - scrollbackLimit)
                }
            }
            screen.remove(at: scrollTop)
            screen.insert(Array(repeating: Cell.blank, count: columns), at: scrollBottom)
            rowIDs.remove(at: scrollTop)
            rowIDs.insert(rowSerial, at: scrollBottom)
            rowSerial += 1
        }
    }

    private mutating func scrollDown(_ count: Int) {
        for _ in 0..<count {
            screen.remove(at: scrollBottom)
            screen.insert(Array(repeating: Cell.blank, count: columns), at: scrollTop)
            rowIDs.remove(at: scrollBottom)
            rowIDs.insert(rowSerial, at: scrollTop)
            rowSerial += 1
        }
    }

    private mutating func advanceToNextTabStop() {
        var next = cursorColumn + 1
        while next < columns, !tabStops.contains(next) { next += 1 }
        cursorColumn = min(next, columns - 1)
        wrapPending = false
    }

    // MARK: - Escape parsing

    private mutating func consumeEscape(_ bytes: [UInt8], from start: Int) -> Int? {
        var index = start + 1
        guard index < bytes.count else { return nil }

        switch bytes[index] {
        case UInt8(ascii: "["):
            index += 1
            var isPrivate = false
            if index < bytes.count, bytes[index] == UInt8(ascii: "?") {
                isPrivate = true
                index += 1
            }
            let parameterStart = index
            while index < bytes.count, isParameterByte(bytes[index]) { index += 1 }
            guard index < bytes.count else { return nil }
            let final = bytes[index]
            let parameters = String(decoding: bytes[parameterStart..<index], as: UTF8.self)
            applyCSI(final: final, parameters: parameters, isPrivate: isPrivate)
            return index + 1

        case UInt8(ascii: "]"):         // OSC — window title, and iTerm codes
            index += 1
            while index < bytes.count {
                if bytes[index] == 0x07 { return index + 1 }
                if bytes[index] == 0x1B, index + 1 < bytes.count,
                   bytes[index + 1] == UInt8(ascii: "\\") {
                    return index + 2
                }
                index += 1
            }
            return nil

        case UInt8(ascii: "M"):         // reverse index
            if cursorRow == scrollTop { scrollDown(1) } else if cursorRow > 0 { cursorRow -= 1 }
            return index + 1

        case UInt8(ascii: "7"):
            savedCursor = (cursorRow, cursorColumn)
            return index + 1
        case UInt8(ascii: "8"):
            if let saved = savedCursor {
                cursorRow = min(saved.row, rows - 1)
                cursorColumn = min(saved.column, columns - 1)
            }
            return index + 1

        case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "#"):
            return index + 2 <= bytes.count ? index + 2 : nil

        case UInt8(ascii: "="), UInt8(ascii: ">"):
            return index + 1            // keypad modes — no effect here

        default:
            return index + 1
        }
    }

    private mutating func applyCSI(final: UInt8, parameters: String, isPrivate: Bool) {
        let parts = parameters.split(separator: ";", omittingEmptySubsequences: false)
        let values = parts.map { Int($0) ?? 0 }
        func value(_ index: Int, _ fallback: Int = 1) -> Int {
            guard index < values.count else { return fallback }
            return values[index] == 0 ? fallback : values[index]
        }

        if isPrivate {
            applyPrivateMode(final: final, values: values)
            return
        }

        switch final {
        case UInt8(ascii: "m"):
            applySGR(values.isEmpty || parameters.isEmpty ? [0] : values)

        case UInt8(ascii: "A"):
            cursorRow = max(0, cursorRow - value(0)); wrapPending = false
        case UInt8(ascii: "B"):
            cursorRow = min(rows - 1, cursorRow + value(0)); wrapPending = false
        case UInt8(ascii: "C"):
            cursorColumn = min(columns - 1, cursorColumn + value(0)); wrapPending = false
        case UInt8(ascii: "D"):
            cursorColumn = max(0, cursorColumn - value(0)); wrapPending = false
        case UInt8(ascii: "E"):
            cursorRow = min(rows - 1, cursorRow + value(0)); cursorColumn = 0; wrapPending = false
        case UInt8(ascii: "F"):
            cursorRow = max(0, cursorRow - value(0)); cursorColumn = 0; wrapPending = false
        case UInt8(ascii: "G"), UInt8(ascii: "`"):
            cursorColumn = min(columns - 1, max(0, value(0) - 1)); wrapPending = false
        case UInt8(ascii: "d"):
            cursorRow = min(rows - 1, max(0, value(0) - 1)); wrapPending = false

        case UInt8(ascii: "H"), UInt8(ascii: "f"):
            cursorRow = min(rows - 1, max(0, value(0) - 1))
            cursorColumn = min(columns - 1, max(0, value(1) - 1))
            wrapPending = false

        case UInt8(ascii: "J"):
            eraseInDisplay(values.first ?? 0)
        case UInt8(ascii: "K"):
            eraseInLine(values.first ?? 0)

        case UInt8(ascii: "L"):
            insertLines(value(0))
        case UInt8(ascii: "M"):
            deleteLines(value(0))
        case UInt8(ascii: "P"):
            deleteCharacters(value(0))
        case UInt8(ascii: "@"):
            insertCharacters(value(0))
        case UInt8(ascii: "X"):
            eraseCharacters(value(0))

        case UInt8(ascii: "S"):
            scrollUp(value(0))
        case UInt8(ascii: "T"):
            scrollDown(value(0))

        case UInt8(ascii: "r"):
            let top = max(0, (values.count > 0 ? values[0] : 1) - 1)
            let bottomRaw = values.count > 1 && values[1] > 0 ? values[1] : rows
            let bottom = min(rows - 1, bottomRaw - 1)
            if top < bottom {
                scrollTop = top
                scrollBottom = bottom
                cursorRow = top
                cursorColumn = 0
            }

        case UInt8(ascii: "s"):
            savedCursor = (cursorRow, cursorColumn)
        case UInt8(ascii: "u"):
            if let saved = savedCursor {
                cursorRow = min(saved.row, rows - 1)
                cursorColumn = min(saved.column, columns - 1)
            }

        default:
            break
        }
    }

    private mutating func applyPrivateMode(final: UInt8, values: [Int]) {
        let enabling = final == UInt8(ascii: "h")
        guard enabling || final == UInt8(ascii: "l") else { return }

        for code in values {
            switch code {
            case 7:
                autowrap = enabling
            case 25:
                isCursorVisible = enabling
            case 1049, 47, 1047:
                enabling ? enterAlternateScreen() : leaveAlternateScreen()
            default:
                // Bracketed paste, mouse reporting, focus events: accepted and
                // ignored. Nothing here reports back to the program.
                break
            }
        }
    }

    private mutating func enterAlternateScreen() {
        guard alternateScreen == nil else { return }
        alternateScreen = screen
        alternateSaved = (cursorRow, cursorColumn)
        screen = Array(
            repeating: Array(repeating: Cell.blank, count: columns),
            count: rows
        )
        rowIDs = (0..<rows).map { _ in defer { rowSerial += 1 }; return rowSerial }
        cursorRow = 0
        cursorColumn = 0
    }

    private mutating func leaveAlternateScreen() {
        guard let saved = alternateScreen else { return }
        screen = saved
        alternateScreen = nil
        rowIDs = (0..<rows).map { _ in defer { rowSerial += 1 }; return rowSerial }
        if let cursor = alternateSaved {
            cursorRow = min(cursor.row, rows - 1)
            cursorColumn = min(cursor.column, columns - 1)
        }
        alternateSaved = nil
    }

    // MARK: - Erasing and editing

    private mutating func eraseInDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseInLine(0)
            for row in (cursorRow + 1)..<rows {
                screen[row] = Array(repeating: Cell.blank, count: columns)
            }
        case 1:
            eraseInLine(1)
            for row in 0..<cursorRow {
                screen[row] = Array(repeating: Cell.blank, count: columns)
            }
        default:
            // A full clear pushes the screen into scrollback rather than
            // discarding it, which is what `clear` in a real terminal does.
            if alternateScreen == nil {
                for line in screen where line.contains(where: { $0 != .blank }) {
                    scrollback.append(line)
                }
                if scrollback.count > scrollbackLimit {
                    scrollback.removeFirst(scrollback.count - scrollbackLimit)
                }
            }
            screen = Array(
                repeating: Array(repeating: Cell.blank, count: columns),
                count: rows
            )
            rowIDs = (0..<rows).map { _ in defer { rowSerial += 1 }; return rowSerial }
        }
        wrapPending = false
    }

    private mutating func eraseInLine(_ mode: Int) {
        guard cursorRow < rows else { return }
        switch mode {
        case 0:
            for column in cursorColumn..<columns { screen[cursorRow][column] = .blank }
        case 1:
            for column in 0...min(cursorColumn, columns - 1) { screen[cursorRow][column] = .blank }
        default:
            screen[cursorRow] = Array(repeating: Cell.blank, count: columns)
        }
        wrapPending = false
    }

    private mutating func insertLines(_ count: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        for _ in 0..<min(count, scrollBottom - cursorRow + 1) {
            screen.remove(at: scrollBottom)
            screen.insert(Array(repeating: Cell.blank, count: columns), at: cursorRow)
            rowIDs.remove(at: scrollBottom)
            rowIDs.insert(rowSerial, at: cursorRow)
            rowSerial += 1
        }
    }

    private mutating func deleteLines(_ count: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        for _ in 0..<min(count, scrollBottom - cursorRow + 1) {
            screen.remove(at: cursorRow)
            screen.insert(Array(repeating: Cell.blank, count: columns), at: scrollBottom)
            rowIDs.remove(at: cursorRow)
            rowIDs.insert(rowSerial, at: scrollBottom)
            rowSerial += 1
        }
    }

    private mutating func deleteCharacters(_ count: Int) {
        guard cursorRow < rows else { return }
        let removable = min(count, columns - cursorColumn)
        guard removable > 0 else { return }
        screen[cursorRow].removeSubrange(cursorColumn..<(cursorColumn + removable))
        screen[cursorRow].append(contentsOf: Array(repeating: Cell.blank, count: removable))
    }

    private mutating func insertCharacters(_ count: Int) {
        guard cursorRow < rows else { return }
        let insertable = min(count, columns - cursorColumn)
        guard insertable > 0 else { return }
        screen[cursorRow].insert(
            contentsOf: Array(repeating: Cell.blank, count: insertable),
            at: cursorColumn
        )
        screen[cursorRow].removeLast(insertable)
    }

    private mutating func eraseCharacters(_ count: Int) {
        guard cursorRow < rows else { return }
        let end = min(cursorColumn + count, columns)
        for column in cursorColumn..<end { screen[cursorRow][column] = .blank }
    }

    // MARK: - SGR

    private mutating func applySGR(_ codes: [Int]) {
        var index = 0
        while index < codes.count {
            switch codes[index] {
            case 0:  style = .plain
            case 1:  style.bold = true
            case 2:  style.faint = true
            case 3:  style.italic = true
            case 4:  style.underline = true
            case 7:  style.inverse = true
            case 22: style.bold = false; style.faint = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 27: style.inverse = false
            case 30...37:
                style.foreground = codes[index] - 30; style.foregroundRGB = nil
            case 39:
                style.foreground = nil; style.foregroundRGB = nil
            case 40...47:
                style.background = codes[index] - 40; style.backgroundRGB = nil
            case 49:
                style.background = nil; style.backgroundRGB = nil
            case 90...97:
                style.foreground = codes[index] - 90 + 8; style.foregroundRGB = nil
            case 100...107:
                style.background = codes[index] - 100 + 8; style.backgroundRGB = nil
            case 38, 48:
                let isForeground = codes[index] == 38
                guard index + 1 < codes.count else { return }
                if codes[index + 1] == 5, index + 2 < codes.count {
                    if isForeground {
                        style.foreground = codes[index + 2]; style.foregroundRGB = nil
                    } else {
                        style.background = codes[index + 2]; style.backgroundRGB = nil
                    }
                    index += 2
                } else if codes[index + 1] == 2, index + 4 < codes.count {
                    let rgb = Style.RGB(
                        red: codes[index + 2], green: codes[index + 3], blue: codes[index + 4]
                    )
                    if isForeground {
                        style.foregroundRGB = rgb; style.foreground = nil
                    } else {
                        style.backgroundRGB = rgb; style.background = nil
                    }
                    index += 4
                } else {
                    return
                }
            default:
                break
            }
            index += 1
        }
    }

    // MARK: - Byte helpers

    private func isControl(_ byte: UInt8) -> Bool {
        byte < 0x20 && byte != 0x1B ? true : byte == 0x1B
    }

    private func isParameterByte(_ byte: UInt8) -> Bool {
        (0x30...0x3F).contains(byte) || (0x20...0x2F).contains(byte)
    }

    private func incompleteUTF8Suffix(_ bytes: [UInt8]) -> Int? {
        var index = bytes.count - 1
        var continuations = 0
        while index >= 0, bytes[index] & 0b1100_0000 == 0b1000_0000 {
            continuations += 1
            index -= 1
            if continuations > 3 { return nil }
        }
        guard index >= 0 else { return nil }

        let lead = bytes[index]
        let needed: Int
        if lead & 0b1000_0000 == 0 { needed = 0 }
        else if lead & 0b1110_0000 == 0b1100_0000 { needed = 1 }
        else if lead & 0b1111_0000 == 0b1110_0000 { needed = 2 }
        else if lead & 0b1111_1000 == 0b1111_0000 { needed = 3 }
        else { return nil }

        return continuations < needed ? continuations + 1 : nil
    }
}
