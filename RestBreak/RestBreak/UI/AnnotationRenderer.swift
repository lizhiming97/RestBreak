import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// 标注的唯一绘制代码：屏幕上的标注图层和导出图片都调用它，保证「看到的 = 得到的」。
@MainActor
enum AnnotationRenderer {
    /// 把「选区底图 + 标注」画进 context。
    /// context 是左下角原点、单位为点、大小等于选区；selection、标注都是屏幕内左上角坐标。
    static func drawComposite(in context: CGContext, selection: CGRect, source: CGImage, scale: CGFloat,
                              annotations: [Annotation], cache: MosaicCache) {
        let size = selection.size
        if let base = source.cropping(to: CaptureGeometry.pixelRect(for: selection, scale: scale)) {
            context.interpolationQuality = .none
            context.draw(base, in: CGRect(origin: .zero, size: size))
        }
        guard !annotations.isEmpty else { return }

        context.saveGState()
        // 换成左上角原点的屏幕坐标，后面直接用标注里存的坐标画
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -selection.minX, y: -selection.minY)
        context.clip(to: selection)
        context.interpolationQuality = .high
        for annotation in annotations {
            draw(annotation, in: context, source: source, scale: scale, cache: cache)
        }
        context.restoreGState()
    }

    /// 导出选区（带标注）为图片，像素尺寸按屏幕像素密度
    static func export(selection: CGRect, source: CGImage, scale: CGFloat,
                       annotations: [Annotation], cache: MosaicCache) -> CGImage? {
        let pixels = CaptureGeometry.pixelRect(for: selection, scale: scale)
        if annotations.isEmpty { return source.cropping(to: pixels) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: pixels.width / selection.width, y: pixels.height / selection.height)
        drawComposite(in: context, selection: selection, source: source, scale: scale,
                      annotations: annotations, cache: cache)
        return context.makeImage()
    }

    // MARK: - 各种标注

    private static func draw(_ a: Annotation, in context: CGContext, source: CGImage, scale: CGFloat,
                             cache: MosaicCache) {
        let color = cgColor(a.style.color)
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(a.lineWidth)
        context.setStrokeColor(color)
        context.setFillColor(color)

        switch a.tool {
        case .rectangle:
            context.stroke(a.rect)
        case .ellipse:
            context.strokeEllipse(in: a.rect)
        case .arrow:
            drawArrow(a, in: context)
        case .pen:
            context.addPath(smoothPath(a.points))
            context.strokePath()
        case .highlighter:
            // 整条路径一次描边，一笔内重叠的地方不会加深
            context.setBlendMode(.multiply)
            context.setStrokeColor(color.copy(alpha: 0.4) ?? color)
            context.setLineCap(.butt)
            context.addPath(smoothPath(a.points))
            context.strokePath()
        case .mosaic:
            if let image = cache.image(for: a, source: source, scale: scale) {
                drawUpright(image, in: a.rect, context: context)
            }
        case .text:
            drawText(a, in: context)
        case .number:
            drawNumber(a, in: context, color: color)
        }
    }

    /// 箭头：线身 + 实心三角箭头，箭头大小跟线宽走
    private static func drawArrow(_ a: Annotation, in context: CGContext) {
        guard let start = a.points.first, let end = a.points.last else { return }
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length >= 1 else { return }
        let ux = dx / length, uy = dy / length
        let head = min(max(a.lineWidth * 3.5, 12), length)
        let halfWidth = head * 0.45
        let base = CGPoint(x: end.x - ux * head, y: end.y - uy * head)

        // 线身画到箭头中间，避免圆头从三角形尖上冒出来
        context.move(to: start)
        context.addLine(to: CGPoint(x: end.x - ux * head * 0.6, y: end.y - uy * head * 0.6))
        context.strokePath()

        context.move(to: end)
        context.addLine(to: CGPoint(x: base.x - uy * halfWidth, y: base.y + ux * halfWidth))
        context.addLine(to: CGPoint(x: base.x + uy * halfWidth, y: base.y - ux * halfWidth))
        context.closePath()
        context.fillPath()
    }

    /// 经过各点的平滑曲线（相邻两点的中点之间用二次曲线连接）
    private static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else {
            path.addLine(to: first)   // 只有一个点时画一个圆点
            return path
        }
        for i in 1..<points.count {
            let previous = points[i - 1], current = points[i]
            let mid = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
            if i == 1 { path.addLine(to: mid) } else { path.addQuadCurve(to: mid, control: previous) }
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// 文字：先画一圈描边再画字，在任何背景上都看得清
    private static func drawText(_ a: Annotation, in context: CGContext) {
        guard let origin = a.points.first, !a.text.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let rect = CGRect(origin: origin, size: CGSize(width: max(a.textSize.width, 1), height: max(a.textSize.height, 1)))
        let outline = NSAttributedString(string: a.text, attributes: textAttributes(a, outline: true))
        outline.draw(with: rect.offsetBy(dx: textPadding, dy: textPadding), options: [.usesLineFragmentOrigin])
        let fill = NSAttributedString(string: a.text, attributes: textAttributes(a, outline: false))
        fill.draw(with: rect.offsetBy(dx: textPadding, dy: textPadding), options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 文字四周给描边留的空间
    static let textPadding: CGFloat = 3

    static func font(size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    /// 文字（含描边留白）占的大小
    static func textSize(_ text: String, fontSize: CGFloat) -> CGSize {
        let measured = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: font(size: fontSize)])
            .boundingRect(with: CGSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin])
        return CGSize(width: ceil(measured.width) + textPadding * 2, height: ceil(measured.height) + textPadding * 2)
    }

    /// 文字的字体和颜色（屏幕上编辑文字的输入框也用它，保证编辑时和画出来一样）
    static func textAttributes(_ a: Annotation, outline: Bool) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.font: font(size: a.fontSize)]
        if outline {
            // 白、黄字配深色描边，其他颜色配白色描边
            let light = a.style.color == .white || a.style.color == .yellow
            attributes[.strokeColor] = light ? NSColor.black.withAlphaComponent(0.75) : NSColor.white
            attributes[.strokeWidth] = 22   // 正数 = 只描边，单位是字号的百分比
        } else {
            attributes[.foregroundColor] = nsColor(a.style.color)
        }
        return attributes
    }

    /// 序号：实心圆 + 数字，外面一圈细边
    private static func drawNumber(_ a: Annotation, in context: CGContext, color: CGColor) {
        let circle = a.bounds
        context.fillEllipse(in: circle)
        let isWhite = a.style.color == .white
        context.setStrokeColor(isWhite ? NSColor.black.withAlphaComponent(0.3).cgColor : NSColor.white.cgColor)
        context.setLineWidth(1.5)
        context.strokeEllipse(in: circle.insetBy(dx: 0.75, dy: 0.75))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let text = NSAttributedString(string: "\(a.number)", attributes: [
            .font: NSFont.systemFont(ofSize: a.numberDiameter * 0.55, weight: .bold),
            .foregroundColor: isWhite ? NSColor.black : NSColor.white,
        ])
        let size = text.size()
        text.draw(at: CGPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 在翻转过的 context 里正着画图片
    private static func drawUpright(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    static func cgColor(_ color: AnnotationColor) -> CGColor {
        let c = color.rgb
        return CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
    }

    static func nsColor(_ color: AnnotationColor) -> NSColor {
        let c = color.rgb
        return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
    }
}

/// 马赛克处理结果的缓存：只在新建、移动、改样式时重新计算，拖动别的标注时不用重算
@MainActor
final class MosaicCache {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private var store: [UUID: (key: String, image: CGImage)] = [:]

    func image(for a: Annotation, source: CGImage, scale: CGFloat) -> CGImage? {
        let pixels = CaptureGeometry.pixelRect(for: a.rect, scale: scale)
            .intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1 else { return nil }
        let key = "\(pixels)|\(a.style.mosaic)|\(a.style.size)"
        if let cached = store[a.id], cached.key == key { return cached.image }
        guard let crop = source.cropping(to: pixels) else { return nil }

        let result: CGImage?
        switch a.style.mosaic {
        case .pixelate:
            result = Self.pixelate(crop, block: max(Int((a.mosaicAmount * scale).rounded()), 2))
        case .blur:
            // 先把边缘向外延伸，模糊后边缘才不会发白
            let input = CIImage(cgImage: crop)
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = input.clampedToExtent()
            filter.radius = Float(a.mosaicAmount * scale)
            result = filter.outputImage.flatMap { Self.context.createCGImage($0, from: input.extent) }
        }
        guard let result else { return nil }
        store[a.id] = (key, result)
        return result
    }

    /// 像素块：每块填这块所有像素的平均色。
    /// 不用系统的 CIPixellate：它每块只取一个点的颜色，浅色背景上的细文字会打出时黑时白、很不均匀的块。
    /// 块从马赛克区域的左上角开始排，边上不满一块的按实际像素平均，不会取到区域外面。
    static func pixelate(_ image: CGImage, block: Int) -> CGImage? {
        let width = image.width, height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for top in stride(from: 0, to: height, by: block) {
            for left in stride(from: 0, to: width, by: block) {
                let bottom = min(top + block, height), right = min(left + block, width)
                var sum = (0, 0, 0, 0)
                for y in top..<bottom {
                    for x in left..<right {
                        let i = (y * width + x) * 4
                        sum.0 += Int(pixels[i]); sum.1 += Int(pixels[i + 1])
                        sum.2 += Int(pixels[i + 2]); sum.3 += Int(pixels[i + 3])
                    }
                }
                let count = (bottom - top) * (right - left)
                let average = [sum.0, sum.1, sum.2, sum.3].map { UInt8(($0 + count / 2) / count) }
                for y in top..<bottom {
                    for x in left..<right {
                        let i = (y * width + x) * 4
                        for c in 0..<4 { pixels[i + c] = average[c] }
                    }
                }
            }
        }
        return context.makeImage()
    }
}
