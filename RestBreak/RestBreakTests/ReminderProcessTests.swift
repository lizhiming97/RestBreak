import Foundation
import Testing
@testable import RestBreak

/// 主 App 每 30 秒一次的处理：到点、错过、强提醒再提醒、自动结束、通知 AI 新建的提醒
struct ReminderProcessTests {
    let cal = RT.calendar

    func data(_ reminders: [Reminder], checkedAt: String?) -> ReminderData {
        var d = ReminderData()
        d.reminders = reminders
        d.checkedAt = checkedAt.map(RT.d)
        return d
    }

    @Test func 第一次运行不补以前的() {
        var d = data([RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []))], checkedAt: nil)
        let report = ReminderPlanner.process(&d, now: RT.d("2026-10-23 10:00"), calendar: cal)
        #expect(d.occurrences.isEmpty && report.cards.isEmpty)
        #expect(d.checkedAt == RT.d("2026-10-23 10:00"))
    }

    @Test func 准时_普通提醒记为已提醒() {
        var d = data([RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []))], checkedAt: "2026-10-23 08:59")
        let report = ReminderPlanner.process(&d, now: RT.d("2026-10-23 09:00"), calendar: cal)
        #expect(d.occurrences.map(\.outcome) == [.notified])
        #expect(report.cards.isEmpty)
        #expect(report.rings.map(\.scheduledAt) == [RT.d("2026-10-23 09:00")])
    }

    @Test func 准时_强提醒弹卡片() {
        var d = data([RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []), style: .firm)], checkedAt: "2026-10-23 08:59")
        let report = ReminderPlanner.process(&d, now: RT.d("2026-10-23 09:00"), calendar: cal)
        #expect(d.occurrences.map(\.outcome) == [.pending])
        #expect(report.cards.map(\.scheduledAt) == [RT.d("2026-10-23 09:00")])
    }

    @Test func 晚了两小时_记为错过并汇总() {
        var d = data([RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []))], checkedAt: "2026-10-23 08:00")
        let report = ReminderPlanner.process(&d, now: RT.d("2026-10-23 11:00"), calendar: cal)
        #expect(d.occurrences.map(\.outcome) == [.missed])
        #expect(report.lateTitles == ["吃药"])
        #expect(report.rings.isEmpty)
    }

    @Test func 晚了超过12小时_只记录不汇总() {
        var d = data([RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []))], checkedAt: "2026-10-23 08:00")
        let report = ReminderPlanner.process(&d, now: RT.d("2026-10-23 21:30"), calendar: cal)
        #expect(d.occurrences.map(\.outcome) == [.missed])
        #expect(report.lateTitles.isEmpty)
    }

    @Test func 强提醒没处理_每10分钟再提醒_3次后记为错过() {
        var d = data([RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []), style: .firm)], checkedAt: "2026-10-23 08:59")
        _ = ReminderPlanner.process(&d, now: RT.d("2026-10-23 09:00"), calendar: cal)
        var nagTimes: [String] = []
        var expiredAt: String?
        for minute in 1...45 {
            let now = "2026-10-23 09:\(String(format: "%02d", minute))"
            let report = ReminderPlanner.process(&d, now: RT.d(now), calendar: cal)
            if !report.nags.isEmpty { nagTimes.append(now) }
            if !report.expired.isEmpty { expiredAt = now }
        }
        #expect(nagTimes == ["2026-10-23 09:10", "2026-10-23 09:20", "2026-10-23 09:30"])
        #expect(expiredAt == "2026-10-23 09:40")
        #expect(d.occurrences.map(\.outcome) == [.missed])
    }

    @Test func 推迟后到点再弹() {
        var d = data([RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []), style: .firm)], checkedAt: "2026-10-23 08:59")
        _ = ReminderPlanner.process(&d, now: RT.d("2026-10-23 09:00"), calendar: cal)
        d.setOutcome("r1", scheduledAt: RT.d("2026-10-23 09:00"), .snoozed, now: RT.d("2026-10-23 09:01"),
                     snoozedUntil: RT.d("2026-10-23 09:11"))
        #expect(ReminderPlanner.process(&d, now: RT.d("2026-10-23 09:10"), calendar: cal).cards.isEmpty)
        let report = ReminderPlanner.process(&d, now: RT.d("2026-10-23 09:11"), calendar: cal)
        #expect(report.cards.map(\.ringAt) == [RT.d("2026-10-23 09:11")])
        #expect(d.occurrences.map(\.outcome) == [.pending])
    }

    @Test func 一次性响过后结束() {
        var d = data([RT.reminder(.once(at: RT.d("2026-10-23 09:00")))], checkedAt: "2026-10-23 08:59")
        _ = ReminderPlanner.process(&d, now: RT.d("2026-10-23 09:00"), calendar: cal)
        #expect(d.reminders[0].state == .finished)
        #expect(d.occurrences.map(\.outcome) == [.notified])
    }

    @Test func AI新建的提醒只通知一次_手动建的不通知() {
        var ai = RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []), id: "a")
        ai.announced = false
        var manual = RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []), id: "m", createdBy: ReminderTools.manualClient)
        manual.announced = false
        var d = data([ai, manual], checkedAt: "2026-10-23 08:00")
        #expect(ReminderPlanner.process(&d, now: RT.d("2026-10-23 08:01"), calendar: cal).created.map(\.id) == ["a"])
        #expect(ReminderPlanner.process(&d, now: RT.d("2026-10-23 08:02"), calendar: cal).created.isEmpty)
        #expect(d.reminders.allSatisfy { $0.announced })
    }

    @Test func 登记系统通知_跳过已处理_带上推迟的_最多limit条() {
        var d = data([RT.reminder(.interval(everyMinutes: 15, from: RT.t("00:00"), to: RT.t("23:45"), weekdays: []))],
                     checkedAt: "2026-10-23 08:00")
        d.setOutcome("r1", scheduledAt: RT.d("2026-10-23 08:15"), .done, now: RT.d("2026-10-23 08:01"))
        d.setOutcome("r1", scheduledAt: RT.d("2026-10-23 07:45"), .snoozed, now: RT.d("2026-10-23 07:50"),
                     snoozedUntil: RT.d("2026-10-23 08:20"))
        let plan = ReminderPlanner.plan(d, from: RT.d("2026-10-23 08:01"), days: 7, limit: 50, calendar: cal)
        #expect(plan.count == 50)
        #expect(!plan.contains { $0.scheduledAt == RT.d("2026-10-23 08:15") })
        #expect(plan.contains { $0.ringAt == RT.d("2026-10-23 08:20") && $0.scheduledAt == RT.d("2026-10-23 07:45") })
        #expect(plan == plan.sorted { $0.ringAt < $1.ringAt })
    }

    @Test func 清理90天前的记录() {
        var d = ReminderData()
        d.setOutcome("r1", scheduledAt: RT.d("2026-07-01 09:00"), .done, now: RT.d("2026-07-01 09:00"))
        d.setOutcome("r1", scheduledAt: RT.d("2026-10-01 09:00"), .done, now: RT.d("2026-10-01 09:00"))
        ReminderPlanner.prune(&d, now: RT.d("2026-10-23 09:00"))
        #expect(d.occurrences.map(\.scheduledAt) == [RT.d("2026-10-01 09:00")])
    }

    @Test func 合盖醒来后再提醒不会连发() {
        var d = data([RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []), style: .firm)], checkedAt: "2026-10-23 08:59")
        _ = ReminderPlanner.process(&d, now: RT.d("2026-10-23 09:00"), calendar: cal)
        // 9:00 之后合盖，9:25 才醒：只补一次再提醒，下一次要再等 10 分钟
        #expect(ReminderPlanner.process(&d, now: RT.d("2026-10-23 09:25"), calendar: cal).nags.count == 1)
        #expect(ReminderPlanner.process(&d, now: RT.d("2026-10-23 09:26"), calendar: cal).nags.isEmpty)
        #expect(ReminderPlanner.process(&d, now: RT.d("2026-10-23 09:35"), calendar: cal).nags.count == 1)
    }
}
