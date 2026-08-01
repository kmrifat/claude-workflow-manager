//
//  PhoneNotifier.swift
//  ClaudeWMMobile
//
//  Local notifications for card moves the phone learns about.
//
//  ## What this can and cannot do
//
//  A local notification has to be scheduled by a running app, and iOS suspends
//  this one — and tears down its socket — seconds after it goes to the
//  background. So notifications arrive while the app is open or recently
//  backgrounded, and stop once it is suspended. There is no background mode that
//  keeps a WebSocket alive; that gap is what APNs exists for, and closing it
//  properly means a push server, which this product deliberately does not have.
//
//  Being honest about that in the UI matters more than the feature does: a
//  notification you sometimes get is worse than one you never get, unless the
//  user knows which is which.
//
//  ## Foreground banners are opted into, deliberately
//
//  iOS shows nothing while the app is frontmost unless you say otherwise. The
//  first cut left that alone, reasoning that a visible board makes a banner
//  redundant — which was wrong twice over. You are usually looking at *one*
//  column of *one* project, so a card moving elsewhere is not visible at all;
//  and it made the feature impossible to try, because anyone testing it has the
//  app open.
//

import Foundation
import UserNotifications
import ClaudeWMWire

@MainActor
final class PhoneNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PhoneNotifier()

    private static let enabledKey = "cardMoveNotificationsEnabled"

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    private var authorization: UNAuthorizationStatus?
    private var isRequesting = false

    private override init() { super.init() }

    /// Called once the phone is actually talking to a Mac.
    ///
    /// Authorization is asked for here rather than at the first move, unlike the
    /// Mac. The Mac is always running, so losing one notice to the prompt costs
    /// nothing; the phone may only be awake for a handful of seconds, and losing
    /// the first one there can mean losing the only one. Pairing just succeeded,
    /// so the question has context.
    func prepare() {
        UNUserNotificationCenter.current().delegate = self
        guard isEnabled else { return }
        Task { await requestIfNeeded() }
    }

    @discardableResult
    private func requestIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        if authorization == nil {
            authorization = await center.notificationSettings().authorizationStatus
        }
        if authorization == .notDetermined, !isRequesting {
            isRequesting = true
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            authorization = granted ? .authorized : .denied
            isRequesting = false
        }
        return authorization != .denied
    }

    /// Shows the banner even with the app frontmost. See the note above.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    /// Posts a notice, asking for permission first if that has not happened yet
    /// — normally it has, in `prepare()`, the moment the phone reached a Mac.
    func post(_ notice: CardMoveNotice) {
        guard isEnabled else { return }
        Task { await deliver(notice) }
    }

    private func deliver(_ notice: CardMoveNotice) async {
        let center = UNUserNotificationCenter.current()

        guard await requestIfNeeded() else { return }

        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.subtitle = notice.subtitle
        content.body = notice.body
        content.threadIdentifier = notice.threadIdentifier
        content.sound = nil

        try? await center.add(UNNotificationRequest(
            identifier: notice.identifier,
            content: content,
            trigger: nil
        ))
    }
}
