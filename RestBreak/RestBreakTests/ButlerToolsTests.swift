import Foundation
import Testing
@testable import RestBreak

struct ButlerToolsTests {
    func call(_ name: String, _ args: [String: Any], at now: String = "2026-10-26 15:00", store: ReminderStore,
              context: ButlerContext? = nil) -> ToolResult {
        ButlerTools.call(name, arguments: args, context: RT.context(now, store: store), situation: { context })!
    }

    let sample = ButlerContext(generatedAt: RT.d("2026-10-26 15:00"), state: "在电脑前", awayMinutes: nil,
                               workingStretchMinutes: 95, firstActiveToday: "09:12", breaksCompletedToday: 4,
                               breaksSkippedToday: 2, todayEvents: [.init(title: "周会", start: "16:00", end: "17:00")])

    @Test func push写成待推送并告诉AI() throws {
        let store = RT.tempStore()
        let r = call("push", ["intent": "forgot", "title": "Codex 跑完了", "why": "结果放了 12 分钟没看",
                              "primaryAction": "去看看", "dedupeKey": "codex-1"], store: store)
        #expect(!r.isError && r.changed)
        let p = try #require(try store.load().butler.pushes.first)
        #expect(p.status == .pending && p.intent == .forgot && p.source == "claude-code")
        #expect(RT.object(r.text)["result"] as? String == "已交给星期五，会在合适的时机显示")
    }

    @Test func push被关卡拦下时当场说明且不写入() throws {
        let store = RT.tempStore()
        try store.update { $0.butler.prefs.mutedIntents = [.pause] }
        let r = call("push", ["intent": "pause", "title": "去吃饭", "why": "一直没离开"], store: store)
        #expect(!r.isError && !r.changed)
        #expect((RT.object(r.text)["result"] as? String)?.contains("没有推送") == true)
        #expect(try store.load().butler.pushes.isEmpty)
    }

    @Test func push参数检查() {
        let store = RT.tempStore()
        #expect(call("push", ["intent": "whatever", "title": "a", "why": "b"], store: store).isError)
        #expect(call("push", ["intent": "info", "title": "a"], store: store).text.contains("why"))
    }

    @Test func 看现状_带上到点提醒() throws {
        let store = RT.tempStore()
        _ = ReminderTools.call("create_reminder", arguments: ["title": "吃药", "messages": ["该吃药了"],
                                                              "schedule": ["kind": "daily", "times": ["21:00"]]],
                               context: RT.context("2026-10-26 15:00", store: store))
        let o = RT.object(call("get_context", [:], store: store, context: sample).text)
        #expect((o["situation"] as? [String: Any])?["state"] as? String == "在电脑前")
        #expect(o["focus"] == nil)
        #expect(o["remainingPushBudget"] as? Int == 8)
        let reminders = try #require(o["reminders"] as? [String: Any])
        #expect((reminders["upcoming"] as? [[String: Any]])?.first?["time"] as? String == "今天 21:00")
        #expect((o["now"] as? [String: Any])?["local"] as? String == "2026-10-26 15:00")
        #expect(o["notes"] == nil)
    }

    @Test func 主App没回应时也能给出部分现状() {
        let o = RT.object(call("get_context", [:], store: RT.tempStore(), context: nil).text)
        #expect((o["situation"] as? String)?.contains("星期五没在运行") == true)
    }

    @Test func 不是管家的工具返回nil() {
        #expect(ButlerTools.call("create_reminder", arguments: [:], context: RT.context("2026-10-26 15:00", store: RT.tempStore()),
                                 situation: { nil }) == nil)
    }

    @Test func 工具定义合法() throws {
        #expect(ButlerTools.specs.map(\.name) == ["get_context", "push"])
        for spec in ButlerTools.specs {
            #expect((try JSONSerialization.jsonObject(with: Data(spec.schema.utf8)) as? [String: Any])?["type"] as? String == "object")
        }
    }
}
