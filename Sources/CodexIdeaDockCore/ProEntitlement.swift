import Foundation

/// Pro 权限的跨设备传递：iOS 订阅后写入 iCloud KV，Mac 读到即解锁。
/// 只为「有没有订阅」这一件事服务，不涉及支付逻辑。
public enum ProEntitlement {
    public static let key = "FlowCue.proUntil"
    /// 订阅到期后仍给一段宽限，避免续订失败瞬间功能消失。
    public static let graceDays = 7

    public static var kv: NSUbiquitousKeyValueStore { .default }
    public static var fallback: UserDefaults { .standard }

    /// 到期时间（本地缓存优先，iCloud 更新后覆盖）。
    public static var expiry: Date? {
        if let raw = kv.string(forKey: key) ?? fallback.string(forKey: key) {
            return ISO8601DateFormatter().date(from: raw)
        }
        return nil
    }

    public static func isPro(now: Date = Date()) -> Bool {
        guard let expiry else { return false }
        return expiry.addingTimeInterval(TimeInterval(graceDays) * 86_400) > now
    }

    /// iOS 在订阅状态变化时调用。
    public static func publish(expiry: Date?) {
        let raw = expiry.map { ISO8601DateFormatter().string(from: $0) }
        if let raw {
            kv.set(raw, forKey: key)
            fallback.set(raw, forKey: key)
        } else {
            kv.removeObject(forKey: key)
            fallback.removeObject(forKey: key)
        }
        kv.synchronize()
    }

    /// 收到外部变更（另一台设备改了订阅）时回调。
    public static func observeChanges(_ handler: @escaping () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kv,
            queue: .main
        ) { _ in handler() }
    }
}
