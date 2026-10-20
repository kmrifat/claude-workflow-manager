//
//  AppDelegate.swift
//  workflow-manager
//
//  What SwiftUI's app lifecycle cannot do: stop a quit — files edited in the
//  Files view and not saved would otherwise vanish with the app, and an editor
//  that loses typing on ⌘Q is worse than none — and start the updater as the
//  app launches.
//

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Started here rather than on first use, so the scheduled check runs
    /// whether or not anyone opens the menu or Settings.
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = AppUpdater.shared
    }

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
