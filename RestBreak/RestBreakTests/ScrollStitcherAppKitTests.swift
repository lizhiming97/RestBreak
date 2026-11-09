import AppKit
import Testing
@testable import RestBreak

/// 用真正的 AppKit 文本视图滚动后截图（系统自己的文字渲染、滚动条），验证拼接能连续拼上
@MainActor
struct ScrollStitcherAppKitTests {
    @Test func 真实文本视图滚动后能连续拼上() throws {
        _ = NSApplication.shared
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 400))
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 400))
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.font = .systemFont(ofSize: 15)
        textView.string = (0..<200).map { "第 \($0) 行 · 长截图拼接测试 Friday scrolling \($0 * 7 % 31)" + ($0 % 6 == 5 ? "\n" : "") }
            .joined(separator: "\n")
        scrollView.documentView = textView
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scrollView
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        textView.sizeToFit()

        func snapshot(at y: CGFloat) throws -> CGImage {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            let rep = try #require(scrollView.bitmapImageRepForCachingDisplay(in: scrollView.bounds))
            scrollView.cacheDisplay(in: scrollView.bounds, to: rep)
            return try #require(rep.cgImage)
        }
        // 往下滚，中途往回滚一段再继续
        let offsets: [CGFloat] = [0, 60, 150, 230, 160, 260, 340, 420]
        let frames = try offsets.map(snapshot)
        let result = ScrollStitcherTests.stitch(frames)
        #expect(!result.motions.contains(.indeterminate))
        // 拼出来的高度 = 一帧 + 最远滚到的距离（按像素）
        let scale = CGFloat(frames[0].height) / 400
        #expect(abs(CGFloat(result.canvas.height) - CGFloat(frames[0].height) - 420 * scale) <= 2)
    }
}
