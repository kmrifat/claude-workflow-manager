//
//  AppUpdater.swift
//  workflow-manager
//
//  Updates through Sparkle, from the GitHub releases this repository already
//  publishes. There is no update server: the feed is
//  `releases/latest/download/appcast.xml`, a URL GitHub redirects to an asset
//  of whichever release is newest, and the release workflow attaches a fresh
//  appcast to every release beside its DMG. Publishing a release is the whole
//  of shipping an update.
//
//  Every update is checked against the EdDSA public key in Info.plist
//  (`SUPublicEDKey`) before it is installed, whether or not the app is signed
//  with a Developer ID. The private half is a repository secret the workflow
//  signs with; lose it and no installed copy will ever accept an update again.
//
//  Debug builds do not start the updater. A dev build's version is whatever
//  the project says, so it would always find "an update" and offer to replace
//  itself with the release. `-EnableUpdater` starts it anyway, and
//  `-UpdateFeedURL <url>` points it at a test feed.
//

import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    /// False while a check or an install is under way, and always in a Debug
    /// build that was not asked to update.
    private(set) var canCheck = false

    /// Sparkle keeps these in the app's defaults; they are mirrored here only
    /// so SwiftUI notices a change.
    var checksAutomatically: Bool {
        didSet { updater.automaticallyChecksForUpdates = checksAutomatically }
    }

    var installsAutomatically: Bool {
        didSet { updater.automaticallyDownloadsUpdates = installsAutomatically }
    }

    private(set) var lastCheck: Date?

    @ObservationIgnored private let delegate = FeedDelegate()
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    private var updater: SPUUpdater { controller.updater }

    var isRunning: Bool {
        #if DEBUG
        CommandLine.arguments.contains("-EnableUpdater")
        #else
        true
        #endif
    }

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
        installsAutomatically = controller.updater.automaticallyDownloadsUpdates
        lastCheck = controller.updater.lastUpdateCheckDate

        guard isRunning else { return }
        controller.startUpdater()

        // KVO, because SPUUpdater is an NSObject and says nothing otherwise.
        // Delivered on whichever thread changed it, hence the hop.
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                let value = updater.canCheckForUpdates
                Task { @MainActor in self?.canCheck = value }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] updater, _ in
                let value = updater.lastUpdateCheckDate
                Task { @MainActor in self?.lastCheck = value }
            },
        ]
    }

    /// Sparkle's own window: "up to date", or the release notes and Install.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(marketing) (\(build))"
    }
}

/// Only for `-UpdateFeedURL` in Debug; nil keeps Info.plist's `SUFeedURL`.
private final class FeedDelegate: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        #if DEBUG
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "-UpdateFeedURL"), index + 1 < arguments.count {
            return arguments[index + 1]
        }
        #endif
        return nil
    }
}
