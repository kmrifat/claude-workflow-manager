//
//  ClaudeWMApp.swift
//  workflow-manager
//
//  The app entry point. The product is "Pitwall": PRODUCT_NAME sets the
//  bundle name, the executable and — via GENERATE_INFOPLIST_FILE — CFBundleName,
//  which is what the bold app menu shows; CFBundleDisplayName in Info.plist
//  covers Finder and the About box.
//
//  The Xcode target, the source folder and the bundle identifier are still
//  `workflow-manager`. That is deliberate: the identifier is where SwiftData
//  puts the store, so changing it would strand an existing board.
//

import SwiftUI
import SwiftData

@main
struct ClaudeWMApp: App {
    let sharedModelContainer = Self.makeContainer()

    /// App-level, not per-window: a card window needs both — to send a card to
    /// Claude, and to know whether Claude is reachable at all — and a second
    /// main window must not start a second MCP server on the same port.
    @State private var syncCoordinator = WorkflowSyncCoordinator()
    @State private var mcpServer = MCPServer()

    /// `-UseSampleData` (Debug only) runs on an in-memory store seeded with
    /// invented projects, so a development build can be launched and
    /// screenshotted without touching — or migrating — the real board.
    private static func makeContainer() -> ModelContainer {
        #if DEBUG
        if CommandLine.arguments.contains("-UseSampleData") {
            return SampleData.container
        }
        #endif
        return AppModelContainer.make()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // Only the first window, before macOS has a saved frame to restore.
        // Without it the window opens at the content's ideal size, which for a
        // sidebar plus five lanes is a short strip that shows one card per lane.
        .defaultSize(width: 1440, height: 900)
        .environment(syncCoordinator)
        .environment(mcpServer)
        .modelContainer(sharedModelContainer)
        .commands { WorkflowCommands() }

        // One window per card, keyed by its UUID, so opening a card that is
        // already open brings its window forward instead of making another.
        WindowGroup("Card", id: CardWindow.sceneID, for: UUID.self) { $itemID in
            CardWindow(itemID: itemID)
        }
        .defaultSize(width: 860, height: 780)
        .windowToolbarStyle(.unified)
        .environment(syncCoordinator)
        .environment(mcpServer)
        .modelContainer(sharedModelContainer)
    }
}
