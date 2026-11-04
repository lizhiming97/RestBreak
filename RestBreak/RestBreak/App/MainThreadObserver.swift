import Foundation

/// 监听可能从后台线程发出的系统通知，并保证处理放在主线程上。
/// 改时间、改时区、过零点（NSCalendarDayChanged）这几个通知系统会从后台线程发；
/// 直接用 selector 指向主线程限定的方法，Swift 6 的线程检查会让整个 App 崩溃（2026-11-04 每天零点闪退）。
@MainActor
enum MainThreadObserver {
    static func observe(_ names: [Notification.Name], center: NotificationCenter = .default,
                        _ action: @escaping @MainActor () -> Void) -> [NSObjectProtocol] {
        names.map { name in
            // queue: .main 让系统把通知转到主队列再调用
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { action() }
            }
        }
    }

    static func remove(_ tokens: [NSObjectProtocol], center: NotificationCenter = .default) {
        tokens.forEach(center.removeObserver)
    }
}
