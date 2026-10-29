import Foundation
import Testing
@testable import RestBreak

/// 截图框选的几何计算：选区、控制点、方向键、目标识别、工具栏位置、像素换算
struct CaptureGeometryTests {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    @Test func 任意方向拖动都得到正的矩形() {
        #expect(CaptureGeometry.rect(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250), in: screen)
                == CGRect(x: 100, y: 100, width: 200, height: 150))
        #expect(CaptureGeometry.rect(from: CGPoint(x: 300, y: 250), to: CGPoint(x: 100, y: 100), in: screen)
                == CGRect(x: 100, y: 100, width: 200, height: 150))
    }

    @Test func 拖出屏幕外被限制在屏幕内() {
        #expect(CaptureGeometry.rect(from: CGPoint(x: 900, y: 700), to: CGPoint(x: 1200, y: 900), in: screen)
                == CGRect(x: 900, y: 700, width: 100, height: 100))
    }

    @Test func 移动选区不会超出屏幕() {
        let r = CGRect(x: 800, y: 600, width: 150, height: 150)
        #expect(CaptureGeometry.moved(r, by: CGSize(width: 100, height: 100), in: screen)
                == CGRect(x: 850, y: 650, width: 150, height: 150))
    }

    @Test func 八个控制点命中() {
        let r = CGRect(x: 100, y: 100, width: 200, height: 100)
        #expect(CaptureGeometry.handle(at: CGPoint(x: 101, y: 99), of: r) == .topLeft)
        #expect(CaptureGeometry.handle(at: CGPoint(x: 200, y: 100), of: r) == .top)
        #expect(CaptureGeometry.handle(at: CGPoint(x: 300, y: 100), of: r) == .topRight)
        #expect(CaptureGeometry.handle(at: CGPoint(x: 300, y: 150), of: r) == .right)
        #expect(CaptureGeometry.handle(at: CGPoint(x: 302, y: 201), of: r) == .bottomRight)
        #expect(CaptureGeometry.handle(at: CGPoint(x: 200, y: 200), of: r) == .bottom)
        #expect(CaptureGeometry.handle(at: CGPoint(x: 100, y: 200), of: r) == .bottomLeft)
        #expect(CaptureGeometry.handle(at: CGPoint(x: 100, y: 150), of: r) == .left)
        #expect(CaptureGeometry.handle(at: CGPoint(x: 200, y: 150), of: r) == nil)
    }

    @Test func 拖控制点调整大小_越过对边会翻转() {
        let r = CGRect(x: 100, y: 100, width: 200, height: 100)
        #expect(CaptureGeometry.resized(r, handle: .bottomRight, to: CGPoint(x: 400, y: 260), in: screen)
                == CGRect(x: 100, y: 100, width: 300, height: 160))
        #expect(CaptureGeometry.resized(r, handle: .left, to: CGPoint(x: 350, y: 0), in: screen)
                == CGRect(x: 300, y: 100, width: 50, height: 100))
        #expect(CaptureGeometry.resized(r, handle: .top, to: CGPoint(x: 0, y: 150), in: screen)
                == CGRect(x: 100, y: 150, width: 200, height: 50))
    }

    @Test func 方向键移动和调整大小() {
        let r = CGRect(x: 100, y: 100, width: 10, height: 10)
        #expect(CaptureGeometry.nudged(r, dx: 1, dy: 0, resize: false, in: screen)
                == CGRect(x: 101, y: 100, width: 10, height: 10))
        #expect(CaptureGeometry.nudged(r, dx: 0, dy: -1, resize: false, in: screen)
                == CGRect(x: 100, y: 99, width: 10, height: 10))
        #expect(CaptureGeometry.nudged(r, dx: 1, dy: 1, resize: true, in: screen)
                == CGRect(x: 100, y: 100, width: 11, height: 11))
        let tiny = CGRect(x: 100, y: 100, width: 1, height: 1)
        #expect(CaptureGeometry.nudged(tiny, dx: -1, dy: -1, resize: true, in: screen) == tiny)   // 最小 1×1
        let edge = CGRect(x: 0, y: 0, width: 10, height: 10)
        #expect(CaptureGeometry.nudged(edge, dx: -1, dy: 0, resize: false, in: screen) == edge)  // 贴边不再移
    }

    @Test func 目标按优先级选_同级取最前面的() {
        let targets = [
            CaptureTarget(frame: CGRect(x: 0, y: 0, width: 1000, height: 33), kind: .menuBar),
            CaptureTarget(frame: CGRect(x: 900, y: 0, width: 40, height: 33), kind: .menuBarItem),
            CaptureTarget(frame: CGRect(x: 100, y: 100, width: 300, height: 300), kind: .window),   // 前
            CaptureTarget(frame: CGRect(x: 50, y: 50, width: 600, height: 600), kind: .window),     // 后
            CaptureTarget(frame: CGRect(x: 880, y: 33, width: 200, height: 300), kind: .menu),
        ]
        #expect(CaptureGeometry.target(at: CGPoint(x: 910, y: 10), in: targets)?.kind == .menuBarItem)
        #expect(CaptureGeometry.target(at: CGPoint(x: 500, y: 10), in: targets)?.kind == .menuBar)
        #expect(CaptureGeometry.target(at: CGPoint(x: 200, y: 200), in: targets)?.frame.width == 300)
        #expect(CaptureGeometry.target(at: CGPoint(x: 60, y: 60), in: targets)?.frame.width == 600)
        #expect(CaptureGeometry.target(at: CGPoint(x: 900, y: 100), in: targets)?.kind == .menu)
        #expect(CaptureGeometry.target(at: CGPoint(x: 990, y: 790), in: targets) == nil)
    }

    @Test func 工具栏优先放下方_放不下放上方_都不行放里面() {
        let bar = CGSize(width: 200, height: 40)
        let below = CaptureGeometry.toolbarOrigin(for: CGRect(x: 100, y: 100, width: 300, height: 200),
                                                  toolbar: bar, in: screen)
        #expect(below == CGPoint(x: 200, y: 308))   // 右对齐选区，下方间距 8
        let above = CaptureGeometry.toolbarOrigin(for: CGRect(x: 100, y: 600, width: 300, height: 180),
                                                  toolbar: bar, in: screen)
        #expect(above == CGPoint(x: 200, y: 552))
        let inside = CaptureGeometry.toolbarOrigin(for: screen, toolbar: bar, in: screen)
        #expect(inside == CGPoint(x: 792, y: 752))
        let leftEdge = CaptureGeometry.toolbarOrigin(for: CGRect(x: 0, y: 100, width: 50, height: 50),
                                                     toolbar: bar, in: screen)
        #expect(leftEdge.x == 8)   // 不超出屏幕左边
    }

    @Test func 点换算成像素() {
        let r = CGRect(x: 10.2, y: 20.6, width: 100.5, height: 50)
        #expect(CaptureGeometry.pixelRect(for: r, scale: 1) == CGRect(x: 10, y: 21, width: 101, height: 50))
        #expect(CaptureGeometry.pixelRect(for: CGRect(x: 10, y: 20, width: 100, height: 50), scale: 2)
                == CGRect(x: 20, y: 40, width: 200, height: 100))
        #expect(CaptureGeometry.pixelSize(for: CGRect(x: 0, y: 0, width: 640, height: 360), scale: 2) == "1280×720")
    }

    @Test func 默认文件名() throws {
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 21
        components.hour = 15; components.minute = 30; components.second = 12
        let date = try #require(Calendar.current.date(from: components))
        #expect(CaptureGeometry.defaultFileName(date: date) == "截图 2026-10-21 15.30.12.png")
    }

    @Test func 颜色值两种格式() {
        #expect(ColorFormat.rgb.text(red: 251, green: 252, blue: 250) == "251, 252, 250")
        #expect(ColorFormat.hex.text(red: 251, green: 252, blue: 250) == "#FBFCFA")
        #expect(ColorFormat.rgb.toggled == .hex && ColorFormat.hex.toggled == .rgb)
    }
}
