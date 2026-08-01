//
//  BoardNotifier.swift
//  workflow-manager
//
//  Local notifications for card moves.
//
//  ## Only moves you did not make
//
//  The Mac user is looking at the Mac. Telling them they just dragged a card is
//  noise, and noise is how a user learns to ignore your notifications. So this
//  is never called from the board UI — only from the two places that can
//  positively attribute a move to somebody else: `WorkflowSyncModel.apply`,
//  where an agent's status change lands, and `BoardService.apply`, where a
//  phone's does.
//
//  Attribution by knowing the call site, rather than by diffing the board and
//  guessing, is the whole reason this stays honest. A diff would notify on every
//  drag and then need heuristics to shut up again.
//
//  ## Authorization
//
//  Requested the first time there is something to say, not at launch. A kanban
//  app that asks for notification permission before the user has done anything
//  has not earned the question, and "not now" is nearly permanent.
//
//  The cost of that choice: the notification that triggers the prompt is
//  dropped, because the answer arrives after it. One lost banner, once, in
//  exchange for a prompt that makes sense when it appears.
//

import Foundation
import UserNotifications
import ClaudeWMWire

@MainActor
final class BoardNotifier {
    static let shared = BoardNotifier()

    /// Off until the user turns it on. Notifications about an agent moving your
    /// cards are the kind of thing people want *or* find intolerable, with very
    /// little in between.
    private static let enabledKey = "boardNotificationsEnabled"

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    private var authorization: UNAuthorizationStatus?
    private var isRequesting = false

    private init() {}

    func post(_ notice: CardMoveNotice) {
        guard isEnabled else { return }
        Task { await deliver(notice) }
        // And to any paired phone that is asleep. `PushRegistry` skips the ones
        // holding a socket, because those notify themselves and would otherwise
        // show the same move twice.
        PushRegistry.shared.push(notice)
    }

    private func deliver(_ notice: CardMoveNotice) async {
        let center = UNUserNotificationCenter.current()

        if authorization == nil {
            authorization = await center.notificationSettings().authorizationStatus
        }
        switch authorization {
        case .notDetermined:
            // First time. Ask, and drop this one — see the note above.
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
        content.sound = nil          // a card moving is not worth a chime

        // A stable identifier per card replaces the previous banner rather than
        // stacking a third one behind two stale ones.
        let request = UNNotificationRequest(
            identifier: notice.identifier,
            content: content,
            trigger: nil             // deliver now
        )
        try? await center.add(request)
    }
}
