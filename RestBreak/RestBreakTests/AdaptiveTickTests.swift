import Foundation
import Testing
@testable import RestBreak

/// 省电的「空闲时放慢 tick」不能改变休息的行为：
/// 同一条随机生成的一天（工作、离开、开会、全屏、指定 App、锁屏、日程），
/// 逐秒 tick 和按 nextTickInterval 放慢 tick，开始和结束每次休息的种类、时刻必须完全一样。
struct AdaptiveTickTests {
    enum Activity { case working, away, meeting, fullscreen, focusApp, locked }
    struct Segment { let start: Int; let activity: Activity }
    struct Change: Equatable, CustomStringConvertible {
        let second: Int; let what: String
        var description: String { "\(second / 60)分\(second % 60)秒 \(what)" }
    }

    func timeline(seed: UInt64, seconds: Int) -> ([Segment], [DateInterval]) {
        var rng = DaySimulationTests.SeededRandom(state: seed)
        var segments: [Segment] = []
        var t = 0
        while t < seconds {
            let roll = Int.random(in: 0..<100, using: &rng)
            let activity: Activity = switch roll {
            case 0..<55: .working
            case 55..<67: .away
            case 67..<77: .meeting
            case 77..<87: .fullscreen
            case 87..<95: .focusApp
            default: .locked
            }
            segments.append(Segment(start: t, activity: activity))
            t += Int.random(in: 60...2400, using: &rng)
        }
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let events = (0..<Int.random(in: 0...6, using: &rng)).map { _ in
            DateInterval(start: t0 + TimeInterval(Int.random(in: 0..<(seconds - 3600), using: &rng)),
                         duration: TimeInterval(Int.random(in: 15...90, using: &rng) * 60))
        }
        return (segments, events)
    }

    func run(seed: UInt64, adaptive: Bool) -> (changes: [Change], ticks: Int) {
        let seconds = 8 * 3600
        let (segments, calendar) = timeline(seed: seed, seconds: seconds)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var s = BreakScheduler(settings: .default, now: t0)
        var changes: [Change] = []
        var ticks = 0
        var second = 0
        while second < seconds {
            let segIndex = segments.lastIndex { $0.start <= second }!
            let seg = segments[segIndex]
            let idle = seg.activity == .away ? TimeInterval(second - seg.start) : 0
            let now = t0 + TimeInterval(second)
            let events = s.tick(now: now, idleSeconds: idle, systemAway: seg.activity == .locked,
                                inMeeting: seg.activity == .meeting, fullscreen: seg.activity == .fullscreen,
                                focusApp: seg.activity == .focusApp, calendarEvents: calendar)
            ticks += 1
            for event in events {
                switch event {
                case .breakStarted(let session): changes.append(Change(second: second, what: "开始\(session.kind.displayName)"))
                case .breakEnded(let kind, let reason): changes.append(Change(second: second, what: "结束\(kind.displayName) \(reason)"))
                case .naturalBreakDetected(let d, let c): changes.append(Change(second: second, what: "自然休息 \(Int(d)) \(c.map(\.rawValue))"))
                default: break
                }
            }
            // 放慢模式：下一次 tick 在 nextTickInterval 之后，但活动切换的那一秒外层也会醒（真实 App 里由事件唤醒）
            var step = 1
            if adaptive {
                step = max(1, Int(s.nextTickInterval(now: now).rounded(.down)))
                // 真实 App 里有系统事件的切换（开会、全屏、切 App、锁屏）会立刻唤醒；
                // 离开状态下监听鼠标，人一回来就唤醒；只有「开始离开」没有事件，靠闲置秒数倒推
                if let next = segments.first(where: { $0.start > second }),
                   !(seg.activity == .working && next.activity == .away) {
                    step = min(step, next.start - second)
                }
            }
            second += step
        }
        return (changes, ticks)
    }

    @Test(arguments: 1...20)
    func 放慢tick不改变休息行为(seed: Int) {
        let fast = run(seed: UInt64(seed), adaptive: false)
        let slow = run(seed: UInt64(seed), adaptive: true)
        #expect(slow.changes == fast.changes, "第一处不同：\(zip(fast.changes, slow.changes).first { $0 != $1 }.map { "逐秒 \($0) / 放慢 \($1)" } ?? "数量不同 \(fast.changes.count) vs \(slow.changes.count)")")
        // 确实省了：tick 次数至少降到三分之一（全屏推迟期间仍逐秒）
        if let i = Array(zip(fast.changes, slow.changes)).firstIndex(where: { $0 != $1 }) {
            print("DIFF 种子 \(seed) 逐秒：\(fast.changes[max(0,i-2)...min(fast.changes.count-1,i+1)]) ｜ 放慢：\(slow.changes[max(0,i-2)...min(slow.changes.count-1,i+1)])")
        }
        print("TICKS 种子 \(seed)：逐秒 \(fast.ticks) 次，放慢后 \(slow.ticks) 次")
        #expect(slow.ticks * 3 < fast.ticks, "逐秒 \(fast.ticks) 次，放慢后 \(slow.ticks) 次")
    }
}
