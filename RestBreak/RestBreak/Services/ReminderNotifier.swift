import Foundation
import UserNotifications

/// 提醒的系统通知，只作兜底：提醒平时由刘海灵动岛显示（NotchIsland）。
/// 每次响铃都提前登记成系统定时通知，但比响铃晚 90 秒；星期五在运行时会先处理这次响铃并撤掉它，
/// 只有星期五没在运行（退出、崩溃）时才会真的弹出来
@MainActor
final class ReminderNotifier {
    enum Action: String {
        case done = "reminder.done"
        case snooze = "reminder.snooze"
        case skip = "reminder.skip"
    }

    static let gentleCategory = "reminder.gentle"
    static let firmCategory = "reminder.firm"
    private static let firePrefix = "reminder.fire."
    /// 上次登记的定时通知 id。存起来是为了下次能精确撤掉，不用去查系统的待发列表
    private static let scheduledKey = "reminderScheduledIDs"

    /// 兜底通知比响铃晚多少秒（主 App 最晚 30 秒处理一次，留足余量）
    static let fallbackDelay: TimeInterval = 90
    private let center = UNUserNotificationCenter.current()

    func start() {
        let done = UNNotificationAction(identifier: Action.done.rawValue, title: "完成")
        let snooze = UNNotificationAction(identifier: Action.snooze.rawValue, title: "10 分钟后")
        let skip = UNNotificationAction(identifier: Action.skip.rawValue, title: "跳过这次")
        NotificationRouter.shared.setCategories([
            UNNotificationCategory(identifier: Self.gentleCategory, actions: [done, snooze], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.firmCategory, actions: [done, snooze, skip], intentIdentifiers: []),
        ], owner: "reminder")
    }

    func requestAuthorization() {
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    /// 重新登记接下来要响的（先撤掉上次登记的）
    func schedule(_ items: [(fire: Fire, reminder: Reminder, message: String)], calendar: Calendar) {
        let old = UserDefaults.standard.stringArray(forKey: Self.scheduledKey) ?? []
        center.removePendingNotificationRequests(withIdentifiers: old)
        var ids: [String] = []
        for item in items {
            let content = UNMutableNotificationContent()
            content.title = item.reminder.title
            content.body = item.message
            content.sound = .default
            content.categoryIdentifier = item.reminder.style == .firm ? Self.firmCategory : Self.gentleCategory
            content.userInfo = Self.info(item.fire)
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                     from: item.fire.ringAt.addingTimeInterval(Self.fallbackDelay))
            let id = Self.fireID(item.fire)
            center.add(UNNotificationRequest(identifier: id, content: content,
                                             trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)),
                       withCompletionHandler: nil)
            ids.append(id)
        }
        UserDefaults.standard.set(ids, forKey: Self.scheduledKey)
    }

    /// 用户处理过某次响铃后，把通知中心里相关的横幅收掉
    func removeDelivered(_ fire: Fire) {
        center.removeDeliveredNotifications(withIdentifiers: [Self.fireID(fire)])
    }

    private static func info(_ fire: Fire) -> [String: String] {
        ["id": fire.reminderID, "at": String(fire.scheduledAt.timeIntervalSince1970),
         "ring": String(fire.ringAt.timeIntervalSince1970), "lead": String(fire.leadDays)]
    }

    private static func fireID(_ fire: Fire) -> String {
        "\(firePrefix)\(fire.reminderID).\(Int(fire.scheduledAt.timeIntervalSince1970)).\(Int(fire.ringAt.timeIntervalSince1970))"
    }
}
