import Foundation
import Testing
@testable import RestBreak

/// 会议检测相关的调度测试（「在开会」= 有 App 正在用麦克风）
struct MeetingTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 0)
    let settings = AppSettings.default

    func minutes(_ m: Double) -> TimeInterval { m * 60 }

    /// 模拟一场会议：从 start 到 end（不含）每秒 tick 一次，麦克风一直开着，返回期间的所有事件
    func runMeeting(_ s: inout BreakScheduler, from start: Date, to end: Date) -> [SchedulerEvent] {
        var events: [SchedulerEvent] = []
        var now = start
        while now < end {
            events += s.tick(now: now, idleSeconds: 0, inMeeting: true)
            now += 1
        }
        return events
    }

    @Test func 会议中到期的休息先不弹_会议结束1分钟后再弹() {
        var s = BreakScheduler(settings: settings, now: t0)
        // 第 15～45 分钟在开会，第 20 分钟微休息到期但不弹
        #expect(runMeeting(&s, from: t0 + minutes(15), to: t0 + minutes(45)).isEmpty)
        #expect(s.isInMeeting)

        // 第 45 分钟会议结束，1 分钟缓冲期内仍不弹
        #expect(s.tick(now: t0 + minutes(45), idleSeconds: 0, inMeeting: false).isEmpty)
        #expect(s.isInMeeting)

        // 缓冲期过后弹出
        let events = s.tick(now: t0 + minutes(46), idleSeconds: 0, inMeeting: false)
        guard case .breakStarted(let session) = events.first else {
            Issue.record("会议结束后应该开始休息"); return
        }
        #expect(session.kind == .micro)
        #expect(!s.isInMeeting)
    }

    @Test func 会议中长时间不操作不算离开() {
        var s = BreakScheduler(settings: settings, now: t0)
        #expect(s.tick(now: t0 + minutes(10), idleSeconds: minutes(8), inMeeting: true).isEmpty)
        #expect(s.state == .running)
    }

    @Test func 会议中睡眠或锁屏仍算离开() {
        var s = BreakScheduler(settings: settings, now: t0)
        _ = s.tick(now: t0 + minutes(10), idleSeconds: 0, systemAway: true, inMeeting: true)
        #expect(s.state == .away(since: t0 + minutes(10)))
    }

    @Test func 休息中开始开会_立即结束休息且不算推迟_会后补上() {
        var s = BreakScheduler(settings: settings, now: t0)
        let start = t0 + minutes(60)
        _ = s.tick(now: start, idleSeconds: 0)   // 长休息开始
        // 休息第 30 秒来了会议，开到第 20 分钟
        let meetingEvents = runMeeting(&s, from: start + 30, to: start + minutes(20))
        #expect(meetingEvents == [.breakEnded(.long, .meetingStarted)])
        #expect(s.state == .running)
        #expect(s.timers[.long]?.postponeCount == 0)

        // 会议结束，1 分钟缓冲期内不弹，之后长休息补上
        #expect(s.tick(now: start + minutes(20), idleSeconds: 0, inMeeting: false).isEmpty)
        let events = s.tick(now: start + minutes(21), idleSeconds: 0, inMeeting: false)
        guard case .breakStarted(let session) = events.first else {
            Issue.record("会议后应该补上长休息"); return
        }
        #expect(session.kind == .long)
    }

    @Test func 开着麦克风时手动开始的休息不会被打断() {
        var s = BreakScheduler(settings: settings, now: t0)
        _ = s.tick(now: t0 + minutes(1), idleSeconds: 0, inMeeting: true)
        _ = s.startBreakNow(.micro, now: t0 + minutes(2))
        #expect(s.tick(now: t0 + minutes(2) + 5, idleSeconds: 0, inMeeting: true).isEmpty)
        guard case .onBreak = s.state else {
            Issue.record("手动开始的休息应该继续"); return
        }
    }

    @Test func 关闭会议检测后开会也照常弹出() {
        var custom = settings
        custom.postponeDuringMeetings = false
        var s = BreakScheduler(settings: custom, now: t0)
        let events = s.tick(now: t0 + minutes(20), idleSeconds: 0, inMeeting: true)
        #expect(!s.isInMeeting)
        guard case .breakStarted = events.first else {
            Issue.record("关闭会议检测后应该照常开始休息"); return
        }
    }
}
