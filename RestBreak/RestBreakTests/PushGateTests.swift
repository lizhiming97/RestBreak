import Foundation
import Testing
@testable import RestBreak

struct PushGateTests {
    let cal = RT.calendar
    func push(_ intent: PushIntent, at: String, key: String? = nil, status: PushRecord.Status = .shown) -> PushRecord {
        PushRecord(id: UUID().uuidString, intent: intent, title: "t", why: "w", primaryAction: nil, dedupeKey: key,
                   source: "x", createdAt: RT.d(at), status: status, handledAt: RT.d(at))
    }

    @Test func 没有记录时放行() {
        #expect(PushGate.check(push(.forgot, at: "2026-10-26 10:00", status: .pending), butler: ButlerData(),
                               now: RT.d("2026-10-26 10:00"), calendar: cal) == .allow)
    }

    @Test func 预算用完_到点了不受影响() {
        var b = ButlerData()
        b.pushes = (0..<8).map { push(.info, at: "2026-10-26 0\($0):00") }
        let now = RT.d("2026-10-26 12:00")
        #expect(PushGate.check(push(.forgot, at: "2026-10-26 12:00"), butler: b, now: now, calendar: cal)
                == .block("今天的打扰预算（8 条）用完了"))
        #expect(PushGate.check(push(.due, at: "2026-10-26 12:00"), butler: b, now: now, calendar: cal) == .allow)
    }

    @Test func 昨天的不算今天的预算() {
        var b = ButlerData()
        b.pushes = (0..<8).map { push(.info, at: "2026-10-25 1\($0):00") }
        #expect(PushGate.check(push(.forgot, at: "2026-10-26 09:00"), butler: b, now: RT.d("2026-10-26 09:00"), calendar: cal) == .allow)
    }

    @Test func 同一件事一天一次() {
        var b = ButlerData()
        b.pushes = [push(.forgot, at: "2026-10-26 09:00", key: "codex-done")]
        #expect(PushGate.check(push(.urgent, at: "2026-10-26 15:00", key: "codex-done"), butler: b,
                               now: RT.d("2026-10-26 15:00"), calendar: cal) == .block("同一件事今天已经说过了"))
    }

    @Test func 同类30分钟内只一条() {
        var b = ButlerData()
        b.pushes = [push(.pause, at: "2026-10-26 13:00")]
        #expect(PushGate.check(push(.pause, at: "2026-10-26 13:20"), butler: b, now: RT.d("2026-10-26 13:20"), calendar: cal)
                == .block("30 分钟内已经提醒过「该停一停」"))
        #expect(PushGate.check(push(.pause, at: "2026-10-26 13:31"), butler: b, now: RT.d("2026-10-26 13:31"), calendar: cal) == .allow)
    }

    @Test func 屏蔽的来意() {
        var b = ButlerData()
        b.prefs.mutedIntents = [.info]
        #expect(PushGate.check(push(.info, at: "2026-10-26 10:00"), butler: b, now: RT.d("2026-10-26 10:00"), calendar: cal)
                == .block("你设置了少提醒「告诉你一声」这类"))
    }

    @Test func 被拦下的不占预算也不算重复() {
        var b = ButlerData()
        b.pushes = (0..<8).map { push(.info, at: "2026-10-26 0\($0):00", key: "k", status: .blocked) }
        #expect(PushGate.check(push(.info, at: "2026-10-26 12:00", key: "k"), butler: b, now: RT.d("2026-10-26 12:00"), calendar: cal) == .allow)
    }

    @Test func 剩余预算() {
        var b = ButlerData()
        b.pushes = [push(.info, at: "2026-10-26 09:00"), push(.due, at: "2026-10-26 09:30")]
        #expect(PushGate.remainingBudget(b, now: RT.d("2026-10-26 10:00"), calendar: cal) == 7)
    }
}
