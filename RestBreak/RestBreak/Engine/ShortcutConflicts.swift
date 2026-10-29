import Foundation

/// 一个系统级快捷键（修饰键用 NSEvent 的数值，和 KeyShortcut 一致）
struct SystemHotKey: Equatable, Sendable {
    var keyCode: UInt16
    var modifiers: UInt
    var isEnabled: Bool
}

/// 判断用户录的快捷键是否和系统快捷键冲突。
/// 系统快捷键（如 ⌘⇧4）不会让我们注册失败，但按下时只会触发系统功能，所以要在录制时提前提醒。
enum ShortcutConflicts {
    private struct Named {
        let keyCode: UInt16
        let modifiers: UInt
        let name: String
    }

    private static let cmd = KeyShortcut.commandFlag, sft = KeyShortcut.shiftFlag
    private static let ctl = KeyShortcut.controlFlag, opt = KeyShortcut.optionFlag

    /// macOS 默认的系统快捷键（读不到本机设置时兜底，也用来给本机设置起中文名）
    private static let system: [Named] = [
        Named(keyCode: 20, modifiers: cmd | sft, name: "将屏幕截屏"),
        Named(keyCode: 20, modifiers: ctl | cmd | sft, name: "将屏幕截屏拷贝到剪贴板"),
        Named(keyCode: 21, modifiers: cmd | sft, name: "将所选区域截屏"),
        Named(keyCode: 21, modifiers: ctl | cmd | sft, name: "将所选区域截屏拷贝到剪贴板"),
        Named(keyCode: 23, modifiers: cmd | sft, name: "截屏和录制选项"),
        Named(keyCode: 49, modifiers: cmd, name: "显示「聚焦」搜索"),
        Named(keyCode: 49, modifiers: opt | cmd, name: "显示「访达」搜索窗口"),
        Named(keyCode: 49, modifiers: ctl, name: "选择上一个输入法"),
        Named(keyCode: 49, modifiers: ctl | opt, name: "选择输入菜单中的下一个输入法"),
        Named(keyCode: 49, modifiers: ctl | cmd, name: "表情与符号"),
        Named(keyCode: 48, modifiers: cmd, name: "切换 App"),
        Named(keyCode: 48, modifiers: cmd | sft, name: "切换 App"),
        Named(keyCode: 50, modifiers: cmd, name: "切换同一 App 的窗口"),
        Named(keyCode: 126, modifiers: ctl, name: "调度中心"),
        Named(keyCode: 125, modifiers: ctl, name: "应用程序窗口"),
        Named(keyCode: 123, modifiers: ctl, name: "向左移动一个空间"),
        Named(keyCode: 124, modifiers: ctl, name: "向右移动一个空间"),
        Named(keyCode: 12, modifiers: ctl | cmd, name: "锁定屏幕"),
        Named(keyCode: 2, modifiers: opt | cmd, name: "隐藏/显示程序坞"),
        Named(keyCode: 53, modifiers: opt | cmd, name: "强制退出"),
        Named(keyCode: 120, modifiers: ctl, name: "将焦点移到菜单栏"),
        Named(keyCode: 99, modifiers: ctl, name: "将焦点移到程序坞"),
        Named(keyCode: 103, modifiers: 0, name: "显示桌面"),
    ]

    /// 几乎所有 App 都在用的菜单快捷键：全局快捷键会把它们抢走，总是算冲突
    private static let common: [Named] = [
        Named(keyCode: 8, modifiers: cmd, name: "拷贝"),
        Named(keyCode: 9, modifiers: cmd, name: "粘贴"),
        Named(keyCode: 7, modifiers: cmd, name: "剪切"),
        Named(keyCode: 0, modifiers: cmd, name: "全选"),
        Named(keyCode: 6, modifiers: cmd, name: "撤销"),
        Named(keyCode: 6, modifiers: cmd | sft, name: "重做"),
        Named(keyCode: 1, modifiers: cmd, name: "存储"),
        Named(keyCode: 45, modifiers: cmd, name: "新建"),
        Named(keyCode: 31, modifiers: cmd, name: "打开"),
        Named(keyCode: 35, modifiers: cmd, name: "打印"),
        Named(keyCode: 3, modifiers: cmd, name: "查找"),
        Named(keyCode: 13, modifiers: cmd, name: "关闭窗口"),
        Named(keyCode: 12, modifiers: cmd, name: "退出 App"),
        Named(keyCode: 4, modifiers: cmd, name: "隐藏 App"),
        Named(keyCode: 46, modifiers: cmd, name: "最小化"),
        Named(keyCode: 17, modifiers: cmd, name: "新建标签页"),
        Named(keyCode: 43, modifiers: cmd, name: "设置"),
        Named(keyCode: 3, modifiers: ctl | cmd, name: "进入全屏幕"),
    ]

    /// 冲突时返回冲突功能的中文名，不冲突返回 nil。
    /// systemHotKeys 为本机实际的系统快捷键表；传 nil 表示读不到，用内置表兜底。
    static func conflict(for shortcut: KeyShortcut, systemHotKeys: [SystemHotKey]?) -> String? {
        let mods = shortcut.modifiers & KeyShortcut.allModifierFlags
        func matches(_ keyCode: UInt16, _ modifiers: UInt) -> Bool {
            keyCode == shortcut.keyCode && modifiers == mods
        }

        if let hit = common.first(where: { matches($0.keyCode, $0.modifiers) }) { return hit.name }
        let builtInName = system.first { matches($0.keyCode, $0.modifiers) }?.name
        guard let systemHotKeys else { return builtInName }
        // 以本机表为准：用户在系统设置里关掉的快捷键不算冲突
        guard systemHotKeys.contains(where: { $0.isEnabled && matches($0.keyCode, $0.modifiers) }) else { return nil }
        return builtInName ?? "系统快捷键"
    }

    /// Carbon 的修饰键数值 → NSEvent 的修饰键数值（忽略 fn、大写锁定等）
    static func eventModifiers(fromCarbon carbon: UInt) -> UInt {
        var result: UInt = 0
        if carbon & 0x100 != 0 { result |= cmd }    // cmdKey
        if carbon & 0x200 != 0 { result |= sft }    // shiftKey
        if carbon & 0x800 != 0 { result |= opt }    // optionKey
        if carbon & 0x1000 != 0 { result |= ctl }   // controlKey
        return result
    }
}
