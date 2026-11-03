// SPDX-License-Identifier: GPL-3.0-only
import CoreGraphics
import Foundation

/// 多屏：macOS 26 给每块屏幕各画一份图标窗口，顺序相同。离屏的收纳项没有可靠的屏幕归属，
/// 所以以「本屏那份分隔符」为锚点，沿首尾相接的窗口串出本屏的收纳链与常显链。
enum DisplayChain {
    /// 坐标取整误差。
    static let tolerance: CGFloat = 2
    /// 相邻图标之间允许的系统间距；超过即视为断链（另一屏的副本至少差两屏右边缘之差）。
    static let maxGap: CGFloat = 8

    struct Chain {
        let divider: MenuBarItem
        /// 分隔符左侧（收纳区），从左到右。
        let hidden: [MenuBarItem]
        /// 分隔符右侧（常显区），从左到右。
        let visible: [MenuBarItem]
        var ordered: [MenuBarItem] { hidden + [divider] + visible }
    }

    static func sameRow(_ a: CGRect, _ b: CGRect) -> Bool { abs(a.minY - b.minY) <= tolerance }

    /// 多份同名窗口里，选出位于该屏菜单栏那一排、右边缘落在该屏内的那份。
    static func copy(titled title: String, on display: CGRect, in items: [MenuBarItem]) -> MenuBarItem? {
        items.first {
            $0.title == title && abs($0.frame.minY - display.minY) <= tolerance
                && $0.frame.maxX >= display.minX && $0.frame.maxX <= display.maxX + tolerance
        }
    }

    enum OwnItem { case divider, launcher }

    /// 组件自己的窗口：其他屏副本用 autosave 名命名；macOS 26 主屏副本却以 bundle ID 命名，分隔符与托盘图标同名。
    static func isOwn(_ item: MenuBarItem, bundleID: String) -> Bool {
        item.title.hasPrefix("MenuBarShelfLab.") || item.title == bundleID
    }

    /// 找本屏上的分隔符或托盘图标那份。同名时按宽度区分：分隔符要么很宽（收起），要么只有几个点（放开）。
    static func ownCopy(_ kind: OwnItem, on display: CGRect, in items: [MenuBarItem], bundleID: String) -> MenuBarItem? {
        let named = kind == .divider ? "MenuBarShelfLab.Divider" : "MenuBarShelfLab.Launcher"
        if let exact = copy(titled: named, on: display, in: items) { return exact }
        let candidates = items.filter {
            $0.title == bundleID && abs($0.frame.minY - display.minY) <= tolerance
                && $0.frame.maxX >= display.minX && $0.frame.maxX <= display.maxX + tolerance
        }
        let isDivider: (MenuBarItem) -> Bool = { $0.frame.width > 100 || $0.frame.width < 12 }
        return kind == .divider ? candidates.first(where: isDivider) : candidates.first { !isDivider($0) }
    }

    static func chain(anchoredAt divider: MenuBarItem, in items: [MenuBarItem], display: CGRect) -> Chain {
        let row = items.filter { $0.id != divider.id && $0.frame.width > 0 && sameRow($0.frame, divider.frame) }
        var used: Set<CGWindowID> = [divider.id]
        var hidden: [MenuBarItem] = []
        var edge = divider.frame.minX
        // 向左：取右边缘最贴近当前边缘的那一个。
        while let next = row.filter({ !used.contains($0.id) && $0.frame.maxX <= edge + tolerance && edge - $0.frame.maxX <= maxGap })
            .max(by: { $0.frame.maxX < $1.frame.maxX }) {
            used.insert(next.id); hidden.insert(next, at: 0); edge = next.frame.minX
        }
        var visible: [MenuBarItem] = []
        edge = divider.frame.maxX
        while let next = row.filter({ !used.contains($0.id) && $0.frame.minX >= edge - tolerance && $0.frame.minX - edge <= maxGap
                                       && $0.frame.maxX <= display.maxX + tolerance })
            .min(by: { $0.frame.minX < $1.frame.minX }) {
            used.insert(next.id); visible.append(next); edge = next.frame.maxX
        }
        return Chain(divider: divider, hidden: hidden, visible: visible)
    }

    /// 同一排、左项右边缘与右项左边缘之间不超过系统间距。
    static func adjacent(left: CGRect, right: CGRect) -> Bool {
        sameRow(left, right) && left.maxX <= right.minX + tolerance && right.minX - left.maxX <= maxGap
    }

    /// AX 只报告一份图标的位置；各屏链顺序相同，长度一致时按位置把来源进程和名称补到其他副本。
    static func shareAttribution(_ chains: [[MenuBarItem]]) -> [[MenuBarItem]] {
        guard let count = chains.first?.count, chains.allSatisfy({ $0.count == count }) else { return chains }
        var result = chains
        for index in 0..<count {
            guard let source = chains.map({ $0[index] }).first(where: { $0.sourceProcessID != nil }) else { continue }
            for display in result.indices where result[display][index].sourceProcessID == nil {
                result[display][index].sourceProcessID = source.sourceProcessID
                result[display][index].accessibilityName = source.accessibilityName
                result[display][index].sourceBundleID = source.sourceBundleID
            }
        }
        return result
    }

    /// 同一图标在另一块屏上的那份：各屏链顺序相同，长度一致时按位置对应。
    static func counterpart(of id: CGWindowID, from source: [MenuBarItem], to target: [MenuBarItem]) -> CGWindowID? {
        guard source.count == target.count, let index = source.firstIndex(where: { $0.id == id }) else { return nil }
        return target[index].id
    }

    /// 某次 AX 查询超时时保留之前识别出的来源应用，避免名称退回「控制中心 · Item-0」。
    static func keepingAttribution(_ fresh: MenuBarItem, previous: MenuBarItem?) -> MenuBarItem {
        guard fresh.sourceProcessID == nil, let previous, ShelfGeometry.sameWindow(fresh, as: previous),
              previous.sourceProcessID != nil else { return fresh }
        var merged = fresh
        merged.sourceProcessID = previous.sourceProcessID
        merged.accessibilityName = previous.accessibilityName
        merged.sourceBundleID = previous.sourceBundleID
        return merged
    }

    /// 临时图标必须完整落在此值右侧：避开应用菜单与刘海；取不到应用菜单时保守地只用右半屏。
    static func clickableLeftLimit(display: CGRect, menuRightEdge: CGFloat?, notchRightEdge: CGFloat?) -> CGFloat {
        max(menuRightEdge.map { $0 + 8 } ?? display.midX, notchRightEdge.map { $0 + 20 } ?? display.minX, display.minX)
    }

    /// 解析 CGSCopyManagedDisplaySpaces：屏幕标识 → 当前桌面 ID。私有格式，缺字段的屏幕跳过。
    static func currentSpaces(from managed: [[String: Any]]) -> [String: UInt] {
        var result: [String: UInt] = [:]
        for display in managed {
            guard let id = display["Display Identifier"] as? String,
                  let current = display["Current Space"] as? [String: Any],
                  let space = (current["id64"] as? NSNumber ?? current["ManagedSpaceID"] as? NSNumber)?.uintValue else { continue }
            result[id] = space
        }
        return result
    }
}
