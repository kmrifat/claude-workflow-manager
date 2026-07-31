//
//  WorkflowCommands.swift
//  workflow-manager
//
//  Menu bar commands. The actual work happens in the views: each command
//  posts through a notification the focused window observes, which keeps the
//  commands free of any dependency on view state.
//

import SwiftUI

extension Notification.Name {
    static let newProjectRequested = Notification.Name("newProjectRequested")
    static let openProjectFolderRequested = Notification.Name("openProjectFolderRequested")
    static let newItemRequested = Notification.Name("newItemRequested")
    static let boardViewModeRequested = Notification.Name("boardViewModeRequested")
    static let deleteItemRequested = Notification.Name("deleteItemRequested")
    /// Carries `["itemID": uuidString]` — start a Claude session for that card.
    static let startClaudeForItem = Notification.Name("startClaudeForItem")
    static let helpRequested = Notification.Name("helpRequested")
    static let phoneAccessRequested = Notification.Name("phoneAccessRequested")
}

struct WorkflowCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project…") {
                NotificationCenter.default.post(name: .newProjectRequested, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("New Work Item") {
                NotificationCenter.default.post(name: .newItemRequested, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Divider()

            Button("Open Project Folder…") {
                NotificationCenter.default.post(name: .openProjectFolderRequested, object: nil)
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        CommandGroup(after: .pasteboard) {
            Button("Delete Work Item") {
                NotificationCenter.default.post(name: .deleteItemRequested, object: nil)
            }
            .keyboardShortcut(.delete, modifiers: .command)
        }

        CommandMenu("View") {
            ForEach(Array(BoardViewMode.allCases.enumerated()), id: \.element.id) { index, mode in
                Button(mode.title) {
                    NotificationCenter.default.post(
                        name: .boardViewModeRequested,
                        object: nil,
                        userInfo: ["mode": mode.rawValue]
                    )
                }
                .keyboardShortcut(
                    KeyEquivalent(Character("\(index + 1)")),
                    modifiers: [.command, .option]
                )
            }
        }

        // Not in the board's view-mode group: this is about the app as a whole,
        // not about what one project is showing.
        CommandGroup(after: .appSettings) {
            Button("Phone Access…") {
                NotificationCenter.default.post(name: .phoneAccessRequested, object: nil)
            }
        }

        CommandGroup(replacing: .help) {
            Button("Claude WM Help") {
                NotificationCenter.default.post(name: .helpRequested, object: nil)
            }
            .keyboardShortcut("?", modifiers: .command)
        }
    }
}
