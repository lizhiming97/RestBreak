import Foundation

/// 时间相关的文字格式化和小工具，只依赖 Foundation，方便测试。
enum TimeText {
    /// 菜单栏上的倒计时："32分"；不到 1 分钟时显示 "45秒"。
    /// 用向上取整，保证 31 分 01 秒显示成 "32分" 而不是 "31分"。
    static func menuBarCountdown(_ remaining: TimeInterval) -> String {
        let seconds = max(0, remaining)
        if seconds >= 60 {
            return "\(Int((seconds / 60).rounded(.up)))分"
        }
        return "\(Int(seconds.rounded(.up)))秒"
    }

    /// 菜单里的相对时间："12 分钟后" / "45 秒后"
    static func relative(_ remaining: TimeInterval) -> String {
        let seconds = max(0, remaining)
        if seconds >= 60 {
            return "\(Int((seconds / 60).rounded(.up))) 分钟后"
        }
        return "\(Int(seconds.rounded(.up))) 秒后"
    }

    /// 休息遮罩上的倒计时："4:59"
    static func clock(_ remaining: TimeInterval) -> String {
        let total = Int(max(0, remaining).rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// 时刻："14:32"
    static func hourMinute(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// 「暂停到明早」用：下一个早上 8 点（凌晨时就是当天 8 点）
    static func nextMorning(after now: Date, hour: Int = 8, calendar: Calendar = .current) -> Date {
        let todayMorning = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
        if todayMorning > now { return todayMorning }
        return calendar.date(byAdding: .day, value: 1, to: todayMorning) ?? now.addingTimeInterval(86_400)
    }
}
