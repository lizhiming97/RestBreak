// SPDX-License-Identifier: GPL-3.0-only
// Adapted from Ice: Bridging.swift, Shims/Private.swift, WindowInfo.swift,
// ScreenCapture.swift and MenuBarItem.swift. See UPSTREAM.md.
import AppKit
import ApplicationServices
import ScreenCaptureKit

@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSGetWindowCount") private func CGSGetWindowCount(_ cid: Int32, _ target: Int32, _ count: UnsafeMutablePointer<Int32>) -> CGError
@_silgen_name("CGSGetProcessMenuBarWindowList") private func CGSGetProcessMenuBarWindowList(_ cid: Int32, _ target: Int32, _ count: Int32, _ list: UnsafeMutablePointer<CGWindowID>, _ realCount: UnsafeMutablePointer<Int32>) -> CGError
@_silgen_name("CGSGetScreenRectForWindow") private func CGSGetScreenRectForWindow(_ cid: Int32, _ wid: CGWindowID, _ frame: UnsafeMutablePointer<CGRect>) -> CGError
@_silgen_name("CGSGetActiveSpace") private func CGSGetActiveSpace(_ cid: Int32) -> UInt
@_silgen_name("CGSCopySpacesForWindows") private func CGSCopySpacesForWindows(_ cid: Int32, _ mask: UInt32, _ ids: CFArray) -> Unmanaged<CFArray>?
@_silgen_name("CGSCopyManagedDisplaySpaces") private func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> Unmanaged<CFArray>?

enum Bridging {
    /// 图标的绘制进程与来源应用分开。只在用户刷新时读取 AX 菜单栏元素。
    @MainActor
    static func attributedItems(_ items: [MenuBarItem]) -> [MenuBarItem] {
        var result = items
        let running = NSWorkspace.shared.runningApplications
        // macOS 26 主屏副本的窗口标题就是来源应用的 bundle ID：直接对应，不依赖 AX 位置匹配。
        let byBundle = Dictionary(running.compactMap { app in app.bundleIdentifier.map { ($0, app) } }, uniquingKeysWith: { first, _ in first })
        for index in result.indices {
            guard let app = byBundle[result[index].title], app.processIdentifier != getpid() else { continue }
            result[index].accessibilityName = app.localizedName ?? result[index].title
            result[index].sourceProcessID = app.processIdentifier
            result[index].sourceBundleID = app.bundleIdentifier
        }
        for app in running where app.processIdentifier != getpid() {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.05)
            var rawBar: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXExtrasMenuBarAttribute as CFString, &rawBar) == .success,
                  let rawBar, CFGetTypeID(rawBar) == AXUIElementGetTypeID() else { continue }
            let bar = rawBar as! AXUIElement
            AXUIElementSetMessagingTimeout(bar, 0.05)
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &children) == .success,
                  let children = children as? [AXUIElement] else { continue }
            for child in children {
                AXUIElementSetMessagingTimeout(child, 0.05)
                var rawPoint: CFTypeRef?, rawSize: CFTypeRef?, rawDescription: CFTypeRef?
                guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &rawPoint) == .success,
                      AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &rawSize) == .success,
                      let rawPoint, let rawSize,
                      CFGetTypeID(rawPoint) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() else { continue }
                var point = CGPoint.zero, size = CGSize.zero
                guard AXValueGetValue(rawPoint as! AXValue, .cgPoint, &point),
                      AXValueGetValue(rawSize as! AXValue, .cgSize, &size), size.width > 0 else { continue }
                let frame = CGRect(origin: point, size: size)
                guard let index = result.firstIndex(where: { abs($0.frame.midX - frame.midX) < 2 && abs($0.frame.midY - frame.midY) < 2 }) else { continue }
                _ = AXUIElementCopyAttributeValue(child, kAXDescriptionAttribute as CFString, &rawDescription)
                let description = rawDescription as? String ?? ""
                let name = app.localizedName ?? result[index].ownerName
                // 描述与应用名相同（如「星期五 · 星期五」）时只显示一次
                result[index].accessibilityName = description.isEmpty || description == name ? name : "\(name) · \(description)"
                result[index].sourceProcessID = app.processIdentifier
                result[index].sourceBundleID = app.bundleIdentifier
            }
        }
        return result
    }

    static var activeSpace: UInt { CGSGetActiveSpace(CGSMainConnectionID()) }

    private static var managedDisplaySpaces: [String: UInt]? {
        guard NSScreen.screensHaveSeparateSpaces,
              let managed = CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?.takeRetainedValue() as? [[String: Any]] else { return nil }
        return DisplayChain.currentSpaces(from: managed)
    }

    /// 「显示器具有单独的空间」打开时每块屏各有当前桌面；关闭时只有一个活动桌面。
    static var currentSpaceIDs: Set<UInt> {
        Set(managedDisplaySpaces.map { Array($0.values) } ?? []).union([activeSpace])
    }

    static func currentSpace(of displayID: CGDirectDisplayID) -> UInt {
        guard let spaces = managedDisplaySpaces,
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let key = CFUUIDCreateString(nil, uuid) as String?,
              let space = spaces[key] else { return activeSpace }
        return space
    }
    static func getWindowFrame(for id: CGWindowID) -> CGRect? {
        var frame = CGRect.zero
        guard CGSGetScreenRectForWindow(CGSMainConnectionID(), id, &frame) == .success else { return nil }
        return frame
    }

    static func menuBarItems() -> [MenuBarItem] {
        let connection = CGSMainConnectionID()
        var count: Int32 = 0
        guard CGSGetWindowCount(connection, 0, &count) == .success, count > 0, count < 100_000 else { return [] }
        var ids = [CGWindowID](repeating: 0, count: Int(count))
        var realCount: Int32 = 0
        guard CGSGetProcessMenuBarWindowList(connection, 0, count, &ids, &realCount) == .success else { return [] }
        let current = currentSpaceIDs
        return ids.prefix(Int(max(0, min(realCount, count)))).compactMap { id in
            if let spaces = CGSCopySpacesForWindows(connection, 0x7, [id] as CFArray)?.takeRetainedValue() as? [UInt],
               !spaces.isEmpty, current.isDisjoint(with: spaces) { return nil }
            return item(id)
        }.sorted { $0.frame.minX < $1.frame.minX }
    }

    static func item(_ id: CGWindowID) -> MenuBarItem? {
        var pointer = UnsafeRawPointer(bitPattern: Int(id))
        guard let array = CFArrayCreate(nil, &pointer, 1, nil),
              let list = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]],
              let info = list.first,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              let frame = getWindowFrame(for: id),
              (info[kCGWindowLayer as String] as? Int) == Int(kCGStatusWindowLevel) else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        return MenuBarItem(windowID: id, ownerPID: pid,
                           title: info[kCGWindowName as String] as? String ?? "",
                           ownerName: app?.localizedName ?? info[kCGWindowOwnerName as String] as? String ?? "未命名应用",
                           bundleID: app?.bundleIdentifier ?? "",
                           frame: frame, isOnScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false)
    }

    /// 不保存完整屏幕，只读取指定菜单栏项的离屏窗口图像。
    static func image(of item: MenuBarItem) -> CGImage? {
        var pointer = UnsafeRawPointer(bitPattern: Int(item.id))
        guard let array = CFArrayCreate(nil, &pointer, 1, nil) else { return nil }
        return CGImage.menuItemImage(array)
    }

    /// 当前进程新打开的菜单/浮窗，用于推迟归位。只在临时图标仍存在时读取。
    static func interfaceWindows(ownerPID: pid_t) -> Set<CGWindowID> {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(list.compactMap { info in
            guard info[kCGWindowOwnerPID as String] as? pid_t == ownerPID,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer != Int(kCGStatusWindowLevel) else { return nil }
            return info[kCGWindowNumber as String] as? CGWindowID
        })
    }

    /// 无刘海时仍要避开左侧的应用菜单；访问超时限制为 0.2 秒。
    static func applicationMenuRightEdge(displayBounds: CGRect) -> CGFloat? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var bar: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(displayBounds.minX + 2), Float(displayBounds.minY + 2), &bar) == .success,
              let bar else { return nil }
        AXUIElementSetMessagingTimeout(bar, 0.2)
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar, kAXRoleAttribute as CFString, &role) == .success,
              role as? String == kAXMenuBarRole else { return nil }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &children) == .success,
              let children = children as? [AXUIElement] else { return nil }
        let frames = children.compactMap { child -> CGRect? in
            var p: CFTypeRef?, s: CFTypeRef?
            AXUIElementSetMessagingTimeout(child, 0.2)
            guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &p) == .success,
                  AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &s) == .success,
                  let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero, size = CGSize.zero
            guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size),
                  abs(point.y - displayBounds.minY) < 2 else { return nil }
            return CGRect(origin: point, size: size)
        }
        return frames.map(\.maxX).max()
    }
}

// Ice uses this compatibility shim because ScreenCaptureKit does not support
// the same offscreen composite-window capture. Keep it isolated for replacement.
private protocol WindowImage {
    init?(windowListFromArrayScreenBounds: CGRect, windowArray: CFArray, imageOption: CGWindowImageOption)
}
extension CGImage: WindowImage {}
private extension WindowImage {
    static func menuItemImage(_ array: CFArray) -> Self? {
        Self(windowListFromArrayScreenBounds: .null, windowArray: array,
             imageOption: [.boundsIgnoreFraming, .bestResolution])
    }
}

@MainActor
public enum ShelfPermissions {
    public static var accessibility: Bool { AXIsProcessTrusted() }
    public static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    public static func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    public static func requestScreenRecording() {
        if #available(macOS 15, *) {
            SCShareableContent.getWithCompletionHandler { _, _ in }
        } else { _ = CGRequestScreenCaptureAccess() }
    }
    public static func openSettings(screenRecording: Bool) {
        let suffix = screenRecording ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(suffix)") { NSWorkspace.shared.open(url) }
    }
}
