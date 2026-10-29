import Foundation
import Testing
@testable import RestBreak

/// 0.6 代码审查发现的问题
@MainActor
struct ButlerReviewFixTests {
    @Test func 现状文件的时间保留小数秒() throws {
        let at = Date(timeIntervalSince1970: 1_792_000_000.8)
        let ctx = ButlerContext(generatedAt: at, state: "在电脑前", awayMinutes: nil, workingStretchMinutes: 0,
                                firstActiveToday: nil, breaksCompletedToday: 0, breaksSkippedToday: 0, todayEvents: nil)
        let back = try ButlerContext.fileDecoder.decode(ButlerContext.self, from: ButlerContext.fileEncoder.encode(ctx))
        // 小程序 0.7 秒时发请求，主 App 0.8 秒写：必须认得出这是刚写的
        #expect(back.generatedAt >= Date(timeIntervalSince1970: 1_792_000_000.7))
    }

    @Test func 等着显示的也占预算_按显示那天算() {
        var b = ButlerData()
        b.pushes = (0..<8).map { i in
            var p = PushRecord(id: "\(i)", intent: .info, title: "t", why: "w", primaryAction: nil, dedupeKey: nil,
                               source: "x", createdAt: RT.d("2026-10-26 09:00"), status: i < 4 ? .waiting : .shown)
            p.handledAt = RT.d("2026-10-26 09:00")
            p.shownAt = i < 4 ? nil : RT.d("2026-10-26 10:00")
            return p
        }
        let next = PushRecord(id: "n", intent: .forgot, title: "t", why: "w", primaryAction: nil, dedupeKey: nil,
                              source: "x", createdAt: RT.d("2026-10-26 12:00"))
        #expect(PushGate.check(next, butler: b, now: RT.d("2026-10-26 12:00"), calendar: RT.calendar) == .block("今天的打扰预算（8 条）用完了"))
        // 23:55 显示、第二天 00:05 才点掉：算前一天的
        var late = b.pushes[7]
        late.shownAt = RT.d("2026-10-25 23:55"); late.handledAt = RT.d("2026-10-26 00:05"); late.status = .dismissed
        b.pushes = [late]
        #expect(PushGate.remainingBudget(b, now: RT.d("2026-10-26 09:00"), calendar: RT.calendar) == 8)
    }

    @Test func 放太久的推送不再显示() throws {
        let store = RT.tempStore()
        try store.update {
            $0.butler.pushes = [PushRecord(id: "old", intent: .forgot, title: "t", why: "w", primaryAction: nil, dedupeKey: nil,
                                           source: "claude-code", createdAt: Date().addingTimeInterval(-2 * 3600))]
        }
        let butler = ButlerCoordinator(store: store, reminders: ReminderCoordinator(store: store))
        butler.processPending()
        let p = try #require(try store.load().butler.pushes.first)
        #expect(p.status == .expired)
    }

    @Test func 放行的推送先记为等着显示() throws {
        let store = RT.tempStore()
        try store.update {
            $0.butler.pushes = [PushRecord(id: "new", intent: .forgot, title: "t", why: "w", primaryAction: nil, dedupeKey: nil,
                                           source: "claude-code", createdAt: Date())]
        }
        let reminders = ReminderCoordinator(store: store)
        reminders.isBusy = { true }   // 正在开会：先等，不显示
        let butler = ButlerCoordinator(store: store, reminders: reminders)
        butler.processPending()
        #expect(try store.load().butler.pushes.first?.status == .waiting)
    }
}
