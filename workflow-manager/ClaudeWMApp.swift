//
//  ClaudeWMApp.swift
//  workflow-manager
//
//  The app entry point. The product is "Claude WM": PRODUCT_NAME sets the
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
    let sharedModelContainer = AppModelContainer.make()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
        .commands { WorkflowCommands() }
    }
}
