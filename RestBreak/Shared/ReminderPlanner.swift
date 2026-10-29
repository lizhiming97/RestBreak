import Foundation

/// 某条提醒的一次响铃。scheduledAt 是按时间安排「本该响」的时刻（也是记录用的键），
/// ringAt 是实际要响的时刻：平时两者相同，「10 分钟后」再响时 ringAt 更晚
struct Fire: Equatable, Hashable, Sendable {
    var reminderID: String
    var scheduledAt: Date
    var ringAt: Date
    /// 提前几天的预告（只有每年的提醒有），0 = 当天
    var leadDays: Int

    init(reminderID: String, date: Date, leadDays: Int = 0) {
        self.init(reminderID: reminderID, scheduledAt: date, ringAt: date, leadDays: leadDays)
    }

    init(reminderID: String, scheduledAt: Date, ringAt: Date, leadDays: Int) {
        self.reminderID = reminderID
        self.scheduledAt = scheduledAt
        self.ringAt = ringAt
        self.leadDays = leadDays
    }
}

/// 提醒的排期规则（纯逻辑，方便测试）
enum ReminderPlanner {
    /// 最多往后看多少天
    static let horizonDays = 400

    /// 只按时间安排算 [start, end) 里的响铃，不看状态和次数上限；达到 limit 条就停
    static func rawFires(_ r: Reminder, from start: Date, to end: Date, calendar: Calendar,
                         limit: Int = .max) -> [Fire] {
        guard start < end, limit > 0 else { return [] }
        if case .once(let at) = r.schedule {
            return at >= start && at < end ? [Fire(reminderID: r.id, date: at)] : []
        }
        var result: [Fire] = []
        var day = calendar.startOfDay(for: start)
        var steps = 0
        // 天数上限按 [start, end) 算：数次数时 start 是建立时间，可能远早于现在
        let maxSteps = Int(end.timeIntervalSince(start) / 86400) + 2
        while day < end && steps < maxSteps && result.count < limit {
            let today = times(on: day, schedule: r.schedule, calendar: calendar).compactMap { time, lead -> Fire? in
                guard let date = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day),
                      date >= start, date < end else { return nil }
                return Fire(reminderID: r.id, date: date, leadDays: lead)
            }
            result += today.sorted { $0.scheduledAt < $1.scheduledAt }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
            steps += 1
        }
        return Array(result.prefix(limit))
    }

    /// 某一天要响的时刻，以及每个时刻是提前几天的预告
    static func times(on day: Date, schedule: Schedule, calendar: Calendar) -> [(ClockTime, Int)] {
        switch schedule {
        case .once:
            return []
        case .daily(let times, let weekdays):
            guard matches(day, weekdays: weekdays, calendar: calendar) else { return [] }
            return times.map { ($0, 0) }
        case .interval(let every, let from, let to, let weekdays):
            guard every > 0, from <= to, matches(day, weekdays: weekdays, calendar: calendar) else { return [] }
            return stride(from: from.minutes, through: to.minutes, by: every).compactMap {
                ClockTime(hour: $0 / 60, minute: $0 % 60).map { ($0, 0) }
            }
        case .monthly(let days, let times):
            let dayOfMonth = calendar.component(.day, from: day)
            let lastDay = calendar.range(of: .day, in: .month, for: day)?.count ?? 31
            guard Set(days.map { min($0, lastDay) }).contains(dayOfMonth) else { return [] }
            return times.map { ($0, 0) }
        case .yearly(let month, let dayOfMonth, let times, let leadDays):
            var result: [(ClockTime, Int)] = []
            for lead in Set([0] + leadDays.filter { $0 > 0 }) {
                guard let target = calendar.date(byAdding: .day, value: lead, to: day),
                      isAnniversary(target, month: month, day: dayOfMonth, calendar: calendar) else { continue }
                result += times.map { ($0, lead) }
            }
            return result
        }
    }

    /// 1 = 周一 … 7 = 周日（系统的 weekday 是 1 = 周日）
    static func isoWeekday(_ date: Date, calendar: Calendar) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7 + 1
    }

    private static func matches(_ day: Date, weekdays: [Int], calendar: Calendar) -> Bool {
        weekdays.isEmpty || weekdays.contains(isoWeekday(day, calendar: calendar))
    }

    /// 是不是每年的那一天；2 月 29 日在平年算 2 月 28 日
    private static func isAnniversary(_ date: Date, month: Int, day: Int, calendar: Calendar) -> Bool {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        guard c.month == month else { return false }
        if month == 2 && day == 29, let year = c.year,
           !(year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) {
            return c.day == 28
        }
        return c.day == day
    }

    /// 考虑状态、开始 / 结束日期、次数上限之后，[start, end) 里真正要响的
    static func fires(_ r: Reminder, from start: Date, to end: Date, calendar: Calendar,
                      limit: Int = .max) -> [Fire] {
        guard r.state == .active else { return [] }
        // 从「开始日期」和「建立时间」里较晚的那个算起，建之前的时刻不响、也不计入次数
        let origin = max(r.startDate ?? r.createdAt, r.createdAt)
        let upper = r.endDate.map { min(end, $0.addingTimeInterval(1)) } ?? end
        guard let maxCount = r.maxOccurrences else {
            return rawFires(r, from: max(start, origin), to: upper, calendar: calendar, limit: limit)
        }
        let all = rawFires(r, from: origin, to: upper, calendar: calendar, limit: maxCount)
        return Array(all.filter { $0.scheduledAt >= start }.prefix(limit))
    }

    /// now 之后的 count 次
    static func next(_ r: Reminder, after now: Date, count: Int, calendar: Calendar) -> [Fire] {
        let horizon = calendar.date(byAdding: .day, value: horizonDays, to: now) ?? now
        return fires(r, from: now.addingTimeInterval(0.001), to: horizon, calendar: calendar, limit: count)
    }

    /// 以后再也不会响了（过了结束日期、响满次数、一次性的已经过了）
    static func shouldFinish(_ r: Reminder, now: Date, calendar: Calendar) -> Bool {
        r.state == .active && next(r, after: now, count: 1, calendar: calendar).isEmpty
    }

    /// 第 ordinal 次响铃用哪句文案；提前预告前面加「还有 N 天：」
    static func message(_ r: Reminder, fire: Fire, ordinal: Int) -> String {
        let base = r.messages.isEmpty ? r.title : r.messages[abs(ordinal) % r.messages.count]
        return fire.leadDays > 0 ? "还有 \(fire.leadDays) 天：\(base)" : base
    }
}
/// 到点的一次响铃，以及晚了多久
struct DueFire: Equatable, Sendable {
    var fire: Fire
    var isSnooze: Bool
    var lateness: TimeInterval
}

/// 一次处理之后，主 App 要做的事
struct ProcessReport: Equatable, Sendable {
    /// 准时到点的普通提醒（灵动岛展开一会儿就收起）
    var rings: [Fire] = []
    /// 要弹卡片的强提醒
    var cards: [Fire] = []
    /// 要再提醒一次的强提醒（横幅）
    var nags: [Fire] = []
    /// 再提醒 3 次仍没处理、已记为错过：卡片收掉
    var expired: [Fire] = []
    /// 合盖、关机期间错过的（5 分钟～12 小时），合成一条汇总通知
    var lateTitles: [String] = []
    /// AI 新建、还没告诉用户的提醒
    var created: [Reminder] = []
}

extension ReminderPlanner {
    /// 晚了 5 分钟以内算准时
    static let onTimeWindow: TimeInterval = 5 * 60
    /// 晚了 12 小时以上只记录、不再告诉用户
    static let maxLateness: TimeInterval = 12 * 3600
    static let nagInterval: TimeInterval = 10 * 60
    static let maxNags = 3
    static let keepDays = 90

    /// (checkedAt, now] 里到点、还没有记录的响铃（含「10 分钟后」再响的）
    static func due(_ data: ReminderData, now: Date, calendar: Calendar) -> [DueFire] {
        guard let since = data.checkedAt, since < now else { return [] }
        let handled = Set(data.occurrences.map { Key($0.reminderID, $0.scheduledAt) })
        var result: [DueFire] = []
        for r in data.reminders {
            for fire in fires(r, from: since.addingTimeInterval(0.001), to: now.addingTimeInterval(0.001), calendar: calendar)
            where !handled.contains(Key(fire.reminderID, fire.scheduledAt)) {
                result.append(DueFire(fire: fire, isSnooze: false, lateness: now.timeIntervalSince(fire.ringAt)))
            }
        }
        for o in data.occurrences where o.outcome == .snoozed {
            guard let until = o.snoozedUntil, until > since, until <= now else { continue }
            let fire = Fire(reminderID: o.reminderID, scheduledAt: o.scheduledAt, ringAt: until, leadDays: o.leadDays)
            result.append(DueFire(fire: fire, isSnooze: true, lateness: now.timeIntervalSince(until)))
        }
        return result.sorted { $0.fire.ringAt < $1.fire.ringAt }
    }

    /// 接下来 days 天要登记成系统定时通知的响铃（跳过已处理的，带上推迟的），按时间排序最多 limit 条
    static func plan(_ data: ReminderData, from now: Date, days: Int, limit: Int, calendar: Calendar) -> [Fire] {
        let end = calendar.date(byAdding: .day, value: days, to: now) ?? now
        let handled = Set(data.occurrences.map { Key($0.reminderID, $0.scheduledAt) })
        var all = data.reminders.flatMap { fires($0, from: now, to: end, calendar: calendar, limit: limit) }
            .filter { !handled.contains(Key($0.reminderID, $0.scheduledAt)) }
        all += data.occurrences.compactMap { o in
            guard o.outcome == .snoozed, let until = o.snoozedUntil, until > now, until < end,
                  data.reminder(o.reminderID) != nil else { return nil }
            return Fire(reminderID: o.reminderID, scheduledAt: o.scheduledAt, ringAt: until, leadDays: o.leadDays)
        }
        return Array(all.sorted { $0.ringAt < $1.ringAt }.prefix(limit))
    }

    static func prune(_ data: inout ReminderData, now: Date) {
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86400)
        data.occurrences.removeAll { $0.scheduledAt < cutoff }
    }

    /// 主 App 每次处理都调用这一个函数（在文件锁里）。顺序：到点 → 再提醒 → 结束 → 通知新建 → 清理
    static func process(_ data: inout ReminderData, now: Date, calendar: Calendar) -> ProcessReport {
        var report = ProcessReport()
        if data.checkedAt == nil { data.checkedAt = now }   // 第一次运行：不补以前的

        for due in due(data, now: now, calendar: calendar) {
            let fire = due.fire
            guard let r = data.reminder(fire.reminderID) else { continue }
            let snoozedUntil = due.isSnooze ? fire.ringAt : nil
            if due.lateness > maxLateness {
                data.setOutcome(r.id, scheduledAt: fire.scheduledAt, leadDays: fire.leadDays, .missed, now: now)
            } else if due.lateness > onTimeWindow {
                data.setOutcome(r.id, scheduledAt: fire.scheduledAt, leadDays: fire.leadDays, .missed, now: now)
                report.lateTitles.append(r.title)
            } else if r.style == .firm {
                data.setOutcome(r.id, scheduledAt: fire.scheduledAt, leadDays: fire.leadDays, .pending,
                                now: now, snoozedUntil: snoozedUntil)
                if let i = data.occurrences.firstIndex(where: { $0.reminderID == r.id && $0.scheduledAt == fire.scheduledAt }) {
                    data.occurrences[i].nagCount = 0
                }
                report.cards.append(fire)
            } else {
                data.setOutcome(r.id, scheduledAt: fire.scheduledAt, leadDays: fire.leadDays, .notified, now: now)
                report.rings.append(fire)
            }
        }

        // 强提醒没处理：每 10 分钟再提醒一次，3 次之后（第 40 分钟）记为错过
        for i in data.occurrences.indices where data.occurrences[i].outcome == .pending {
            let o = data.occurrences[i]
            let base = o.snoozedUntil ?? o.scheduledAt
            let fire = Fire(reminderID: o.reminderID, scheduledAt: o.scheduledAt, ringAt: now, leadDays: o.leadDays)
            let elapsed = now.timeIntervalSince(base)
            if elapsed >= nagInterval * Double(maxNags + 1) {
                data.occurrences[i].outcome = .missed
                data.occurrences[i].actedAt = now
                report.expired.append(fire)
            } else if o.nagCount < maxNags, elapsed >= nagInterval * Double(o.nagCount + 1),
                      now.timeIntervalSince(o.actedAt ?? base) >= nagInterval {
                data.occurrences[i].nagCount += 1
                data.occurrences[i].actedAt = now
                report.nags.append(fire)
            }
        }

        for i in data.reminders.indices where shouldFinish(data.reminders[i], now: now, calendar: calendar) {
            data.reminders[i].state = .finished
            data.reminders[i].updatedAt = now
        }
        for i in data.reminders.indices where !data.reminders[i].announced {
            data.reminders[i].announced = true
            if data.reminders[i].createdBy != ReminderTools.manualClient { report.created.append(data.reminders[i]) }
        }
        prune(&data, now: now)
        data.checkedAt = now
        return report
    }

    private struct Key: Hashable {
        let id: String
        let at: Date
        init(_ id: String, _ at: Date) { self.id = id; self.at = at }
    }
}
