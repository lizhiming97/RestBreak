import Foundation
import Testing
@testable import RestBreak

/// 代码审查发现的问题，每个先写测试复现，再修复
struct ReviewFixTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 0)
    let settings = AppSettings.default

    func minutes(_ m: Double) -> TimeInterval { m * 60 }

    /// 每秒 tick 一次，条件由闭包按时间给出，返回期间所有事件
    func run(_ s: inout BreakScheduler, from start: Date, to end: Date,
             idle: (Date) -> TimeInterval = { _ in 0 },
             meeting: (Date) -> Bool = { _ in false },
             fullscreen: (Date) -> Bool = { _ in false }) -> [(Date, SchedulerEvent)] {
        var events: [(Date, SchedulerEvent)] = []
        var now = start
        while now < end {
            for e in s.tick(now: now, idleSeconds: idle(now), inMeeting: meeting(now), fullscreen: fullscreen(now)) {
                events.append((now, e))
            }
            now += 1
        }
        return events
    }

    func firstStart(_ events: [(Date, SchedulerEvent)]) -> (Date, BreakKind)? {
        for (date, event) in events { if case .breakStarted(let s) = event { return (date, s.kind) } }
        return nil
    }

    @Test func 问题1_全屏推迟途中开会_开会时间不计入推迟上限() {
        var s = BreakScheduler(settings: settings, now: t0)
        let due = t0 + minutes(20)
        // 一直全屏；推迟 10 分钟后开会 40 分钟
        let meetingRange = (due + minutes(10))..<(due + minutes(50))
        let events = run(&s, from: due - 5, to: due + minutes(80),
                         meeting: { meetingRange.contains($0) }, fullscreen: { _ in true })
        // 推迟计时：会前 10 分钟 + 会后（含 1 分钟缓冲期）20 分钟 → 约 due + 71 分钟弹出
        let start = firstStart(events)
        #expect(start != nil)
        if let (date, _) = start {
            #expect(date >= due + minutes(70), "开会时间被算进了推迟上限，\(date.timeIntervalSince(due) / 60) 分钟就弹了")
            #expect(date <= due + minutes(72))
        }
    }

    @Test func 问题2_推迟满上限时弹出的是下一个要到期的休息() {
        var s = BreakScheduler(settings: settings, now: t0)
        // 微休息 T 到期，长休息 T+33 到期，一直全屏
        var custom = settings
        custom[.long].interval = minutes(53)
        s = BreakScheduler(settings: custom, now: t0)
        let due = t0 + minutes(20)
        let events = run(&s, from: due - 5, to: due + minutes(31), fullscreen: { _ in true })
        let start = firstStart(events)
        #expect(start?.1 != nil, "推迟满 30 分钟后没有任何休息弹出")
        #expect(start?.1 == .micro)
        if let (date, _) = start { #expect(date == due + minutes(30)) }
    }

    @Test func 问题3_开会结束后没操作_不把整场会追溯成离开() {
        var s = BreakScheduler(settings: settings, now: t0)
        // 第 1 分钟开始最后一次操作，开 60 分钟网课不碰键盘，会后又过 3 分钟才碰
        let meetingEnd = t0 + minutes(61)
        let touch = meetingEnd + minutes(3)
        let events = run(&s, from: t0 + minutes(1), to: touch + 2,
                         idle: { $0 < touch ? $0.timeIntervalSince(t0 + minutes(1)) : 0 },
                         meeting: { $0 < meetingEnd })
        for (_, e) in events {
            if case .naturalBreakDetected(let duration, _) = e {
                Issue.record("把 \(Int(duration / 60)) 分钟的会议当成了离开")
            }
        }
    }

    @Test func 问题6_全屏时点推迟_按推迟时长回来_不再重新推迟30分钟() {
        var s = BreakScheduler(settings: settings, now: t0)
        let due = t0 + minutes(20)
        _ = run(&s, from: due - 5, to: due + minutes(30) + 1, fullscreen: { _ in true })
        guard case .onBreak = s.state else { Issue.record("推迟满上限后应该在休息中"); return }
        let postponedAt = due + minutes(30) + 1
        _ = s.postpone(now: postponedAt)
        let events = run(&s, from: postponedAt, to: postponedAt + minutes(5), fullscreen: { _ in true })
        let start = firstStart(events)
        #expect(start?.0 == postponedAt + minutes(2), "点了推迟 2 分钟，却没有在 2 分钟后回来")
    }

    @Test func 问题7_暂停中手动开始休息_休息结束后仍保持暂停() {
        var s = BreakScheduler(settings: settings, now: t0)
        _ = s.pause(until: nil, now: t0)
        _ = s.startBreakNow(.micro, now: t0 + minutes(5))
        _ = run(&s, from: t0 + minutes(5), to: t0 + minutes(6))
        #expect(s.state == .paused(until: nil))
    }

    @Test func 问题4_严格模式下休息中不能用暂停结束休息() {
        var custom = settings
        custom.strictMode = true
        var s = BreakScheduler(settings: custom, now: t0)
        _ = s.tick(now: t0 + minutes(20), idleSeconds: 0)
        #expect(s.pause(until: nil, now: t0 + minutes(20) + 5).isEmpty)
        guard case .onBreak = s.state else { Issue.record("严格模式下休息被暂停打断了"); return }
    }
}
