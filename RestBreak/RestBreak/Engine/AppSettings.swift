import Foundation

/// 休息的种类。rawValue 会写进设置 JSON，不要随便改名。
enum BreakKind: String, Codable, CaseIterable, Sendable {
    case micro   // 微休息：护眼、短暂放松
    case long    // 长休息：起身活动

    /// 显示给用户看的中文名
    var displayName: String {
        switch self {
        case .micro: "微休息"
        case .long: "长休息"
        }
    }
}

/// 日历排程用哪里的日程
enum CalendarSource: String, Codable, CaseIterable, Sendable {
    case mac        // Mac「日历」App 里的日历
    case dingtalk   // 钉钉日历（通过钉钉官方 MCP 读取）

    var title: String { self == .mac ? "Mac 日历" : "钉钉日历" }
}

/// 用户指定的「使用时推迟休息」的 App
struct FocusApp: Codable, Equatable, Sendable, Identifiable {
    /// App 的唯一标识，如 com.apple.iWork.Keynote
    var bundleID: String
    /// 显示用的名字，如 Keynote
    var name: String

    var id: String { bundleID }
}

/// 单个休息类型的配置。时间单位统一是「秒」。
struct BreakConfig: Codable, Equatable, Sendable {
    var isEnabled: Bool
    /// 两次休息之间的间隔
    var interval: TimeInterval
    /// 每次休息持续多久
    var duration: TimeInterval
    /// 点「推迟」后多久再弹出
    var postponeDuration: TimeInterval
    /// 优先级：数字越小越优先（长休息 0，微休息 1）
    var priority: Int
}

/// 整个 App 的设置，会以 JSON 形式存进 UserDefaults。
struct AppSettings: Codable, Equatable, Sendable {
    var microBreak: BreakConfig
    var longBreak: BreakConfig
    /// 闲置超过多少秒算「离开」
    var awayThreshold: TimeInterval
    /// 每次休息最多可以推迟几次
    var maxPostpones: Int
    /// 严格模式：休息时不显示「推迟」「跳过」
    var strictMode: Bool
    /// 菜单栏图标旁边显示倒计时
    var showCountdownInMenuBar: Bool
    /// 开会时（有 App 在用麦克风）自动推迟休息
    var postponeDuringMeetings: Bool
    /// 前台 App 全屏时（看视频、做演示）推迟休息
    var postponeDuringFullscreen: Bool
    /// 使用指定 App 时推迟休息
    var postponeDuringFocusApps: Bool
    /// 指定的 App 列表
    var focusApps: [FocusApp]
    /// 全屏或使用指定 App 时最多推迟多久，到了照样休息
    var maxDeferral: TimeInterval
    /// 全局快捷键（没设置的操作不在字典里）
    var shortcuts: [ShortcutAction: KeyShortcut]
    /// 按日历安排休息：日程中不弹，日程前提前休息
    var followCalendar: Bool
    /// 参与排程的日历 ID（EKCalendar.calendarIdentifier）
    var calendarIDs: [String]
    /// 日程来源：Mac 日历或钉钉日历
    var calendarSource: CalendarSource
    /// 休息遮罩的背景样式
    var overlayStyle: OverlayStyle
    /// 「我的照片」用的文件夹（没选时为 nil）
    var photoFolder: PhotoFolderRef?
    /// 截图时在光标旁显示放大镜和颜色值
    var showMagnifier: Bool
    /// 贴图的初始透明度（0.2～1.0）
    var pinOpacity: Double
    /// 截图标注：每个工具上次用的颜色和粗细（没用过的工具不在字典里）
    var annotationStyles: [AnnotationTool: ToolStyle]

    /// 默认设置（第一次启动、或点「恢复默认」时使用）
    static let `default` = AppSettings(
        microBreak: BreakConfig(isEnabled: true, interval: 20 * 60, duration: 20,
                                postponeDuration: 2 * 60, priority: 1),
        longBreak: BreakConfig(isEnabled: true, interval: 60 * 60, duration: 5 * 60,
                               postponeDuration: 5 * 60, priority: 0),
        awayThreshold: 5 * 60,
        maxPostpones: 2,
        strictMode: false,
        showCountdownInMenuBar: true,
        postponeDuringMeetings: true,
        postponeDuringFullscreen: true,
        postponeDuringFocusApps: true,
        focusApps: [],
        maxDeferral: 30 * 60,
        shortcuts: [:],
        followCalendar: false,
        calendarIDs: [],
        calendarSource: .mac,
        overlayStyle: .frosted,
        photoFolder: nil,
        showMagnifier: true,
        pinOpacity: 1.0,
        annotationStyles: [:]
    )

    /// 某个标注工具的样式，没改过就用默认（红色、中号、像素块）
    func style(for tool: AnnotationTool) -> ToolStyle {
        annotationStyles[tool] ?? .default
    }

    /// 方便按种类读写：settings[.micro].interval = 600
    subscript(kind: BreakKind) -> BreakConfig {
        get { kind == .micro ? microBreak : longBreak }
        set {
            switch kind {
            case .micro: microBreak = newValue
            case .long: longBreak = newValue
            }
        }
    }
}

// MARK: - 兼容旧版本保存的设置
// 以后给设置加新字段时，老用户存的 JSON 里没有这个字段。
// 系统自动生成的解码会因此整体失败，导致所有设置被重置成默认值。
// 这里改成逐个字段读取：有就用存的值，没有就用默认值。

extension AppSettings {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings.default
        microBreak = try BreakConfig(from: container, forKey: .microBreak, fallback: fallback.microBreak)
        longBreak = try BreakConfig(from: container, forKey: .longBreak, fallback: fallback.longBreak)
        awayThreshold = try container.value(.awayThreshold, default: fallback.awayThreshold)
        maxPostpones = try container.value(.maxPostpones, default: fallback.maxPostpones)
        strictMode = try container.value(.strictMode, default: fallback.strictMode)
        showCountdownInMenuBar = try container.value(.showCountdownInMenuBar, default: fallback.showCountdownInMenuBar)
        postponeDuringMeetings = try container.value(.postponeDuringMeetings, default: fallback.postponeDuringMeetings)
        postponeDuringFullscreen = try container.value(.postponeDuringFullscreen, default: fallback.postponeDuringFullscreen)
        postponeDuringFocusApps = try container.value(.postponeDuringFocusApps, default: fallback.postponeDuringFocusApps)
        focusApps = try container.value(.focusApps, default: fallback.focusApps)
        maxDeferral = try container.value(.maxDeferral, default: fallback.maxDeferral)
        shortcuts = try container.value(.shortcuts, default: fallback.shortcuts)
        followCalendar = try container.value(.followCalendar, default: fallback.followCalendar)
        calendarIDs = try container.value(.calendarIDs, default: fallback.calendarIDs)
        calendarSource = try container.value(.calendarSource, default: fallback.calendarSource)
        overlayStyle = try container.value(.overlayStyle, default: fallback.overlayStyle)
        photoFolder = try container.decodeIfPresent(PhotoFolderRef.self, forKey: .photoFolder)
        showMagnifier = try container.value(.showMagnifier, default: fallback.showMagnifier)
        pinOpacity = try container.value(.pinOpacity, default: fallback.pinOpacity)
        annotationStyles = try container.value(.annotationStyles, default: fallback.annotationStyles)
    }
}

extension BreakConfig {
    /// 从上层设置里读出一个休息配置，缺的字段用 fallback 补上
    init<Key: CodingKey>(from parent: KeyedDecodingContainer<Key>, forKey key: Key, fallback: BreakConfig) throws {
        guard parent.contains(key) else {
            self = fallback
            return
        }
        let container = try parent.nestedContainer(keyedBy: CodingKeys.self, forKey: key)
        isEnabled = try container.value(.isEnabled, default: fallback.isEnabled)
        interval = try container.value(.interval, default: fallback.interval)
        duration = try container.value(.duration, default: fallback.duration)
        postponeDuration = try container.value(.postponeDuration, default: fallback.postponeDuration)
        priority = try container.value(.priority, default: fallback.priority)
    }
}

private extension KeyedDecodingContainer {
    /// 读取一个字段；JSON 里没有这个字段时返回默认值
    func value<T: Decodable>(_ key: Key, default fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}
