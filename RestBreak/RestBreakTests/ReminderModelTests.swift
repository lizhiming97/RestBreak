import Foundation
import Testing
@testable import RestBreak

/// 提醒的数据模型：时刻解析、时间安排的编解码、完成记录的写入
struct ReminderModelTests {
    @Test func 时刻解析() {
        #expect(ClockTime("9:05")?.description == "09:05")
        #expect(ClockTime("21:00")?.minutes == 21 * 60)
        #expect(ClockTime("24:00") == nil)
        #expect(ClockTime("9点") == nil)
        #expect(RT.t("08:00") < RT.t("09:30"))
    }

    @Test(arguments: [
        Schedule.once(at: Date(timeIntervalSince1970: 1_792_000_020)),
        .daily(times: [RT.t("09:00"), RT.t("21:00")], weekdays: [1, 2, 3]),
        .interval(everyMinutes: 90, from: RT.t("09:00"), to: RT.t("18:00"), weekdays: []),
        .monthly(days: [10, 31], times: [RT.t("09:00")]),
        .yearly(month: 11, day: 5, times: [RT.t("09:00")], leadDays: [5]),
    ])
    func 时间安排编解码往返(_ schedule: Schedule) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(schedule)
        #expect(try decoder.decode(Schedule.self, from: data) == schedule)
    }

    @Test func 不写weekdays时为每天() throws {
        let json = #"{"kind":"daily","times":["09:00"]}"#
        let schedule = try JSONDecoder().decode(Schedule.self, from: Data(json.utf8))
        #expect(schedule == .daily(times: [RT.t("09:00")], weekdays: []))
    }

    @Test func 不认识的kind解码失败() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Schedule.self, from: Data(#"{"kind":"hourly"}"#.utf8))
        }
    }

    @Test func 写完成记录_新增和覆盖() {
        var data = ReminderData()
        let at = RT.d("2026-10-23 09:00")
        data.setOutcome("r1", scheduledAt: at, .pending, now: at)
        data.setOutcome("r1", scheduledAt: at, .done, now: RT.d("2026-10-23 09:03"))
        #expect(data.occurrences.count == 1)
        #expect(data.occurrences[0].outcome == .done)
        #expect(data.occurrences[0].actedAt == RT.d("2026-10-23 09:03"))
    }

    @Test func 推迟时记下再响时间并清零再提醒次数() {
        var data = ReminderData()
        let at = RT.d("2026-10-23 09:00")
        data.setOutcome("r1", scheduledAt: at, .pending, now: at)
        data.occurrences[0].nagCount = 2
        data.setOutcome("r1", scheduledAt: at, .snoozed, now: RT.d("2026-10-23 09:05"),
                        snoozedUntil: RT.d("2026-10-23 09:15"))
        #expect(data.occurrences[0].snoozedUntil == RT.d("2026-10-23 09:15"))
        #expect(data.occurrences[0].nagCount == 0)
    }

    @Test func 记录客户端() {
        var data = ReminderData()
        data.recordClient("claude-code", now: RT.d("2026-10-23 09:00"))
        data.recordClient("claude-code", now: RT.d("2026-10-23 10:00"))
        data.recordClient("codex-mcp-client", now: RT.d("2026-10-23 10:00"))
        #expect(data.clients.count == 2)
        #expect(data.clients.first { $0.name == "claude-code" }?.lastSeen == RT.d("2026-10-23 10:00"))
    }

    @Test func 新id不重复() {
        let existing: Set<String> = ["abc123"]
        let id = ReminderData.newID(existing: existing)
        #expect(id.count == 6 && !existing.contains(id))
    }
}
