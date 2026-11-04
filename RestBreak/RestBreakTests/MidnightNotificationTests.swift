import Foundation
import Testing
@testable import RestBreak

/// 2026-11-04 用户反馈每天早上星期五不见了：系统在零点从后台线程发 NSCalendarDayChanged，
/// 主线程限定的 selector 被直接调用，Swift 的线程检查让整个进程崩溃。
@MainActor
struct MidnightNotificationTests {
    @Test func 后台线程发来的零点通知在主线程处理且不崩溃() async {
        var ranOnMain = false
        let tokens = MainThreadObserver.observe([.NSCalendarDayChanged, .NSSystemClockDidChange, .NSSystemTimeZoneDidChange]) {
            ranOnMain = Thread.isMainThread
        }
        defer { MainThreadObserver.remove(tokens) }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
                done.resume()
            }
        }
        // 处理被排到主队列上，让出一次再检查
        for _ in 0..<20 where !ranOnMain { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(ranOnMain)
    }
}
