import AppKit
import Testing
@testable import RestBreak

/// 全局快捷键：显示文字、保存读取、在系统里注册
@MainActor
struct ShortcutTests {
    let command = NSEvent.ModifierFlags.command.rawValue
    let option = NSEvent.ModifierFlags.option.rawValue
    let control = NSEvent.ModifierFlags.control.rawValue
    let shift = NSEvent.ModifierFlags.shift.rawValue

    @Test func 显示文字按系统顺序排列修饰键() {
        // macOS 菜单里的顺序：⌃ ⌥ ⇧ ⌘
        let shortcut = KeyShortcut(keyCode: 35, modifiers: command | shift | control | option, keyName: "P")
        #expect(shortcut.display == "⌃⌥⇧⌘P")
    }

    @Test func 特殊按键有专门的显示名() {
        #expect(KeyShortcut.keyName(forKeyCode: 49, characters: " ") == "空格")
        #expect(KeyShortcut.keyName(forKeyCode: 122, characters: "") == "F1")
        #expect(KeyShortcut.keyName(forKeyCode: 123, characters: "") == "←")
        #expect(KeyShortcut.keyName(forKeyCode: 0, characters: "a") == "A")
    }

    @Test func 必须带修饰键_功能键除外() {
        #expect(!KeyShortcut.isAllowed(keyCode: 0, modifiers: 0))
        #expect(!KeyShortcut.isAllowed(keyCode: 0, modifiers: shift))
        #expect(KeyShortcut.isAllowed(keyCode: 0, modifiers: command))
        #expect(KeyShortcut.isAllowed(keyCode: 122, modifiers: 0))   // F1
    }

    @Test func 快捷键设置能保存和读取() throws {
        var settings = AppSettings.default
        settings.shortcuts[.togglePause] = KeyShortcut(keyCode: 35, modifiers: control | option, keyName: "P")
        let data = try JSONEncoder().encode(settings)
        let loaded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(loaded.shortcuts == settings.shortcuts)
        #expect(AppSettings.default.shortcuts.isEmpty)
    }

    @Test func 能在系统里注册和注销快捷键() {
        let manager = HotkeyManager()
        // ⌃⌥⇧⌘F19：几乎不可能被占用的组合
        let shortcut = KeyShortcut(keyCode: 80, modifiers: command | option | control | shift, keyName: "F19")
        let failed = manager.register([.startMicroBreak: shortcut])
        #expect(failed.isEmpty)
        manager.unregisterAll()
    }

    @Test func 截图快捷键和休息快捷键分开显示() {
        #expect(ShortcutAction.allCases.filter(\.isScreenshot) == [.captureScreen, .pinClipboard])
        #expect(ShortcutAction.allCases.filter { !$0.isScreenshot } == [.startMicroBreak, .togglePause, .skipNextBreak])
    }
}
