// CC BY-NC 4.0. Friday integration: settings live in Friday's settings window, shared through the App Group.
import Foundation

/// 组件运行状态，写给星期五设置页显示。
public struct MouseStatus: Codable, Equatable {
    /// off 已关闭；permission 缺辅助功能权限；running 运行中；paused 锁屏/睡眠暂停；mos 检测到 Mos；failed 接管失败
    public var state: String
    public var message: String
    public init(state: String, message: String) { self.state = state; self.message = message }
}

/// 星期五写 config.json（设置），组件写 status.json（状态），各发一个 Darwin 通知告诉对方「变了」。
/// 文件格式是两边的约定：星期五主程序里有一份同字段的结构（不链接本组件代码）。
public enum SharedStore {
    public static let groupID = "B45N72QF4V.com.lizhiming.RestBreak"
    public static let configChanged = "com.lizhiming.RestBreak.mouse.config"
    public static let statusChanged = "com.lizhiming.RestBreak.mouse.status"

    public static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("MouseCompanion", isDirectory: true)
    }

    public static func decodeConfiguration(_ data: Data) -> ScrollConfiguration? {
        guard var value = try? JSONDecoder().decode(ScrollConfiguration.self, from: data) else { return nil }
        value.normalize()
        return value
    }

    public static func readConfiguration() -> ScrollConfiguration {
        directory.flatMap { try? Data(contentsOf: $0.appendingPathComponent("config.json")) }
            .flatMap(decodeConfiguration) ?? ScrollConfiguration()
    }

    public static func write(_ status: MouseStatus) {
        guard let directory, let data = try? JSONEncoder().encode(status) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("status.json"), options: .atomic)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(statusChanged as CFString), nil, nil, true)
    }
}
