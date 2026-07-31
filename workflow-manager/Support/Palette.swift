//
//  Palette.swift
//  workflow-manager
//
//  UI-side mappings for the model enums, kept out of the model files.
//

import SwiftUI

extension ProjectAccent {
    var color: Color {
        switch self {
        case .blue:   .blue
        case .purple: .purple
        case .pink:   .pink
        case .red:    .red
        case .orange: .orange
        case .yellow: .yellow
        case .green:  .green
        case .teal:   .teal
        case .gray:   .gray
        }
    }
}

extension Priority {
    var color: Color {
        switch self {
        case .low:    .secondary
        case .normal: .blue
        case .high:   .orange
        case .urgent: .red
        }
    }
}

extension ProjectStatus {
    var color: Color {
        switch self {
        case .planning:  .indigo
        case .active:    .green
        case .onHold:    .orange
        case .completed: .blue
        case .archived:  .secondary
        }
    }
}

/// SF Symbols offered when picking a project icon.
enum ProjectSymbols {
    static let all: [String] = [
        "square.stack.3d.up",
        "hammer",
        "paintbrush",
        "chart.line.uptrend.xyaxis",
        "globe",
        "iphone",
        "desktopcomputer",
        "server.rack",
        "books.vertical",
        "lightbulb",
        "flask",
        "cart",
        "megaphone",
        "person.2",
        "map",
        "leaf",
    ]
}
