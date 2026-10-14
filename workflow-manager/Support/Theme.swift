//
//  Theme.swift
//  workflow-manager
//
//  The few colours the system palette does not already name. Everything else —
//  backgrounds, text, separators, selection — stays semantic (`.primary`,
//  `.secondary`, `.background`, `Color.accentColor`) so light and dark both
//  come from macOS rather than from us.
//
//  The accent is Pitwall's orange-red, the icon's leader bar, and lives in the
//  `AccentColor` asset (both targets) so system controls pick it up too. Its
//  light variant is a shade deeper — #D63D0E against the icon's #FF4F1F — so
//  white text on a selected row clears 4.5:1 on a light window.
//
//  The values are the ones in design/ClaudeWM.fig, which shares DevVault's
//  palette. Each has a light and a dark variant because the dark tints are too
//  pale to read on white.
//

import SwiftUI
import AppKit

enum Theme {
    /// Claude: an agent working, queued or reporting. One colour, one meaning.
    static let agent = Color(light: 0x8944AB, dark: 0xBF5AF2)
    /// Text on an agent-tinted background, where `agent` itself is too dark.
    static let agentText = Color(light: 0x8944AB, dark: 0xD49BF5)
    /// Running commands, finished cards, passing checks.
    static let running = Color(light: 0x1F9D55, dark: 0x32D74B)
    static let warning = Color(light: 0xC77700, dark: 0xFF9F0A)
    static let danger = Color(light: 0xD70015, dark: 0xFF6961)
    /// Links and the outline icons in the sidebar.
    static let link = Color(light: 0x0A64D8, dark: 0x4D9BFF)

    /// A board card. Lifted off the lane in dark, plain white in light.
    static let card = Color(light: 0xFFFFFF, dark: 0x2C2C2E)
    /// The lane a column's cards sit in.
    static let lane = Color(light: 0x000000, dark: 0xFFFFFF).opacity(0.04)
    /// Hairline around cards.
    static let hairline = Color.primary.opacity(0.09)
    /// A Settings group box and its border — DevVault's values.
    static let groupBox = Color(light: 0xFFFFFF, dark: 0x252527)
    static let groupStroke = Color(light: 0xE3E3E6, dark: 0x3A3A3C)
    /// The well a command or code sits in.
    static let codeWell = Color(light: 0xF5F5F7, dark: 0x161618)

    /// Row metrics shared by the sidebar, per design/ClaudeWM.fig › SB.
    enum Sidebar {
        static let rowHeight: CGFloat = 28
        static let viewRowHeight: CGFloat = 26
        static let headerHeight: CGFloat = 24
        static let indent: CGFloat = 18
        static let badge: CGFloat = 18
    }
}

extension ColumnRole {
    var color: Color {
        switch self {
        case .todo:       .blue
        case .inProgress: Theme.warning
        case .review:     Theme.agent
        case .done:       Theme.running
        }
    }
}

extension BoardColumn {
    /// The dot beside a column's name. A column with no role of its own is
    /// grey — a Backlog, say — unless it is where cards count as done.
    var tint: Color {
        if let role { return role.color }
        return isCompletionColumn ? Theme.running : .gray
    }
}

extension Color {
    /// A colour that follows the window's appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
