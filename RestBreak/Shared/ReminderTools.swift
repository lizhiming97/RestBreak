import Foundation

struct ToolError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

struct ToolResult: Equatable, Sendable {
    var text: String
    var isError: Bool
    /// 改了数据：小程序据此决定要不要拉起主 App
    var changed: Bool
}

struct ToolSpec: Sendable {
    let name: String
    let description: String
    /// JSON Schema 原文
    let schema: String
    let readOnly: Bool
    let destructive: Bool
    /// 可以设成不用每次批准：只读的，或有打扰预算兜底的（「连接 AI」页的接入说明、Codex 配置据此生成）
    var autoApprove = false
}

struct ToolContext {
    var now: Date
    var calendar: Calendar
    /// 调用方的 MCP 客户端名
    var client: String
    var store: ReminderStore
}

/// 到点提醒的 4 个工具（看现状的 get_context 在 ButlerTools）。参数是 JSON 解出来的字典，结果是 JSON 文本；不依赖 MCP SDK，方便测试
enum ReminderTools {
    static let manualClient = "手动"
    static let maxActive = 100
    static let minIntervalMinutes = 15
    static let maxCreatesPerHour = 20

    static var instructions: String { """
    你连接的是「星期五」：用户 Mac 上的休息与提醒助手。它本身不调用任何 AI，只负责把话递到用户眼前（刘海处的灵动岛）。说什么、什么时候该说，由你来判断。
    两种开口方式，分清楚：
    - 用户说了明确时间的事（「每天 21:00 提醒我吃药」「周五下午 3 点提醒我交周报」）：用 create_reminder 建在星期五里，到点由星期五准时提醒，你不在线也会响。
    - 你自己判断出来、现在就值得说的事：用 push。不要为了「过一会再说」去建提醒。
    建提醒：
    - 用户提到将来要做的事（吃药、买东西、截止日期、给某人回电话、交房租、家人生日）时，主动问一句「要我在星期五里提醒你吗？」，用户同意后再建。
    - 时间都按用户本地时间理解。不确定现在几点时先调用 get_context，它会返回当前时间和星期几。
    - messages 写 1～5 句贴合用户情况的提醒文案：短一点、暖一点，可以带上原因或进度（如「还剩 4 天就吃完了」）。反复响的提醒写 2～5 句不同的话，星期五会轮换使用。
    - 吃药、重要截止这类不能错过的用 style = "firm"，其他用默认的 "gentle"。
    - reason 用一句话写清这个提醒从哪来，比如「10/23 聊到医生开了 7 天抗生素」。
    - 用户聊到相关话题时，可以先用 get_context，或带 historyDays 调用 list_reminders，看看完成情况再给出关心。
    - 不要删除或修改不是这次对话里建的提醒，除非用户明确要求。
    - 建好后，用工具返回的 next（接下来 3 次）向用户复述确认。

    \(ButlerTools.instructions)
    """ }

    private static let scheduleSchema = #"""
    {"type":"object","required":["kind"],"description":"什么时候响。时刻写本地时间 HH:mm；日期时间写 yyyy-MM-dd HH:mm（也接受带时区的 ISO 8601）","properties":{
     "kind":{"type":"string","enum":["once","daily","interval","monthly","yearly"],"description":"once 一次 / daily 每天（可限星期几）/ interval 每隔一段时间 / monthly 每月 / yearly 每年"},
     "at":{"type":"string","description":"once：什么时候，如 2026-10-24 18:30"},
     "times":{"type":"array","items":{"type":"string"},"description":"daily / monthly / yearly：哪几个时刻，如 [\"09:00\",\"21:00\"]"},
     "weekdays":{"type":"array","items":{"type":"integer","minimum":1,"maximum":7},"description":"daily / interval：只在星期几响，1 = 周一 … 7 = 周日；不填 = 每天"},
     "everyMinutes":{"type":"integer","minimum":15,"description":"interval：每隔多少分钟（至少 15）"},
     "from":{"type":"string","description":"interval：从几点开始，如 09:00"},
     "to":{"type":"string","description":"interval：到几点结束，如 18:00"},
     "days":{"type":"array","items":{"type":"integer","minimum":1,"maximum":31},"description":"monthly：每月几号；31 号在小月自动改成当月最后一天"},
     "month":{"type":"integer","minimum":1,"maximum":12,"description":"yearly：几月"},
     "day":{"type":"integer","minimum":1,"maximum":31,"description":"yearly：几号"},
     "leadDays":{"type":"array","items":{"type":"integer","minimum":1,"maximum":30},"description":"yearly：提前几天也预告一次，如 [5]"}}}
    """#

    private static let fieldSchemas = """
     "title":{"type":"string","description":"提醒标题，40 字以内，如「吃抗生素」"},
     "messages":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":5,"description":"1～5 句提醒文案，每次响铃轮换使用"},
     "schedule":\(scheduleSchema),
     "style":{"type":"string","enum":["gentle","firm"],"description":"gentle：只弹横幅（默认）；firm：横幅加一张不处理就不消失的卡片，没处理会每 10 分钟再提醒，适合吃药"},
     "reason":{"type":"string","description":"一句话：为什么建这个提醒"},
     "startDate":{"type":"string","description":"从哪天开始，yyyy-MM-dd；不填 = 现在"},
     "endDate":{"type":"string","description":"到哪天结束（含这一天），yyyy-MM-dd"},
     "maxOccurrences":{"type":"integer","minimum":1,"description":"一共响几次后自动结束，比如吃 7 天、一天 3 次就是 21"}
    """

    static let specs: [ToolSpec] = [
        ToolSpec(name: "create_reminder",
                 description: "新建一条提醒。用户同意后再调用。返回提醒内容和接下来 3 次响的时间，用来向用户复述确认。",
                 schema: #"{"type":"object","required":["title","messages","schedule"],"properties":{"# + fieldSchemas + "}}",
                 readOnly: false, destructive: false),
        ToolSpec(name: "list_reminders",
                 description: "列出提醒。status 为 active（默认，含已暂停）或 all（含已结束）；historyDays 为 1～30 时附上最近几天每次的完成情况，用来回答「这周药都按时吃了吗」。",
                 schema: #"{"type":"object","properties":{"status":{"type":"string","enum":["active","all"]},"historyDays":{"type":"integer","minimum":0,"maximum":30}}}"#,
                 readOnly: true, destructive: false, autoApprove: true),
        ToolSpec(name: "update_reminder",
                 description: "按 id 修改提醒，只传要改的字段。state 传 paused 暂停、active 恢复（已结束的也能恢复）；endDate、maxOccurrences 传 null 表示去掉限制。",
                 schema: #"{"type":"object","required":["id"],"properties":{"id":{"type":"string"},"state":{"type":"string","enum":["active","paused"]},"# + fieldSchemas + "}}",
                 readOnly: false, destructive: false),
        ToolSpec(name: "delete_reminder",
                 description: "按 id 删除提醒及其完成记录。只删用户明确要删的。",
                 schema: #"{"type":"object","required":["id"],"properties":{"id":{"type":"string"}}}"#,
                 readOnly: false, destructive: true),
    ]

    static func call(_ name: String, arguments: [String: Any], context: ToolContext) -> ToolResult {
        do {
            switch name {
            case "create_reminder": return try create(arguments, context)
            case "list_reminders": return try list(arguments, context)
            case "update_reminder": return try update(arguments, context)
            case "delete_reminder": return try delete(arguments, context)
            default: throw ToolError("没有这个工具：\(name)")
            }
        } catch let error as ToolError {
            return ToolResult(text: error.message, isError: true, changed: false)
        } catch let error as StoreError {
            return ToolResult(text: error.description, isError: true, changed: false)
        } catch {
            return ToolResult(text: "星期五出错了：\(error.localizedDescription)", isError: true, changed: false)
        }
    }

    // MARK: - 四个工具

    /// 到点提醒的概况，放进 get_context：今天和接下来 24 小时要响的及状态、最近 3 天错过的
    static func overview(_ data: ReminderData, _ c: ToolContext) -> [String: Any] {
        let start = c.calendar.startOfDay(for: c.now)
        let end = c.now.addingTimeInterval(86400)
        let upcoming = data.reminders
            .flatMap { ReminderPlanner.fires($0, from: start, to: end, calendar: c.calendar) }
            .sorted { $0.scheduledAt < $1.scheduledAt }
            .compactMap { fire -> [String: Any]? in
                guard let r = data.reminder(fire.reminderID) else { return nil }
                let state = data.occurrence(r.id, at: fire.scheduledAt).map { outcomeText($0.outcome) }
                    ?? (fire.scheduledAt > c.now ? "待响" : "已过（星期五还没处理）")
                return ["id": r.id, "title": r.title, "time": ScheduleText.fireText(fire.scheduledAt, now: c.now, calendar: c.calendar), "state": state]
            }
        let missed = data.occurrences
            .filter { $0.outcome == .missed && $0.scheduledAt >= c.now.addingTimeInterval(-3 * 86400) }
            .compactMap { o -> [String: Any]? in
                guard let r = data.reminder(o.reminderID) else { return nil }
                return ["id": r.id, "title": r.title, "time": ScheduleText.dateTime(o.scheduledAt, calendar: c.calendar)]
            }
        return ["upcoming": upcoming, "missedRecently": missed,
                "activeCount": data.reminders.filter { $0.state == .active }.count,
                "pausedCount": data.reminders.filter { $0.state == .paused }.count]
    }

    private static func create(_ args: [String: Any], _ c: ToolContext) throws -> ToolResult {
        let title = try requiredText(args, "title", max: 40)
        let messages = try messageList(args["messages"])
        let schedule = try parseSchedule(args["schedule"], context: c)
        let style = try parseStyle(args["style"]) ?? .gentle
        let reason = try optionalText(args, "reason", max: 200)
        let startDate = try optionalDay(args, "startDate", c)
        let endDate = try optionalDay(args, "endDate", c).map(endOfDay(c))
        let maxOccurrences = try optionalPositive(args, "maxOccurrences")
        if let startDate, let endDate, endDate < startDate { throw ToolError("endDate 早于 startDate") }

        return try c.store.update { data in
            guard data.reminders.filter({ $0.state != .finished }).count < maxActive else {
                throw ToolError("已经有 \(maxActive) 条提醒了，请先帮用户删掉一些不用的")
            }
            let recent = data.reminders.filter { $0.createdBy == c.client && c.now.timeIntervalSince($0.createdAt) < 3600 }
            guard recent.count < maxCreatesPerHour else {
                throw ToolError("一小时内最多新建 \(maxCreatesPerHour) 条提醒，请稍后再试")
            }
            let reminder = Reminder(id: ReminderData.newID(existing: Set(data.reminders.map(\.id))),
                                    title: title, messages: messages, schedule: schedule, style: style, reason: reason,
                                    createdBy: c.client, createdAt: c.now, updatedAt: c.now,
                                    startDate: startDate, endDate: endDate, maxOccurrences: maxOccurrences,
                                    state: .active, announced: false)
            let next = ReminderPlanner.next(reminder, after: c.now, count: 3, calendar: c.calendar)
            guard !next.isEmpty else {
                throw ToolError("按这个时间安排，以后一次都不会响。请检查 endDate、maxOccurrences、weekdays。现在是 \(nowText(c))")
            }
            data.reminders.append(reminder)
            return result(["now": nowInfo(c), "created": describe(reminder, c),
                           "next": next.map { ScheduleText.fireText($0.scheduledAt, now: c.now, calendar: c.calendar) }],
                          changed: true)
        }
    }

    private static func list(_ args: [String: Any], _ c: ToolContext) throws -> ToolResult {
        let status = args["status"] as? String ?? "active"
        let historyDays = min(max(args["historyDays"] as? Int ?? 0, 0), 30)
        let data = try c.store.load()
        let items = data.reminders.filter { status == "all" || $0.state != .finished }.map { r -> [String: Any] in
            var item = describe(r, c)
            if historyDays > 0 {
                let since = c.now.addingTimeInterval(-Double(historyDays) * 86400)
                item["history"] = data.occurrences
                    .filter { $0.reminderID == r.id && $0.scheduledAt >= since }
                    .sorted { $0.scheduledAt < $1.scheduledAt }
                    .map { ["time": ScheduleText.dateTime($0.scheduledAt, calendar: c.calendar), "result": outcomeText($0.outcome)] }
            }
            return item
        }
        return result(["now": nowInfo(c), "reminders": items], changed: false)
    }

    private static func update(_ args: [String: Any], _ c: ToolContext) throws -> ToolResult {
        let id = try requiredText(args, "id", max: 20)
        return try c.store.update { data in
            guard let i = data.reminders.firstIndex(where: { $0.id == id }) else {
                throw ToolError("没有 id 为 \(id) 的提醒，先用 list_reminders 查一下")
            }
            var r = data.reminders[i]
            if args["title"] != nil { r.title = try requiredText(args, "title", max: 40) }
            if args["messages"] != nil { r.messages = try messageList(args["messages"]) }
            if args["schedule"] != nil { r.schedule = try parseSchedule(args["schedule"], context: c) }
            if args["style"] != nil { r.style = try parseStyle(args["style"]) ?? r.style }
            if args["reason"] != nil { r.reason = try optionalText(args, "reason", max: 200) }
            if args["startDate"] != nil { r.startDate = try optionalDay(args, "startDate", c) }
            if args["endDate"] != nil { r.endDate = try optionalDay(args, "endDate", c).map(endOfDay(c)) }
            if args["maxOccurrences"] != nil { r.maxOccurrences = try optionalPositive(args, "maxOccurrences") }
            if let state = args["state"] {
                switch state as? String {
                case "active": r.state = .active
                case "paused": r.state = .paused
                default: throw ToolError("state 只能是 active 或 paused")
                }
            }
            r.updatedAt = c.now
            let next = ReminderPlanner.next(r, after: c.now, count: 3, calendar: c.calendar)
            if r.state == .active && next.isEmpty {
                throw ToolError("改完以后一次都不会响了。请检查 endDate、maxOccurrences、weekdays。现在是 \(nowText(c))")
            }
            data.reminders[i] = r
            return result(["now": nowInfo(c), "updated": describe(r, c),
                           "next": next.map { ScheduleText.fireText($0.scheduledAt, now: c.now, calendar: c.calendar) }],
                          changed: true)
        }
    }

    private static func delete(_ args: [String: Any], _ c: ToolContext) throws -> ToolResult {
        let id = try requiredText(args, "id", max: 20)
        return try c.store.update { data in
            guard let r = data.reminder(id) else { throw ToolError("没有 id 为 \(id) 的提醒，先用 list_reminders 查一下") }
            data.reminders.removeAll { $0.id == id }
            data.occurrences.removeAll { $0.reminderID == id }
            return result(["deleted": r.title], changed: true)
        }
    }

    // MARK: - 解析

    static func parseSchedule(_ value: Any?, context c: ToolContext) throws -> Schedule {
        guard let object = value as? [String: Any] else {
            throw ToolError(#"schedule 必须是对象，例如 {"kind":"daily","times":["09:00"]}"#)
        }
        switch object["kind"] as? String {
        case "once":
            guard let text = object["at"] as? String else { throw ToolError(#"once 需要 at，例如 "2026-10-24 18:30""#) }
            guard let at = parseDateTime(text, calendar: c.calendar) else {
                throw ToolError("at「\(text)」看不懂，请写成 yyyy-MM-dd HH:mm，例如 2026-10-24 18:30")
            }
            guard at > c.now else { throw ToolError(pastMessage(at, c)) }
            return .once(at: at)
        case "daily":
            return .daily(times: try clockList(object["times"]), weekdays: try weekdays(object["weekdays"]))
        case "interval":
            guard let every = object["everyMinutes"] as? Int else { throw ToolError("interval 需要 everyMinutes（整数分钟）") }
            guard every >= minIntervalMinutes else { throw ToolError("everyMinutes 至少 \(minIntervalMinutes) 分钟，太频繁会打扰用户") }
            let from = try clock(object["from"], name: "from")
            let to = try clock(object["to"], name: "to")
            guard from < to else { throw ToolError("from 要早于 to") }
            return .interval(everyMinutes: every, from: from, to: to, weekdays: try weekdays(object["weekdays"]))
        case "monthly":
            guard let days = object["days"] as? [Int], !days.isEmpty, days.allSatisfy((1...31).contains) else {
                throw ToolError("monthly 需要 days：1～31 的整数数组，例如 [10]")
            }
            return .monthly(days: Array(Set(days)).sorted(), times: try clockList(object["times"]))
        case "yearly":
            guard let month = object["month"] as? Int, (1...12).contains(month),
                  let day = object["day"] as? Int, (1...31).contains(day) else {
                throw ToolError("yearly 需要 month（1～12）和 day（1～31）")
            }
            let maxDay = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
            guard day <= maxDay else { throw ToolError("\(month) 月没有 \(day) 号") }
            let leadDays = object["leadDays"] as? [Int] ?? []
            guard leadDays.allSatisfy((1...30).contains) else { throw ToolError("leadDays 是 1～30 的整数数组") }
            return .yearly(month: month, day: day, times: try clockList(object["times"]), leadDays: Array(Set(leadDays)).sorted())
        default:
            throw ToolError("schedule.kind 必须是 once / daily / interval / monthly / yearly 之一")
        }
    }

    /// 接受 "yyyy-MM-dd HH:mm"、"yyyy-MM-ddTHH:mm"（本地时间），以及带时区的 ISO 8601。秒数一律舍去
    static func parseDateTime(_ text: String, calendar: Calendar) -> Date? {
        let s = text.trimmingCharacters(in: .whitespaces)
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            iso.formatOptions = options
            if let date = iso.date(from: s) { return truncateToMinute(date, calendar: calendar) }
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mmXXXXX"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: s) { return truncateToMinute(date, calendar: calendar) }
        }
        return nil
    }

    private static func truncateToMinute(_ date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .minute, for: date)?.start ?? date
    }

    private static func pastMessage(_ at: Date, _ c: ToolContext) -> String {
        var text = "at \(stamp(at, c)) 已经过去了，现在是 \(nowText(c))。"
        if let tomorrow = c.calendar.date(byAdding: .day, value: 1, to: at), tomorrow > c.now {
            text += "是不是想设成明天 \(stamp(tomorrow, c))？"
        }
        return text
    }

    private static func clock(_ value: Any?, name: String) throws -> ClockTime {
        guard let text = value as? String, let time = ClockTime(text) else {
            throw ToolError("\(name) 要写成 HH:mm，例如 09:00")
        }
        return time
    }

    private static func clockList(_ value: Any?) throws -> [ClockTime] {
        guard let list = value as? [String], !list.isEmpty else { throw ToolError(#"times 要写成 HH:mm 的数组，例如 ["09:00","21:00"]"#) }
        let times = try list.map { try clock($0, name: "times 里的「\($0)」") }
        return Array(Set(times)).sorted()
    }

    private static func weekdays(_ value: Any?) throws -> [Int] {
        guard let value, !(value is NSNull) else { return [] }
        guard let list = value as? [Int], list.allSatisfy((1...7).contains) else {
            throw ToolError("weekdays 是 1～7 的整数数组，1 = 周一 … 7 = 周日")
        }
        return Array(Set(list)).sorted()
    }

    private static func parseStyle(_ value: Any?) throws -> ReminderStyle? {
        guard let value, !(value is NSNull) else { return nil }
        guard let text = value as? String, let style = ReminderStyle(rawValue: text) else {
            throw ToolError("style 只能是 gentle 或 firm")
        }
        return style
    }

    private static func requiredText(_ args: [String: Any], _ key: String, max: Int) throws -> String {
        guard let text = (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw ToolError("缺少 \(key)")
        }
        guard text.count <= max else { throw ToolError("\(key) 最多 \(max) 个字") }
        return text
    }

    private static func optionalText(_ args: [String: Any], _ key: String, max: Int) throws -> String? {
        guard let value = args[key], !(value is NSNull) else { return nil }
        guard let text = value as? String else { throw ToolError("\(key) 必须是文字") }
        guard text.count <= max else { throw ToolError("\(key) 最多 \(max) 个字") }
        return text.isEmpty ? nil : text
    }

    private static func messageList(_ value: Any?) throws -> [String] {
        guard let list = value as? [String] else { throw ToolError("messages 是 1～5 句文字的数组") }
        let messages = list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard (1...5).contains(messages.count) else { throw ToolError("messages 要有 1～5 句") }
        guard messages.allSatisfy({ $0.count <= 200 }) else { throw ToolError("每句 messages 最多 200 个字") }
        return messages
    }

    private static func optionalDay(_ args: [String: Any], _ key: String, _ c: ToolContext) throws -> Date? {
        guard let value = args[key], !(value is NSNull) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = c.calendar
        formatter.timeZone = c.calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let text = value as? String, let date = formatter.date(from: text) else {
            throw ToolError("\(key) 要写成 yyyy-MM-dd，例如 2026-10-30")
        }
        return c.calendar.startOfDay(for: date)
    }

    private static func endOfDay(_ c: ToolContext) -> (Date) -> Date {
        { c.calendar.date(bySettingHour: 23, minute: 59, second: 59, of: $0) ?? $0 }
    }

    private static func optionalPositive(_ args: [String: Any], _ key: String) throws -> Int? {
        guard let value = args[key], !(value is NSNull) else { return nil }
        guard let number = value as? Int, number >= 1 else { throw ToolError("\(key) 是大于 0 的整数") }
        return number
    }

    // MARK: - 输出

    private static func describe(_ r: Reminder, _ c: ToolContext) -> [String: Any] {
        var item: [String: Any] = [
            "id": r.id, "title": r.title, "messages": r.messages, "style": r.style.rawValue, "state": r.state.rawValue,
            "schedule": ScheduleText.describe(r.schedule, calendar: c.calendar),
            "createdBy": ClientNames.display(r.createdBy),
            "next": ReminderPlanner.next(r, after: c.now, count: 3, calendar: c.calendar)
                .map { ScheduleText.fireText($0.scheduledAt, now: c.now, calendar: c.calendar) },
        ]
        if let reason = r.reason { item["reason"] = reason }
        if let status = ScheduleText.status(r, now: c.now, calendar: c.calendar) { item["status"] = status }
        return item
    }

    static func outcomeText(_ outcome: Outcome) -> String {
        switch outcome {
        case .pending: "等用户处理"
        case .notified: "已提醒"
        case .done: "完成"
        case .snoozed: "推迟了"
        case .skipped: "跳过"
        case .missed: "错过"
        }
    }

    static func nowInfo(_ c: ToolContext) -> [String: Any] {
        ["local": stamp(c.now, c),
         "weekday": "周" + ScheduleText.weekdayNames[ReminderPlanner.isoWeekday(c.now, calendar: c.calendar) - 1],
         "timeZone": c.calendar.timeZone.identifier]
    }

    private static func nowText(_ c: ToolContext) -> String {
        "\(stamp(c.now, c)) 周\(ScheduleText.weekdayNames[ReminderPlanner.isoWeekday(c.now, calendar: c.calendar) - 1])（\(c.calendar.timeZone.identifier)）"
    }

    private static func stamp(_ date: Date, _ c: ToolContext) -> String {
        let formatter = DateFormatter()
        formatter.calendar = c.calendar
        formatter.timeZone = c.calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    static func result(_ object: [String: Any], changed: Bool) -> ToolResult {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return ToolResult(text: String(decoding: data, as: UTF8.self), isError: false, changed: changed)
    }
}
