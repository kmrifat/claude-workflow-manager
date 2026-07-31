import AppKit
import SwiftUI
import WorkflowCore
import WorkflowHostKit

/// The macOS menu bar client.
///
/// Embeds the host in-process: it starts the poller and the dashboard server on
/// launch and shuts them down on quit. The menu bar shows the number of active
/// runs at a glance, and quitting while a run is live asks first — quitting must
/// not silently kill a session someone is watching.
///
/// Built as an SPM executable rather than an `.xcodeproj` app: it spawns
/// `claude`, `git` and `cloudflared`, so it can never be sandboxed, and an
/// accessory-policy `NSApplication` is all a menu bar item needs.
@main
struct HostAppMain {
    static func main() {
        let application = NSApplication.shared
        let controller = HostAppController()
        application.delegate = controller
        // Accessory, not regular: no Dock icon, no menu bar title — this lives
        // in the status bar.
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
final class HostAppController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let model = HostAppModel()
    private var popover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "square.stack.3d.up",
            accessibilityDescription: "WorkflowHost"
        )
        item.button?.imagePosition = .imageLeading
        item.button?.action = #selector(togglePopover)
        item.button?.target = self
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 340, height: 420)
        popover.contentViewController = NSHostingController(
            rootView: HostAppMenu(model: model)
        )
        self.popover = popover

        model.onCountChanged = { [weak self] count in
            // The count is the whole point of the menu bar item: how much is in
            // flight, without opening anything.
            self?.statusItem?.button?.title = count == 0 ? "" : " \(count)"
        }

        Task { await model.start() }
    }

    @objc private func togglePopover() {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            Task { await model.refresh() }
        }
    }

    /// Quitting must not silently kill a live Claude session.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.activeRunCount > 0 else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "\(model.activeRunCount) run\(model.activeRunCount == 1 ? " is" : "s are") still going."
        alert.informativeText = """
            Quitting stops the host, which ends those sessions. \
            Their worktrees are left in place either way.
            """
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }
}
