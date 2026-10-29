import Foundation

/// 一天里的某个时刻（本地时间），存成 "09:00"
struct ClockTime: Hashable, Comparable, Sendable, CustomStringConvertible {
    var hour: Int
    var minute: Int

    init?(hour: Int, minute: Int) {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }

    /// 接受 "9:00"、"09:00"
    init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        self.init(hour: h, minute: m)
    }

    var minutes: Int { hour * 60 + minute }
    var description: String { String(format: "%02d:%02d", hour, minute) }
    static func < (a: ClockTime, b: ClockTime) -> Bool { a.minutes < b.minutes }
}

extension ClockTime: Codable {
    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = ClockTime(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "时刻格式不对：\(text)"))
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// 什么时候响。星期用 1 = 周一 … 7 = 周日，空数组 = 每天
enum Schedule: Equatable, Sendable {
    case once(at: Date)
    case daily(times: [ClockTime], weekdays: [Int])
    /// 每隔 everyMinutes 分钟，从 from 到 to（含 to，如果正好落在上面）
    case interval(everyMinutes: Int, from: ClockTime, to: ClockTime, weekdays: [Int])
    /// 31 号在小月改成当月最后一天
    case monthly(days: [Int], times: [ClockTime])
    /// 2 月 29 日在平年改成 2 月 28 日；leadDays：提前几天也预告一次
    case yearly(month: Int, day: Int, times: [ClockTime], leadDays: [Int])

    var kind: String {
        switch self {
        case .once: "once"
        case .daily: "daily"
        case .interval: "interval"
        case .monthly: "monthly"
        case .yearly: "yearly"
        }
    }
}

extension Schedule: Codable {
    private enum Key: String, CodingKey {
        case kind, at, times, weekdays, everyMinutes, from, to, days, month, day, leadDays
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "once":
            self = .once(at: try c.decode(Date.self, forKey: .at))
        case "daily":
            self = .daily(times: try c.decode([ClockTime].self, forKey: .times),
                          weekdays: try c.decodeIfPresent([Int].self, forKey: .weekdays) ?? [])
        case "interval":
            self = .interval(everyMinutes: try c.decode(Int.self, forKey: .everyMinutes),
                             from: try c.decode(ClockTime.self, forKey: .from),
                             to: try c.decode(ClockTime.self, forKey: .to),
                             weekdays: try c.decodeIfPresent([Int].self, forKey: .weekdays) ?? [])
        case "monthly":
            self = .monthly(days: try c.decode([Int].self, forKey: .days),
                            times: try c.decode([ClockTime].self, forKey: .times))
        case "yearly":
            self = .yearly(month: try c.decode(Int.self, forKey: .month),
                           day: try c.decode(Int.self, forKey: .day),
                           times: try c.decode([ClockTime].self, forKey: .times),
                           leadDays: try c.decodeIfPresent([Int].self, forKey: .leadDays) ?? [])
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "不认识的 kind：\(kind)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .once(let at):
            try c.encode(at, forKey: .at)
        case .daily(let times, let weekdays):
            try c.encode(times, forKey: .times)
            try c.encode(weekdays, forKey: .weekdays)
        case .interval(let every, let from, let to, let weekdays):
            try c.encode(every, forKey: .everyMinutes)
            try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to)
            try c.encode(weekdays, forKey: .weekdays)
        case .monthly(let days, let times):
            try c.encode(days, forKey: .days)
            try c.encode(times, forKey: .times)
        case .yearly(let month, let day, let times, let leadDays):
            try c.encode(month, forKey: .month)
            try c.encode(day, forKey: .day)
            try c.encode(times, forKey: .times)
            try c.encode(leadDays, forKey: .leadDays)
        }
    }
}

/// gentle：只弹横幅；firm：横幅 + 处理了才消失的卡片，没处理会再提醒
enum ReminderStyle: String, Codable, Sendable { case gentle, firm }

/// finished：过了结束日期、响满次数、一次性提醒已经响过
enum ReminderState: String, Codable, Sendable { case active, paused, finished }

struct Reminder: Codable, Identifiable, Equatable, Sendable {
    /// 6 位短 id，方便 AI 引用
    var id: String
    var title: String
    /// 每次响铃轮换使用的文案（AI 按用户语气写）
    var messages: [String]
    var schedule: Schedule
    var style: ReminderStyle
    /// 为什么建这个提醒，显示在 App 里
    var reason: String?
    /// 建它的客户端名（MCP clientInfo.name）
    var createdBy: String
    var createdAt: Date
    var updatedAt: Date
    var startDate: Date?
    /// 结束时刻（含）：AI 给的日期会换成那一天的 23:59:59
    var endDate: Date?
    var maxOccurrences: Int?
    var state: ReminderState
    /// 主 App 已经弹过「AI 帮你建了提醒」
    var announced: Bool
}

/// 一次响铃的结果。pending：强提醒的卡片还没处理
enum Outcome: String, Codable, Sendable { case pending, notified, done, snoozed, skipped, missed }

/// 一次响铃的记录，用 (reminderID, scheduledAt) 区分
struct Occurrence: Codable, Equatable, Sendable {
    var reminderID: String
    var scheduledAt: Date
    var leadDays: Int
    var outcome: Outcome
    /// 最后一次改变状态的时间
    var actedAt: Date?
    /// 强提醒已经再次提醒了几次
    var nagCount: Int
    /// 「10 分钟后」再响的时间；再响后保留，作为再次提醒的计时起点
    var snoozedUntil: Date?
}

struct ClientRecord: Codable, Equatable, Sendable {
    var name: String
    var lastSeen: Date
}

/// store.json 的全部内容
struct ReminderData: Codable, Equatable, Sendable {
    static let currentSchema = 3

    var schemaVersion = ReminderData.currentSchema
    var reminders: [Reminder] = []
    var occurrences: [Occurrence] = []
    var clients: [ClientRecord] = []
    /// 主 App 上次处理到期提醒的时间；它之后到点的还没处理过
    var checkedAt: Date?
    /// 管家：推送记录、打扰设置和关注方向（0.6 起，schema 2；0.7 去掉记事和下班时间，schema 3）
    var butler = ButlerData()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, reminders, occurrences, clients, checkedAt, butler
    }

    /// v1 文件没有 butler：用默认值（编码仍用自动生成的）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        reminders = try c.decode([Reminder].self, forKey: .reminders)
        occurrences = try c.decode([Occurrence].self, forKey: .occurrences)
        clients = try c.decode([ClientRecord].self, forKey: .clients)
        checkedAt = try c.decodeIfPresent(Date.self, forKey: .checkedAt)
        butler = try c.decodeIfPresent(ButlerData.self, forKey: .butler) ?? ButlerData()
        schemaVersion = ReminderData.currentSchema   // 读进来就按当前版本写回
    }

    func reminder(_ id: String) -> Reminder? { reminders.first { $0.id == id } }

    func occurrence(_ id: String, at scheduledAt: Date) -> Occurrence? {
        occurrences.first { $0.reminderID == id && $0.scheduledAt == scheduledAt }
    }

    /// 写一次响铃的结果：已有记录就覆盖，没有就新增
    mutating func setOutcome(_ id: String, scheduledAt: Date, leadDays: Int = 0, _ outcome: Outcome,
                             now: Date, snoozedUntil: Date? = nil) {
        if let i = occurrences.firstIndex(where: { $0.reminderID == id && $0.scheduledAt == scheduledAt }) {
            occurrences[i].outcome = outcome
            occurrences[i].actedAt = now
            if let snoozedUntil { occurrences[i].snoozedUntil = snoozedUntil }
            if outcome == .snoozed { occurrences[i].nagCount = 0 }
        } else {
            occurrences.append(Occurrence(reminderID: id, scheduledAt: scheduledAt, leadDays: leadDays,
                                          outcome: outcome, actedAt: now, nagCount: 0, snoozedUntil: snoozedUntil))
        }
    }

    mutating func recordClient(_ name: String, now: Date) {
        if let i = clients.firstIndex(where: { $0.name == name }) {
            clients[i].lastSeen = now
        } else {
            clients.append(ClientRecord(name: name, lastSeen: now))
        }
    }

    static func newID(existing: Set<String>) -> String {
        let letters = Array("abcdefghjkmnpqrstuvwxyz23456789")
        while true {
            let id = String((0..<6).map { _ in letters.randomElement()! })
            if !existing.contains(id) { return id }
        }
    }
}
