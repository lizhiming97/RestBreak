import Foundation
import Testing
@testable import RestBreak

/// 合并：微休息和长休息挨得太近时，直接做长休息（临近合并、会前合并）
struct BreakMergeTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 0)
    let settings = AppSettings.default

    func minutes(_ m: Double) -> TimeInterval { m * 60 }
    func event(_ from: Double, _ to: Double) -> DateInterval {
        DateInterval(start: t0 + minutes(from), end: t0 + minutes(to))
    }

    /// 每秒 tick 一次，返回期间开始的休息（时刻和内容）
    func run(_ s: inout BreakScheduler, from start: Date, to end: Date,
             calendar: [DateInterval] = [], mic: (Date) -> Bool = { _ in false }) -> [(Date, BreakSession)] {
        var out: [(Date, BreakSession)] = []
        var now = start
        while now < end {
            for e in s.tick(now: now, idleSeconds: 0, inMeeting: mic(now), calendarEvents: calendar) {
                if case .breakStarted(let session) = e { out.append((now, session)) }
            }
            now += 1
        }
        return out
    }

    /// 在 at 手动做一次微休息并做完，让微休息和长休息错开
    func manualMicro(_ s: inout BreakScheduler, at: Date) {
        _ = s.startBreakNow(.micro, now: at)
        _ = s.tick(now: at + settings[.micro].duration, idleSeconds: 0)
    }

    // MARK: - 合并窗口

    @Test func 合并窗口按设置缩放() {
        func window(_ micro: Double, _ long: Double) -> TimeInterval {
            var custom = settings
            custom[.micro].interval = minutes(micro)
            custom[.long].interval = minutes(long)
            return BreakScheduler(settings: custom, now: t0).mergeWindow
        }
        #expect(window(20, 60) == minutes(15))
        #expect(window(10, 30) == minutes(7.5))
        #expect(window(20, 40) == minutes(10))
        #expect(window(30, 90) == minutes(15))
    }

    // MARK: - 规则 1：临近合并

    @Test func 微休息到点时长休息不到15分钟_直接做长休息() {
        var s = BreakScheduler(settings: settings, now: t0)
        // 31 分手动做一次微休息 → 下次微休息 51:20，长休息 60:00，只差 8 分 40 秒
        manualMicro(&s, at: t0 + minutes(31))
        let plan = s.plannedBreak(now: t0 + minutes(40))
        #expect(plan?.kind == .long)
        #expect(plan?.start == t0 + minutes(51) + 20)
        #expect(plan?.mergeReason == .nearbyLong(advancedBy: minutes(8) + 40))

        let started = run(&s, from: t0 + minutes(40), to: t0 + minutes(62))
        #expect(started.count == 1)
        #expect(started.first?.0 == t0 + minutes(51) + 20)
        #expect(started.first?.1.kind == .long)
        #expect(started.first?.1.mergeReason == .nearbyLong(advancedBy: minutes(8) + 40))
    }

    @Test func 合并后的长休息做完_两种休息重新对齐() {
        var s = BreakScheduler(settings: settings, now: t0)
        manualMicro(&s, at: t0 + minutes(31))
        _ = run(&s, from: t0 + minutes(40), to: t0 + minutes(57))
        let end = t0 + minutes(56) + 20
        #expect(s.state == .running)
        #expect(s.timers[.long]?.dueDate == end + minutes(60))
        #expect(s.timers[.micro]?.dueDate == end + minutes(20))
    }

    @Test func 长休息超过15分钟才到_照常做微休息() {
        var s = BreakScheduler(settings: settings, now: t0)
        // 24 分手动做微休息 → 下次微休息 44:20，长休息 60:00，差 15 分 40 秒
        manualMicro(&s, at: t0 + minutes(24))
        let started = run(&s, from: t0 + minutes(30), to: t0 + minutes(45))
        #expect(started.first?.0 == t0 + minutes(44) + 20)
        #expect(started.first?.1.kind == .micro)
        #expect(started.first?.1.mergeReason == nil)
    }

    @Test func 手动开始微休息不升级() {
        var s = BreakScheduler(settings: settings, now: t0)
        let events = s.startBreakNow(.micro, now: t0 + minutes(50))
        guard case .breakStarted(let session) = events.first else { Issue.record("没有开始休息"); return }
        #expect(session.kind == .micro)
        #expect(session.mergeReason == nil)
    }

    @Test func 开会攒着的微休息_散会时长休息快到了就一起做() {
        var s = BreakScheduler(settings: settings, now: t0)
        // 15～50 分开会：20 分的微休息攒着；散会 1 分钟缓冲后（51 分）长休息还有 9 分钟到期
        let started = run(&s, from: t0, to: t0 + minutes(52),
                          mic: { $0 >= t0 + minutes(15) && $0 < t0 + minutes(50) })
        #expect(started.count == 1)
        #expect(started.first?.1.kind == .long)
        #expect(started.first?.0 == t0 + minutes(51))
    }

    @Test func 跳过合并来的长休息_微休息照常来() {
        var s = BreakScheduler(settings: settings, now: t0)
        manualMicro(&s, at: t0 + minutes(31))
        s.skipUpcoming(now: t0 + minutes(40))
        #expect(s.timers[.long]?.dueDate == t0 + minutes(100))
        #expect(s.plannedBreak(now: t0 + minutes(40))?.kind == .micro)
        #expect(s.plannedBreak(now: t0 + minutes(40))?.start == t0 + minutes(51) + 20)
    }

    // MARK: - 规则 2：会前合并

    @Test func 会前最后一次微休息换成长休息() {
        var s = BreakScheduler(settings: settings, now: t0)
        // 45～75 分开会，长休息 60 分到期（会议中）。40 分那次微休息是会前最后一次：
        // 换成长休息，39 分开始、44 分做完，留 1 分钟进会
        let cal = [event(45, 75)]
        let first = run(&s, from: t0, to: t0 + minutes(30), calendar: cal)
        #expect(first.map(\.1.kind) == [.micro])
        // 菜单提前就能看到：下次是会前的长休息
        #expect(s.plannedBreak(now: t0 + minutes(30))?.kind == .long)
        #expect(s.plannedBreak(now: t0 + minutes(30))?.mergeReason == .beforeMeeting)

        let second = run(&s, from: t0 + minutes(30), to: t0 + minutes(45), calendar: cal)
        #expect(second.map(\.1.kind) == [.long])
        #expect(second.first?.0 == t0 + minutes(39))
        #expect(second.first?.1.mergeReason == .beforeMeeting)
    }

    @Test func 会前合并_刚休完不久就不提前() {
        var s = BreakScheduler(settings: settings, now: t0)
        // 41 分开会：长休息要 35 分开始，离 20 分那次微休息做完才 14 分 40 秒（不到合并窗口）
        // → 照常把微休息提前到会前，长休息散会后再做
        let cal = [event(41, 100)]
        let started = run(&s, from: t0, to: t0 + minutes(41), calendar: cal)
        #expect(started.map(\.1.kind) == [.micro, .micro])
        #expect(started.last?.0 == t0 + minutes(39) + 40)
    }

    @Test func 会前合并_长休息最多提前半个间隔() {
        var s = BreakScheduler(settings: settings, now: t0)
        // 21～60 分开会：长休息要 15 分开始，比 60 分到期早 45 分钟，超过半个间隔 → 不合并
        let started = run(&s, from: t0, to: t0 + minutes(21), calendar: [event(21, 60)])
        #expect(started.map(\.1.kind) == [.micro])
    }

    @Test func 连着的会按整串算() {
        var custom = settings
        custom[.long].interval = minutes(70)
        var s = BreakScheduler(settings: custom, now: t0)
        // 45～50、60～65 两个会中间只空 10 分钟，当成一场开到 65 分；长休息 70 分到期，在散会后 15 分钟内
        let cal = [event(45, 50), event(60, 65)]
        let started = run(&s, from: t0, to: t0 + minutes(45), calendar: cal)
        #expect(started.last?.1.kind == .long)
        #expect(started.last?.0 == t0 + minutes(39))

        // 只有第一场会：长休息 70 分到期，不在散会后 15 分钟内 → 不合并
        var single = BreakScheduler(settings: custom, now: t0)
        let alone = run(&single, from: t0, to: t0 + minutes(45), calendar: [event(45, 50)])
        #expect(alone.last?.1.kind == .micro)
    }

    // MARK: - 遮罩文字

    @MainActor @Test func 遮罩说明合并原因() {
        #expect(BreakCoordinator.mergeNote(.nearbyLong(advancedBy: minutes(8) + 40)) == "长休息也快到了，提前 9 分钟一起休")
        #expect(BreakCoordinator.mergeNote(.nearbyLong(advancedBy: 10)) == "长休息也到了，一起休")
        #expect(BreakCoordinator.mergeNote(.beforeMeeting) == "快开会了，先把长休息做了")
        #expect(BreakCoordinator.mergeNote(nil) == nil)
    }
}
