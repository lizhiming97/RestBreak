import Foundation
@testable import RestBreak

/// 提醒相关测试的公共工具。时间一律按北京时间，2026-10-23 是周五
enum RT {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        c.locale = Locale(identifier: "zh_CN")
        return c
    }()

    /// "2026-10-23 15:12" → Date（北京时间）
    static func d(_ text: String) -> Date { ReminderTools.parseDateTime(text, calendar: calendar)! }
    static func t(_ text: String) -> ClockTime { ClockTime(text)! }

    static func reminder(_ schedule: Schedule, id: String = "r1", title: String = "吃药",
                         created: String = "2026-10-23 08:00", style: ReminderStyle = .gentle,
                         start: Date? = nil, end: Date? = nil, max: Int? = nil,
                         messages: [String] = ["该吃药啦"], createdBy: String = "claude-code") -> Reminder {
        Reminder(id: id, title: title, messages: messages, schedule: schedule, style: style, reason: nil,
                 createdBy: createdBy, createdAt: d(created), updatedAt: d(created),
                 startDate: start, endDate: end, maxOccurrences: max, state: .active, announced: true)
    }

    static func tempStore() -> ReminderStore {
        ReminderStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("reminders-\(UUID().uuidString)", isDirectory: true))
    }

    static func context(_ now: String, store: ReminderStore, client: String = "claude-code") -> ToolContext {
        ToolContext(now: d(now), calendar: calendar, client: client, store: store)
    }

    /// 工具返回的 JSON 文本 → 字典
    static func object(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }
}
