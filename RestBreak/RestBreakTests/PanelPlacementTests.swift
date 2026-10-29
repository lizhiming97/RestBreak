import Foundation
import Testing
@testable import RestBreak

/// 识别结果面板放在截图旁边：右 → 左 → 下 → 上，不出屏幕、不挡截图
struct PanelPlacementTests {
    // 左下角坐标（和 NSScreen 一致）
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let panel = CGSize(width: 440, height: 300)

    @Test func 右边放得下就放右边_顶部对齐() {
        let frame = PanelPlacement.frame(for: panel, beside: CGRect(x: 100, y: 400, width: 400, height: 300), in: screen)
        #expect(frame == CGRect(x: 512, y: 400, width: 440, height: 300))
    }

    @Test func 右边不够放左边() {
        let shot = CGRect(x: 900, y: 400, width: 400, height: 300)
        let frame = PanelPlacement.frame(for: panel, beside: shot, in: screen)
        #expect(abs(frame.maxX - 888) < 0.01)
        #expect(!frame.intersects(shot))
    }

    @Test func 左右都不够放下面() {
        let shot = CGRect(x: 300, y: 450, width: 900, height: 300)
        let frame = PanelPlacement.frame(for: panel, beside: shot, in: screen)
        #expect(abs(frame.maxY - 438) < 0.01)
        #expect(screen.contains(frame))
    }

    @Test func 下面也不够放上面() {
        let shot = CGRect(x: 300, y: 100, width: 900, height: 300)
        let frame = PanelPlacement.frame(for: panel, beside: shot, in: screen)
        #expect(abs(frame.minY - 412) < 0.01)
        #expect(screen.contains(frame))
    }

    @Test func 截图几乎占满屏幕时_放进屏幕内不出界() {
        let shot = CGRect(x: 20, y: 20, width: 1400, height: 860)
        let frame = PanelPlacement.frame(for: panel, beside: shot, in: screen)
        #expect(screen.insetBy(dx: 8, dy: 8).contains(frame))
    }

    @Test func 靠近屏幕顶部时不会顶出去() {
        let shot = CGRect(x: 100, y: 750, width: 300, height: 140)   // 贴着屏幕上边
        let frame = PanelPlacement.frame(for: panel, beside: shot, in: screen)
        #expect(frame.maxY <= screen.maxY - 8)
        #expect(frame.minX == 412)   // 还是在右边
    }
}
