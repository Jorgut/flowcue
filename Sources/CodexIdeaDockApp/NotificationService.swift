import Foundation
import UserNotifications
#if SWIFT_PACKAGE
import CodexIdeaDockCore
#endif

/// 统一的通知出口：权限、投递、点击后跳转。
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    /// 点击「新消息」通知时回调（agentID, sessionID）
    var onOpenSession: ((String, String) -> Void)?
    /// 点击「待审」通知时回调
    var onOpenApprovals: (() -> Void)?

    /// 未读回复计数（菜单栏角标用）
    var unreadStore: ReplyUnreadStore?
    /// 用户正看着 Agent 列表时不再累加未读
    var suppressUnread: (() -> Bool)?

    private let center = UNUserNotificationCenter.current()
    private let enabledKey = "FlowCue.notificationsEnabled"

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    func start() {
        center.delegate = self
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            self.center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func postTurnFinished(agent: String, sessionTitle: String, snippet: String, agentID: String, sessionID: String) {
        if suppressUnread?() != true {
            unreadStore?.markUnread(agentID: agentID, sessionID: sessionID)
        }
        guard isEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = agent
        content.subtitle = sessionTitle
        content.body = snippet
        content.sound = .default
        content.userInfo = ["agentID": agentID, "sessionID": sessionID]
        deliver(content, id: "msg-\(agentID)-\(sessionID)")
    }

    func postApprovals(count: Int) {
        guard isEnabled, count > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "FlowCue"
        content.body = count == 1
            ? L10n.text("有 1 个待审批求")
            : L10n.text("有 ") + String(count) + L10n.text(" 个待审批求")
        content.sound = .default
        content.userInfo = ["kind": "approvals"]
        deliver(content, id: "approvals-\(count)")
    }

    private func deliver(_ content: UNMutableNotificationContent, id: String) {
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let kind = info["kind"] as? String
        let agentID = info["agentID"] as? String
        let sessionID = info["sessionID"] as? String
        await MainActor.run {
            if kind == "approvals" {
                onOpenApprovals?()
            } else if let agentID, let sessionID {
                onOpenSession?(agentID, sessionID)
            }
        }
    }
}
