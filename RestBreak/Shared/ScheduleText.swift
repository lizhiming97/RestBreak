import Foundation

/// 把时间安排和时刻转成中文说法（App 界面和给 AI 的结果共用）
enum ScheduleText {
    static let weekdayNames = ["一", "二", "三", "四", "五", "六", "日"]

    static func describe(_ schedule: Schedule, calendar: Calendar) -> String {
        switch schedule {
        case .once(let at):
            return dateTime(at, calendar: calendar)
        case .daily(let times, let weekdays):
            return "\(days(weekdays)) \(join(times))"
        case .interval(let every, let from, let to, let weekdays):
            return "\(days(weekdays)) \(from)–\(to) 每 \(minutes(every))"
        case .monthly(let ds, let times):
            return "每月 \(ds.sorted().map { "\($0) 号" }.joined(separator: "、")) \(join(times))"
        case .yearly(let month, let day, let times, let leadDays):
            let lead = leadDays.isEmpty ? "" : "（提前 \(leadDays.sorted(by: >).map(String.init).joined(separator: "、")) 天预告）"
            return "每年 \(month) 月 \(day) 日 \(join(times))\(lead)"
        }
    }

    static func days(_ weekdays: [Int]) -> String {
        let set = Set(weekdays)
        if set.isEmpty || set.count == 7 { return "每天" }
        if set == Set(1...5) { return "工作日" }
        if set == [6, 7] { return "周末" }
        return "每周" + set.sorted().map { weekdayNames[$0 - 1] }.joined(separator: "、")
    }

    static func minutes(_ m: Int) -> String {
        if m % 60 == 0 { return "\(m / 60) 小时" }
        return m > 60 ? "\(m / 60) 小时 \(m % 60) 分钟" : "\(m) 分钟"
    }

    static func join(_ times: [ClockTime]) -> String {
        times.sorted().map(\.description).joined(separator: "、")
    }

    /// "10 月 24 日 周六 18:30"
    static func dateTime(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        let weekday = weekdayNames[ReminderPlanner.isoWeekday(date, calendar: calendar) - 1]
        return "\(c.month!) 月 \(c.day!) 日 周\(weekday) " + String(format: "%02d:%02d", c.hour!, c.minute!)
    }

    /// "今天 21:00" / "明天 09:00" / "10 月 26 日 周一 09:00"
    static func fireText(_ date: Date, now: Date, calendar: Calendar) -> String {
        let time = String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date))
        if calendar.isDate(date, inSameDayAs: now) { return "今天 \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "明天 \(time)"
        }
        return dateTime(date, calendar: calendar)
    }

    /// 列表里的补充说明：「已暂停」「已结束」「还剩 N 次」「还剩 N 天」
    static func status(_ r: Reminder, now: Date, calendar: Calendar) -> String? {
        switch r.state {
        case .paused: return "已暂停"
        case .finished: return "已结束"
        case .active: break
        }
        if r.maxOccurrences != nil {
            let horizon = calendar.date(byAdding: .day, value: ReminderPlanner.horizonDays, to: now) ?? now
            return "还剩 \(ReminderPlanner.fires(r, from: now, to: horizon, calendar: calendar).count) 次"
        }
        if let end = r.endDate,
           let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: end)).day {
            return "还剩 \(days + 1) 天"
        }
        return nil
    }

    /// "刚刚" / "3 分钟前" / "3 小时前" / "2 天前"
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) 小时前" }
        return "\(Int(seconds / 86400)) 天前"
    }
}

/// MCP 客户端名 → 给人看的名字
enum ClientNames {
    static func display(_ name: String) -> String {
        switch name {
        case "claude-code": "Claude Code"
        case "codex-mcp-client": "Codex"
        case "claude-ai": "Claude"
        default: name
        }
    }
}
