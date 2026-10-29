import Foundation

/// 全局快捷键能触发的操作
enum ShortcutAction: String, Codable, CaseIterable, CodingKeyRepresentable, Sendable {
    case startMicroBreak   // 现在开始微休息
    case togglePause       // 暂停 / 恢复
    case skipNextBreak     // 跳过下一次休息（休息中则跳过当前这次）
    case captureScreen     // 截图
    case pinClipboard      // 把剪贴板内容贴到桌面

    /// 截图相关的操作在设置「截图」页显示，其他在「快捷键」页
    var isScreenshot: Bool { self == .captureScreen || self == .pinClipboard }

    var title: String {
        switch self {
        case .startMicroBreak: "现在开始微休息"
        case .togglePause: "暂停 / 恢复"
        case .skipNextBreak: "跳过下一次休息"
        case .captureScreen: "截图"
        case .pinClipboard: "贴剪贴板"
        }
    }

    var subtitle: String {
        switch self {
        case .startMicroBreak: "随时让眼睛星期五"
        case .togglePause: "暂停直到再按一次"
        case .skipNextBreak: "休息中按下则跳过当前这次；严格模式下无效"
        case .captureScreen: "框选屏幕区域，复制、保存或贴到桌面"
        case .pinClipboard: "把剪贴板里的图片或文字贴到桌面"
        }
    }
}

/// 一个快捷键组合，如 ⌃⌥P。
/// modifiers 用的是 AppKit NSEvent.ModifierFlags 的原始数值，这里只依赖 Foundation，方便单元测试。
struct KeyShortcut: Codable, Equatable, Sendable {
    /// 物理按键编号（和键盘布局无关）
    var keyCode: UInt16
    /// 修饰键（⌃⌥⇧⌘）
    var modifiers: UInt
    /// 按键本身的显示名，如 "P"、"空格"、"F1"
    var keyName: String

    // NSEvent.ModifierFlags 的原始数值
    static let shiftFlag: UInt = 1 << 17
    static let controlFlag: UInt = 1 << 18
    static let optionFlag: UInt = 1 << 19
    static let commandFlag: UInt = 1 << 20
    static let allModifierFlags = shiftFlag | controlFlag | optionFlag | commandFlag

    init(keyCode: UInt16, modifiers: UInt, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.allModifierFlags
        self.keyName = keyName
    }

    /// 完整显示，修饰键按 macOS 菜单的顺序：⌃⌥⇧⌘
    var display: String {
        var text = ""
        if modifiers & Self.controlFlag != 0 { text += "⌃" }
        if modifiers & Self.optionFlag != 0 { text += "⌥" }
        if modifiers & Self.shiftFlag != 0 { text += "⇧" }
        if modifiers & Self.commandFlag != 0 { text += "⌘" }
        return text + keyName
    }

    /// 功能键 F1～F20 的按键编号
    static let functionKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    /// 其他特殊按键的显示名
    private static let specialKeys: [UInt16: String] = [
        49: "空格", 36: "↩", 76: "⌤", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]

    /// 按键显示名；characters 是按下时不含修饰键的字符
    static func keyName(forKeyCode keyCode: UInt16, characters: String) -> String {
        if let name = functionKeys[keyCode] ?? specialKeys[keyCode] { return name }
        return characters.uppercased()
    }

    /// 全局快捷键至少要有 ⌃⌥⌘ 之一（只有 ⇧ 会和打字冲突）；功能键可以单独用
    static func isAllowed(keyCode: UInt16, modifiers: UInt) -> Bool {
        if functionKeys[keyCode] != nil { return true }
        return modifiers & (controlFlag | optionFlag | commandFlag) != 0
    }
}
