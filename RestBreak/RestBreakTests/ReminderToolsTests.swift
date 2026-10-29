import Foundation
import Testing
@testable import RestBreak

/// 5 个 MCP 工具：正常和出错的输入输出
struct ReminderToolsTests {
    func call(_ name: String, _ args: [String: Any], at now: String = "2026-10-23 15:12",
              store: ReminderStore, client: String = "claude-code") -> ToolResult {
        ReminderTools.call(name, arguments: args, context: RT.context(now, store: store, client: client))
    }

    let daily: [String: Any] = ["title": "吃抗生素", "messages": ["饭后半小时，该吃药啦"],
                                "schedule": ["kind": "daily", "times": ["09:00", "21:00"]], "style": "firm",
                                "reason": "10/23 聊到医生开了 7 天抗生素", "endDate": "2026-10-29"]

    @Test func 新建每天提醒() throws {
        let store = RT.tempStore()
        let result = call("create_reminder", daily, store: store)
        #expect(!result.isError && result.changed)
        let object = RT.object(result.text)
        #expect(object["next"] as? [String] == ["今天 21:00", "明天 09:00", "明天 21:00"])
        #expect((object["now"] as? [String: Any])?["weekday"] as? String == "周五")
        let saved = try #require(try store.load().reminders.first)
        #expect(saved.createdBy == "claude-code" && saved.style == .firm && !saved.announced)
        #expect(saved.endDate == RT.calendar.date(bySettingHour: 23, minute: 59, second: 59, of: RT.d("2026-10-29 00:00")))
    }

    @Test func 过去的时间报错并给建议() {
        let result = call("create_reminder", ["title": "买牛奶", "messages": ["下班买牛奶"],
                                              "schedule": ["kind": "once", "at": "2026-10-23 08:00"]], store: RT.tempStore())
        #expect(result.isError)
        #expect(result.text.contains("已经过去了") && result.text.contains("2026-10-23 15:12 周五") && result.text.contains("明天"))
    }

    @Test func 带时区的时间也接受() throws {
        let store = RT.tempStore()
        let result = call("create_reminder", ["title": "开会", "messages": ["准备开会"],
                                              "schedule": ["kind": "once", "at": "2026-10-24T09:30+08:00"]], store: store)
        #expect(!result.isError)
        #expect(try store.load().reminders.first?.schedule == .once(at: RT.d("2026-10-24 09:30")))
    }

    @Test func 时刻格式不对() {
        let result = call("create_reminder", ["title": "喝水", "messages": ["喝水"],
                                              "schedule": ["kind": "daily", "times": ["9点"]]], store: RT.tempStore())
        #expect(result.isError && result.text.contains("HH:mm"))
    }

    @Test func 间隔太短() {
        let result = call("create_reminder", ["title": "喝水", "messages": ["喝水"],
                                              "schedule": ["kind": "interval", "everyMinutes": 10, "from": "09:00", "to": "18:00"]],
                          store: RT.tempStore())
        #expect(result.isError && result.text.contains("15"))
    }

    @Test func 以后不会再响时报错() {
        var args = daily
        args["endDate"] = "2026-10-23"
        args["schedule"] = ["kind": "daily", "times": ["09:00"]]
        let result = call("create_reminder", args, store: RT.tempStore())
        #expect(result.isError && result.text.contains("一次都不会响"))
    }

    @Test func 最多100条() throws {
        let store = RT.tempStore()
        try store.update { data in
            data.reminders = (0..<100).map { RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []), id: "x\($0)", createdBy: "手动") }
        }
        #expect(call("create_reminder", daily, store: store).text.contains("100 条"))
    }

    @Test func 同一客户端每小时最多新建20条() {
        let store = RT.tempStore()
        for _ in 0..<20 { #expect(!call("create_reminder", daily, store: store).isError) }
        #expect(call("create_reminder", daily, store: store).isError)
        #expect(!call("create_reminder", daily, store: store, client: "codex-mcp-client").isError)
    }

    @Test func 列表带完成情况() throws {
        let store = RT.tempStore()
        _ = call("create_reminder", daily, store: store)
        let id = try #require(try store.load().reminders.first?.id)
        try store.update { $0.setOutcome(id, scheduledAt: RT.d("2026-10-23 21:00"), .done, now: RT.d("2026-10-23 21:05")) }
        let result = call("list_reminders", ["historyDays": 7], at: "2026-10-24 08:00", store: store)
        let reminders = try #require(RT.object(result.text)["reminders"] as? [[String: Any]])
        let history = try #require(reminders.first?["history"] as? [[String: Any]])
        #expect(history.first?["result"] as? String == "完成")
        #expect(reminders.first?["schedule"] as? String == "每天 09:00、21:00")
    }

    @Test func 修改和暂停() throws {
        let store = RT.tempStore()
        _ = call("create_reminder", daily, store: store)
        let id = try #require(try store.load().reminders.first?.id)
        let result = call("update_reminder", ["id": id, "title": "吃消炎药", "state": "paused"], store: store)
        #expect(!result.isError)
        let saved = try #require(try store.load().reminders.first)
        #expect(saved.title == "吃消炎药" && saved.state == .paused)
        #expect(call("update_reminder", ["id": "nope00"], store: store).text.contains("list_reminders"))
    }

    @Test func 删除连同记录() throws {
        let store = RT.tempStore()
        _ = call("create_reminder", daily, store: store)
        let id = try #require(try store.load().reminders.first?.id)
        try store.update { $0.setOutcome(id, scheduledAt: RT.d("2026-10-23 21:00"), .done, now: RT.d("2026-10-23 21:05")) }
        #expect(!call("delete_reminder", ["id": id], store: store).isError)
        let data = try store.load()
        #expect(data.reminders.isEmpty && data.occurrences.isEmpty)
    }

    @Test func 工具定义合法() throws {
        #expect(Set(ReminderTools.specs.map(\.name)).count == 4)
        for spec in ReminderTools.specs {
            let schema = try #require(try JSONSerialization.jsonObject(with: Data(spec.schema.utf8)) as? [String: Any], "\(spec.name)")
            #expect(schema["type"] as? String == "object")
        }
        #expect(ReminderTools.specs.filter(\.readOnly).map(\.name) == ["list_reminders"])
        #expect(Set(AllTools.specs.map(\.name)).count == 6)
        #expect(!ReminderTools.instructions.isEmpty)
    }

    @Test func 不认识的工具() {
        #expect(call("make_coffee", [:], store: RT.tempStore()).isError)
    }
}
