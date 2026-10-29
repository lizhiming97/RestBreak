import AppKit

// 把用户给的 logo（米白底 + 黑色 f）做成 macOS 标准图标：
// 1024 画布，824×824 圆角方块居中（圆角 185），带轻微阴影；f 保持原样，按方块大小居中缩放。
let args = CommandLine.arguments
let src = NSImage(contentsOf: URL(fileURLWithPath: args[1]))!
let rep = NSBitmapImageRep(data: src.tiffRepresentation!)!
let w = rep.pixelsWide, h = rep.pixelsHigh

// 背景色：取四个角的平均
var bg = (r: 0.0, g: 0.0, b: 0.0)
for (x, y) in [(5, 5), (w - 6, 5), (5, h - 6), (w - 6, h - 6)] {
    let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    bg.r += c.redComponent / 4; bg.g += c.greenComponent / 4; bg.b += c.blueComponent / 4
}
// 字形范围：亮度明显低于背景的像素
var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<h { for x in 0..<w {
    let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    if (c.redComponent + c.greenComponent + c.blueComponent) / 3 < 0.5 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }
}}
print("背景色", bg, "字形范围", minX, minY, maxX, maxY)
let pad = 6
let glyphRect = NSRect(x: minX - pad, y: h - maxY - 1 - pad, width: maxX - minX + 1 + pad * 2, height: maxY - minY + 1 + pad * 2)
let glyph = NSImage(size: glyphRect.size)
glyph.lockFocus()
src.draw(in: NSRect(origin: .zero, size: glyphRect.size), from: glyphRect, operation: .copy, fraction: 1)
glyph.unlockFocus()

let bgColor = NSColor(srgbRed: bg.r, green: bg.g, blue: bg.b, alpha: 1)
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)

func icon(size: Int, glyphHeight: CGFloat) -> NSBitmapImageRep {
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    NSGraphicsContext.current?.imageInterpolation = .high
    let t = NSAffineTransform(); t.scale(by: CGFloat(size) / 1024); t.concat()
    let path = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow(); s.shadowColor = NSColor.black.withAlphaComponent(0.3)
    s.shadowBlurRadius = 24; s.shadowOffset = NSSize(width: 0, height: -10); s.set()
    bgColor.setFill(); path.fill()
    NSGraphicsContext.restoreGraphicsState()
    // 一圈极淡的描边，浅色桌面上也看得清边界
    NSColor.black.withAlphaComponent(0.08).setStroke(); path.lineWidth = 2; path.stroke()
    let scale = glyphHeight / glyph.size.height
    let gw = glyph.size.width * scale
    // 斜体 f 视觉重心偏右，稍微往左挪一点
    let rect = NSRect(x: 512 - gw / 2 - 8, y: 512 - glyphHeight / 2, width: gw, height: glyphHeight)
    NSGraphicsContext.saveGraphicsState(); path.addClip()
    glyph.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    return out
}

let dir = URL(fileURLWithPath: args[2])
let specs: [(Int, String)] = [(16, "16x16@1x"), (32, "16x16@2x"), (32, "32x32@1x"), (64, "32x32@2x"),
                             (128, "128x128@1x"), (256, "128x128@2x"), (256, "256x256@1x"),
                             (512, "256x256@2x"), (512, "512x512@1x"), (1024, "512x512@2x")]
var images: [[String: String]] = []
for (px, name) in specs {
    // 小尺寸时字形放大一些（笔画更粗），否则 16/32 像素会发虚
    let gh: CGFloat = px <= 32 ? 640 : (px <= 64 ? 600 : 560)
    let file = "icon_\(name).png"
    try! icon(size: px, glyphHeight: gh).representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(file))
    let parts = name.split(separator: "@")
    images.append(["idiom": "mac", "size": String(parts[0]), "scale": String(parts[1]), "filename": file])
}
let json: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    .write(to: dir.appendingPathComponent("Contents.json"))

// 预览图：深浅两种背景上的各尺寸
let preview = NSImage(size: NSSize(width: 1100, height: 420), flipped: false) { _ in
    for (row, bgc) in [NSColor(white: 0.96, alpha: 1), NSColor(white: 0.16, alpha: 1)].enumerated() {
        bgc.setFill(); NSRect(x: 0, y: CGFloat(1 - row) * 210, width: 1100, height: 210).fill()
        var x: CGFloat = 30
        for px in [180, 128, 64, 32, 16] {
            let img = NSImage(cgImage: icon(size: px * 2, glyphHeight: px <= 32 ? 640 : (px <= 64 ? 600 : 560)).cgImage!, size: NSSize(width: px, height: px))
            img.draw(in: NSRect(x: x, y: CGFloat(1 - row) * 210 + (210 - CGFloat(px)) / 2, width: CGFloat(px), height: CGFloat(px)))
            x += CGFloat(px) + 60
        }
    }
    return true
}
try! NSBitmapImageRep(data: preview.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: args[3]))
print("ok")
