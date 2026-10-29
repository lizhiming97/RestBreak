import Foundation
import Testing
@testable import RestBreak

struct ReminderHistoryTests {
    @Test func 某一天_推送和到点提醒按时间倒序_别的天不算() throws {
        let store = RT.tempStore()
        _ = ReminderTools.call("create_reminder", arguments: ["title": "吃药", "messages": ["该吃药了"], "style": "firm",
                                                              "schedule": ["kind": "daily", "times": ["21:00"]]],
                               context: RT.context("2026-10-26 15:00", store: store))
        let id = try #require(try store.load().reminders.first?.id)
        try store.update {
            $0.setOutcome(id, scheduledAt: RT.d("2026-10-26 21:00"), .done, now: RT.d("2026-10-26 21:02"))
            $0.setOutcome(id, scheduledAt: RT.d("2026-10-27 21:00"), .missed, now: RT.d("2026-10-27 21:40"))
            var shown = PushRecord(id: "p1", intent: .pause, title: "去吃饭", why: "一直没离开电脑", primaryAction: nil,
                                   dedupeKey: nil, source: "codex-mcp-client", createdAt: RT.d("2026-10-26 12:28"))
            shown.status = .shown; shown.shownAt = RT.d("2026-10-26 12:30")
            var blocked = PushRecord(id: "p2", intent: .info, title: "x", why: "y", primaryAction: nil, dedupeKey: nil,
                                     source: "codex-mcp-client", createdAt: RT.d("2026-10-26 09:00"))
            blocked.status = .blocked; blocked.reason = "今天的打扰预算用完了"
            $0.butler.pushes = [shown, blocked]
        }
        let entries = ReminderHistory.entries(try store.load(), on: RT.d("2026-10-26 08:00"), calendar: RT.calendar)
        #expect(entries.map(\.title) == ["吃药", "去吃饭", "x"])
        #expect(entries[0].detail == "完成" && entries[0].meta.contains("强提醒"))
        #expect(entries[1].time == RT.d("2026-10-26 12:30") && entries[1].meta == "该停一停 · 已显示 · Codex")
        #expect(entries[2].meta.contains("没推：今天的打扰预算用完了"))
        #expect(ReminderHistory.entries(try store.load(), on: RT.d("2026-10-27 08:00"), calendar: RT.calendar).map(\.detail) == ["错过"])
    }
}
