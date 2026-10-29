import Foundation
import Testing
@testable import RestBreak

/// 指定 App 规则：前台是指定的 App 时推迟休息，和全屏共用「最多推迟」上限
struct FocusAppTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 0)
    let settings = AppSettings.default

    func minutes(_ m: Double) -> TimeInterval { m * 60 }

    func run(_ s: inout BreakScheduler, from start: Date, to end: Date,
             idle: TimeInterval = 0, focusApp: Bool = true) -> [SchedulerEvent] {
        var events: [SchedulerEvent] = []
        var now = start
        while now < end {
            events += s.tick(now: now, idleSeconds: idle, focusApp: focusApp)
            now += 1
        }
        return events
    }

    func startedKind(_ events: [SchedulerEvent]) -> BreakKind? {
        for case .breakStarted(let session) in events { return session.kind }
        return nil
    }

    @Test func 使用指定App时到期不弹_切走后立即弹() {
        var s = BreakScheduler(settings: settings, now: t0)
        #expect(startedKind(run(&s, from: t0 + minutes(19), to: t0 + minutes(25))) == nil)
        #expect(s.isDeferringBreak)
        #expect(s.isUsingFocusApp)
        #expect(startedKind(s.tick(now: t0 + minutes(25), idleSeconds: 0, focusApp: false)) == .micro)
    }

    @Test func 一直使用指定App时受最多推迟上限() {
        var s = BreakScheduler(settings: settings, now: t0)
        let due = t0 + minutes(20)
        #expect(startedKind(run(&s, from: due, to: due + minutes(30))) == nil)
        #expect(startedKind(s.tick(now: due + minutes(30), idleSeconds: 0, focusApp: true)) == .micro)
    }

    @Test func 指定App中长时间不操作仍算离开() {
        var s = BreakScheduler(settings: settings, now: t0)
        _ = s.tick(now: t0 + minutes(10), idleSeconds: minutes(6), focusApp: true)
        #expect(s.state == .away(since: t0 + minutes(4)))
    }

    @Test func 关闭指定App规则后照常弹出() {
        var custom = settings
        custom.postponeDuringFocusApps = false
        var s = BreakScheduler(settings: custom, now: t0)
        #expect(startedKind(s.tick(now: t0 + minutes(20), idleSeconds: 0, focusApp: true)) == .micro)
    }

    @Test func 指定App列表能保存和读取() throws {
        var custom = settings
        custom.focusApps = [FocusApp(bundleID: "com.apple.iWork.Keynote", name: "Keynote")]
        let data = try JSONEncoder().encode(custom)
        let loaded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(loaded.focusApps == custom.focusApps)
    }
}
