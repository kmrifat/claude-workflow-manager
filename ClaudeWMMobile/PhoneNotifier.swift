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
//  ## Foreground is deliberately silent
//
//  No `UNUserNotificationCenterDelegate` returning `.banner`. If the board is on
//  screen the card visibly moves, and a banner over the top of it says the same
//  thing twice.
//

import Foundation
import UserNotifications
import ClaudeWMWire

@MainActor
final class PhoneNotifier {
    static let shared = PhoneNotifier()

    private static let enabledKey = "cardMoveNotificationsEnabled"

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    private var authorization: UNAuthorizationStatus?
    private var isRequesting = false

    private init() {}

    /// Asked for at a moment the user can connect to something — the first move
    /// they did not make — rather than on first launch, when the question has
    /// not been earned. The notification that triggers the prompt is dropped,
    /// because the answer arrives after it.
    func post(_ notice: CardMoveNotice) {
        guard isEnabled else { return }
        Task { await deliver(notice) }
    }

    private func deliver(_ notice: CardMoveNotice) async {
        let center = UNUserNotificationCenter.current()

        if authorization == nil {
            authorization = await center.notificationSettings().authorizationStatus
        }
        switch authorization {
        case .notDetermined:
            guard !isRequesting else { return }
            isRequesting = true
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            authorization = granted ? .authorized : .denied
            isRequesting = false
            return
        case .denied:
            return
        default:
            break
        }

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
