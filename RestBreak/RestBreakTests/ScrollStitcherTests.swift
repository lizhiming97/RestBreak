import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import RestBreak

/// 长截图拼接（第二版）：用真实文字排出一张长页面，按各种滚动方式截出帧，拼回来和原图逐像素比较。
struct ScrollStitcherTests {
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    static func context(_ width: Int, _ height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// 一张长网页：白底黑字，每隔几行留空白（段落间距）
    static func page(width: Int = 600, height: Int = 6000) -> CGImage {
        let ctx = context(width, height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("PingFang SC" as CFString, 20, nil)
        var y = height - 36, line = 0
        while y > 30 {
            if line % 7 != 6 {
                let text = NSAttributedString(string: "第 \(line) 行：星期五长截图 Scrolling capture \(line * 37 % 101)",
                                              attributes: [.font: font, .foregroundColor: CGColor(gray: 0.1, alpha: 1)])
                ctx.textPosition = CGPoint(x: 18 + CGFloat(line % 5) * 9, y: CGFloat(y))
                CTLineDraw(CTLineCreateWithAttributedString(text), ctx)
            }
            y -= 32
            line += 1
        }
        return ctx.makeImage()!
    }

    /// 视口：顶部 header 行导航栏、底部 footer 行底栏、左侧 sidebar 列侧边栏都不动，中间显示页面从 offset 开始的一段。
    /// blink：在内容区画一个闪烁的光标；noise：内容区一块每帧都变的动画
    static func frame(_ page: CGImage, offset: Int, width: Int = 600, height: Int = 700, header: Int = 0, footer: Int = 0,
                      sidebar: Int = 0, blink: Bool = false, noiseSeed: Int? = nil) -> CGImage {
        let ctx = context(width, height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let content = height - header - footer
        if let crop = page.cropping(to: CGRect(x: 0, y: offset, width: width - sidebar, height: content)) {
            ctx.draw(crop, in: CGRect(x: sidebar, y: footer, width: width - sidebar, height: content))
        }
        if header > 0 {
            ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
            ctx.fill(CGRect(x: 0, y: height - header, width: width, height: header))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 20, y: height - header + 15, width: 140, height: 18))
        }
        if footer > 0 {
            ctx.setFillColor(CGColor(gray: 0.85, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: footer))
            ctx.setFillColor(CGColor(gray: 0.3, alpha: 1))
            ctx.fill(CGRect(x: width - 160, y: 10, width: 120, height: 16))
        }
        if sidebar > 0 {
            ctx.setFillColor(CGColor(gray: 0.92, alpha: 1))
            ctx.fill(CGRect(x: 0, y: footer, width: sidebar, height: content))
            ctx.setFillColor(CGColor(gray: 0.35, alpha: 1))
            for row in stride(from: 30, to: content - 20, by: 50) {
                ctx.fill(CGRect(x: 12, y: footer + row, width: sidebar - 30 - (row % 3) * 8, height: 14))
            }
        }
        if blink {
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: sidebar + 300, y: footer + 200, width: 2, height: 22))
        }
        if let noiseSeed {
            var seed = UInt64(noiseSeed) &* 0x9E37_79B9_7F4A_7C15 | 1
            for i in 0..<40 {
                for j in 0..<40 {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    ctx.setFillColor(CGColor(gray: CGFloat(seed >> 56) / 255, alpha: 1))
                    ctx.fill(CGRect(x: width - 120 + i * 2, y: footer + 300 + j * 2, width: 2, height: 2))
                }
            }
        }
        return ctx.makeImage()!
    }

    /// 和会话里的拼接流程一致：每帧和上一帧比，第一次移动时认定导航栏/底栏，再记到画布上
    static func stitch(_ frames: [CGImage], limit: Int = 30_000) -> (canvas: ScrollCanvas, motions: [MotionEstimator.Motion], image: CGImage?) {
        var previous = GrayFrame(image: frames[0])
        var canvas = ScrollCanvas(frameHeight: frames[0].height, limit: limit)
        var motions: [MotionEstimator.Motion] = []
        for (index, image) in frames.enumerated().dropFirst() {
            let gray = GrayFrame(image: image)
            let motion = MotionEstimator.estimate(previous: previous, next: gray)
            motions.append(motion)
            switch motion {
            case .moved(let d):
                if !canvas.bandsKnown {
                    let bands = MotionEstimator.fixedBands(previous: previous, next: gray)
                    canvas.setBands(top: bands.top, bottom: bands.bottom)
                }
                _ = canvas.apply(d, frame: index)
                previous = gray
            case .still:
                canvas.touch(frame: index)
                previous = gray
            case .indeterminate:
                break
            }
        }
        let image = LongImageComposer.compose(canvas.finalPieces().map { (frames[$0.frame], $0.rows) })
        return (canvas, motions, image)
    }

    static func bytes(_ image: CGImage) -> [UInt8] {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    /// 期望的长图：页面从 0 到 end 这一段（不含导航栏/底栏时）
    static func expected(_ page: CGImage, end: Int) -> CGImage {
        LongImageComposer.compose([(page, 0..<end)])!
    }

    let page = Self.page()

    @Test func 往下滚各种步长都逐像素还原() throws {
        let offsets = [0, 37, 90, 151, 200, 263, 330, 401, 470, 555]
        let result = Self.stitch(offsets.map { Self.frame(page, offset: $0) })
        #expect(result.motions == zip(offsets.dropFirst(), offsets).map { .moved($0 - $1) })
        let image = try #require(result.image)
        #expect(Self.bytes(image) == Self.bytes(Self.expected(page, end: 555 + 700)))
    }

    @Test func 往回滚再往下不报错且不重复() throws {
        let offsets = [0, 120, 240, 150, 60, 180, 300, 420]
        let result = Self.stitch(offsets.map { Self.frame(page, offset: $0) })
        #expect(!result.motions.contains(.indeterminate))
        let image = try #require(result.image)
        #expect(Self.bytes(image) == Self.bytes(Self.expected(page, end: 420 + 700)))
    }

    @Test func 导航栏只保留一次底栏补在最后() throws {
        let offsets = [0, 100, 210, 330]
        let frames = offsets.map { Self.frame(page, offset: $0, header: 60, footer: 40) }
        let result = Self.stitch(frames)
        #expect(result.canvas.top == 60)
        #expect(result.canvas.bottom == 40)
        let image = try #require(result.image)
        let content = 700 - 60 - 40
        let truth = try #require(LongImageComposer.compose([(frames[0], 0..<60), (page, 0..<(330 + content)),
                                                            (frames[3], 660..<700)]))
        #expect(Self.bytes(image) == Self.bytes(truth))
    }

    @Test func 侧边栏不动和闪烁光标动画都不影响() throws {
        let offsets = [0, 80, 175, 260, 360, 445]
        let frames = offsets.enumerated().map { index, offset in
            Self.frame(page, offset: offset, sidebar: 160, blink: index % 2 == 0, noiseSeed: index)
        }
        let result = Self.stitch(frames)
        #expect(result.motions == zip(offsets.dropFirst(), offsets).map { .moved($0 - $1) })
        #expect(result.canvas.height == 700 + 445)
    }

    @Test func 只有动画和光标闪烁时算没动() {
        let a = GrayFrame(image: Self.frame(page, offset: 300, blink: true, noiseSeed: 1))
        let b = GrayFrame(image: Self.frame(page, offset: 300, blink: false, noiseSeed: 2))
        #expect(MotionEstimator.estimate(previous: a, next: b) == .still)
    }

    @Test func 大片空白看不出来() {
        let blank = Self.context(600, 700)
        blank.setFillColor(CGColor(gray: 1, alpha: 1))
        blank.fill(CGRect(x: 0, y: 0, width: 600, height: 700))
        let frame = GrayFrame(image: blank.makeImage()!)
        #expect(MotionEstimator.estimate(previous: frame, next: frame) == .indeterminate)
    }

    @Test func 到达高度上限后停止() {
        var canvas = ScrollCanvas(frameHeight: 300, limit: 600)
        canvas.setBands(top: 0, bottom: 0)
        #expect(canvas.apply(200, frame: 1) == .appended(100..<300))
        #expect(canvas.apply(200, frame: 2) == .limitReached)
        #expect(canvas.height <= 600)
    }

    @Test func 合成长图高度正确() throws {
        let a = Self.frame(page, offset: 0, width: 40, height: 6)
        let b = Self.frame(page, offset: 4, width: 40, height: 6)
        let long = try #require(LongImageComposer.compose([(a, 0..<6), (b, 4..<6)]))
        #expect(long.width == 40)
        #expect(long.height == 8)
    }

    /// 全屏大小的选区（2900×1700 像素）也要能及时算完；Debug 版比发布版慢很多，只设个宽松上限
    @Test func 大选区估计不会太慢() {
        let big = Self.page(width: 2900, height: 4000)
        let a = GrayFrame(image: Self.frame(big, offset: 0, width: 2900, height: 1700))
        let b = GrayFrame(image: Self.frame(big, offset: 90, width: 2900, height: 1700))
        let clock = ContinuousClock()
        var motion = MotionEstimator.Motion.indeterminate
        let elapsed = clock.measure { motion = MotionEstimator.estimate(previous: a, next: b) }
        #expect(motion == .moved(90))
        #expect(elapsed < .seconds(3))
    }
}
