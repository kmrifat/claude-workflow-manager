//
//  AppDelegate.swift
//  workflow-manager
//
//  The one thing SwiftUI's app lifecycle cannot do: stop a quit. Files edited
//  in the Files view and not saved would otherwise vanish with the app, and
//  an editor that loses typing on ⌘Q is worse than none.
//

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let unsaved = FilesStateStore.unsavedFiles
        guard !unsaved.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = unsaved.count == 1
            ? "“\(unsaved[0].lastPathComponent)” has unsaved changes."
            : "\(unsaved.count) files have unsaved changes."
        alert.informativeText = unsaved.count == 1
            ? "Quitting throws them away. Save it from the Files view first to keep them."
            : unsaved.map(\.lastPathComponent).sorted().joined(separator: ", ")
                + "\n\nQuitting throws the changes away. Save them from the Files view first to keep them."
        alert.addButton(withTitle: "Don’t Quit")
        let quit = alert.addButton(withTitle: "Quit Anyway")
        quit.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}
