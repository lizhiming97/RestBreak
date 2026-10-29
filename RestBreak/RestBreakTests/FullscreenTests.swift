import Foundation
import Testing
@testable import RestBreak

/// 全屏检测相关的调度测试：全屏时推迟休息，但最多推迟 30 分钟（默认）
struct FullscreenTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 0)
    let settings = AppSettings.default

    func minutes(_ m: Double) -> TimeInterval { m * 60 }

    /// 每秒 tick 一次，返回期间所有事件
    func run(_ s: inout BreakScheduler, from start: Date, to end: Date,
             idle: TimeInterval = 0, fullscreen: Bool = true) -> [SchedulerEvent] {
        var events: [SchedulerEvent] = []
        var now = start
        while now < end {
            events += s.tick(now: now, idleSeconds: idle, fullscreen: fullscreen)
            now += 1
        }
        return events
    }

    func startedKind(_ events: [SchedulerEvent]) -> BreakKind? {
        for case .breakStarted(let session) in events { return session.kind }
        return nil
    }

    @Test func 全屏时到期不弹_退出全屏后立即弹() {
        var s = BreakScheduler(settings: settings, now: t0)
        #expect(run(&s, from: t0 + minutes(19), to: t0 + minutes(25)).isEmpty)
        #expect(s.isDeferringBreak)
        let events = s.tick(now: t0 + minutes(25), idleSeconds: 0, fullscreen: false)
        #expect(startedKind(events) == .micro)
        #expect(!s.isDeferringBreak)
    }

    @Test func 一直全屏时最多推迟30分钟() {
        var s = BreakScheduler(settings: settings, now: t0)
        let due = t0 + minutes(20)
        #expect(startedKind(run(&s, from: due, to: due + minutes(30))) == nil)
        let events = s.tick(now: due + minutes(30), idleSeconds: 0, fullscreen: true)
        #expect(startedKind(events) == .micro)
    }

    @Test func 推迟上限可调() {
        var custom = settings
        custom.maxDeferral = minutes(10)
        var s = BreakScheduler(settings: custom, now: t0)
        let due = t0 + minutes(20)
        #expect(startedKind(run(&s, from: due, to: due + minutes(10))) == nil)
        #expect(startedKind(s.tick(now: due + minutes(10), idleSeconds: 0, fullscreen: true)) == .micro)
    }

    @Test func 全屏中不碰键盘鼠标不算离开() {
        var s = BreakScheduler(settings: settings, now: t0)
        _ = s.tick(now: t0 + minutes(10), idleSeconds: minutes(8), fullscreen: true)
        #expect(s.state == .running)
    }

    @Test func 开会优先于全屏_开会时不计入全屏推迟时长() {
        var s = BreakScheduler(settings: settings, now: t0)
        let due = t0 + minutes(20)
        // 全屏开会 40 分钟：会议规则生效，不会因为全屏上限而弹出
        var now = due
        var events: [SchedulerEvent] = []
        while now < due + minutes(40) {
            events += s.tick(now: now, idleSeconds: 0, inMeeting: true, fullscreen: true)
            now += 1
        }
        #expect(events.isEmpty)
    }

    @Test func 关闭全屏检测后照常弹出() {
        var custom = settings
        custom.postponeDuringFullscreen = false
        var s = BreakScheduler(settings: custom, now: t0)
        #expect(startedKind(s.tick(now: t0 + minutes(20), idleSeconds: 0, fullscreen: true)) == .micro)
    }
}
