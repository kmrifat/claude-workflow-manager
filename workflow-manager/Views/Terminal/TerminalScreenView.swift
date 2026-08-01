//
//  TerminalScreenView.swift
//  workflow-manager
//
//  Draws the emulator's grid and sends keystrokes back to the shell.
//
//  Two details that make it feel like a terminal rather than a text view:
//
//  * **The size is derived from the font, and drives the pty.** Columns and rows
//    are computed from the measured advance of the monospaced font, then pushed
//    to the shell, so `$COLUMNS` matches what is on screen and programs wrap
//    where the pane actually ends.
//  * **Keys go to the shell, not to SwiftUI.** Tab has to reach completion
//    rather than moving focus, and Ctrl-C has to reach the tty rather than
//    being a menu shortcut.
//

import SwiftUI

struct TerminalScreenView: View {
    let session: TerminalSession
    var fontSize: CGFloat = 12

    @FocusState private var isFocused: Bool

    /// Cell metrics for the monospaced font at this size. Measured once —
    /// asking AppKit per frame shows up in a profile immediately.
    private var metrics: (width: CGFloat, height: CGFloat) {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        // Measure a run and divide, rather than asking for one glyph's
        // advance: it is exact for a monospaced face and avoids the
        // NSGlyph/CGGlyph mismatch entirely.
        let sample = "0000000000" as NSString
        let width = sample.size(withAttributes: [.font: font]).width / 10
        return (
            width > 0 ? width : fontSize * 0.6,
            ceil(font.ascender - font.descender + font.leading) + 1
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let cell = metrics
            let columns = max(20, Int((geometry.size.width - 16) / cell.width))
            let rows = max(5, Int((geometry.size.height - 12) / cell.height))

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(session.screen.displayRows) { row in
                            line(row, cellWidth: cell.width)
                                .frame(height: cell.height, alignment: .topLeading)
                                .id(row.id)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomAnchor)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    // Top-leading, and filling: without this the grid is
                    // centred in the pane whenever it is shorter than the view.
                    .frame(
                        maxWidth: .infinity,
                        minHeight: geometry.size.height,
                        alignment: .topLeading
                    )
                }
                // Follow the newest output only while the pane is already at
                // the bottom. `contentSize` can be shorter than the container
                // when there is little output, so the comparison is clamped
                // rather than being a bare subtraction that goes negative.
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    let maxOffset = max(0, geometry.contentSize.height - geometry.containerSize.height)
                    return geometry.contentOffset.y >= maxOffset - Self.tailSlack
                } action: { _, isAtBottom in
                    session.followsTail = isAtBottom
                }
                .onChange(of: session.screen.displayRows.count) { _, _ in
                    guard session.followsTail else { return }
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
                .onAppear {
                    guard session.followsTail else { return }
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            .task(id: TerminalSize(columns: columns, rows: rows)) {
                session.resize(columns: columns, rows: rows)
            }
        }
        .background(Self.background)
        .contentShape(.rect)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onTapGesture { isFocused = true }
        .onAppear { isFocused = true }
        .onKeyPress(phases: [.down, .repeat]) { press in
            guard session.isRunning else { return .ignored }
            guard let bytes = encode(press) else { return .ignored }
            session.send(bytes)
            return .handled
        }
    }

    private struct TerminalSize: Equatable {
        let columns: Int
        let rows: Int
    }

    private static let bottomAnchor = "terminal-bottom"

    /// How close to the bottom still counts as "at the bottom". A couple of
    /// lines of tolerance, because a pane that only follows on an exact pixel
    /// match stops following the first time a partial row is showing.
    private static let tailSlack: CGFloat = 24

    /// Terminals are conventionally dark, and the cell colours below assume it.
    private static let background = Color(red: 0.11, green: 0.11, blue: 0.12)

    // MARK: - Drawing

    /// One row, as a single `Text` built from runs of equal style.
    ///
    /// A `Text` per cell would be correct and unusably slow: a 100×30 screen is
    /// 3,000 views before scrollback.
    /// One row as a single `AttributedString`.
    ///
    /// `AttributedString` rather than concatenated `Text` because a terminal
    /// needs per-run *background* colour — a selection, a highlighted search
    /// match, an inverse-video prompt — and `Text.background` returns a view,
    /// so it cannot survive concatenation.
    private func line(_ row: TerminalEmulator.Row, cellWidth: CGFloat) -> some View {
        let cells = row.trimmed
        var attributed = AttributedString()

        if cells.isEmpty {
            attributed = AttributedString(" ")
        } else {
            var runText = ""
            var runStyle = cells[0].style

            func flush() {
                guard !runText.isEmpty else { return }
                attributed.append(styled(runText, runStyle))
                runText = ""
            }

            for cell in cells {
                if cell.style != runStyle {
                    flush()
                    runStyle = cell.style
                }
                runText.append(cell.character)
            }
            flush()
        }

        return Text(attributed)
            .font(.system(size: fontSize, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func styled(_ string: String, _ style: TerminalEmulator.Style) -> AttributedString {
        var run = AttributedString(string)

        var foreground = color(index: style.foreground, rgb: style.foregroundRGB)
            ?? Self.defaultForeground
        var background = color(index: style.background, rgb: style.backgroundRGB)

        // Inverse is how a shell draws a selection or a highlighted match.
        if style.inverse {
            let swapped = background ?? Self.background
            background = foreground
            foreground = swapped
        }
        if style.faint { foreground = foreground.opacity(0.65) }

        run.foregroundColor = foreground
        if let background { run.backgroundColor = background }

        run.font = .system(
            size: fontSize,
            weight: style.bold ? .bold : .regular,
            design: .monospaced
        )
        if style.italic { run.font = run.font?.italic() }
        if style.underline { run.underlineStyle = .single }

        return run
    }

    private static let defaultForeground = Color(red: 0.85, green: 0.86, blue: 0.88)

    private func color(index: Int?, rgb: TerminalEmulator.Style.RGB?) -> Color? {
        if let rgb {
            return Color(
                red: Double(rgb.red) / 255,
                green: Double(rgb.green) / 255,
                blue: Double(rgb.blue) / 255
            )
        }
        guard let index else { return nil }
        return Self.palette(index)
    }

    /// The xterm 256-colour palette, on a dark background.
    static func palette(_ index: Int) -> Color {
        switch index {
        case 0:  return Color(red: 0.26, green: 0.27, blue: 0.30)
        case 1:  return Color(red: 0.92, green: 0.40, blue: 0.40)
        case 2:  return Color(red: 0.47, green: 0.80, blue: 0.44)
        case 3:  return Color(red: 0.90, green: 0.75, blue: 0.38)
        case 4:  return Color(red: 0.42, green: 0.64, blue: 0.93)
        case 5:  return Color(red: 0.78, green: 0.53, blue: 0.90)
        case 6:  return Color(red: 0.36, green: 0.78, blue: 0.82)
        case 7:  return Color(red: 0.78, green: 0.79, blue: 0.82)
        case 8:  return Color(red: 0.45, green: 0.47, blue: 0.51)
        case 9:  return Color(red: 1.00, green: 0.52, blue: 0.52)
        case 10: return Color(red: 0.58, green: 0.90, blue: 0.54)
        case 11: return Color(red: 0.98, green: 0.86, blue: 0.48)
        case 12: return Color(red: 0.55, green: 0.74, blue: 1.00)
        case 13: return Color(red: 0.88, green: 0.65, blue: 1.00)
        case 14: return Color(red: 0.48, green: 0.90, blue: 0.94)
        case 15: return Color(red: 0.96, green: 0.96, blue: 0.97)

        case 16...231:
            let value = index - 16
            let steps = [0, 95, 135, 175, 215, 255]
            return Color(
                red: Double(steps[(value / 36) % 6]) / 255,
                green: Double(steps[(value / 6) % 6]) / 255,
                blue: Double(steps[value % 6]) / 255
            )

        case 232...255:
            let level = Double(8 + (index - 232) * 10) / 255
            return Color(red: level, green: level, blue: level)

        default:
            return defaultForeground
        }
    }

    // MARK: - Keys

    /// Turns a key press into the bytes a terminal would send.
    private func encode(_ press: KeyPress) -> String? {
        let modifiers = press.modifiers

        switch press.key {
        case .upArrow:    return TerminalKeys.up
        case .downArrow:  return TerminalKeys.down
        case .leftArrow:  return TerminalKeys.left
        case .rightArrow: return TerminalKeys.right
        case .home:       return TerminalKeys.home
        case .end:        return TerminalKeys.end
        case .pageUp:     return TerminalKeys.pageUp
        case .pageDown:   return TerminalKeys.pageDown
        case .deleteForward: return TerminalKeys.delete
        case .delete:     return TerminalKeys.backspace
        case .tab:        return TerminalKeys.tab
        case .return:     return TerminalKeys.enter
        case .escape:     return TerminalKeys.escape
        default:          break
        }

        guard let character = press.characters.first else { return nil }

        if modifiers.contains(.control) {
            return TerminalKeys.control(character)
        }
        // Option-key: send ESC + key, the way a terminal does. Command stays
        // with the app, so ⌘C still copies.
        if modifiers.contains(.option) {
            return TerminalKeys.meta(press.characters)
        }
        if modifiers.contains(.command) { return nil }

        return press.characters.isEmpty ? nil : press.characters
    }
}
