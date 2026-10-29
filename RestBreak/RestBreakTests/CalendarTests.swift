import Foundation
import Testing
@testable import RestBreak

/// 日历排程：日程进行中不弹休息；快到日程时把休息提前，赶在日程开始前休息完
struct CalendarTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 0)
    let settings = AppSettings.default

    func minutes(_ m: Double) -> TimeInterval { m * 60 }
    func event(_ from: Double, _ to: Double) -> DateInterval {
        DateInterval(start: t0 + minutes(from), end: t0 + minutes(to))
    }

    /// 每秒 tick 一次，返回期间所有事件及时间
    func run(_ s: inout BreakScheduler, from start: Date, to end: Date,
             events calendar: [DateInterval], idle: TimeInterval = 0) -> [(Date, SchedulerEvent)] {
        var out: [(Date, SchedulerEvent)] = []
        var now = start
        while now < end {
            for e in s.tick(now: now, idleSeconds: idle, calendarEvents: calendar) { out.append((now, e)) }
            now += 1
        }
        return out
    }

    func starts(_ events: [(Date, SchedulerEvent)]) -> [(Date, BreakKind)] {
        events.compactMap { date, e in
            if case .breakStarted(let s) = e { return (date, s.kind) }
            return nil
        }
    }

    @Test func 日程中到期不弹_日程结束立即弹() {
        var s = BreakScheduler(settings: settings, now: t0)
        // 微休息 20 分到期，在日程开始 15 分钟之后 → 不提前，日程中暂缓
        let cal = [event(2, 40)]
        let out = run(&s, from: t0, to: t0 + minutes(41), events: cal)
        let first = starts(out).first
        #expect(first?.0 == t0 + minutes(40))
        #expect(first?.1 == .micro)
    }

    @Test func 日程中显示状态() {
        var s = BreakScheduler(settings: settings, now: t0)
        _ = s.tick(now: t0 + minutes(15), idleSeconds: 0, calendarEvents: [event(10, 40)])
        #expect(s.isInCalendarEvent)
        #expect(s.nextBreakStart(now: t0 + minutes(15))?.date == t0 + minutes(40))
    }

    @Test func 休息快到时有日程_提前到日程开始前休息完() {
        var s = BreakScheduler(settings: settings, now: t0)
        // 微休息 20 分到期，日程 21 分开始：提前到 21:00 - 20 秒休息 - 1 分钟缓冲 = 19:40 开始
        let out = run(&s, from: t0, to: t0 + minutes(22), events: [event(21, 60)])
        let first = starts(out).first
        #expect(first?.0 == t0 + minutes(19) + 40)
        #expect(first?.1 == .micro)
    }

    @Test func 长休息提前_最多提前15分钟() {
        var s = BreakScheduler(settings: settings, now: t0)
        // 长休息 60 分到期，日程 62 分开始：62 - 5 - 1 = 56 分开始
        let out = run(&s, from: t0, to: t0 + minutes(62), events: [event(62, 90)])
        #expect(starts(out).first { $0.1 == .long }?.0 == t0 + minutes(56))

        // 日程 120 分才开始、休息 60 分到期：离日程太远，不提前，照常 60 分开始
        var s2 = BreakScheduler(settings: settings, now: t0)
        let out2 = run(&s2, from: t0, to: t0 + minutes(61), events: [event(120, 150)])
        #expect(starts(out2).first { $0.1 == .long }?.0 == t0 + minutes(60))
    }

    @Test func 日程开始很久之后才到期的休息_不提前() {
        var s = BreakScheduler(settings: settings, now: t0)
        // 微休息 20 分到期；日程 2～60 分。休息在日程中途到期 → 不提前，日程结束再弹
        let out = run(&s, from: t0, to: t0 + minutes(61), events: [event(2, 60)])
        #expect(starts(out).first?.0 == t0 + minutes(60))
    }

    @Test func 日程中离开电脑仍算自然休息() {
        var s = BreakScheduler(settings: settings, now: t0)
        // 去会议室开线下会：日程中 6 分钟没碰电脑 → 算离开
        _ = s.tick(now: t0 + minutes(16), idleSeconds: minutes(6), calendarEvents: [event(10, 40)])
        #expect(s.state == .away(since: t0 + minutes(10)))
    }

    @Test func 没有日程时不受影响() {
        var s = BreakScheduler(settings: settings, now: t0)
        let out = run(&s, from: t0, to: t0 + minutes(21), events: [])
        #expect(starts(out).first?.0 == t0 + minutes(20))
    }

    @Test func 日历设置能保存和读取() throws {
        var custom = settings
        custom.followCalendar = true
        custom.calendarIDs = ["A", "B"]
        let loaded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(custom))
        #expect(loaded.followCalendar)
        #expect(loaded.calendarIDs == ["A", "B"])
        #expect(!AppSettings.default.followCalendar)
    }
}
