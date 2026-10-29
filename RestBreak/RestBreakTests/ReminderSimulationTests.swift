import Foundation
import Testing
@testable import RestBreak

/// 固定种子模拟 30 天：每 5 分钟处理一次，随机合盖几小时，随机处理强提醒的卡片。
/// 检查规则不变量：不重复、不漏、结束后不再响、卡片不会一直挂着
struct ReminderSimulationTests {
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    @Test(arguments: [1, 7, 42])
    func 三十天不变量(seed: UInt64) {
        let cal = RT.calendar
        var rng = Seeded(state: seed)
        var d = ReminderData()
        d.reminders = [
            RT.reminder(.daily(times: [RT.t("09:00"), RT.t("21:00")], weekdays: []), id: "med", style: .firm, max: 21),
            RT.reminder(.interval(everyMinutes: 90, from: RT.t("09:00"), to: RT.t("18:00"), weekdays: [1, 2, 3, 4, 5]), id: "water"),
            RT.reminder(.monthly(days: [31], times: [RT.t("10:00")]), id: "rent"),
            RT.reminder(.once(at: RT.d("2026-10-30 18:30")), id: "milk", style: .firm),
            RT.reminder(.yearly(month: 11, day: 5, times: [RT.t("09:00")], leadDays: [5]), id: "mom"),
        ]
        let start = RT.d("2026-10-23 08:00")
        let end = RT.d("2026-11-22 08:00")
        d.checkedAt = start
        var now = start
        var finishedAt: [String: Date] = [:]
        while now < end {
            now += 5 * 60
            // 约 1% 的概率合盖 1～14 小时（期间不处理）
            if Int.random(in: 0..<100, using: &rng) == 0 { now += TimeInterval(Int.random(in: 1...14, using: &rng)) * 3600 }
            // 随机处理挂着的卡片
            for o in d.occurrences where o.outcome == .pending && Bool.random(using: &rng) {
                switch Int.random(in: 0..<3, using: &rng) {
                case 0: d.setOutcome(o.reminderID, scheduledAt: o.scheduledAt, .done, now: now)
                case 1: d.setOutcome(o.reminderID, scheduledAt: o.scheduledAt, .snoozed, now: now, snoozedUntil: now + 600)
                default: d.setOutcome(o.reminderID, scheduledAt: o.scheduledAt, .skipped, now: now)
                }
            }
            _ = ReminderPlanner.process(&d, now: now, calendar: cal)
            for r in d.reminders where r.state == .finished && finishedAt[r.id] == nil { finishedAt[r.id] = now }

            // 不变量 1：同一次响铃只有一条记录
            let keys = d.occurrences.map { "\($0.reminderID)|\($0.scheduledAt.timeIntervalSince1970)" }
            #expect(Set(keys).count == keys.count)
            // 不变量 2：卡片挂着不会超过 40 分钟（再提醒 3 次后记为错过）
            for o in d.occurrences where o.outcome == .pending {
                #expect(now.timeIntervalSince(o.snoozedUntil ?? o.scheduledAt) < 40 * 60 + 5 * 60)
            }
        }
        // 不变量 3：每条提醒在模拟期内该响的都有记录，一次不多一次不少
        for r in d.reminders {
            var original = r
            original.state = .active
            let expected = Set(ReminderPlanner.fires(original, from: start + 0.001, to: d.checkedAt! + 0.001, calendar: cal).map(\.scheduledAt))
            let recorded = Set(d.occurrences.filter { $0.reminderID == r.id }.map(\.scheduledAt))
            #expect(recorded == expected, "\(r.id)")
        }
        // 不变量 4：吃药一共响 21 次就结束；牛奶响一次就结束
        #expect(d.occurrences.filter { $0.reminderID == "med" }.count == 21)
        #expect(d.reminder("med")?.state == .finished && d.reminder("milk")?.state == .finished)
        // 不变量 5：结束之后没有新的记录
        for (id, at) in finishedAt {
            #expect(!d.occurrences.contains { $0.reminderID == id && $0.scheduledAt > at })
        }
    }
}
