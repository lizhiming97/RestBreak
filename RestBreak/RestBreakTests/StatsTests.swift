import Foundation
import Testing
@testable import RestBreak

/// 休息统计：按天记录完成 / 跳过 / 推迟次数、累计休息时长、最长连续工作时长
struct StatsTests {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()
    /// 2026-10-20 09:00（北京时间）
    var morning: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 9))! }

    func minutes(_ m: Double) -> TimeInterval { m * 60 }
    func session(_ kind: BreakKind, at start: Date) -> BreakSession {
        let duration = AppSettings.default[kind].duration
        return BreakSession(kind: kind, startedAt: start, endsAt: start + duration, postponeCount: 0)
    }

    @Test func 记录完成跳过推迟和休息时长() {
        var r = StatsRecorder(calendar: calendar)
        let t = morning
        r.record(.breakStarted(session(.micro, at: t)), now: t)
        r.record(.breakEnded(.micro, .completed), now: t + 20)
        r.record(.breakStarted(session(.long, at: t + minutes(30))), now: t + minutes(30))
        r.record(.breakEnded(.long, .postponed), now: t + minutes(30) + 10)
        r.record(.breakStarted(session(.long, at: t + minutes(35))), now: t + minutes(35))
        r.record(.breakEnded(.long, .skipped), now: t + minutes(35) + 5)
        r.record(.naturalBreakDetected(awayDuration: minutes(12), completed: [.micro, .long]), now: t + minutes(60))

        let day = r.day(for: t)
        #expect(day.completed == 1)
        #expect(day.skipped == 1)
        #expect(day.postponed == 1)
        #expect(day.naturalBreaks == 1)
        // 完成的微休息 20 秒 + 自然休息 12 分钟
        #expect(day.restSeconds == 20 + minutes(12))
        #expect(day.completionRate == 0.5)
    }

    @Test func 被打断的休息不计入完成或跳过() {
        var r = StatsRecorder(calendar: calendar)
        r.record(.breakStarted(session(.micro, at: morning)), now: morning)
        r.record(.breakEnded(.micro, .meetingStarted), now: morning + 5)
        r.record(.breakStarted(session(.micro, at: morning + 60)), now: morning + 60)
        r.record(.breakEnded(.micro, .interrupted), now: morning + 65)
        let day = r.day(for: morning)
        #expect(day.completed == 0 && day.skipped == 0)
        #expect(day.completionRate == nil)
    }

    @Test func 最长连续工作_休息完成或离开后重新计算() {
        var r = StatsRecorder(calendar: calendar)
        var now = morning
        // 工作 50 分钟 → 完成一次休息 → 再工作 30 分钟
        while now < morning + minutes(50) { r.tick(now: now, isWorking: true); now += 1 }
        r.record(.breakStarted(session(.micro, at: now)), now: now)
        r.record(.breakEnded(.micro, .completed), now: now + 20)
        now += 20
        let resumed = now
        while now < resumed + minutes(30) { r.tick(now: now, isWorking: true); now += 1 }
        #expect(abs(r.day(for: morning).longestWorkStretch - minutes(50)) <= 1)

        // 跳过的休息不算休息：再工作 40 分钟中间跳过一次 → 连续 70 分钟
        r.record(.breakStarted(session(.micro, at: now)), now: now)
        r.record(.breakEnded(.micro, .skipped), now: now + 2)
        let afterSkip = now
        while now < afterSkip + minutes(40) { r.tick(now: now, isWorking: true); now += 1 }
        #expect(abs(r.day(for: morning).longestWorkStretch - minutes(70)) <= 2)
    }

    @Test func 暂停和离开时不计入连续工作() {
        var r = StatsRecorder(calendar: calendar)
        var now = morning
        while now < morning + minutes(10) { r.tick(now: now, isWorking: true); now += 1 }
        while now < morning + minutes(100) { r.tick(now: now, isWorking: false); now += 1 }
        while now < morning + minutes(110) { r.tick(now: now, isWorking: true); now += 1 }
        #expect(abs(r.day(for: morning).longestWorkStretch - minutes(10)) <= 1)
    }

    @Test func 跨过午夜按新的一天记录() {
        var r = StatsRecorder(calendar: calendar)
        let night = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 23, minute: 59))!
        r.record(.breakStarted(session(.micro, at: night)), now: night)
        r.record(.breakEnded(.micro, .completed), now: night + 20)
        r.record(.breakStarted(session(.micro, at: night + 90)), now: night + 90)
        r.record(.breakEnded(.micro, .completed), now: night + 110)
        #expect(r.day(for: night).completed == 1)
        #expect(r.day(for: night + 120).completed == 1)
    }

    @Test func 最近N天_没有记录的日子补零_只保留90天() {
        var r = StatsRecorder(calendar: calendar)
        r.record(.breakStarted(session(.micro, at: morning)), now: morning)
        r.record(.breakEnded(.micro, .completed), now: morning + 20)
        let week = r.lastDays(7, endingAt: morning)
        #expect(week.count == 7)
        #expect(week.last?.completed == 1)
        #expect(week.first?.completed == 0)

        let later = morning + 100 * 86_400
        r.record(.breakStarted(session(.micro, at: later)), now: later)
        r.record(.breakEnded(.micro, .completed), now: later + 20)
        #expect(r.days.count == 1)
    }

    @Test func 统计数据能保存和读取() throws {
        var r = StatsRecorder(calendar: calendar)
        r.record(.breakStarted(session(.micro, at: morning)), now: morning)
        r.record(.breakEnded(.micro, .completed), now: morning + 20)
        let data = try JSONEncoder().encode(r.days)
        let loaded = StatsRecorder(days: try JSONDecoder().decode([String: DayStats].self, from: data), calendar: calendar)
        #expect(loaded.day(for: morning) == r.day(for: morning))
    }
}
