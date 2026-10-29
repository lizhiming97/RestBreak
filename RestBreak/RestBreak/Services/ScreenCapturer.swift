import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit

/// 读取本机的系统快捷键表（系统设置 › 键盘 › 键盘快捷键 里的那些）
enum SystemHotKeys {
    /// 读不到时返回 nil（调用方用内置表兜底）
    static func current() -> [SystemHotKey]? {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let array = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return nil }
        return array.compactMap { entry in
            guard let code = (entry[kHISymbolicHotKeyCode] as? NSNumber)?.intValue,
                  code >= 0, code < 0xFFFF,   // 0xFFFF 表示按字符而不是按键，忽略
                  let carbon = (entry[kHISymbolicHotKeyModifiers] as? NSNumber)?.uintValue
            else { return nil }
            let enabled = (entry[kHISymbolicHotKeyEnabled] as? NSNumber)?.boolValue ?? false
            return SystemHotKey(keyCode: UInt16(code),
                                modifiers: ShortcutConflicts.eventModifiers(fromCarbon: carbon),
                                isEnabled: enabled)
        }
    }
}

/// 一块屏幕的定格画面
struct ScreenSnapshot {
    let screen: NSScreen
    /// 整块屏幕的图像（像素）
    let image: CGImage
    /// 这块屏幕上能单击选中的目标（屏幕内坐标，左上角原点）
    let targets: [CaptureTarget]

    /// 像素 / 点（Retina 屏为 2）
    var scale: CGFloat { CGFloat(image.width) / screen.frame.width }
}

/// 截屏相关的系统功能：录屏权限、截取屏幕、读取可单击选中的目标
@MainActor
enum ScreenCapturer {
    /// 是否已有录屏权限（不会弹窗）
    nonisolated static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// 弹出系统的录屏授权请求（只有第一次会真的弹）
    static func requestPermission() {
        CGRequestScreenCaptureAccess()
    }

    /// 打开「系统设置 › 隐私与安全性 › 录屏与系统录音」
    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 截屏

    /// 缓存的显示器列表：每次截图都去查要多花几十毫秒，显示器变化时清掉
    private static var cachedDisplays: [SCDisplay]?

    /// 启动时先查一次显示器，让第一次截图也快
    /// 显示器插拔、改分辨率后调用
    static func invalidateDisplays() {
        cachedDisplays = nil
    }

    private static func displays() async throws -> [SCDisplay] {
        if let cachedDisplays { return cachedDisplays }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        cachedDisplays = content.displays
        return content.displays
    }

    /// 把所有屏幕截下来（并行截，每块屏按自己的像素密度）
    static func captureAllScreens() async throws -> [ScreenSnapshot] {
        let screens = NSScreen.screens
        // 可选中的目标在截图前读一次，和定格画面保持一致
        let targets = screens.map { targets(for: $0) }
        let displays = try await displays()

        var jobs: [CaptureJob] = []
        for (index, screen) in screens.enumerated() {
            guard let id = screen.displayID, let display = displays.first(where: { $0.displayID == id }) else { continue }
            let config = SCStreamConfiguration()
            config.width = Int(screen.frame.width * screen.backingScaleFactor)
            config.height = Int(screen.frame.height * screen.backingScaleFactor)
            config.showsCursor = false
            config.captureResolution = .best
            config.colorSpaceName = CGColorSpace.sRGB
            jobs.append(CaptureJob(index: index,
                                   filter: SCContentFilter(display: display, excludingWindows: []),
                                   config: config))
        }

        let images = try await withThrowingTaskGroup(of: (Int, CGImage).self) { group in
            for job in jobs {
                group.addTask {
                    (job.index, try await SCScreenshotManager.captureImage(contentFilter: job.filter,
                                                                         configuration: job.config))
                }
            }
            var result: [Int: CGImage] = [:]
            for try await (index, image) in group { result[index] = image }
            return result
        }
        return screens.indices.compactMap { index in
            images[index].map { ScreenSnapshot(screen: screens[index], image: $0, targets: targets[index]) }
        }
    }

    /// 截一块屏需要的参数。ScreenCaptureKit 的这两个类型没标 Sendable，但我们只读不改
    private struct CaptureJob: @unchecked Sendable {
        let index: Int
        let filter: SCContentFilter
        let config: SCStreamConfiguration
    }

    // MARK: - 可单击选中的目标

    /// 读取某块屏幕上的窗口、菜单栏、菜单栏图标、展开的菜单。
    /// 只认这几种窗口层：别的 App（如钉钉截图助手）会放透明的全屏窗口，要排除掉。
    static func targets(for screen: NSScreen) -> [CaptureTarget] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]],
              let mainHeight = NSScreen.screens.first?.frame.height
        else { return [] }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let pinLevel = Int(CGWindowLevelForKey(.floatingWindow))
        // 屏幕左上角在全局坐标（左上角原点）里的位置
        let origin = CGPoint(x: screen.frame.minX, y: mainHeight - screen.frame.maxY)
        let bounds = CGRect(origin: .zero, size: screen.frame.size)

        return list.compactMap { window -> CaptureTarget? in
            guard let layer = window[kCGWindowLayer as String] as? Int,
                  let boundsDict = window[kCGWindowBounds as String] as! CFDictionary?,
                  let frame = CGRect(dictionaryRepresentation: boundsDict)
            else { return nil }
            let pid = window[kCGWindowOwnerPID as String] as? pid_t
            let kind: CaptureTarget.Kind
            switch layer {
            case Int(CGWindowLevelForKey(.statusWindow)): kind = .menuBarItem
            case Int(CGWindowLevelForKey(.mainMenuWindow)): kind = .menuBar
            case Int(CGWindowLevelForKey(.popUpMenuWindow)): kind = .menu
            case 0: kind = .window
            case pinLevel where pid == myPID: kind = .window   // 自己的贴图
            default: return nil
            }
            if let alpha = window[kCGWindowAlpha as String] as? Double, alpha <= 0 { return nil }
            guard frame.width >= 4, frame.height >= 4 else { return nil }
            let local = frame.offsetBy(dx: -origin.x, dy: -origin.y).intersection(bounds)
            guard !local.isNull, local.width >= 4, local.height >= 4 else { return nil }
            return CaptureTarget(frame: local, kind: kind)
        }
    }

    // MARK: - 取色

    /// 图像上某个像素的 sRGB 颜色
    nonisolated static func color(atPixel point: CGPoint, in image: CGImage) -> (red: Int, green: Int, blue: Int)? {
        let x = Int(point.x), y = Int(point.y)
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return drawn ? (Int(bytes[0]), Int(bytes[1]), Int(bytes[2])) : nil
    }
}

extension NSScreen {
    /// 这块屏幕的显示器编号
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
