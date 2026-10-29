import AppKit
import SwiftUI
import Testing
@testable import RestBreak

/// 设置窗口：内容刚好铺满窗口，底部不能多出白边
@MainActor
struct SettingsWindowTests {
    @Test func 窗口大小固定_内容铺满到底部() throws {
        let window = SettingsWindowController.makeWindow(
            SettingsView(page: .stats).environmentObject(BreakCoordinator()))
        // 真的显示出来并跑一遍布局：昨天的测试没显示窗口，自动布局没运行，所以没测出窗口被撑高
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date() + 0.3)
        defer { window.orderOut(nil) }
        #expect(window.frame.size == NSSize(width: 760, height: 600))   // 无标题栏占位：整个窗口就是 760×600
        let view = try #require(window.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        // 最底下一行像素：左边是侧边栏的浅灰，不是窗口的纯白
        let bottomLeft = try #require(rep.colorAt(x: 20, y: rep.pixelsHigh - 2)?.usingColorSpace(.sRGB))
        #expect(bottomLeft.redComponent < 0.97)
    }

    @Test func 提醒页分段标题放得下() {
        // 标题「提醒」右边的分段：内容区宽 508，留 80 给标题
        let view = NSHostingView(rootView: SegmentPicker(selection: .constant(RemindersTab.setup)))
        #expect(view.fittingSize.width <= 508 - 80)
    }
}
