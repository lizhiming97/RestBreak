import AppKit
import Testing
@testable import RestBreak

/// 真实跑一次系统 OCR：把文字画成图片再识别
@MainActor
struct TextRecognizerTests {
    private func render(_ lines: [String], fontSize: CGFloat = 28) throws -> CGImage {
        let width = 900, height = 80 + lines.count * 60
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        for (i, line) in lines.enumerated() {
            NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: fontSize),
                                                          .foregroundColor: NSColor.black])
                .draw(at: NSPoint(x: 40, y: height - 80 - i * 60))
        }
        NSGraphicsContext.restoreGraphicsState()
        return try #require(rep.cgImage)
    }

    @Test func 识别中英文并保持行顺序() async throws {
        let image = try render(["休息一会儿再继续工作", "Background tasks finished"])
        let text = try await TextRecognizer.recognize(image)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines.first?.contains("休息一会儿") == true)
        #expect(lines.last?.contains("Background tasks") == true)
    }

    @Test func 没有文字的图片返回空() async throws {
        let image = try render([])
        #expect(try await TextRecognizer.recognize(image).isEmpty)
    }
}
