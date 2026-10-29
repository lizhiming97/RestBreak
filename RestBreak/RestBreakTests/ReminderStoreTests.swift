import Foundation
import Testing
@testable import RestBreak

/// store.json：读写、加锁、版本号
struct ReminderStoreTests {
    @Test func 没有文件时是空数据() throws {
        #expect(try RT.tempStore().load() == ReminderData())
    }

    @Test func 写入后能读回() throws {
        let store = RT.tempStore()
        let r = RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []))
        try store.update { $0.reminders.append(r) }
        #expect(try store.load().reminders == [r])
    }

    @Test func 修改过程中出错就不写() throws {
        let store = RT.tempStore()
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try store.update { data in
                data.reminders.append(RT.reminder(.once(at: RT.d("2026-10-24 09:00"))))
                throw Boom()
            }
        }
        #expect(try store.load().reminders.isEmpty)
    }

    @Test func 新版本的数据拒绝读写() throws {
        let store = RT.tempStore()
        try store.update { $0.checkedAt = RT.d("2026-10-23 09:00") }
        let newer = #"{"schemaVersion":99,"reminders":[],"occurrences":[],"clients":[]}"#
        try Data(newer.utf8).write(to: store.fileURL)
        #expect(throws: StoreError.newerSchema(99)) { try store.load() }
        #expect(throws: StoreError.newerSchema(99)) { try store.update { $0.checkedAt = nil } }
        #expect(String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self) == newer)   // 没被覆盖
    }

    @Test func 坏文件报错且不覆盖() throws {
        let store = RT.tempStore()
        try store.update { $0.checkedAt = nil }
        try Data("{不是 json".utf8).write(to: store.fileURL)
        #expect(throws: StoreError.self) { try store.update { $0.checkedAt = nil } }
        #expect(String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self) == "{不是 json")
    }

    @Test func 同时写200次不丢数据() throws {
        let store = RT.tempStore()
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            try? store.update { $0.reminders.append(RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []), id: "r\(i)")) }
        }
        #expect(try store.load().reminders.count == 200)
    }

    @Test func 读不了文件时报错_不当成空数据覆盖() throws {
        let store = RT.tempStore()
        try store.update { $0.reminders.append(RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []))) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.fileURL.path) }
        #expect(throws: StoreError.self) { try store.update { $0.checkedAt = Date() } }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.fileURL.path)
        #expect(try store.load().reminders.count == 1)
    }
}
