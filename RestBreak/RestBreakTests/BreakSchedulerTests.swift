import Foundation
import Testing
@testable import RestBreak

/// 调度引擎的单元测试。
/// 在 Xcode 里按 ⌘U 运行，或命令行：xcodebuild -scheme RestBreak test
struct BreakSchedulerTests {
    /// 固定的起始时间，所有测试都从这里开始算，方便推算
    let t0 = Date(timeIntervalSinceReferenceDate: 0)
    let settings = AppSettings.default

    func minutes(_ m: Double) -> TimeInterval { m * 60 }

    // MARK: - 基本计时

    @Test func 初始化时各休息从现在开始计时() {
        let s = BreakScheduler(settings: settings, now: t0)
        #expect(s.timers[.micro]?.dueDate == t0 + minutes(20))
        #expect(s.timers[.long]?.dueDate == t0 + minutes(60))
        #expect(s.state == .running)
    }

    @Test func 未到期时不开始休息() {
        var s = BreakScheduler(settings: settings, now: t0)
        let events = s.tick(now: t0 + minutes(19), idleSeconds: 0)
        #expect(events.isEmpty)
        #expect(s.state == .running)
    }

    @Test func 微休息到期后开始并在时长结束后完成() {
        var s = BreakScheduler(settings: settings, now: t0)
        let start = t0 + minutes(20)
        let events = s.tick(now: start, idleSeconds: 0)
        guard case .breakStarted(let session) = events.first else {
            Issue.record("应该开始休息"); return
        }
        #expect(session.kind == .micro)
        #expect(session.endsAt == start + 20)

        // 休息期间闲置不会被当成离开
        #expect(s.tick(now: start + 10, idleSeconds: 600).isEmpty)

        let end = start + 20
        #expect(s.tick(now: end, idleSeconds: 0) == [.breakEnded(.micro, .completed)])
        #expect(s.state == .running)
        #expect(s.timers[.micro]?.dueDate == end + minutes(20))
    }

    @Test func 禁用的休息不会开始() {
        var custom = settings
        custom[.micro].isEnabled = false
        var s = BreakScheduler(settings: custom, now: t0)
        #expect(s.tick(now: t0 + minutes(30), idleSeconds: 0).isEmpty)
    }

    // MARK: - 优先级

    @Test func 长休息5分钟内也要到期时跳过微休息() {
        var custom = settings
        custom[.micro].interval = minutes(57)   // 微休息 57 分到期，长休息 60 分到期
        var s = BreakScheduler(settings: custom, now: t0)
        let now = t0 + minutes(57)
        #expect(s.tick(now: now, idleSeconds: 0).isEmpty)
        #expect(s.timers[.micro]?.dueDate == now + minutes(57))

        // 3 分钟后长休息正常开始
        let events = s.tick(now: t0 + minutes(60), idleSeconds: 0)
        guard case .breakStarted(let session) = events.first else {
            Issue.record("应该开始长休息"); return
        }
        #expect(session.kind == .long)
    }

    @Test func 开始长休息时重置微休息_完成后再重置一次() {
        var s = BreakScheduler(settings: settings, now: t0)
        _ = s.startBreakNow(.long, now: t0 + minutes(10))
        #expect(s.timers[.micro]?.dueDate == t0 + minutes(30))

        let end = t0 + minutes(15)
        #expect(s.tick(now: end, idleSeconds: 0) == [.breakEnded(.long, .completed)])
        #expect(s.timers[.micro]?.dueDate == end + minutes(20))
        #expect(s.timers[.long]?.dueDate == end + minutes(60))
    }

    @Test func 两个同时到期时取优先级高的长休息() {
        var custom = settings
        custom[.micro].interval = minutes(60)
        var s = BreakScheduler(settings: custom, now: t0)
        let events = s.tick(now: t0 + minutes(60), idleSeconds: 0)
        guard case .breakStarted(let session) = events.first else {
            Issue.record("应该开始休息"); return
        }
        #expect(session.kind == .long)
    }

    // MARK: - 推迟 / 跳过

    @Test func 推迟会延后并计数_达到上限后不能再推迟() {
        var s = BreakScheduler(settings: settings, now: t0)
        var now = t0 + minutes(20)
        _ = s.tick(now: now, idleSeconds: 0)

        for round in 1...2 {
            #expect(s.canPostponeCurrentBreak)
            #expect(s.postpone(now: now) == [.breakEnded(.micro, .postponed)])
            #expect(s.timers[.micro]?.postponeCount == round)
            #expect(s.timers[.micro]?.dueDate == now + minutes(2))
            now = now + minutes(2)
            _ = s.tick(now: now, idleSeconds: 0)
        }

        // 已推迟 2 次（默认上限），第三次不允许
        #expect(!s.canPostponeCurrentBreak)
        #expect(s.postpone(now: now).isEmpty)

        // 跳过后计数清零
        #expect(s.skip(now: now) == [.breakEnded(.micro, .skipped)])
        #expect(s.timers[.micro] == BreakTimer(dueDate: now + minutes(20)))
    }

    @Test func 严格模式下不能推迟和跳过() {
        var custom = settings
        custom.strictMode = true
        var s = BreakScheduler(settings: custom, now: t0)
        _ = s.tick(now: t0 + minutes(20), idleSeconds: 0)
        #expect(!s.canPostponeCurrentBreak)
        #expect(!s.canSkipCurrentBreak)
        #expect(s.postpone(now: t0 + minutes(20)).isEmpty)
        #expect(s.skip(now: t0 + minutes(20)).isEmpty)
    }

    // MARK: - 离开 / 自然休息

    @Test func 闲置超过阈值视为离开_回来后离开够久的休息算完成() {
        var s = BreakScheduler(settings: settings, now: t0)
        // 第 10 分钟时已经闲置了 5 分钟 → 从第 5 分钟起算离开
        #expect(s.tick(now: t0 + minutes(10), idleSeconds: minutes(5)).isEmpty)
        #expect(s.state == .away(since: t0 + minutes(5)))

        // 离开期间即使到期也不弹休息
        #expect(s.tick(now: t0 + minutes(25), idleSeconds: minutes(20)).isEmpty)

        // 第 8 分钟前离开（3 分钟），共离开 3 分钟：微休息（20 秒）算完成，长休息（5 分钟）顺延 3 分钟
        var s2 = BreakScheduler(settings: settings, now: t0)
        s2.enterAway(now: t0 + minutes(5))
        let back = t0 + minutes(8)
        let events = s2.tick(now: back, idleSeconds: 0, systemAway: false)
        #expect(events == [.naturalBreakDetected(awayDuration: minutes(3), completed: [.micro])])
        #expect(s2.timers[.micro]?.dueDate == back + minutes(20))
        #expect(s2.timers[.long]?.dueDate == t0 + minutes(63))
        #expect(s2.state == .running)
    }

    @Test func 锁屏期间保持离开状态() {
        var s = BreakScheduler(settings: settings, now: t0)
        #expect(s.tick(now: t0 + minutes(1), idleSeconds: 0, systemAway: true).isEmpty)
        #expect(s.state == .away(since: t0 + minutes(1)))
        #expect(s.tick(now: t0 + minutes(30), idleSeconds: 0, systemAway: true).isEmpty)

        let back = t0 + minutes(30)
        let events = s.tick(now: back, idleSeconds: 0, systemAway: false)
        #expect(events == [.naturalBreakDetected(awayDuration: minutes(29), completed: [.micro, .long])])
        #expect(s.timers[.long]?.dueDate == back + minutes(60))
    }

    // MARK: - 暂停 / 恢复 / 重置

    @Test func 定时暂停到点后自动恢复并重新计时() {
        var s = BreakScheduler(settings: settings, now: t0)
        _ = s.pause(until: t0 + minutes(30), now: t0)
        #expect(s.tick(now: t0 + minutes(25), idleSeconds: 0).isEmpty)
        #expect(s.tick(now: t0 + minutes(30), idleSeconds: 0) == [.pauseEnded])
        #expect(s.timers[.micro]?.dueDate == t0 + minutes(50))
        #expect(s.state == .running)
    }

    @Test func 无限期暂停需要手动恢复() {
        var s = BreakScheduler(settings: settings, now: t0)
        _ = s.pause(until: nil, now: t0)
        #expect(s.tick(now: t0 + minutes(500), idleSeconds: 0).isEmpty)
        s.resume(now: t0 + minutes(500))
        #expect(s.state == .running)
        #expect(s.timers[.long]?.dueDate == t0 + minutes(560))
    }

    @Test func 休息中暂停会中断当前休息() {
        var s = BreakScheduler(settings: settings, now: t0)
        _ = s.tick(now: t0 + minutes(20), idleSeconds: 0)
        let events = s.pause(until: nil, now: t0 + minutes(20))
        #expect(events == [.breakEnded(.micro, .interrupted)])
        #expect(s.state == .paused(until: nil))
    }

    @Test func 修改设置只重置变化的休息() {
        var s = BreakScheduler(settings: settings, now: t0)
        var changed = settings
        changed[.micro].interval = minutes(30)
        s.updateSettings(changed, now: t0 + minutes(10))
        #expect(s.timers[.micro]?.dueDate == t0 + minutes(40))
        #expect(s.timers[.long]?.dueDate == t0 + minutes(60))
    }

    // MARK: - 下次休息

    @Test func 下次休息考虑优先级跳过规则() {
        var custom = settings
        custom[.micro].interval = minutes(57)
        let s = BreakScheduler(settings: custom, now: t0)
        let next = s.nextBreak()
        #expect(next?.kind == .long)
        #expect(next?.dueDate == t0 + minutes(60))

        let normal = BreakScheduler(settings: settings, now: t0)
        #expect(normal.nextBreak()?.kind == .micro)
    }
}

struct TimeTextTests {
    @Test func 菜单栏倒计时格式() {
        #expect(TimeText.menuBarCountdown(31 * 60 + 1) == "32分")
        #expect(TimeText.menuBarCountdown(60) == "1分")
        #expect(TimeText.menuBarCountdown(44.2) == "45秒")
        #expect(TimeText.menuBarCountdown(0) == "0秒")
    }

    @Test func 明早八点() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let night = cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 22))!
        let earlyMorning = cal.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 2))!
        let expected = cal.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 8))!
        #expect(TimeText.nextMorning(after: night, calendar: cal) == expected)
        #expect(TimeText.nextMorning(after: earlyMorning, calendar: cal) == expected)
    }
}
