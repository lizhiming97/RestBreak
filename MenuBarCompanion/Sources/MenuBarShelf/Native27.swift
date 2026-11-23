// SPDX-License-Identifier: GPL-3.0-only
// macOS 27 的收纳方式。思路参考 Ice 的 macOS 27 适配（jordanbaird/Ice#995，NativeAllowListConcealer27 /
// TrackedApplications27，GPL-3.0），代码按本组件自己写。
//
// macOS 27 的菜单栏由系统 MenuBarAgent 统一绘制，图标不再是各应用自己的窗口，「拖到分隔符左边藏起来」已经做不到。
// 系统自己给每个应用一个「允许在菜单栏显示」开关（系统设置 › 控制中心），存在
// group.com.apple.controlcenter 组容器的 trackedApplications 偏好里。改这个开关，图标约 0.25 秒内消失或回来，
// 系统图标和点击都不受影响。读写这个容器需要「完全磁盘访问权限」（2026-11-23 本机 macOS 27.2.1 实测）。
// 坑：组件装在 星期五.app/Contents/Helpers/ 里时，系统把权限算在外层的「星期五」头上——给「星期五菜单栏」
// 授权没用，同一个程序放在别处就能读，放进星期五里就读不到；要给「星期五」开完全磁盘访问权限。
import AppKit
import ApplicationServices

enum Native27 {
    /// 当前系统是否用这套方式（macOS 27 及以后）。
    static var isActive: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
    }

    // MARK: - 系统的「允许在菜单栏显示」开关

    /// trackedApplications 是 Swift Codable 编出来的扁平数组：键、值、键、值……
    /// 键形如 {"bundle": {"_0": "<bundle id>"}}，值里有 isAllowed。只改 bundle 键对应值的 isAllowed，别的原样写回。
    enum Switches {
        private typealias Copy = @convention(c) (CFString, CFString, CFString, CFString, CFString) -> Unmanaged<CFPropertyList>?
        private typealias SetValue = @convention(c) (CFString, CFPropertyList?, CFString, CFString, CFString, CFString) -> Void
        private typealias Synchronize = @convention(c) (CFString, CFString, CFString, CFString) -> Bool

        /// 必须用 CoreFoundation 带容器的私有调用：直接改文件，MenuBarAgent 要重启才生效。
        private static let calls: (copy: Copy, set: SetValue, sync: Synchronize)? = {
            guard let handle = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOW),
                  let copy = dlsym(handle, "_CFPreferencesCopyValueWithContainer"),
                  let set = dlsym(handle, "_CFPreferencesSetValueWithContainer"),
                  let sync = dlsym(handle, "_CFPreferencesSynchronizeWithContainer") else { return nil }
            return (unsafeBitCast(copy, to: Copy.self), unsafeBitCast(set, to: SetValue.self), unsafeBitCast(sync, to: Synchronize.self))
        }()
        private static let key = "trackedApplications" as CFString
        private static let domain = "group.com.apple.controlcenter" as CFString
        private static var container: CFString {
            (NSHomeDirectory() + "/Library/Group Containers/group.com.apple.controlcenter") as CFString
        }

        /// 读得到说明有完全磁盘访问权限。
        static var isReadable: Bool { read() != nil }

        static func read() -> [Any]? {
            guard let calls,
                  let value = calls.copy(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost, container)?.takeRetainedValue(),
                  let data = value as? Data else { return nil }
            return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [Any]
        }

        static func bundleID(ofKey key: Any) -> String? {
            guard let key = key as? [String: Any], key.count == 1, let bundle = key["bundle"] as? [String: Any] else { return nil }
            return bundle["_0"] as? String
        }

        /// 每个应用当前是否允许显示。
        static func states(in array: [Any]) -> [String: Bool] {
            var result: [String: Bool] = [:]
            for index in stride(from: 0, to: array.count - 1, by: 2) {
                guard let id = bundleID(ofKey: array[index]),
                      let allowed = (array[index + 1] as? [String: Any])?["isAllowed"] as? Bool else { continue }
                result[id] = (result[id] ?? false) || allowed
            }
            return result
        }

        /// 把这些应用的开关设成 allowed，返回真正改了的。
        static func setting(_ allowed: Bool, for ids: Set<String>, in array: [Any]) -> (array: [Any], changed: Set<String>) {
            var result = array
            var changed = Set<String>()
            for index in stride(from: 0, to: array.count - 1, by: 2) {
                guard let id = bundleID(ofKey: array[index]), ids.contains(id),
                      var value = array[index + 1] as? [String: Any],
                      let current = value["isAllowed"] as? Bool, current != allowed else { continue }
                value["isAllowed"] = allowed
                result[index + 1] = value
                changed.insert(id)
            }
            return (result, changed)
        }

        @discardableResult
        static func write(_ array: [Any]) -> Bool {
            guard let calls,
                  let data = try? PropertyListSerialization.data(fromPropertyList: array, format: .binary, options: 0) else { return false }
            calls.set(key, data as CFData, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost, container)
            return calls.sync(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost, container)
        }
    }

    // MARK: - 列出图标

    struct Icon {
        let bundleID: String
        let pid: pid_t
        let name: String
        let element: AXUIElement
        let frame: CGRect
        /// 外层应用（图标来自某个 .app 包内部的辅助程序时）：系统的开关可能记在它名下。
        let enclosing: (id: String, name: String)?
    }

    /// 图标所在的最外层 .app 及其 bundle ID、名字；它本身就是最外层时返回 nil。
    /// 系统的「允许在菜单栏显示」开关有时记在外层应用名下：WPS 的图标来自包内的「WPS Office Service」，
    /// 开关却记在 wpsoffice.app（`com.kingsoft.wpsoffice.mac`）名下；Ice 在 Docker 上遇到的是同一回事。
    static func enclosingApp(ofBundlePath path: String) -> (id: String, name: String)? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let first = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        let outer = "/" + parts[1...first].joined(separator: "/")
        guard outer != path,
              let plist = NSDictionary(contentsOfFile: outer + "/Contents/Info.plist"),
              let id = plist["CFBundleIdentifier"] as? String else { return nil }
        // 名字优先取本地化的（WPS 的 Info.plist 里写的是 wpsoffice，显示名是「WPS Office」）。
        let name = FileManager.default.displayName(atPath: outer)
        let fallback = plist["CFBundleDisplayName"] as? String ?? plist["CFBundleName"] as? String ?? id
        return (id, name.isEmpty ? fallback : name)
    }

    /// 各应用（不含系统 MenuBarAgent 自己的电池、Wi-Fi 等）的菜单栏图标，按位置从左到右。
    /// 注意：被系统收起的图标，AX 仍按最后画过的位置报告，所以收起状态只看开关，不看位置。
    static func icons() -> [Icon] {
        var result: [Icon] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier, bundleID != "com.apple.MenuBarAgent",
                  app.processIdentifier != getpid() else { continue }
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
                var rawPoint: CFTypeRef?, rawSize: CFTypeRef?
                guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &rawPoint) == .success,
                      AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &rawSize) == .success,
                      let rawPoint, let rawSize,
                      CFGetTypeID(rawPoint) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() else { continue }
                var point = CGPoint.zero, size = CGSize.zero
                guard AXValueGetValue(rawPoint as! AXValue, .cgPoint, &point),
                      AXValueGetValue(rawSize as! AXValue, .cgSize, &size), size.width > 0 else { continue }
                result.append(Icon(bundleID: bundleID, pid: app.processIdentifier, name: app.localizedName ?? bundleID,
                                   element: child, frame: CGRect(origin: point, size: size),
                                   enclosing: app.bundleURL.flatMap { enclosingApp(ofBundlePath: $0.path) }))
            }
        }
        return result.sorted { $0.frame.minX < $1.frame.minX }
    }

    // MARK: - 系统折叠区（菜单栏放不下时，左侧的 « 按钮）

    /// 菜单栏放不下时，系统把多出来的应用图标折叠到 « 后面。折叠着的图标**读不到**（应用的 AXExtrasMenuBar
    /// 直接返回错误），展开后才能读到、点到（2026-11-23 本机 Mesl 实测）。和 Ice 一样按辅助功能标识找这个按钮。
    struct Overflow {
        let element: AXUIElement
        let isExpanded: Bool
    }
    static let overflowID = "menu-bar-overflow-indicator"
    static let overflowExpandedID = "menu-bar-overflow-indicator-expanded"

    /// 当前的 « 按钮（多块屏时取第一个）；菜单栏放得下时没有。
    static func overflow() -> Overflow? {
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else { return nil }
        let element = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.2)
        var rawBar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXExtrasMenuBarAttribute as CFString, &rawBar) == .success,
              let rawBar, CFGetTypeID(rawBar) == AXUIElementGetTypeID() else { return nil }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(rawBar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
              let children = children as? [AXUIElement] else { return nil }
        for child in children {
            var identifier: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXIdentifierAttribute as CFString, &identifier)
            switch identifier as? String {
            case overflowID: return Overflow(element: child, isExpanded: false)
            case overflowExpandedID: return Overflow(element: child, isExpanded: true)
            default: continue
            }
        }
        return nil
    }

    /// 展开（expand=true）或收回折叠区。已经是要的状态就什么都不做，返回 false。
    @discardableResult
    static func setOverflow(expanded: Bool) -> Bool {
        guard let overflow = overflow(), overflow.isExpanded != expanded else { return false }
        return AXUIElementPerformAction(overflow.element, kAXPressAction as CFString) == .success
    }

    /// 这些进程现在打开着的面板 / 菜单窗口（不含菜单栏那一排的图标窗口）。
    /// macOS 27 上图标窗口和面板窗口都在 layer 24，不能靠层级区分（WPS 的云盘面板实测就是 24），
    /// 改按位置和大小：落在菜单栏那一条里的又矮又窄的才是图标，其余算面板。
    static func panelWindows(pids: Set<pid_t>) -> Set<CGWindowID> {
        guard !pids.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let menuBarHeight = max(NSStatusBar.system.thickness, 33)
        var result = Set<CGWindowID>()
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let dict = info[kCGWindowBounds as String] as! CFDictionary?,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { continue }
            // 菜单栏那一条里的矮窗口是图标本身，不算「面板打开着」。
            let inMenuBar = bounds.height <= menuBarHeight + 8
                && NSScreen.screens.contains { screen in
                    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
                    let display = CGDisplayBounds(number.uint32Value)
                    return abs(bounds.minY - display.minY) <= menuBarHeight
                }
            if !inMenuBar { result.insert(id) }
        }
        return result
    }

    /// 由 bundle ID 算出固定的编号（≥ 0x8000_0000，不会和真实窗口编号冲突），图标图片文件按它缓存。
    static func stableID(for bundleID: String, index: Int) -> CGWindowID {
        var hash: UInt32 = 2_166_136_261
        for byte in "\(bundleID)#\(index)".utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return 0x8000_0000 | (hash & 0x7FFF_FFFF)
    }

    /// 应用自己的图标（macOS 27 拿不到单个菜单栏图标的截图）。
    static func appIcon(bundleID: String) -> CGImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        var rect = CGRect(x: 0, y: 0, width: 64, height: 64)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// 图标是否已经画在菜单栏上（在某块屏幕的菜单栏那一排里）。刚放出来的图标要等系统画好才能点。
    static func isDrawn(_ frame: CGRect) -> Bool {
        let displays = NSScreen.screens.compactMap { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber }
            .map { CGDisplayBounds($0.uint32Value) }
        return displays.contains { abs(frame.minY - $0.minY) < 12 && frame.minX >= $0.minX && frame.maxX <= $0.maxX }
    }

    /// 点开图标。macOS 27 上应用的菜单栏图标多数不响应辅助功能的「按下」（实测返回失败），
    /// 和 Ice 一样：在图标中心发一次真实的鼠标点击，再把光标放回原处；点不到时才退回辅助功能。
    static func press(_ icon: Icon, right: Bool) -> Bool {
        if isDrawn(icon.frame) {
            let point = CGPoint(x: icon.frame.midX, y: icon.frame.midY)
            let original = CGEvent(source: nil)?.location
            let source = CGEventSource(stateID: .hidSystemState)
            let button: CGMouseButton = right ? .right : .left
            let types: [CGEventType] = right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp]
            var posted = 0
            for type in types {
                guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { continue }
                event.post(tap: .cghidEventTap)
                posted += 1
            }
            if let original { CGWarpMouseCursorPosition(original) }
            if posted == types.count { return true }
        }
        if right, AXUIElementPerformAction(icon.element, kAXShowMenuAction as CFString) == .success { return true }
        return AXUIElementPerformAction(icon.element, kAXPressAction as CFString) == .success
    }
}
