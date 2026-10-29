import Foundation
import Testing
@testable import RestBreak

struct ScheduleTextTests {
    let cal = RT.calendar

    @Test func 描述时间安排() {
        #expect(ScheduleText.describe(.daily(times: [RT.t("21:00"), RT.t("09:00")], weekdays: []), calendar: cal) == "每天 09:00、21:00")
        #expect(ScheduleText.describe(.daily(times: [RT.t("10:00")], weekdays: [1, 2, 3, 4, 5]), calendar: cal) == "工作日 10:00")
        #expect(ScheduleText.describe(.daily(times: [RT.t("10:00")], weekdays: [6, 7]), calendar: cal) == "周末 10:00")
        #expect(ScheduleText.describe(.daily(times: [RT.t("10:00")], weekdays: [3, 1]), calendar: cal) == "每周一、三 10:00")
        #expect(ScheduleText.describe(.interval(everyMinutes: 90, from: RT.t("09:00"), to: RT.t("18:00"), weekdays: []), calendar: cal)
                == "每天 09:00–18:00 每 1 小时 30 分钟")
        #expect(ScheduleText.describe(.monthly(days: [10], times: [RT.t("09:00")]), calendar: cal) == "每月 10 号 09:00")
        #expect(ScheduleText.describe(.yearly(month: 11, day: 5, times: [RT.t("09:00")], leadDays: [5]), calendar: cal)
                == "每年 11 月 5 日 09:00（提前 5 天预告）")
        #expect(ScheduleText.describe(.once(at: RT.d("2026-10-24 18:30")), calendar: cal) == "10 月 24 日 周六 18:30")
    }

    @Test func 下次响铃的说法() {
        let now = RT.d("2026-10-23 15:00")
        #expect(ScheduleText.fireText(RT.d("2026-10-23 21:00"), now: now, calendar: cal) == "今天 21:00")
        #expect(ScheduleText.fireText(RT.d("2026-10-24 09:00"), now: now, calendar: cal) == "明天 09:00")
        #expect(ScheduleText.fireText(RT.d("2026-10-26 09:00"), now: now, calendar: cal) == "10 月 26 日 周一 09:00")
    }

    @Test func 状态说明() {
        let now = RT.d("2026-10-23 15:00")
        let times = RT.reminder(.daily(times: [RT.t("09:00"), RT.t("21:00")], weekdays: []), max: 21)
        #expect(ScheduleText.status(times, now: now, calendar: cal) == "还剩 20 次")
        let days = RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []), end: RT.d("2026-10-26 23:59"))
        #expect(ScheduleText.status(days, now: now, calendar: cal) == "还剩 4 天")
        var paused = days; paused.state = .paused
        #expect(ScheduleText.status(paused, now: now, calendar: cal) == "已暂停")
    }

    @Test func 客户端显示名() {
        #expect(ClientNames.display("claude-code") == "Claude Code")
        #expect(ClientNames.display("codex-mcp-client") == "Codex")
        #expect(ClientNames.display("cursor") == "cursor")
    }

    @Test func 多久以前() {
        let now = RT.d("2026-10-23 15:00")
        #expect(ScheduleText.ago(now - 20, now: now) == "刚刚")
        #expect(ScheduleText.ago(RT.d("2026-10-23 14:57"), now: now) == "3 分钟前")
        #expect(ScheduleText.ago(RT.d("2026-10-23 12:00"), now: now) == "3 小时前")
        #expect(ScheduleText.ago(RT.d("2026-10-21 12:00"), now: now) == "2 天前")
    }
}
