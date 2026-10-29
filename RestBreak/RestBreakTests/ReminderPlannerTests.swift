import Foundation
import Testing
@testable import RestBreak

/// 每种时间安排在一段时间里该响哪些时刻
struct ReminderPlannerTests {
    let cal = RT.calendar

    func dates(_ r: Reminder, _ from: String, _ to: String) -> [Date] {
        ReminderPlanner.fires(r, from: RT.d(from), to: RT.d(to), calendar: cal).map(\.scheduledAt)
    }

    @Test func 每天两次_跨零点() {
        let r = RT.reminder(.daily(times: [RT.t("21:00"), RT.t("09:00")], weekdays: []))
        #expect(dates(r, "2026-10-23 00:00", "2026-10-25 00:00")
                == ["2026-10-23 09:00", "2026-10-23 21:00", "2026-10-24 09:00", "2026-10-24 21:00"].map(RT.d))
    }

    @Test func 建之前的时刻不算() {
        let r = RT.reminder(.daily(times: [RT.t("09:00"), RT.t("21:00")], weekdays: []), created: "2026-10-23 15:00")
        #expect(dates(r, "2026-10-23 00:00", "2026-10-24 00:00") == [RT.d("2026-10-23 21:00")])
    }

    @Test func 只在工作日() {
        // 10-23 周五，24、25 是周末，26 周一
        let r = RT.reminder(.daily(times: [RT.t("10:00")], weekdays: [1, 2, 3, 4, 5]))
        #expect(dates(r, "2026-10-23 00:00", "2026-10-27 00:00") == ["2026-10-23 10:00", "2026-10-26 10:00"].map(RT.d))
    }

    @Test func 每隔90分钟_含结束时刻() {
        let r = RT.reminder(.interval(everyMinutes: 90, from: RT.t("09:00"), to: RT.t("12:00"), weekdays: []))
        #expect(dates(r, "2026-10-23 00:00", "2026-10-24 00:00")
                == ["2026-10-23 09:00", "2026-10-23 10:30", "2026-10-23 12:00"].map(RT.d))
    }

    @Test func 每月31号_小月改成最后一天() {
        let r = RT.reminder(.monthly(days: [31], times: [RT.t("09:00")]))
        #expect(dates(r, "2026-10-23 00:00", "2027-01-01 00:00")
                == ["2026-10-31 09:00", "2026-11-30 09:00", "2026-12-31 09:00"].map(RT.d))
    }

    @Test func 每月30号和31号_小月只响一次() {
        let r = RT.reminder(.monthly(days: [30, 31], times: [RT.t("09:00")]))
        #expect(dates(r, "2026-11-01 00:00", "2026-12-01 00:00") == [RT.d("2026-11-30 09:00")])
    }

    @Test func 每年2月29日_平年改成28日() {
        let r = RT.reminder(.yearly(month: 2, day: 29, times: [RT.t("09:00")], leadDays: []))
        // 每次最多往后看 400 天（horizonDays），所以平年、闰年分两段查
        #expect(dates(r, "2026-10-23 00:00", "2027-10-01 00:00") == [RT.d("2027-02-28 09:00")])
        #expect(dates(r, "2027-10-01 00:00", "2028-10-01 00:00") == [RT.d("2028-02-29 09:00")])
    }

    @Test func 每年_提前预告() {
        let r = RT.reminder(.yearly(month: 11, day: 5, times: [RT.t("09:00")], leadDays: [5]))
        let fires = ReminderPlanner.fires(r, from: RT.d("2026-10-23 00:00"), to: RT.d("2026-12-01 00:00"), calendar: cal)
        #expect(fires.map(\.scheduledAt) == ["2026-10-31 09:00", "2026-11-05 09:00"].map(RT.d))
        #expect(fires.map(\.leadDays) == [5, 0])
    }

    @Test func 每年_提前预告跨年() {
        let r = RT.reminder(.yearly(month: 1, day: 2, times: [RT.t("09:00")], leadDays: [5]))
        #expect(dates(r, "2026-12-01 00:00", "2027-01-03 00:00") == ["2026-12-28 09:00", "2027-01-02 09:00"].map(RT.d))
    }

    @Test func 一次性() {
        let r = RT.reminder(.once(at: RT.d("2026-10-23 18:30")))
        #expect(dates(r, "2026-10-23 00:00", "2026-10-24 00:00") == [RT.d("2026-10-23 18:30")])
        #expect(dates(r, "2026-10-23 18:31", "2026-10-24 00:00").isEmpty)
    }

    @Test func 结束日期当天还响_之后结束() {
        let r = RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []), end: RT.d("2026-10-25 23:59"))
        #expect(dates(r, "2026-10-23 00:00", "2026-10-30 00:00").count == 3)
        #expect(!ReminderPlanner.shouldFinish(r, now: RT.d("2026-10-25 08:00"), calendar: cal))
        #expect(ReminderPlanner.shouldFinish(r, now: RT.d("2026-10-25 10:00"), calendar: cal))
    }

    @Test func 响满次数后结束() {
        let r = RT.reminder(.daily(times: [RT.t("09:00"), RT.t("21:00")], weekdays: []), max: 3)
        #expect(dates(r, "2026-10-23 00:00", "2026-10-30 00:00")
                == ["2026-10-23 09:00", "2026-10-23 21:00", "2026-10-24 09:00"].map(RT.d))
        // 从中间开始查，也只剩第 3 次
        #expect(dates(r, "2026-10-24 00:00", "2026-10-30 00:00") == [RT.d("2026-10-24 09:00")])
        #expect(ReminderPlanner.shouldFinish(r, now: RT.d("2026-10-24 10:00"), calendar: cal))
    }

    @Test func 暂停的不响() {
        var r = RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []))
        r.state = .paused
        #expect(dates(r, "2026-10-23 00:00", "2026-10-30 00:00").isEmpty)
        #expect(!ReminderPlanner.shouldFinish(r, now: RT.d("2027-10-23 00:00"), calendar: cal))
    }

    @Test func 接下来几次() {
        let r = RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []))
        let next = ReminderPlanner.next(r, after: RT.d("2026-10-23 09:00"), count: 2, calendar: cal)
        #expect(next.map(\.scheduledAt) == ["2026-10-24 09:00", "2026-10-25 09:00"].map(RT.d))
    }

    @Test func 换时区后按新时区的墙上时间响() {
        var tokyo = cal
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let r = RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []))
        let fire = ReminderPlanner.next(r, after: RT.d("2026-10-23 12:00"), count: 1, calendar: tokyo)[0]
        #expect(tokyo.component(.hour, from: fire.scheduledAt) == 9)
    }

    @Test func 文案按第几次轮换() {
        let r = RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []), messages: ["甲", "乙"])
        let fire = Fire(reminderID: "r1", date: RT.d("2026-10-24 09:00"))
        #expect(ReminderPlanner.message(r, fire: fire, ordinal: 0) == "甲")
        #expect(ReminderPlanner.message(r, fire: fire, ordinal: 1) == "乙")
        #expect(ReminderPlanner.message(r, fire: fire, ordinal: 2) == "甲")
        let lead = Fire(reminderID: "r1", date: RT.d("2026-10-24 09:00"), leadDays: 5)
        #expect(ReminderPlanner.message(r, fire: lead, ordinal: 0) == "还有 5 天：甲")
    }

    @Test func 有次数上限的每年提醒_响过一次不会提前结束() {
        // 审查发现：从建立时间数次数时只看 400 天，第二年的就数不到了
        let r = RT.reminder(.yearly(month: 3, day: 1, times: [RT.t("09:00")], leadDays: []), max: 3)
        #expect(!ReminderPlanner.shouldFinish(r, now: RT.d("2027-03-02 00:00"), calendar: cal))
        // next 每次最多往后看 400 天，所以只看到下一次
        #expect(ReminderPlanner.next(r, after: RT.d("2027-03-02 00:00"), count: 5, calendar: cal).map(\.scheduledAt)
                == [RT.d("2028-03-01 09:00")])
        #expect(!ReminderPlanner.shouldFinish(r, now: RT.d("2028-03-02 00:00"), calendar: cal))
        #expect(ReminderPlanner.shouldFinish(r, now: RT.d("2029-03-02 00:00"), calendar: cal))
    }
}
