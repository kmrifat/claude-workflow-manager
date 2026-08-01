//
//  PushRegistration.swift
//  ClaudeWMMobile
//
//  Getting an APNs token and handing it to the Mac.
//
//  This is the half of the notification story a local notification cannot do:
//  iOS suspends this app seconds after the screen goes off, and a suspended app
//  cannot schedule anything. A push is delivered by the system, so it arrives
//  whether or not this process exists.
//
//  The token goes to the Mac over the board socket, *after* `hello`, so it is
//  covered by the same pairing key as everything else. A token accepted from an
//  unpaired peer would let a stranger aim someone's Mac at a device of their
//  choosing.
//

import Foundation
import UIKit

@MainActor
@Observable
final class PushRegistration: NSObject {
    static let shared = PushRegistration()

    /// Set once Apple hands one over. Nil until then, and on the Simulator
    /// forever — the Simulator has no push token, which is why this feature can
    /// only be tested on a real device.
    private(set) var token: String?

    /// Stable per install, unlike the token, which changes on reinstall and
    /// occasionally on its own. The Mac keys its stored tokens on this so a new
    /// token replaces the old rather than accumulating a dead one.
    var deviceID: String {
        UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
    }

    /// Called on every launch: registration is cheap, and the token can change
    /// underneath you at any time.
    func register() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    func received(_ deviceToken: Data) {
        // APNs wants it hex, not base64 — a base64 token is accepted by the
        // request and then silently never delivered.
        token = deviceToken.map { String(format: "%02x", $0) }.joined()
    }

    func failed(_ error: any Error) {
        // Common and not worth alarming anyone about: no push entitlement on
        // this build, no network, or the Simulator.
        token = nil
    }
}

/// SwiftUI has no hook for the remote-notification callbacks, so the app still
/// needs an app delegate for these two methods and nothing else.
final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in PushRegistration.shared.received(deviceToken) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        Task { @MainActor in PushRegistration.shared.failed(error) }
    }
}
