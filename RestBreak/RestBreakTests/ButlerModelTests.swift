import Foundation
import Testing
@testable import RestBreak

struct ButlerModelTests {
    @Test func 旧版数据文件能读_管家部分为默认值() throws {
        let v1 = #"{"schemaVersion":1,"reminders":[],"occurrences":[],"clients":[]}"#
        let data = try ReminderStore.decoder.decode(ReminderData.self, from: Data(v1.utf8))
        #expect(data.butler == ButlerData())
        #expect(data.butler.prefs.dailyBudget == 8)
    }

    @Test func 读0点6的文件_管家记事和下班时间被丢弃() throws {
        let v2 = #"""
        {"schemaVersion":2,"reminders":[],"occurrences":[],"clients":[],
         "butler":{"pushes":[],"notes":[{"id":"n1","text":"x","source":"c","createdAt":"2026-10-26T10:00:00Z"}],
                   "prefs":{"dailyBudget":5,"mutedIntents":["pause"],"workEnd":{"hour":19,"minute":0}}}}
        """#
        let data = try ReminderStore.decoder.decode(ReminderData.self, from: Data(v2.utf8))
        #expect(data.schemaVersion == 3)
        #expect(data.butler.prefs.dailyBudget == 5 && data.butler.prefs.mutedIntents == [.pause])
    }

    @Test func 认不出的来意跳过_旧的关注方向字段忽略() throws {
        let json = #"{"mutedIntents":["pause","futureIntent"],"focusPresets":["meeting"],"focusCustom":"写周报"}"#
        let prefs = try JSONDecoder().decode(ButlerPrefs.self, from: Data(json.utf8))
        #expect(prefs.mutedIntents == [.pause] && prefs.dailyBudget == 8)
    }

    @Test func 写入读回() throws {
        var data = ReminderData()
        data.butler.pushes.append(PushRecord(id: "p1", intent: .forgot, title: "Codex 跑完了", why: "放了 12 分钟没看",
                                             primaryAction: "去看看", dedupeKey: "codex-done", source: "claude-code",
                                             createdAt: RT.d("2026-10-26 15:00")))
        data.butler.prefs.dailyBudget = 5
        let encoded = try ReminderStore.encoder.encode(data)
        #expect(try ReminderStore.decoder.decode(ReminderData.self, from: encoded) == data)
    }

    @Test func 来意的中文说法() {
        #expect(PushIntent.allCases.map(\.label) == ["到点了", "快来不及了", "可能忘了", "该停一停", "告诉你一声"])
    }
}
