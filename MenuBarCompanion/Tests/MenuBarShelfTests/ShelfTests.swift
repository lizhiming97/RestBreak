// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Testing
@testable import MenuBarShelf

private func item(_ id: UInt32, x: CGFloat, width: CGFloat = 24, y: CGFloat = 0, onScreen: Bool = true,
                  title: String? = nil) -> MenuBarItem {
    MenuBarItem(windowID: id, ownerPID: 100, title: title ?? "\(id)", ownerName: "Fixture",
                bundleID: "test.fixture", frame: CGRect(x: x, y: y, width: width, height: 24), isOnScreen: onScreen)
}

/// 从右边缘向左首尾相接排出一排；`divider` 为该排中分隔符的 id。
private func lay(_ ids: [UInt32], widths: [CGFloat], endingAt right: CGFloat, y: CGFloat, divider: UInt32) -> [MenuBarItem] {
    var x = right
    return zip(ids, widths).reversed().map { id, width in
        x -= width
        return item(id, x: x, width: width, y: y, title: id == divider ? "MenuBarShelfLab.Divider" : nil)
    }.reversed()
}

struct ShelfGeometryTests {
    @Test func tahoeDragCompensatesForItemWidthInBothDirections() {
        let hidden = CGRect(x: -4000, y: 0, width: 69, height: 24)
        let visible = CGRect(x: 1124, y: 0, width: 44, height: 24)
        let right = ShelfGeometry.movePoints(item: hidden, target: visible, toLeft: true)
        #expect(right.start == CGPoint(x: 1124, y: 0))
        #expect(right.end == CGPoint(x: 1055, y: 0))
        let left = ShelfGeometry.movePoints(item: visible, target: hidden, toLeft: true)
        #expect(left.start.x == -4001)
        #expect(left.end.x == -4000)
        let after = ShelfGeometry.movePoints(item: hidden, target: visible, toLeft: false)
        #expect(after.start.x == 1168)
        #expect(after.end.x == 1099)
        var remote = item(2, x: 0)
        remote.sourceProcessID = 222
        #expect(remote.eventPID == 222)
        #expect(item(2, x: 0).eventPID == 100)
    }

    @Test func virtualWindowNumberIsRejected() {
        #expect(CGWindowID(exactly: 8_589_934_592 as Int) == nil)
    }
    @Test func reusedWindowIDCannotRedirectRestorationToAnotherApp() {
        let old = item(44, x: 0)
        let replacement = MenuBarItem(windowID: 44, ownerPID: 200, title: "44", ownerName: "Other",
                                      bundleID: "other.app", frame: .zero, isOnScreen: true)
        #expect(!ShelfGeometry.sameWindow(replacement, as: old))
        #expect(ShelfGeometry.sameWindow(item(44, x: 600), as: old))
    }

    @Test func menuPanelHangsBelowAnchorAndStaysOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let size = CGSize(width: 300, height: 400)
        let mid = ShelfGeometry.menuPanelFrame(screen: screen, menuBarHeight: 37, size: size, anchorMinX: 1000)
        #expect(mid.minX == 994)                  // 左缘与图标对齐（减去面板内边距）
        #expect(mid.maxY == CGFloat(956 - 37 - 4))         // 贴在菜单栏下方
        let edge = ShelfGeometry.menuPanelFrame(screen: screen, menuBarHeight: 37, size: size, anchorMinX: 1400)
        #expect(edge.maxX == screen.maxX - 8)     // 靠右时收进屏幕
        let dell = CGRect(x: -211, y: 956, width: 1920, height: 1080)
        let up = ShelfGeometry.menuPanelFrame(screen: dell, menuBarHeight: 24, size: size, anchorMinX: -500)
        #expect(up.minX == -203)
        #expect(up.maxY == CGFloat(956 + 1080 - 24 - 4))
    }

    @Test func menuPanelHeightCapsRowsAndAddsRestoreBanner() {
        let few = ShelfGeometry.menuPanelHeight(rows: 3, hasPendingRestore: false)
        let many = ShelfGeometry.menuPanelHeight(rows: 40, hasPendingRestore: false)
        #expect(many - few == 9 * ShelfGeometry.menuRowHeight)   // 最多显示 12 行，其余滚动
        #expect(ShelfGeometry.menuPanelHeight(rows: 3, hasPendingRestore: true) > few)
    }

    @Test func firstRunDividerSitsLeftOfEveryVisibleIcon() {
        let display = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let row = [item(1, x: 678, onScreen: false), item(2, x: 872), item(3, x: 1321, width: 151),
                   item(9, x: 900, y: -1080)]
        // 距右缘的点数：最左侧本屏图标（含被刘海挡住的）再往左 10pt。
        #expect(ShelfGeometry.leftmostPreferredPosition(items: row, display: display) == Double(1470 - 678 + 10))
        #expect(ShelfGeometry.leftmostPreferredPosition(items: [], display: display) == nil)
    }

    @Test func targetSelectionSkipsOffscreenAndNotchCoveredSlots() {
        let items = [item(1, x: 700), item(2, x: 850, onScreen: false), item(3, x: 940), item(4, x: 1000)]
        let target = ShelfGeometry.insertionTarget(items: items, width: 80, leftLimit: 900)
        #expect(target?.id == 4)
        #expect(ShelfGeometry.insertionTarget(items: items, width: 200, leftLimit: 900) == nil)
    }

    @Test func restoreAnchorPreservesOriginalNeighbour() {
        let all = [item(1, x: -80), item(2, x: -50), item(3, x: -20), item(4, x: 10)]
        #expect(ShelfGeometry.returnAnchor(for: all[1], in: all) == 3)
        #expect(ShelfGeometry.returnAnchor(for: all[3], in: all) == nil)
        #expect(ShelfGeometry.returnAnchor(for: item(9, x: 1), in: all) == nil)
    }

    @Test func failedRestoreRetriesWithBoundedBackoff() {
        let delays: [Duration?] = (0..<6).map { ShelfGeometry.restoreRetryDelay(afterFailures: $0) }
        let expected: [Duration?] = [.seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30), nil]
        #expect(delays == expected)
    }

    @Test func systemIndicatorsCannotBeMoved() {
        for title in ["Clock", "BentoBox", "AudioVideoModule", "FaceTime", "MusicRecognition"] {
            let system = MenuBarItem(windowID: 1, ownerPID: 1, title: title, ownerName: "Control Center",
                                     bundleID: "com.apple.controlcenter", frame: .zero, isOnScreen: true)
            #expect(!system.isMovable)
        }
        #expect(item(1, x: 100).isMovable)
    }
}

@MainActor
struct ShelfLifecycleTests {
    @Test func constructingAndStoppingNeverAddsStatusItemsOrHidesAnything() async {
        let controller = ShelfController()
        #expect(!controller.isEnabled)
        #expect(!controller.isCollapsed)
        #expect(!controller.hasPendingRestore)
        controller.setHidden(1, hidden: true)
        controller.showShelf()
        #expect(!controller.isEnabled)
        await controller.stop()
        await controller.stop() // 重复退出不能泄漏 monitor 或留下宽占位。
        #expect(controller.items.isEmpty)
        #expect(!controller.isBusy)
    }

    @Test func missingEventTapCompletesInsteadOfHanging() async {
        // 无效 PID，不能对真实应用投递；测试提取时修复的 continuation 永久悬挂。
        let tap = EventTap(options: .listenOnly, location: .pid(-1), place: .tailAppendEventTap,
                           types: [.null]) { _, _, _ in nil }
        var finished = false
        tap.enable(timeout: .milliseconds(30)) { tap.disable(); finished = true }
        try? await Task.sleep(for: .milliseconds(100))
        tap.disable()
        #expect(finished)
    }
}

struct DisplayChainTests {
    let builtIn = CGRect(x: 0, y: 0, width: 1470, height: 956)
    let dell = CGRect(x: -211, y: -1080, width: 1920, height: 1080) // 用户实际排列：DELL 在上方

    @Test func stackedDisplaysEachGetTheirOwnChain() {
        let a = lay([1, 2, 3, 4, 5], widths: [30, 30, 22, 30, 40], endingAt: 1472, y: 0, divider: 3)
        let b = lay([101, 102, 103, 104, 105], widths: [30, 30, 22, 30, 40], endingAt: 1709, y: -1080, divider: 103)
        let all = (a + b).shuffled()
        let dividerA = DisplayChain.copy(titled: "MenuBarShelfLab.Divider", on: builtIn, in: all)
        let dividerB = DisplayChain.copy(titled: "MenuBarShelfLab.Divider", on: dell, in: all)
        #expect(dividerA?.id == 3)
        #expect(dividerB?.id == 103)
        let chainA = DisplayChain.chain(anchoredAt: dividerA!, in: all, display: builtIn)
        let chainB = DisplayChain.chain(anchoredAt: dividerB!, in: all, display: dell)
        #expect(chainA.hidden.map(\.id) == [1, 2])
        #expect(chainA.visible.map(\.id) == [4, 5])
        #expect(chainA.ordered.map(\.id) == [1, 2, 3, 4, 5])
        #expect(chainB.hidden.map(\.id) == [101, 102])
        #expect(chainB.visible.map(\.id) == [104, 105])
    }

    @Test func sideBySideDisplaysOnSameRowDoNotMix() {
        let left = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let right = CGRect(x: 1470, y: 0, width: 1920, height: 1080)
        // 收起状态：分隔符 10000pt，收纳项被推到很远的左侧，两屏同一排。
        let a = lay([1, 2, 3, 4, 5], widths: [30, 30, 10_000, 30, 40], endingAt: 1470, y: 0, divider: 3)
        let b = lay([11, 12, 13, 14, 15], widths: [30, 30, 10_000, 30, 40], endingAt: 3390, y: 0, divider: 13)
        let all = a + b
        let dividerA = DisplayChain.copy(titled: "MenuBarShelfLab.Divider", on: left, in: all)!
        let dividerB = DisplayChain.copy(titled: "MenuBarShelfLab.Divider", on: right, in: all)!
        #expect(DisplayChain.chain(anchoredAt: dividerA, in: all, display: left).hidden.map(\.id) == [1, 2])
        #expect(DisplayChain.chain(anchoredAt: dividerB, in: all, display: right).hidden.map(\.id) == [11, 12])
        #expect(DisplayChain.chain(anchoredAt: dividerB, in: all, display: right).visible.map(\.id) == [14, 15])
    }

    @Test func chainAllowsSmallSystemSpacingButStopsAtGaps() {
        let divider = item(3, x: 100, width: 22, title: "MenuBarShelfLab.Divider")
        let near = item(2, x: 70, width: 24)       // 与分隔符相隔 6pt：系统间距，仍属本屏
        let far = item(1, x: 20, width: 24)        // 相隔 26pt：断链
        let chain = DisplayChain.chain(anchoredAt: divider, in: [far, near, divider], display: builtIn)
        #expect(chain.hidden.map(\.id) == [2])
    }

    @Test func missingDividerOnDisplayReturnsNil() {
        let a = lay([1, 2, 3], widths: [30, 22, 30], endingAt: 1472, y: 0, divider: 2)
        #expect(DisplayChain.copy(titled: "MenuBarShelfLab.Divider", on: dell, in: a) == nil)
    }

    @Test func geometricAdjacencyIgnoresOtherDisplaysCopies() {
        #expect(DisplayChain.adjacent(left: CGRect(x: 0, y: 0, width: 30, height: 24), right: CGRect(x: 30, y: 0, width: 20, height: 24)))
        #expect(DisplayChain.adjacent(left: CGRect(x: 0, y: 0, width: 30, height: 24), right: CGRect(x: 36, y: 0, width: 20, height: 24)))
        #expect(!DisplayChain.adjacent(left: CGRect(x: 0, y: 0, width: 30, height: 24), right: CGRect(x: 60, y: 0, width: 20, height: 24)))
        #expect(!DisplayChain.adjacent(left: CGRect(x: 30, y: 0, width: 20, height: 24), right: CGRect(x: 0, y: 0, width: 30, height: 24)))
        #expect(!DisplayChain.adjacent(left: CGRect(x: 0, y: 0, width: 30, height: 24), right: CGRect(x: 30, y: -1080, width: 20, height: 24)))
    }

    @Test func attributionIsSharedAcrossDisplayCopiesByPosition() {
        var a = [item(1, x: 0), item(2, x: 24)]
        let b = [item(11, x: 300), item(12, x: 324)]
        a[1].sourceProcessID = 777
        a[1].accessibilityName = "CC Switch"
        a[1].sourceBundleID = "com.ccswitch"
        let shared = DisplayChain.shareAttribution([a, b])
        #expect(shared[1][1].sourceProcessID == 777)
        #expect(shared[1][1].accessibilityName == "CC Switch")
        #expect(shared[1][1].sourceBundleID == "com.ccswitch")
        #expect(shared[1][0].sourceProcessID == nil)
        // 长度不同说明某屏链不完整，不能按位置对应。
        let uneven = DisplayChain.shareAttribution([a, [item(11, x: 300)]])
        #expect(uneven[1][0].sourceProcessID == nil)
    }

    @Test func clickableLeftLimitRespectsNotchMenuAndFallback() {
        let display = CGRect(x: -211, y: -1080, width: 1920, height: 1080)
        #expect(DisplayChain.clickableLeftLimit(display: display, menuRightEdge: 300, notchRightEdge: nil) == 308)
        #expect(DisplayChain.clickableLeftLimit(display: display, menuRightEdge: nil, notchRightEdge: nil) == display.midX)
        #expect(DisplayChain.clickableLeftLimit(display: builtIn, menuRightEdge: 400, notchRightEdge: 845) == 865)
    }

    @Test func managedDisplaySpacesParseCurrentSpacePerDisplay() {
        let data: [[String: Any]] = [
            ["Display Identifier": "Main", "Current Space": ["id64": NSNumber(value: 3), "ManagedSpaceID": NSNumber(value: 3)]],
            ["Display Identifier": "UUID-DELL", "Current Space": ["ManagedSpaceID": NSNumber(value: 9)]],
            ["Display Identifier": "Broken"],
        ]
        #expect(DisplayChain.currentSpaces(from: data) == ["Main": 3, "UUID-DELL": 9])
    }

    @Test func counterpartMapsSameIconAcrossDisplays() {
        let a = [item(1, x: 0), item(2, x: 24), item(3, x: 48)]
        let b = [item(11, x: 300), item(12, x: 324), item(13, x: 348)]
        #expect(DisplayChain.counterpart(of: 2, from: a, to: b) == 12)
        #expect(DisplayChain.counterpart(of: 2, from: a, to: a) == 2)
        #expect(DisplayChain.counterpart(of: 9, from: a, to: b) == nil)
        #expect(DisplayChain.counterpart(of: 2, from: a, to: Array(b.prefix(2))) == nil)
    }

    @Test func attributionSurvivesFailedAccessibilityQuery() {
        var known = item(5, x: 0)
        known.sourceProcessID = 42
        known.accessibilityName = "飞书"
        let fresh = item(5, x: 30)               // 本次 AX 超时，没有名称
        let merged = DisplayChain.keepingAttribution(fresh, previous: known)
        #expect(merged.accessibilityName == "飞书")
        #expect(merged.sourceProcessID == 42)
        let other = MenuBarItem(windowID: 5, ownerPID: 7, title: "x", ownerName: "Other", bundleID: "o", frame: .zero, isOnScreen: true)
        #expect(DisplayChain.keepingAttribution(other, previous: known).accessibilityName == nil) // 窗口编号被复用
    }
}

struct SnapshotTests {
    @Test func monochromeDetectionSeparatesTemplateIcons() {
        func image(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGImage {
            let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(red: r, green: g, blue: b, alpha: 1)
            context.fill(CGRect(x: 2, y: 2, width: 4, height: 4))
            return context.makeImage()!
        }
        #expect(SnapshotStore.isMonochrome(image(1, 1, 1)))
        #expect(!SnapshotStore.isMonochrome(image(0.2, 0.6, 1)))
        let trimmed = SnapshotStore.trimmed(image(1, 1, 1))
        #expect(trimmed?.width == 8 && trimmed?.height == 8)   // 4px 内容 + 各 2px 留白
    }

    @Test func primaryDisplayCopiesTitledByBundleIDStillFindDivider() {
        // macOS 26 主屏副本以 bundle ID 命名：分隔符和托盘图标同名，按宽度区分。
        let display = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let own = "com.lizhiming.MenuBarShelfLab"
        let row = [item(1, x: -4338, width: 38, title: "com.tencent.workbuddy.mac"),
                   item(2, x: -3861, width: 5016, title: own),
                   item(3, x: 1155, width: 44, title: own),
                   item(4, x: 1199, width: 38, title: "com.openai.codex")]
        #expect(DisplayChain.ownCopy(.divider, on: display, in: row, bundleID: own)?.id == 2)
        #expect(DisplayChain.ownCopy(.launcher, on: display, in: row, bundleID: own)?.id == 3)
        let expanded = [item(5, x: 600, width: 4, title: own), item(6, x: 1155, width: 44, title: own)]
        #expect(DisplayChain.ownCopy(.divider, on: display, in: expanded, bundleID: own)?.id == 5)
        let dell = CGRect(x: -211, y: -1080, width: 1920, height: 1080)
        let titled = [item(7, x: -3624, width: 5016, y: -1080, title: "MenuBarShelfLab.Divider")]
        #expect(DisplayChain.ownCopy(.divider, on: dell, in: titled, bundleID: own)?.id == 7)
        #expect(DisplayChain.isOwn(item(3, x: 0, title: own), bundleID: own))
        #expect(!DisplayChain.isOwn(item(4, x: 0, title: "com.openai.codex"), bundleID: own))
    }

    @Test func layoutKeysSurviveRestartAndDistinguishDuplicates() {
        var a = item(1, x: 0), b = item(2, x: 30), c = item(3, x: 60)
        a.sourceBundleID = "com.anthropic.claudefordesktop"
        b.sourceBundleID = "com.anthropic.claudefordesktop"
        c.sourceBundleID = nil   // 来源未识别：用窗口标题
        #expect(ShelfGeometry.layoutKeys([a, b, c]) == ["com.anthropic.claudefordesktop#0", "com.anthropic.claudefordesktop#1", "3#0"])
    }
}
