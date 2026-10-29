import Foundation
import Testing
@testable import RestBreak

/// 整体测试：逐秒模拟很多个 8 小时工作日，随机穿插各种情况，检查调度规则在混合场景下始终成立。
/// 用固定的随机种子，失败时可以稳定复现。
struct DaySimulationTests {
    /// 可设定种子的随机数生成器（SplitMix64）
    struct SeededRandom: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// 一段时间里用户在做什么
    enum Activity: CaseIterable {
        case working, away, meeting, fullscreen, focusApp, locked
    }

    struct Violation: CustomStringConvertible {
        let seed: UInt64
        let second: Int
        let message: String
        var description: String { "种子 \(seed) 第 \(second / 60) 分 \(second % 60) 秒：\(message)" }
    }

    @Test(arguments: 1...20)
    func 模拟一个工作日(seed: Int) {
        let (violations, stats) = simulateDay(seed: UInt64(seed), strict: seed % 5 == 0)
        #expect(violations.isEmpty, "\(violations.prefix(5))")
        // 确认模拟真的覆盖到了各种情况，而不是什么都没发生
        #expect(stats.breaksStarted >= 8, "一天只弹了 \(stats.breaksStarted) 次休息")
        print("SIM 种子 \(seed)：休息 \(stats.breaksStarted) 次（推迟满上限后弹出 \(stats.forcedAfterDeferral) 次），推迟中 \(stats.secondsDeferred / 60) 分钟，用户推迟 \(stats.postponed) 次、跳过 \(stats.skipped) 次，自然休息 \(stats.naturalBreaks) 次")
    }

    struct Stats {
        var breaksStarted = 0
        var forcedAfterDeferral = 0
        var secondsDeferred = 0
        var postponed = 0
        var skipped = 0
        var naturalBreaks = 0
        var secondsInEvent = 0
        var pulledForward = 0
    }

    @Test func 二十天合计覆盖到各种情况() {
        var deferred = 0, inEvent = 0, pulled = 0
        for seed in 1...20 {
            let stats = simulateDay(seed: UInt64(seed), strict: seed % 5 == 0).1
            deferred += stats.secondsDeferred
            inEvent += stats.secondsInEvent
            pulled += stats.pulledForward
        }
        #expect(deferred > 0, "20 天里没有发生过全屏/指定 App 推迟")
        #expect(inEvent > 0, "20 天里没有遇到过日程")
        #expect(pulled > 0, "20 天里没有为日程提前过休息")
    }

    func simulateDay(seed: UInt64, strict: Bool) -> ([Violation], Stats) {
        var stats = Stats()
        var rng = SeededRandom(state: seed)
        var settings = AppSettings.default
        settings.strictMode = strict
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var s = BreakScheduler(settings: settings, now: t0)

        var violations: [Violation] = []
        let daySeconds = 8 * 3600

        var activity = Activity.working
        var activityEndsAt = 0
        var idleSince = 0                 // 「离开」开始的秒数，用来算 idleSeconds
        var currentBreak: BreakSession?   // 正在进行的休息
        var lastBreakStartOrAction = 0    // 上一次开始休息、或用户做了会影响计时的操作的时刻
        var normalStretchStart: Int?      // 连续「正常工作、没暂停」开始的时刻
        var deferralEndsBefore: Date?     // 上一秒的推迟上限

        // 当天的日历：随机 0～6 个日程，每个 15～90 分钟
        var calendar: [DateInterval] = []
        for _ in 0..<Int.random(in: 0...6, using: &rng) {
            let start = t0 + TimeInterval(Int.random(in: 0..<(daySeconds - 3600), using: &rng))
            calendar.append(DateInterval(start: start, duration: TimeInterval(Int.random(in: 15...90, using: &rng) * 60)))
        }

        for second in 0..<daySeconds {
            let now = t0 + TimeInterval(second)

            // 1. 换活动：每段 1～40 分钟，正常工作的概率高一些
            if second >= activityEndsAt {
                let roll = Int.random(in: 0..<100, using: &rng)
                activity = switch roll {
                case 0..<55: .working
                case 55..<67: .away
                case 67..<77: .meeting
                case 77..<87: .fullscreen
                case 87..<95: .focusApp
                default: .locked
                }
                activityEndsAt = second + Int.random(in: 60...2400, using: &rng)
                if activity == .away { idleSince = second }
            }

            // 2. 偶尔的用户操作（休息外）
            var userActed = false
            if currentBreak == nil, Int.random(in: 0..<20_000, using: &rng) == 0 {
                if case .paused = s.state {
                    s.resume(now: now)
                } else {
                    _ = s.pause(until: now + 30 * 60, now: now)
                }
                userActed = true
            }
            var events: [SchedulerEvent] = []
            if currentBreak == nil, Int.random(in: 0..<30_000, using: &rng) == 0 {
                events += s.startBreakNow(.micro, now: now)   // 快捷键：现在开始微休息
                userActed = true
            }

            // 3. 休息中：随机推迟或跳过
            if currentBreak != nil, Int.random(in: 0..<40, using: &rng) == 0 {
                if Bool.random(using: &rng) {
                    events += s.postpone(now: now)
                } else {
                    events += s.skip(now: now)
                }
                if !events.isEmpty { userActed = true }
            }

            // 4. 这一秒的系统状态
            let idle = activity == .away ? TimeInterval(second - idleSince) : 0
            let meeting = activity == .meeting
            let fullscreen = activity == .fullscreen
            let focusApp = activity == .focusApp
            let locked = activity == .locked
            let stateBefore = s.state
            let deferralDeadline = s.deferralEndsAt ?? deferralEndsBefore
            events += s.tick(now: now, idleSeconds: idle, systemAway: locked,
                             inMeeting: meeting, fullscreen: fullscreen, focusApp: focusApp,
                             calendarEvents: calendar)
            deferralEndsBefore = s.deferralEndsAt
            if s.isDeferringBreak { stats.secondsDeferred += 1 }
            if s.isInCalendarEvent { stats.secondsInEvent += 1 }

            // 5. 检查规则
            func fail(_ message: String) {
                violations.append(Violation(seed: seed, second: second, message: message))
            }
            for event in events {
                switch event {
                case .breakStarted(let session):
                    if currentBreak != nil { fail("上一次休息还没结束，又开始了 \(session.kind.displayName)") }
                    if !userActed {
                        if meeting || s.isInMeeting { fail("开会时自动开始了休息") }
                        if locked { fail("锁屏时开始了休息") }
                        if calendar.contains(where: { $0.start <= now && now < $0.end }) {
                            fail("日程进行中自动开始了休息")
                        }
                        if case .paused = stateBefore { fail("暂停中自动开始了休息") }
                        if case .away = stateBefore { fail("离开状态下开始了休息") }
                        if (fullscreen || focusApp) && session.postponeCount == 0 {
                            if let deadline = deferralDeadline, now < deadline {
                                fail("全屏/指定 App 中，还没推迟满上限就开始了休息")
                            }
                        }
                    }
                    #expect(session.endsAt.timeIntervalSince(session.startedAt) == settings[session.kind].duration)
                    stats.breaksStarted += 1
                    if let due = s.timers[session.kind]?.dueDate, due > now, !userActed { stats.pulledForward += 1 }
                    if (fullscreen || focusApp) && !userActed { stats.forcedAfterDeferral += 1 }
                    currentBreak = session
                    lastBreakStartOrAction = second
                case .breakEnded(let kind, let reason):
                    guard let started = currentBreak else {
                        fail("没有进行中的休息，却收到了结束事件"); break
                    }
                    if started.kind != kind { fail("结束的休息种类和开始的不一致") }
                    if reason == .completed && now != started.endsAt { fail("休息没有按时结束") }
                    if strict && (reason == .postponed || reason == .skipped) { fail("严格模式下还能推迟或跳过") }
                    if reason == .postponed { stats.postponed += 1 }
                    if reason == .skipped { stats.skipped += 1 }
                    currentBreak = nil
                case .naturalBreakDetected:
                    stats.naturalBreaks += 1
                case .pauseEnded:
                    break
                }
            }
            if case .onBreak = s.state, currentBreak == nil { fail("引擎在休息中，但没收到开始事件") }

            // 6. 活性：连续正常工作（没暂停、没离开、也没有用户操作），不会超过 26 分钟还没有休息
            let paused: Bool = if case .paused = s.state { true } else { false }
            let normal = activity == .working && !paused && !s.isInMeeting && !s.isInCalendarEvent
                && currentBreak == nil && !userActed
            if normal {
                let start = normalStretchStart ?? second
                normalStretchStart = start
                let quietFor = second - max(start, lastBreakStartOrAction)
                if quietFor > 26 * 60 {
                    fail("连续正常工作 \(quietFor / 60) 分钟都没有休息")
                    normalStretchStart = nil
                }
            } else {
                normalStretchStart = nil
            }
            if userActed { lastBreakStartOrAction = second }
        }
        return (violations, stats)
    }
}
