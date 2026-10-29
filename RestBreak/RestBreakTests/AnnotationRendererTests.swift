import AppKit
import Testing
@testable import RestBreak

/// 标注的绘制和导出：用纯色或棋盘格假图检查像素
@MainActor
struct AnnotationRendererTests {
    private let gray = (red: 128, green: 128, blue: 128)

    /// 纯灰色图
    private func grayImage(width: Int, height: Int) throws -> CGImage {
        try makeImage(width: width, height: height) { _, _ in (128, 128, 128) }
    }

    /// 1 像素黑白相间的棋盘格
    private func checkerboard(width: Int, height: Int) throws -> CGImage {
        try makeImage(width: width, height: height) { x, y in (x + y) % 2 == 0 ? (0, 0, 0) : (255, 255, 255) }
    }

    private func makeImage(width: Int, height: Int, color: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = color(x, y), i = (y * width + x) * 4
                bytes[i] = c.0; bytes[i + 1] = c.1; bytes[i + 2] = c.2
            }
        }
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: width * 4, space: space,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> (red: Int, green: Int, blue: Int) {
        try #require(ScreenCapturer.color(atPixel: CGPoint(x: x, y: y), in: image))
    }

    private func style(_ color: AnnotationColor = .red, size: StrokeSize = .medium,
                       mosaic: MosaicStyle = .pixelate) -> ToolStyle {
        ToolStyle(color: color, size: size, mosaic: mosaic)
    }

    private func export(_ annotations: [Annotation], source: CGImage, selection: CGRect,
                        scale: CGFloat = 1) throws -> CGImage {
        try #require(AnnotationRenderer.export(selection: selection, source: source, scale: scale,
                                               annotations: annotations, cache: MosaicCache()))
    }

    @Test func 没有标注时导出原图裁剪() throws {
        let source = try grayImage(width: 400, height: 300)
        let image = try export([], source: source, selection: CGRect(x: 50, y: 40, width: 200, height: 100))
        #expect(image.width == 200 && image.height == 100)
        #expect(try pixel(image, 10, 10) == gray)
    }

    @Test func 矩形画在边上_里面还是原图() throws {
        let source = try grayImage(width: 400, height: 300)
        let rect = Annotation(tool: .rectangle, points: [CGPoint(x: 20, y: 20), CGPoint(x: 120, y: 80)], style: style())
        let image = try export([rect], source: source, selection: CGRect(x: 0, y: 0, width: 200, height: 150))
        let edge = try pixel(image, 20, 50)
        #expect(edge.red > 200 && edge.green < 100)
        #expect(try pixel(image, 70, 50) == gray)
        #expect(try pixel(image, 160, 120) == gray)
    }

    @Test func 标注按选区平移() throws {
        // 选区从 (100,100) 开始，标注在屏幕坐标 (120,120) → 导出图里的 (20,20)
        let source = try grayImage(width: 400, height: 300)
        let rect = Annotation(tool: .rectangle, points: [CGPoint(x: 120, y: 120), CGPoint(x: 180, y: 160)], style: style())
        let image = try export([rect], source: source, selection: CGRect(x: 100, y: 100, width: 150, height: 100))
        let edge = try pixel(image, 20, 40)
        #expect(edge.red > 200 && edge.green < 100)
    }

    @Test func 箭头终点是箭头颜色() throws {
        let source = try grayImage(width: 400, height: 300)
        let arrow = Annotation(tool: .arrow, points: [CGPoint(x: 20, y: 75), CGPoint(x: 180, y: 75)],
                               style: style(.blue))
        let image = try export([arrow], source: source, selection: CGRect(x: 0, y: 0, width: 200, height: 150))
        let tip = try pixel(image, 175, 75)
        #expect(tip.blue > 200 && tip.red < 120)
        let shaft = try pixel(image, 60, 75)
        #expect(shaft.blue > 200)
    }

    @Test func 像素块马赛克把相邻像素变成一样() throws {
        let source = try checkerboard(width: 200, height: 200)
        #expect(try pixel(source, 50, 50) != pixel(source, 51, 50))
        let mosaic = Annotation(tool: .mosaic, points: [CGPoint(x: 20, y: 20), CGPoint(x: 120, y: 120)],
                                style: style(size: .large))
        let image = try export([mosaic], source: source, selection: CGRect(x: 0, y: 0, width: 200, height: 200))
        #expect(try pixel(image, 50, 50) == pixel(image, 51, 50))
        // 马赛克外面不受影响
        #expect(try pixel(image, 150, 150) != pixel(image, 151, 150))
    }

    @Test func 模糊马赛克把黑白混成灰() throws {
        let source = try checkerboard(width: 200, height: 200)
        let mosaic = Annotation(tool: .mosaic, points: [CGPoint(x: 20, y: 20), CGPoint(x: 120, y: 120)],
                                style: style(mosaic: .blur))
        let image = try export([mosaic], source: source, selection: CGRect(x: 0, y: 0, width: 200, height: 200))
        let c = try pixel(image, 70, 70)
        #expect(c.red > 60 && c.red < 200)
    }

    @Test func 文字画出来了() throws {
        let source = try grayImage(width: 400, height: 300)
        var text = Annotation(tool: .text, points: [CGPoint(x: 10, y: 10)], style: style(.black), text: "测试 Test")
        text.textSize = AnnotationRenderer.textSize(text.text, fontSize: text.fontSize)
        #expect(text.textSize.width > 40 && text.textSize.height > 15)
        let image = try export([text], source: source, selection: CGRect(x: 0, y: 0, width: 200, height: 100))
        var changed = 0
        for x in stride(from: 10, to: 10 + Int(text.textSize.width), by: 2) {
            for y in stride(from: 10, to: 10 + Int(text.textSize.height), by: 2) where try pixel(image, x, y) != gray {
                changed += 1
            }
        }
        #expect(changed > 20)
    }

    @Test func 序号是实心圆() throws {
        let source = try grayImage(width: 200, height: 200)
        let number = Annotation(tool: .number, points: [CGPoint(x: 100, y: 100)], style: style(.green), number: 7)
        let image = try export([number], source: source, selection: CGRect(x: 0, y: 0, width: 200, height: 200))
        let rim = try pixel(image, 100, 90)   // 圆内、数字上方
        #expect(rim.green > 150 && rim.red < 120)
    }

    @Test func Retina导出尺寸按像素() throws {
        let source = try grayImage(width: 800, height: 600)   // 2 倍屏：400×300 点
        let rect = Annotation(tool: .rectangle, points: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 40)], style: style())
        let image = try export([rect], source: source, selection: CGRect(x: 0, y: 0, width: 100, height: 50), scale: 2)
        #expect(image.width == 200 && image.height == 100)
        let edge = try pixel(image, 20, 50)   // 点 (10, 25) → 像素 (20, 50)
        #expect(edge.red > 200)
    }

    @Test func 像素块取整块的平均色_不是随机取一个点() throws {
        // 白底上一条 1 像素宽的黑线（像截图里的细文字）：
        // 每块应该是均匀的浅灰（平均色），而不是有的块全黑、有的块全白
        let source = try makeImage(width: 200, height: 200) { x, _ in x == 53 ? (0, 0, 0) : (255, 255, 255) }
        let mosaic = Annotation(tool: .mosaic, points: [CGPoint(x: 40, y: 40), CGPoint(x: 120, y: 120)],
                                style: style(size: .large))   // 像素块 16
        let image = try export([mosaic], source: source, selection: CGRect(x: 0, y: 0, width: 200, height: 200))
        let onLine = try pixel(image, 53, 80)
        #expect(onLine.red > 200 && onLine.red < 250)          // 浅灰，不是黑
        let sameBlock = try pixel(image, 41, 80)
        #expect(sameBlock == onLine)                            // 同一块颜色一样
    }

    @Test func 白色区域打码后边缘不发白不透明() throws {
        // 纯色区域打码后应该还是同一个颜色，边上的块也一样（不会因为取到选区外而变浅）
        let source = try makeImage(width: 200, height: 200) { _, _ in (200, 210, 220) }
        let mosaic = Annotation(tool: .mosaic, points: [CGPoint(x: 33, y: 37), CGPoint(x: 131, y: 129)],
                                style: style(size: .large))
        let image = try export([mosaic], source: source, selection: CGRect(x: 0, y: 0, width: 200, height: 200))
        for (x, y) in [(33, 37), (130, 128), (33, 128), (130, 37), (80, 80)] {
            let c = try pixel(image, x, y)
            #expect(abs(c.red - 200) <= 1 && abs(c.green - 210) <= 1 && abs(c.blue - 220) <= 1)
        }
    }
}
