import UserNotifications

/// 用户点了某条通知（已经从系统对象里取出要用的字符串，可以跨线程传）
struct NotificationReply: Sendable {
    var category: String
    var action: String
    var info: [String: String]
}

/// 系统只允许一个通知代理，也只有一份「通知分类（按钮组合）」列表。
/// 现在只有提醒的兜底通知（休息前的提前通知 2026-10-26 按用户要求删除）
@MainActor
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    var onReminderReply: ((NotificationReply) -> Void)?
    private var categories: [String: Set<UNNotificationCategory>] = [:]

    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// 各自登记自己的按钮组合，这里合并后一起交给系统（系统每次都整份替换）
    func setCategories(_ set: Set<UNNotificationCategory>, owner: String) {
        categories[owner] = set
        UNUserNotificationCenter.current().setNotificationCategories(categories.values.reduce(into: []) { $0.formUnion($1) })
    }

    /// 设置窗口开着（App 在前台）时也照常显示横幅
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        var info: [String: String] = [:]
        for (key, value) in content.userInfo {
            if let key = key as? String, let value = value as? String { info[key] = value }
        }
        await route(NotificationReply(category: content.categoryIdentifier, action: response.actionIdentifier, info: info))
    }

    private func route(_ reply: NotificationReply) {
        if reply.category.hasPrefix("reminder.") { onReminderReply?(reply) }
    }
}
