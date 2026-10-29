import Foundation

/// 主 App 和命令行小程序（restbreak-mcp）共用的 App Group 信息。
/// 两个程序开了同一个 App Group，才能读写同一个文件夹。
enum AppGroup {
    /// 用团队 ID 当前缀：macOS 15 起不会弹「访问其他 App 的数据」提示
    static let identifier = "B45N72QF4V.com.lizhiming.RestBreak"
    static let appBundleID = "com.lizhiming.RestBreak"

    /// 共享文件夹：~/Library/Group Containers/<identifier>/
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// 主 App 应 AI 的请求写下的现状（平时不写）
    static var contextURL: URL? { containerURL?.appendingPathComponent("Reminders/context.json") }
}

/// Darwin 通知：跨进程的「有东西变了」信号，只有名字，不能带内容
enum DarwinNotice {
    static let remindersChanged = "com.lizhiming.RestBreak.reminders.changed"
    /// 小程序要现状：主 App 收到后写 context.json
    static let contextRequest = "com.lizhiming.RestBreak.context.request"

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name as CFString), nil, nil, true)
    }
}
