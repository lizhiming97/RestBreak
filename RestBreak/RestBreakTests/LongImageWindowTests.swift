import AppKit
import Testing
@testable import RestBreak

@MainActor
struct LongImageWindowTests {
    private func tallImage(width: Int = 400, height: Int = 20_000) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for band in stride(from: 0, to: height, by: 100) {
            let g = CGFloat(band % 1000) / 1000
            ctx.setFillColor(red: g, green: 0.5, blue: 1 - g, alpha: 1)
            ctx.fill(CGRect(x: 0, y: band, width: width, height: 100))
        }
        return ctx.makeImage()!
    }

    @Test func 很长的图能显示并原尺寸导出() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.screens.first)
        let window = LongImageWindow(image: tallImage(), scale: 2, on: screen, annotationStyles: [:])
        defer { window.close() }
        window.orderFrontRegardless()
        window.displayIfNeeded()
        // 窗口不会比屏幕高；看得见的区域就是标注的「选区」
        #expect(window.frame.height <= screen.visibleFrame.height)
        let visible = try #require(window.canvas.annotationSelection)
        #expect(visible.height > 0 && visible.height < 10_000)
        // 画布按点计：20000 像素 / 2 = 10000 点
        #expect(window.imagePointSize == CGSize(width: 200, height: 10_000))
        let exported = try #require(window.exportImage())
        #expect(exported.width == 400)
        #expect(exported.height == 20_000)
    }

    @Test func 工具栏不遮挡长图() async throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.screens.first)
        let window = LongImageWindow(image: tallImage(width: 1300, height: 6000), scale: 2, on: screen, annotationStyles: [:])
        defer { window.close() }
        window.orderFrontRegardless()
        func check() {
            window.contentView?.layoutSubtreeIfNeeded()
            let toolbar = window.toolbarView.convert(window.toolbarView.bounds, to: nil)
            let image = window.scrollView.frame
            #expect(toolbar.height > 30)
            #expect(image.maxY <= toolbar.minY + 0.5)   // 长图区域在工具栏下面，不重叠
            // 长图顶端（第 0 行）一开始就在可见区域里，并且和区域上边有留白
            let top = window.canvas.convert(NSPoint(x: 0, y: 0), to: nil)
            #expect(top.y <= image.maxY - LongImageWindow.margin + 1)
            #expect(image.height > 100)
        }
        check()
        // 选了画图工具：工具栏下面多出属性条，长图区域跟着往下让
        window.canvas.editor.select(tool: .rectangle)
        try await Task.sleep(for: .milliseconds(400))
        check()
        window.setContentSize(NSSize(width: 900, height: 500))
        check()
    }

    /// 渲染窗口存成图片，人工检查用（只在设置了 FRIDAY_SNAPSHOT 时运行）
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FRIDAY_SNAPSHOT"] != nil))
    func 窗口截图检查() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.screens.first)
        let ctx = CGContext(data: nil, width: 1300, height: 6000, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.94, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1300, height: 6000))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 5990, width: 1300, height: 10))
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 1, alpha: 1))
        for y in stride(from: 100, to: 6000, by: 300) { ctx.fill(CGRect(x: 100, y: 6000 - y - 80, width: 400, height: 80)) }
        let window = LongImageWindow(image: ctx.makeImage()!, scale: 2, on: screen, annotationStyles: [:])
        defer { window.close() }
        window.orderFrontRegardless()
        window.displayIfNeeded()
        let view = try #require(window.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("friday-longwindow.png"))
    }
}
