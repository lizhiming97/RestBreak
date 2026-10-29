import Foundation
import Testing
@testable import RestBreak

/// 资源占用：没事的时候不写盘
@MainActor
struct ResourceTests {
    func modified(_ store: ReminderStore) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: store.fileURL.path))?[.modificationDate] as? Date
    }

    @Test func 没有变化时提醒处理不写盘() async throws {
        let store = RT.tempStore()
        let coordinator = ReminderCoordinator(store: store)
        coordinator.check(now: Date())           // 第一次：记下起点，会写一次
        let first = try #require(modified(store))
        try await Task.sleep(for: .milliseconds(1100))
        coordinator.check(now: Date().addingTimeInterval(30))
        coordinator.check(now: Date().addingTimeInterval(60))
        #expect(modified(store) == first, "只有「处理到哪了」变化，不应该重写数据文件")
    }

    @Test func 有提醒到点时照常写盘并且不漏() async throws {
        let store = RT.tempStore()
        let coordinator = ReminderCoordinator(store: store)
        let start = Date()
        coordinator.check(now: start)
        try store.update { $0.reminders.append(RT.reminder(.once(at: start.addingTimeInterval(120)), created: "2020-01-01 00:00")) }
        coordinator.check(now: start.addingTimeInterval(60))    // 还没到点：不写
        coordinator.check(now: start.addingTimeInterval(121))   // 到点：记下这次响铃
        let data = try store.load()
        #expect(data.occurrences.count == 1)
        #expect(data.reminders.first?.state == .finished)
    }
}
