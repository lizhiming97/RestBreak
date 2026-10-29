import AppKit
import Carbon.HIToolbox

/// 在系统里注册全局快捷键（在任何 App 里按都有效）。
/// 用 Carbon 的 RegisterEventHotKey：沙盒内可用，不需要「辅助功能」权限。
@MainActor
final class HotkeyManager {
    /// 快捷键被按下时回调
    var onAction: ((ShortcutAction) -> Void)?

    private var registered: [UInt32: (action: ShortcutAction, ref: EventHotKeyRef)] = [:]
    private var handlerRef: EventHandlerRef?
    /// 用来识别「这是我们注册的快捷键」的四字符签名：'RBrk'
    private static let signature: OSType = 0x5242_726B

    /// 注册一组快捷键（会先注销之前的）。返回注册失败（通常是被别的 App 占用）的操作。
    @discardableResult
    func register(_ shortcuts: [ShortcutAction: KeyShortcut]) -> Set<ShortcutAction> {
        installHandlerIfNeeded()
        unregisterAll()

        var failed: Set<ShortcutAction> = []
        for (index, action) in ShortcutAction.allCases.enumerated() {
            guard let shortcut = shortcuts[action] else { continue }
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(shortcut.keyCode),
                                             Self.carbonModifiers(shortcut.modifiers),
                                             EventHotKeyID(signature: Self.signature, id: id),
                                             GetEventDispatcherTarget(), 0, &ref)
            if status == noErr, let ref {
                registered[id] = (action, ref)
            } else {
                failed.insert(action)
            }
        }
        return failed
    }

    func unregisterAll() {
        for entry in registered.values { UnregisterEventHotKey(entry.ref) }
        registered.removeAll()
    }

    /// 只装一次事件处理器；快捷键按下时系统会调用它
    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == HotkeyManager.signature,
                  let userData else { return OSStatus(eventNotHandledErr) }
            let id = hotKeyID.id
            // 系统在主线程上调用这个回调
            MainActor.assumeIsolated {
                Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue().handle(id: id)
            }
            return noErr
        }
        InstallEventHandler(GetEventDispatcherTarget(), callback, 1, &eventType,
                            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    private func handle(id: UInt32) {
        guard let action = registered[id]?.action else { return }
        onAction?(action)
    }

    /// AppKit 的修饰键数值 → Carbon 的修饰键数值
    private static func carbonModifiers(_ flags: UInt) -> UInt32 {
        var result: UInt32 = 0
        if flags & KeyShortcut.commandFlag != 0 { result |= UInt32(cmdKey) }
        if flags & KeyShortcut.optionFlag != 0 { result |= UInt32(optionKey) }
        if flags & KeyShortcut.controlFlag != 0 { result |= UInt32(controlKey) }
        if flags & KeyShortcut.shiftFlag != 0 { result |= UInt32(shiftKey) }
        return result
    }
}
