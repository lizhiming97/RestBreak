// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import os

typealias Logger = os.Logger
extension Logger {
    init(category: String) { self.init(subsystem: "com.lizhiming.MenuBarShelfLab", category: category) }
}
extension CGError { var logString: String { "CGError(\(rawValue))" } }

public enum ShelfError: LocalizedError {
    case permission, screenRecording, inputBusy, missingItem, noSpace, dividerMissing, spaceChanged, displayRemoved, captureFailed
    case automaticMenuBar, pendingRestore, movementFailed
    public var errorDescription: String? {
        switch self {
        case .permission: "请先在系统设置中允许「星期五菜单栏」使用辅助功能。"
        case .screenRecording: "请先允许屏幕录制，以显示各应用的菜单栏图标。授权后可能需要重新打开「星期五菜单栏」。"
        case .inputBusy: "鼠标或修饰键正在使用中，请松开后重试。"
        case .missingItem: "图标已经退出或位置发生变化，请刷新后重试。"
        case .noSpace: "菜单栏可见区域放不下这个图标，请先收纳其他图标或关闭倒计时文字。"
        case .dividerMissing: "这块屏幕上暂时找不到收纳分隔符，请稍后重试或点“刷新”。"
        case .spaceChanged: "桌面已切换。请回到原来的桌面再操作，或点击“恢复临时图标”。"
        case .displayRemoved: "外接屏已断开，临时图标留在可见区域，可在设置列表里重新收纳。"
        case .captureFailed: "系统未返回这个图标的图像。可以按名称点击，或重新授权屏幕录制后重启。"
        case .automaticMenuBar: "请先关闭系统的“自动隐藏菜单栏”，再使用下方展开栏。"
        case .pendingRestore: "上一个应用菜单仍打开，或图标尚未归位。请先关闭菜单并恢复图标。"
        case .movementFailed: "未能确认图标移动成功，请刷新后重试。"
        }
    }
}

/// 窗口标识只在当前进程生命周期内使用；不把它持久化为应用身份。
public struct MenuBarItem: Identifiable, Sendable {
    public let windowID: CGWindowID
    public let ownerPID: pid_t
    public let title: String
    public let ownerName: String
    public let bundleID: String
    public let frame: CGRect
    public let isOnScreen: Bool
    var accessibilityName: String? = nil
    var sourceProcessID: pid_t? = nil
    /// 来源应用的 bundle ID（macOS 26 的绘制进程统一是控制中心，靠 AX 匹配得到）。
    public internal(set) var sourceBundleID: String? = nil
    var eventPID: pid_t { sourceProcessID ?? ownerPID }
    public var id: CGWindowID { windowID }
    public var displayName: String {
        accessibilityName ?? (title.isEmpty || title == ownerName ? ownerName : "\(ownerName) · \(title)")
    }
    var logString: String { "\(bundleID):\(title) [\(windowID)]" }
    // The same non-movable / non-hideable system items excluded by Ice.
    public var isMovable: Bool {
        if bundleID == "com.apple.controlcenter" {
            return !["Clock", "BentoBox", "AudioVideoModule", "FaceTime", "MusicRecognition"].contains(title)
                && !title.hasPrefix("BentoBox-")
        }
        return !(bundleID == "com.apple.systemuiserver" && title == "Siri")
    }
}

/// 纯几何逻辑：单独测试刘海、负坐标外屏、过宽内容和返回位置。
enum ShelfGeometry {
    static func movePoints(item: CGRect, target: CGRect, toLeft: Bool) -> (start: CGPoint, end: CGPoint) {
        var start = CGPoint(x: toLeft ? target.minX : target.maxX, y: target.minY)
        var end = start
        let movingRight = toLeft ? item.maxX <= target.minX : item.minX <= target.maxX
        if movingRight { end.x -= item.width }
        else { start.x += toLeft ? -1 : 1 }
        return (start, end)
    }

    static func sameWindow(_ current: MenuBarItem, as original: MenuBarItem) -> Bool {
        current.id == original.id && current.ownerPID == original.ownerPID && current.bundleID == original.bundleID
    }

    /// 下拉面板：行高与最多同时显示的行数，超出部分在面板内滚动。
    static let menuRowHeight: CGFloat = 28
    static let menuVisibleRows = 12

    /// 标题 + 收起区 + 分隔 + 列表 + 底部留白；待归位时多一条恢复提示。
    static func menuPanelHeight(rows: Int, hasPendingRestore: Bool) -> CGFloat {
        38 + 46 + 13 + CGFloat(min(max(rows, 1), menuVisibleRows)) * menuRowHeight + 8 + (hasPendingRestore ? 34 : 0)
    }

    /// 面板挂在触发图标正下方，左缘与图标对齐（面板有 6pt 内边距），靠边时收进屏幕。
    static func menuPanelFrame(screen: CGRect, menuBarHeight: CGFloat, size: CGSize, anchorMinX: CGFloat) -> CGRect {
        let margin: CGFloat = 8
        let width = min(size.width, screen.width - 2 * margin)
        let x = min(max(anchorMinX - 6, screen.minX + margin), screen.maxX - margin - width)
        return CGRect(x: x, y: screen.maxY - menuBarHeight - size.height - 4, width: width, height: size.height)
    }

    /// 重启后识别同一个图标：窗口编号会变，用来源应用（识别不到时用窗口标题）加同应用内的序号。
    static func layoutKeys(_ items: [MenuBarItem]) -> [String] {
        var seen: [String: Int] = [:]
        return items.map { item in
            let base = item.sourceBundleID ?? item.title
            defer { seen[base, default: 0] += 1 }
            return "\(base)#\(seen[base, default: 0])"
        }
    }

    /// 首次启用：分隔符放在本屏最左侧图标（含被刘海挡住的）的左边，保证一开始什么都不收。
    /// 返回 Preferred Position（距屏幕右缘的点数）。
    static func leftmostPreferredPosition(items: [MenuBarItem], display: CGRect) -> Double? {
        let row = items.filter { abs($0.frame.minY - display.minY) <= DisplayChain.tolerance && $0.frame.maxX <= display.maxX + 1 }
        guard let left = row.map(\.frame.minX).min() else { return nil }
        return Double(display.maxX - left + 10)
    }

    static func insertionTarget(items: [MenuBarItem], width: CGFloat, leftLimit: CGFloat) -> MenuBarItem? {
        items.sorted { $0.frame.minX < $1.frame.minX }.first {
            $0.isOnScreen && $0.frame.minX - width >= leftLimit
        }
    }

    static func returnAnchor(for item: MenuBarItem, in ordered: [MenuBarItem]) -> CGWindowID? {
        // Prefer the immediate right neighbour; the controller restores to its left.
        guard let i = ordered.firstIndex(where: { $0.id == item.id }), i + 1 < ordered.count else { return nil }
        return ordered[i + 1].id
    }

    /// 自动归位失败后的重试间隔；有限次数后返回 nil，交给手动恢复（强制归位）。
    static func restoreRetryDelay(afterFailures failures: Int) -> Duration? {
        let delays: [Duration] = [.seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)]
        return delays.indices.contains(failures) ? delays[failures] : nil
    }

}
