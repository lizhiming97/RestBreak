import Foundation
import Testing
@testable import RestBreak

/// 快捷键与系统快捷键的冲突检测
struct ShortcutConflictTests {
    let command = KeyShortcut.commandFlag, shift = KeyShortcut.shiftFlag
    let control = KeyShortcut.controlFlag, option = KeyShortcut.optionFlag

    @Test func Carbon修饰键换算_忽略fn() {
        #expect(ShortcutConflicts.eventModifiers(fromCarbon: 768) == command | shift)
        #expect(ShortcutConflicts.eventModifiers(fromCarbon: 0x20000 | 0x1000) == control)
        #expect(ShortcutConflicts.eventModifiers(fromCarbon: 0x800 | 0x100) == option | command)
    }

    @Test func 内置表能认出系统截屏() {
        let shortcut = KeyShortcut(keyCode: 21, modifiers: command | shift, keyName: "4")
        #expect(ShortcutConflicts.conflict(for: shortcut, systemHotKeys: nil) == "将所选区域截屏")
    }

    @Test func 不同组合或不同修饰键不冲突() {
        #expect(ShortcutConflicts.conflict(for: KeyShortcut(keyCode: 0, modifiers: control | option, keyName: "A"),
                                           systemHotKeys: nil) == nil)
        #expect(ShortcutConflicts.conflict(for: KeyShortcut(keyCode: 21, modifiers: command | option, keyName: "4"),
                                           systemHotKeys: nil) == nil)
    }

    @Test func 系统里关掉的快捷键不算冲突() {
        let off = SystemHotKey(keyCode: 21, modifiers: command | shift, isEnabled: false)
        let shortcut = KeyShortcut(keyCode: 21, modifiers: command | shift, keyName: "4")
        #expect(ShortcutConflicts.conflict(for: shortcut, systemHotKeys: [off]) == nil)
    }

    @Test func 本机表里启用的快捷键_没有中文名时叫系统快捷键() {
        let on = SystemHotKey(keyCode: 7, modifiers: control | option | command, isEnabled: true)
        let shortcut = KeyShortcut(keyCode: 7, modifiers: control | option | command, keyName: "X")
        #expect(ShortcutConflicts.conflict(for: shortcut, systemHotKeys: [on]) == "系统快捷键")
    }

    @Test func 常用App快捷键总是算冲突() {
        let copy = KeyShortcut(keyCode: 8, modifiers: command, keyName: "C")
        #expect(ShortcutConflicts.conflict(for: copy, systemHotKeys: []) == "拷贝")
    }

    @Test func 沙盒里能读到本机系统快捷键() throws {
        let keys = try #require(SystemHotKeys.current())
        #expect(!keys.isEmpty)
        // 系统截屏 ⌘⇧3 一定在表里（不管是否启用）
        #expect(keys.contains { $0.keyCode == 20 && $0.modifiers == command | shift })
    }
}
