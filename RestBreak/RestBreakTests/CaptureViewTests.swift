import AppKit
import Testing
@testable import RestBreak

/// 框选界面：裁剪方向、选区位置换算是否正确
@MainActor
struct CaptureViewTests {
    /// 造一张「四色」假截图：左上红、右上绿、左下蓝、右下黄（按图像方向，第一行在最上面）
    private func quadrantImage(width: Int, height: Int) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // CGContext 是左下角原点：y 大的一半是图像的上半部分
        let w = CGFloat(width) / 2, h = CGFloat(height) / 2
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))   // 左上
        context.fill(CGRect(x: 0, y: h, width: w, height: h))
        context.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))   // 右上
        context.fill(CGRect(x: w, y: h, width: w, height: h))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))   // 左下
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1))   // 右下
        context.fill(CGRect(x: w, y: 0, width: w, height: h))
        return try #require(context.makeImage())
    }

    private func makeView() throws -> (CaptureView, NSScreen) {
        let screen = try #require(NSScreen.main)
        let scale = screen.backingScaleFactor
        let image = try quadrantImage(width: Int(screen.frame.width * scale), height: Int(screen.frame.height * scale))
        let view = CaptureView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.load(ScreenSnapshot(screen: screen, image: image, targets: []), showMagnifier: false)
        return (view, screen)
    }

    @Test func 左上角选区裁出左上角的颜色() throws {
        let (view, screen) = try makeView()
        view.select(CGRect(x: 20, y: 20, width: 100, height: 60))
        let cropped = try #require(view.selectedImage())
        #expect(cropped.width == Int(100 * screen.backingScaleFactor))
        let color = try #require(ScreenCapturer.color(atPixel: CGPoint(x: 10, y: 10), in: cropped))
        #expect(color.red == 255 && color.green == 0 && color.blue == 0)
    }

    @Test func 右下角选区裁出右下角的颜色() throws {
        let (view, screen) = try makeView()
        let size = screen.frame.size
        view.select(CGRect(x: size.width - 120, y: size.height - 80, width: 100, height: 60))
        let cropped = try #require(view.selectedImage())
        let color = try #require(ScreenCapturer.color(atPixel: CGPoint(x: 10, y: 10), in: cropped))
        #expect(color.red == 255 && color.green == 255 && color.blue == 0)
    }

    @Test func 选区换算成全局屏幕坐标() throws {
        let (view, screen) = try makeView()
        view.select(CGRect(x: 20, y: 30, width: 100, height: 60))
        let rect = try #require(view.selectionInScreen)
        // 左上角坐标 y=30 → 左下角坐标 y = 屏幕高 - 30 - 60
        #expect(rect == NSRect(x: screen.frame.minX + 20, y: screen.frame.minY + screen.frame.height - 90,
                               width: 100, height: 60))
    }
}
