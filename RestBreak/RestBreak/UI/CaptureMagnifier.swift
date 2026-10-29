import AppKit

/// 截图时光标旁的放大镜：放大的像素网格（中心十字高亮），下面是坐标、颜色值和按键提示
final class MagnifierLayer: CALayer {
    private let pixels = 17                 // 每边显示多少个像素（奇数，中间那格是光标）
    private let cell: CGFloat = 9           // 每个像素放大成多少点
    private var zoomSize: CGFloat { CGFloat(pixels) * cell }
    private let infoHeight: CGFloat = 84

    private let zoom = CALayer()
    private let grid = CAShapeLayer()
    /// 光标所在的那一行、那一列（蓝色十字）
    private let cross = CAShapeLayer()
    /// 光标所在像素的小方框：外黑内白，任何颜色上都看得见
    private let centerOuter = CAShapeLayer()
    private let centerInner = CAShapeLayer()
    private let coordsText = CATextLayer()
    private let colorText = CATextLayer()
    private let hintText = CATextLayer()
    private let swatch = CALayer()
    private var copiedUntil = Date.distantPast

    override init() {
        super.init()
        isHidden = true
        backgroundColor = NSColor(white: 0.16, alpha: 0.94).cgColor
        cornerRadius = 8
        masksToBounds = false
        borderColor = NSColor.black.withAlphaComponent(0.6).cgColor
        borderWidth = 1
        shadowColor = NSColor.black.cgColor
        shadowOpacity = 0.3
        shadowRadius = 8
        shadowOffset = CGSize(width: 0, height: -3)

        zoom.magnificationFilter = .nearest   // 放大后保持像素格子，不模糊
        zoom.masksToBounds = true
        zoom.cornerRadius = 7
        zoom.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]   // 只圆上面两个角
        grid.strokeColor = NSColor.black.withAlphaComponent(0.06).cgColor
        grid.lineWidth = 0.5
        grid.fillColor = nil
        cross.fillColor = NSColor(red: 0.24, green: 0.48, blue: 0.97, alpha: 0.55).cgColor
        centerOuter.fillColor = nil
        centerOuter.strokeColor = NSColor.black.cgColor
        centerOuter.lineWidth = 1.5
        centerInner.fillColor = nil
        centerInner.strokeColor = NSColor.white.cgColor
        centerInner.lineWidth = 1

        for (text, size, alpha) in [(coordsText, 12.0, 1.0), (colorText, 12.0, 1.0), (hintText, 11.0, 0.72)] {
            text.fontSize = size
            text.font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
            text.foregroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
        }
        swatch.cornerRadius = 2
        swatch.borderColor = NSColor.white.withAlphaComponent(0.7).cgColor
        swatch.borderWidth = 0.5
        for sublayer in [zoom, grid, cross, centerOuter, centerInner, coordsText, colorText, hintText, swatch] {
            addSublayer(sublayer)
        }

        bounds = CGRect(x: 0, y: 0, width: zoomSize, height: zoomSize + infoHeight)
        for layer in [zoom, grid, cross, centerOuter, centerInner] as [CALayer] {
            layer.frame = CGRect(x: 0, y: infoHeight, width: zoomSize, height: zoomSize)
        }
        let path = CGMutablePath()
        for i in 1..<pixels {
            let v = CGFloat(i) * cell
            path.move(to: CGPoint(x: v, y: 0)); path.addLine(to: CGPoint(x: v, y: zoomSize))
            path.move(to: CGPoint(x: 0, y: v)); path.addLine(to: CGPoint(x: zoomSize, y: v))
        }
        grid.path = path
        // 信息区（图层坐标左下角原点）：坐标 / 颜色 / 两行提示
        coordsText.frame = CGRect(x: 10, y: 60, width: zoomSize - 16, height: 17)
        swatch.frame = CGRect(x: 10, y: 44, width: 12, height: 12)
        colorText.frame = CGRect(x: 28, y: 41, width: zoomSize - 34, height: 17)
        hintText.frame = CGRect(x: 10, y: 4, width: zoomSize - 16, height: 34)
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setScale(_ scale: CGFloat) {
        contentsScale = scale
        for text in [coordsText, colorText, hintText] { text.contentsScale = scale }
    }

    func clear() {
        zoom.contents = nil
        isHidden = true
    }

    /// 复制颜色后，提示行显示「已复制 …」1 秒
    func flashCopied(_ value: String) {
        copiedUntil = Date() + 1
        hintText.string = "已复制 \(value)"
    }

    /// mouse：光标在屏幕内的位置（左上角坐标，单位点）；screenSize：屏幕大小（点）
    func update(image: CGImage, scale: CGFloat, mouse: CGPoint, color: (red: Int, green: Int, blue: Int)?,
                format: ColorFormat, in screenSize: CGSize) {
        // 光标所在像素，以及以它为中心、限制在图像内的区域
        let px = min(max(Int(mouse.x * scale), 0), image.width - 1)
        let py = min(max(Int(mouse.y * scale), 0), image.height - 1)
        let half = pixels / 2
        let x0 = min(max(px - half, 0), max(image.width - pixels, 0))
        let y0 = min(max(py - half, 0), max(image.height - pixels, 0))
        zoom.contents = image.cropping(to: CGRect(x: x0, y: y0, width: pixels, height: pixels))

        // 光标像素的格子（贴边时不在正中）；图层坐标左下角原点，所以 y 要倒过来
        let cx = CGFloat(px - x0) * cell
        let cy = zoomSize - CGFloat(py - y0 + 1) * cell
        let crossPath = CGMutablePath()
        crossPath.addRect(CGRect(x: cx, y: 0, width: cell, height: cy))                                   // 下半竖条
        crossPath.addRect(CGRect(x: cx, y: cy + cell, width: cell, height: zoomSize - cy - cell))         // 上半竖条
        crossPath.addRect(CGRect(x: 0, y: cy, width: cx, height: cell))                                   // 左半横条
        crossPath.addRect(CGRect(x: cx + cell, y: cy, width: zoomSize - cx - cell, height: cell))         // 右半横条
        cross.path = crossPath
        let box = CGRect(x: cx, y: cy, width: cell, height: cell)
        centerOuter.path = CGPath(rect: box.insetBy(dx: -0.75, dy: -0.75), transform: nil)
        centerInner.path = CGPath(rect: box.insetBy(dx: 0.5, dy: 0.5), transform: nil)

        coordsText.string = "坐标：\(Int(mouse.x)), \(Int(mouse.y))"
        if let color {
            colorText.string = format.text(red: color.red, green: color.green, blue: color.blue)
            swatch.backgroundColor = CGColor(srgbRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255,
                                             blue: CGFloat(color.blue) / 255, alpha: 1)
        }
        if Date() >= copiedUntil {
            hintText.string = "按 ⌘C 复制颜色值\n按 Shift 切换 \(format == .rgb ? "HEX" : "RGB")"
        }

        // 位置：光标右下 20pt，超出屏幕时翻到左边 / 上边（换成左下角坐标）
        let size = bounds.size
        var x = mouse.x + 20
        var topY = mouse.y + 20
        if x + size.width > screenSize.width { x = mouse.x - 20 - size.width }
        if topY + size.height > screenSize.height { topY = mouse.y - 20 - size.height }
        frame = CGRect(x: x, y: screenSize.height - topY - size.height, width: size.width, height: size.height)
    }
}

/// 截图用的光标：圆圈 + 十字，带白色描边，在深色背景上也看得清
@MainActor
enum CaptureCursor {
    static let crosshair: NSCursor = {
        let size: CGFloat = 32, c: CGFloat = 16, radius: CGFloat = 7
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let path = NSBezierPath()
            path.appendOval(in: NSRect(x: c - radius, y: c - radius, width: radius * 2, height: radius * 2))
            for (from, to) in [(2.0, 12.0), (20.0, 30.0)] {
                path.move(to: NSPoint(x: from, y: c)); path.line(to: NSPoint(x: to, y: c))
                path.move(to: NSPoint(x: c, y: from)); path.line(to: NSPoint(x: c, y: to))
            }
            path.lineCapStyle = .round
            NSColor.white.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 3.2
            path.stroke()
            NSColor.black.setStroke()
            path.lineWidth = 1.3
            path.stroke()
            // 中心一个小点，标出热点位置
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: c - 0.8, y: c - 0.8, width: 1.6, height: 1.6)).fill()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: c, y: c))
    }()
}
