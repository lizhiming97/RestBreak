import Foundation

enum StoreError: Error, Equatable, CustomStringConvertible {
    case noContainer
    case newerSchema(Int)
    case corrupt(String)
    case io(String)

    var description: String {
        switch self {
        case .noContainer: "拿不到星期五的共享文件夹（App Group 权限没配好）"
        case .newerSchema(let v): "提醒数据是新版星期五写的（版本 \(v)），请更新星期五"
        case .corrupt(let detail): "提醒数据文件损坏：\(detail)"
        case .io(let detail): "读写提醒数据失败：\(detail)"
        }
    }
}

/// 提醒数据存在 App Group 共享文件夹里的 Reminders/store.json。
/// 主 App 和多个小程序（Claude、Codex 各启动一个）可能同时写，
/// 所以「读 → 改 → 写」整个过程都放在文件锁里，写的时候先写临时文件再替换（.atomic）。
struct ReminderStore: Sendable {
    let fileURL: URL

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("store.json")
    }

    /// 正式的数据位置。环境变量 XIEYIHUI_STORE=test 时用 Reminders-test，端到端测试不碰真实数据
    static func shared() throws -> ReminderStore {
        guard let base = AppGroup.containerURL else { throw StoreError.noContainer }
        let folder = ProcessInfo.processInfo.environment["XIEYIHUI_STORE"] == "test" ? "Reminders-test" : "Reminders"
        return ReminderStore(directory: base.appendingPathComponent(folder, isDirectory: true))
    }

    func load() throws -> ReminderData {
        try withLock(LOCK_SH) { try read() }
    }

    /// 在锁里读出数据交给 body 修改；改了才写回，写完发 Darwin 通知（notify 为 false 时不发）
    @discardableResult
    func update<T>(notify: Bool = true, _ body: (inout ReminderData) throws -> T) throws -> T {
        let (result, changed) = try withLock(LOCK_EX) { () throws -> (T, Bool) in
            var data = try read()
            let before = data
            let result = try body(&data)
            let changed = data != before
            if changed { try write(data) }
            return (result, changed)
        }
        if changed && notify { DarwinNotice.post(DarwinNotice.remindersChanged) }
        return result
    }

    private func read() throws -> ReminderData {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return ReminderData() }   // 还没有文件
        let raw: Data
        do {
            raw = try Data(contentsOf: fileURL)
        } catch {
            // 读不了（权限、磁盘出错）一定要报错：当成空数据的话，下一次写入会把所有提醒清空
            throw StoreError.io(error.localizedDescription)
        }
        struct Header: Decodable { var schemaVersion: Int }
        guard let header = try? Self.decoder.decode(Header.self, from: raw) else {
            throw StoreError.corrupt("没有版本号")
        }
        if header.schemaVersion > ReminderData.currentSchema { throw StoreError.newerSchema(header.schemaVersion) }
        do {
            return try Self.decoder.decode(ReminderData.self, from: raw)
        } catch {
            throw StoreError.corrupt(error.localizedDescription)
        }
    }

    private func write(_ data: ReminderData) throws {
        do {
            try Self.encoder.encode(data).write(to: fileURL, options: .atomic)
        } catch {
            throw StoreError.io(error.localizedDescription)
        }
    }

    /// 锁加在单独的 .lock 文件上：store.json 每次都被整个替换，锁不能加在它身上
    private func withLock<T>(_ operation: Int32, _ body: () throws -> T) throws -> T {
        let folder = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw StoreError.io(error.localizedDescription)
        }
        let fd = open(folder.appendingPathComponent(".lock").path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { throw StoreError.io("打不开锁文件") }
        defer { close(fd) }
        guard flock(fd, operation) == 0 else { throw StoreError.io("加锁失败") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
