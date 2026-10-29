import AppKit
import SwiftUI
import Testing
@testable import RestBreak

/// 用模拟的鼠标、键盘事件走一遍标注流程
@MainActor
struct AnnotationInteractionTests {
    private func grayImage(width: Int, height: Int) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func makeView() throws -> CaptureView {
        let screen = try #require(NSScreen.main)
        let image = try grayImage(width: Int(screen.frame.width * screen.backingScaleFactor),
                                  height: Int(screen.frame.height * screen.backingScaleFactor))
        let view = CaptureView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.load(ScreenSnapshot(screen: screen, image: image, targets: []), showMagnifier: false)
        view.select(CGRect(x: 100, y: 100, width: 300, height: 200))
        return view
    }

    /// 左上角坐标 → 视图里的鼠标事件
    private func mouse(_ type: NSEvent.EventType, _ view: CaptureView, _ x: CGFloat, _ y: CGFloat,
                       flags: NSEvent.ModifierFlags = [], clicks: Int = 1) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: view.bounds.height - y),
                                        modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                        eventNumber: 0, clickCount: clicks, pressure: 1))
    }

    private func key(_ code: UInt16, _ chars: String = "", flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                      windowNumber: 0, context: nil, characters: chars,
                                      charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
    }

    private func drag(_ view: CaptureView, from a: CGPoint, to b: CGPoint) throws {
        view.mouseDown(with: try mouse(.leftMouseDown, view, a.x, a.y))
        view.mouseDragged(with: try mouse(.leftMouseDragged, view, (a.x + b.x) / 2, (a.y + b.y) / 2))
        view.mouseDragged(with: try mouse(.leftMouseDragged, view, b.x, b.y))
        view.mouseUp(with: try mouse(.leftMouseUp, view, b.x, b.y))
    }

    @Test func 选矩形工具拖动画出红框_导出带标注() throws {
        let view = try makeView()
        view.keyDown(with: try key(18, "1"))   // 数字键 1 = 矩形
        #expect(view.editor.tool == .rectangle)
        try drag(view, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 250, y: 220))
        #expect(view.editor.document.items.count == 1)
        #expect(view.editor.document.items[0].rect == CGRect(x: 150, y: 150, width: 100, height: 70))

        let image = try #require(view.selectedImage())
        let scale = CGFloat(image.width) / 300
        let edge = try #require(ScreenCapturer.color(atPixel: CGPoint(x: 50 * scale, y: 80 * scale), in: image))
        #expect(edge.red > 200 && edge.green < 100)   // 选区内 (50, 80) 是矩形左边
    }

    @Test func 点中已有标注可以拖动和删除_撤销恢复() throws {
        let view = try makeView()
        view.editor.select(tool: .arrow)
        try drag(view, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 300, y: 150))
        #expect(view.editor.document.items.count == 1)
        // 点在箭头上拖动 = 移动，不是画新箭头
        try drag(view, from: CGPoint(x: 200, y: 151), to: CGPoint(x: 200, y: 201))
        #expect(view.editor.document.items.count == 1)
        #expect(view.editor.document.items[0].points[0] == CGPoint(x: 150, y: 200))
        view.keyDown(with: try key(51))   // ⌫ 删除选中的
        #expect(view.editor.document.isEmpty)
        view.editor.undo()
        #expect(view.editor.document.items[0].points[0] == CGPoint(x: 150, y: 200))
        view.editor.undo()
        #expect(view.editor.document.items[0].points[0] == CGPoint(x: 150, y: 150))
    }

    @Test func 序号点一下就加_编号递增() throws {
        let view = try makeView()
        view.editor.select(tool: .number)
        view.mouseDown(with: try mouse(.leftMouseDown, view, 150, 150))
        view.mouseUp(with: try mouse(.leftMouseUp, view, 150, 150))
        view.mouseDown(with: try mouse(.leftMouseDown, view, 250, 150))
        view.mouseUp(with: try mouse(.leftMouseUp, view, 250, 150))
        #expect(view.editor.document.items.map(\.number) == [1, 2])
    }

    @Test func 选区外不画() throws {
        let view = try makeView()
        view.editor.select(tool: .rectangle)
        try drag(view, from: CGPoint(x: 600, y: 600), to: CGPoint(x: 700, y: 700))
        #expect(view.editor.document.isEmpty)
        #expect(view.selection == CGRect(x: 100, y: 100, width: 300, height: 200))   // 选区没被改
    }

    @Test func Esc一步步退_有标注要按两次() throws {
        let view = try makeView()
        view.editor.select(tool: .rectangle)
        try drag(view, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 250, y: 220))
        view.keyDown(with: try key(53))
        #expect(view.editor.tool == nil)              // 第一下：取消工具
        view.keyDown(with: try key(53))
        #expect(view.selection != nil)               // 第二下：只提示，不丢标注
        #expect(!view.editor.document.isEmpty)
        view.keyDown(with: try key(53))
        #expect(view.selection == nil)               // 1 秒内再按：放弃标注、清除选区
        #expect(view.editor.document.isEmpty)
    }

    @Test func 马赛克显示范围框_只在选了马赛克工具时() throws {
        let view = try makeView()
        view.editor.select(tool: .mosaic)
        view.mouseDown(with: try mouse(.leftMouseDown, view, 150, 150))
        view.mouseDragged(with: try mouse(.leftMouseDragged, view, 250, 200))
        #expect(view.editor.mosaicOutlineLayer.path != nil)          // 拖动中有框
        view.mouseUp(with: try mouse(.leftMouseUp, view, 250, 200))
        #expect(view.editor.mosaicOutlineLayer.path != nil)          // 画完、还选着马赛克工具：已有的也有框
        view.editor.select(tool: .arrow)
        #expect(view.editor.mosaicOutlineLayer.path == nil)          // 换成别的工具就不显示
        let image = try #require(view.selectedImage())
        // 框不进导出：选区左上角 (150-100, 150-100) 处不是蓝色
        let scale = CGFloat(image.width) / 300
        let corner = try #require(ScreenCapturer.color(atPixel: CGPoint(x: 50 * scale, y: 50 * scale), in: image))
        #expect(!(corner.blue > 200 && corner.red < 120))
    }
}
