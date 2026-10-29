# 截图 + 贴图（第一期）Implementation Plan

> **状态：已完成（v0.4.0，2026-10-22）。** 下面的勾选框没有逐条打勾，以本行为准；实际实现以代码和 docs/项目细节.md 为准。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在「歇一会」里加入全局快捷键截图（定格框选、窗口/菜单栏识别、放大镜、复制/保存/贴图）、贴剪贴板，以及所有快捷键的系统冲突检测。

**Architecture:** 纯逻辑（几何计算、目标识别、冲突判断）放 `Engine/`，只依赖 Foundation，单元测试覆盖；系统调用（ScreenCaptureKit、窗口列表、系统快捷键表）放 `Services/ScreenCapturer.swift`；框选界面是每屏一个 `.screenSaver` 级窗口，内容用 Core Animation 图层；`App/ScreenshotController.swift` 串起流程并管理贴图。

**Tech Stack:** Swift 6 / SwiftUI / AppKit / ScreenCaptureKit / Core Animation / Carbon（`CopySymbolicHotKeys`）/ Swift Testing。

**设计文档:** `docs/superpowers/specs/2026-10-21-screenshot-pin-design.md`

**已实测的系统事实（2026-10-21，macOS 26）:**
- 窗口层级：菜单栏 = 24（`Window Server`/`Menubar`，每块屏一个，高 33/30），菜单栏右侧图标 = 25（macOS 26 全部属于「控制中心」进程，每个图标一个窗口），弹出菜单 = 101，普通窗口 = 0。钉钉截图助手等有 layer 1100 的透明全屏窗口，**必须只认 0 / 24 / 25 / 101 和自己的贴图窗口**。
- `CopySymbolicHotKeys` 返回 230 条，每条 `kHISymbolicHotKeyCode` / `kHISymbolicHotKeyModifiers`（Carbon 修饰键：⌘0x100 ⇧0x200 ⌥0x800 ⌃0x1000，0x20000 = fn 标志位，忽略）/ `kHISymbolicHotKeyEnabled`。例：⌘⇧3 = (20, 768)，⌘Space = (49, 256)。
- 坐标：`CGWindowListCopyWindowInfo` 的 bounds 是左上角原点、以主屏左上角为 (0,0) 的全局坐标；`NSScreen.frame` 是左下角原点。换算：`cgY = 主屏高 - (appKitY + 高)`。

**约定:** 中文注释；`@MainActor` UI 类；每个任务结束 `xcodebuild` 编译通过再提交。

测试命令（下文简写为 `$TEST`）：
```bash
cd RestBreak && xcodebuild test -scheme RestBreak -destination 'platform=macOS' -quiet 2>&1 | tail -30
```
编译命令（`$BUILD`）：
```bash
cd RestBreak && xcodebuild -scheme RestBreak -configuration Debug build -quiet 2>&1 | tail -30
```

---

## 文件结构

| 文件 | 职责 |
|---|---|
| `Engine/CaptureGeometry.swift`（新） | 选区矩形、控制点、方向键、目标识别、工具栏位置、点↔像素、默认文件名 |
| `Engine/ShortcutConflicts.swift`（新） | `SystemHotKey`、内置系统快捷键表、Carbon→NSEvent 修饰键换算、冲突判断 |
| `Services/ScreenCapturer.swift`（新） | 权限、ScreenCaptureKit 截屏、读窗口目标、读系统快捷键 |
| `UI/CaptureOverlay.swift`（新） | 框选窗口 + 图层视图 + 工具栏 |
| `UI/PinWindow.swift`（新） | 贴图窗口、文字卡片、「已复制」小提示 |
| `App/ScreenshotController.swift`（新） | 流程控制、贴图管理 |
| `UI/ScreenshotPage.swift`（新） | 设置「截图」页 |
| `Engine/KeyShortcut.swift` | 新增两个 `ShortcutAction` + `isScreenshot` |
| `Engine/AppSettings.swift` | `showMagnifier`、`pinOpacity` |
| `App/BreakCoordinator.swift` | 持有 `ScreenshotController`，转发快捷键，休息开始时取消截图 |
| `UI/SettingsWindow.swift` | 侧边栏「截图」；通用组件改为 internal；快捷键卡片抽成 `ShortcutCard` 并加入冲突提示 |
| `RestBreak.entitlements` | `files.user-selected.read-write` |

---

### Task 1: 设置项和快捷键操作

**Files:**
- Modify: `RestBreak/RestBreak/Engine/KeyShortcut.swift`
- Modify: `RestBreak/RestBreak/Engine/AppSettings.swift`
- Test: `RestBreak/RestBreakTests/AppSettingsTests.swift`, `RestBreak/RestBreakTests/ShortcutTests.swift`

- [ ] **Step 1: 写失败的测试**

`AppSettingsTests.swift` 末尾加：
```swift
    @Test func 旧设置没有截图字段时用默认值() throws {
        var json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings.default)) as? [String: Any])
        json.removeValue(forKey: "showMagnifier")
        json.removeValue(forKey: "pinOpacity")
        let loaded = try JSONDecoder().decode(AppSettings.self,
                                              from: JSONSerialization.data(withJSONObject: json))
        #expect(loaded.showMagnifier)
        #expect(loaded.pinOpacity == 1.0)
    }
```
`ShortcutTests.swift` 加：
```swift
    @Test func 截图快捷键和休息快捷键分开显示() {
        #expect(ShortcutAction.allCases.filter(\.isScreenshot) == [.captureScreen, .pinClipboard])
        #expect(ShortcutAction.allCases.filter { !$0.isScreenshot } == [.startMicroBreak, .togglePause, .skipNextBreak])
    }
```

- [ ] **Step 2: 运行 `$TEST`，确认编译失败（`showMagnifier`、`captureScreen` 不存在）**

- [ ] **Step 3: 实现**

`KeyShortcut.swift` 的 `ShortcutAction`：
```swift
    case captureScreen     // 截图
    case pinClipboard      // 把剪贴板内容贴到桌面

    /// 截图相关的操作在设置「截图」页显示，其他在「快捷键」页
    var isScreenshot: Bool { self == .captureScreen || self == .pinClipboard }
```
`title`：`.captureScreen: "截图"`、`.pinClipboard: "贴剪贴板"`；`subtitle`：`.captureScreen: "框选屏幕区域，复制、保存或贴到桌面"`、`.pinClipboard: "把剪贴板里的图片或文字贴到桌面"`。

`AppSettings.swift`：属性（放在 `photoFolder` 后）
```swift
    /// 截图时在光标旁显示放大镜和颜色值
    var showMagnifier: Bool
    /// 贴图的初始透明度（0.2～1.0）
    var pinOpacity: Double
```
默认值 `showMagnifier: true, pinOpacity: 1.0`；解码：
```swift
        showMagnifier = try container.value(.showMagnifier, default: fallback.showMagnifier)
        pinOpacity = try container.value(.pinOpacity, default: fallback.pinOpacity)
```

- [ ] **Step 4: 运行 `$TEST`，全部通过**
- [ ] **Step 5: 提交** `git commit -m "截图：设置项和快捷键操作"`

---

### Task 2: CaptureGeometry（纯逻辑）

**Files:**
- Create: `RestBreak/RestBreak/Engine/CaptureGeometry.swift`
- Test: `RestBreak/RestBreakTests/CaptureGeometryTests.swift`

坐标约定：本文件所有点、矩形都是**某块屏幕内、左上角原点、单位为点**（和截图图像方向一致）。

- [ ] **Step 1: 写失败的测试**

```swift
import Foundation
import Testing
@testable import RestBreak

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
        #expect(CaptureGeometry.nudged(r, dx: 1, dy: 0, resize: false, in: screen) == CGRect(x: 101, y: 100, width: 10, height: 10))
        #expect(CaptureGeometry.nudged(r, dx: 0, dy: -1, resize: false, in: screen) == CGRect(x: 100, y: 99, width: 10, height: 10))
        #expect(CaptureGeometry.nudged(r, dx: 1, dy: 1, resize: true, in: screen) == CGRect(x: 100, y: 100, width: 11, height: 11))
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
        let below = CaptureGeometry.toolbarOrigin(for: CGRect(x: 100, y: 100, width: 300, height: 200), toolbar: bar, in: screen)
        #expect(below == CGPoint(x: 200, y: 308))   // 右对齐选区，下方间距 8
        let above = CaptureGeometry.toolbarOrigin(for: CGRect(x: 100, y: 600, width: 300, height: 180), toolbar: bar, in: screen)
        #expect(above == CGPoint(x: 200, y: 552))
        let inside = CaptureGeometry.toolbarOrigin(for: screen, toolbar: bar, in: screen)
        #expect(inside == CGPoint(x: 792, y: 752))
        let leftEdge = CaptureGeometry.toolbarOrigin(for: CGRect(x: 0, y: 100, width: 50, height: 50), toolbar: bar, in: screen)
        #expect(leftEdge.x == 8)   // 不超出屏幕左边
    }

    @Test func 点换算成像素() {
        let r = CGRect(x: 10.2, y: 20.6, width: 100.5, height: 50)
        #expect(CaptureGeometry.pixelRect(for: r, scale: 1) == CGRect(x: 10, y: 21, width: 101, height: 50))
        #expect(CaptureGeometry.pixelRect(for: CGRect(x: 10, y: 20, width: 100, height: 50), scale: 2)
                == CGRect(x: 20, y: 40, width: 200, height: 100))
        #expect(CaptureGeometry.pixelSize(for: CGRect(x: 0, y: 0, width: 640, height: 360), scale: 2) == "1280×720")
    }

    @Test func 默认文件名() {
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 21
        components.hour = 15; components.minute = 30; components.second = 12
        let date = Calendar.current.date(from: components)!
        #expect(CaptureGeometry.defaultFileName(date: date) == "截图 2026-10-21 15.30.12.png")
    }
}
```

- [ ] **Step 2: `$TEST` 确认编译失败**

- [ ] **Step 3: 实现 `CaptureGeometry.swift`**

```swift
import Foundation

/// 截图时能被「单击直接选中」的目标
struct CaptureTarget: Equatable, Sendable {
    enum Kind: Int, Sendable {
        // rawValue 越小越优先：鼠标同时在多个目标上时选优先级高的
        case menuBarItem = 0   // 菜单栏右侧的单个图标（电量、Wi-Fi、时间…）
        case menu = 1          // 展开的菜单
        case menuBar = 2       // 整条菜单栏
        case window = 3        // 普通窗口（含贴图）
    }
    /// 屏幕内坐标（左上角原点，单位：点）
    var frame: CGRect
    var kind: Kind
}

/// 选区的 8 个控制点
enum SelectionHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

/// 截图框选用到的纯数学计算。
/// 所有坐标都是「某块屏幕内、左上角原点、单位为点」，和截图图像的方向一致。
enum CaptureGeometry {
    /// 控制点的可点范围（半径）
    static let handleRadius: CGFloat = 6
    /// 工具栏和选区、屏幕边缘的间距
    static let toolbarGap: CGFloat = 8

    /// 拖动起点、终点 → 选区（任意方向都行，限制在屏幕内）
    static func rect(from start: CGPoint, to end: CGPoint, in bounds: CGRect) -> CGRect {
        let a = clamp(start, in: bounds), b = clamp(end, in: bounds)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// 整体移动选区，碰到屏幕边缘就停
    static func moved(_ rect: CGRect, by delta: CGSize, in bounds: CGRect) -> CGRect {
        var r = rect.offsetBy(dx: delta.width, dy: delta.height)
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        return r
    }

    /// 鼠标在哪个控制点上（没有则 nil）
    static func handle(at point: CGPoint, of rect: CGRect) -> SelectionHandle? {
        SelectionHandle.allCases.first { h in
            let p = position(of: h, in: rect)
            return abs(point.x - p.x) <= handleRadius && abs(point.y - p.y) <= handleRadius
        }
    }

    /// 控制点的位置
    static func position(of handle: SelectionHandle, in r: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: r.minX, y: r.minY)
        case .top: CGPoint(x: r.midX, y: r.minY)
        case .topRight: CGPoint(x: r.maxX, y: r.minY)
        case .right: CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
        case .left: CGPoint(x: r.minX, y: r.midY)
        }
    }

    /// 拖动控制点调整选区：被拖的边跟着鼠标，对边不动；越过对边时自动翻转
    static func resized(_ r: CGRect, handle: SelectionHandle, to point: CGPoint, in bounds: CGRect) -> CGRect {
        let p = clamp(point, in: bounds)
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        switch handle {
        case .topLeft: minX = p.x; minY = p.y
        case .top: minY = p.y
        case .topRight: maxX = p.x; minY = p.y
        case .right: maxX = p.x
        case .bottomRight: maxX = p.x; maxY = p.y
        case .bottom: maxY = p.y
        case .bottomLeft: minX = p.x; maxY = p.y
        case .left: minX = p.x
        }
        return rect(from: CGPoint(x: minX, y: minY), to: CGPoint(x: maxX, y: maxY), in: bounds)
    }

    /// 方向键：移动 1 点；resize 为 true 时改右边/下边，最小 1×1
    static func nudged(_ r: CGRect, dx: CGFloat, dy: CGFloat, resize: Bool, in bounds: CGRect) -> CGRect {
        guard resize else { return moved(r, by: CGSize(width: dx, height: dy), in: bounds) }
        let width = min(max(r.width + dx, 1), bounds.maxX - r.minX)
        let height = min(max(r.height + dy, 1), bounds.maxY - r.minY)
        return CGRect(x: r.minX, y: r.minY, width: width, height: height)
    }

    /// 鼠标下的目标：先按种类优先级，同一种类取列表里靠前的（列表按从前到后排列）
    static func target(at point: CGPoint, in targets: [CaptureTarget]) -> CaptureTarget? {
        targets.enumerated()
            .filter { $0.element.frame.contains(point) }
            .min { ($0.element.kind.rawValue, $0.offset) < ($1.element.kind.rawValue, $1.offset) }?
            .element
    }

    /// 工具栏左上角：优先选区下方（右对齐），放不下放上方，都放不下放进选区底部；水平方向不超出屏幕
    static func toolbarOrigin(for selection: CGRect, toolbar: CGSize, in bounds: CGRect) -> CGPoint {
        let gap = toolbarGap
        var x = selection.maxX - toolbar.width
        x = min(max(x, bounds.minX + gap), bounds.maxX - toolbar.width - gap)
        let y: CGFloat
        if selection.maxY + gap + toolbar.height <= bounds.maxY - gap {
            y = selection.maxY + gap
        } else if selection.minY - gap - toolbar.height >= bounds.minY + gap {
            y = selection.minY - gap - toolbar.height
        } else {
            y = selection.maxY - gap - toolbar.height
            x = min(max(selection.maxX - gap - toolbar.width, bounds.minX + gap), bounds.maxX - toolbar.width - gap)
        }
        return CGPoint(x: x, y: y)
    }

    /// 点 → 图像像素（取整到整像素）
    static func pixelRect(for rect: CGRect, scale: CGFloat) -> CGRect {
        let r = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                       width: rect.width * scale, height: rect.height * scale)
        let x = r.minX.rounded(), y = r.minY.rounded()
        return CGRect(x: x, y: y, width: max((r.maxX - x).rounded(), 1), height: max((r.maxY - y).rounded(), 1))
    }

    /// 选区左上角显示的尺寸文字（像素），如「1280×720」
    static func pixelSize(for rect: CGRect, scale: CGFloat) -> String {
        let p = pixelRect(for: rect, scale: scale)
        return "\(Int(p.width))×\(Int(p.height))"
    }

    /// 保存时的默认文件名：截图 2026-10-21 15.30.12.png
    static func defaultFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "截图 \(formatter.string(from: date)).png"
    }

    private static func clamp(_ p: CGPoint, in b: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, b.minX), b.maxX), y: min(max(p.y, b.minY), b.maxY))
    }
}
```

注意 `toolbarOrigin` 测试中 `inside` 情况：选区 = 整屏，x = 1000-8-200 = 792，y = 800-8-40 = 752。`below`：x = 400-200 = 200，y = 300+8 = 308。`above`：选区底 780+8+40 > 792 → 上方 y = 600-8-40 = 552。

- [ ] **Step 4: `$TEST` 全部通过**
- [ ] **Step 5: 提交** `git commit -m "截图：选区几何计算和目标识别"`

---

### Task 3: 系统快捷键冲突（纯逻辑 + 读取系统表）

**Files:**
- Create: `RestBreak/RestBreak/Engine/ShortcutConflicts.swift`
- Create: `RestBreak/RestBreak/Services/ScreenCapturer.swift`（本任务只写 `SystemHotKeys` 部分）
- Test: `RestBreak/RestBreakTests/ShortcutConflictTests.swift`

- [ ] **Step 1: 写失败的测试**

```swift
import AppKit
import Testing
@testable import RestBreak

@MainActor
struct ShortcutConflictTests {
    let command = KeyShortcut.commandFlag, shift = KeyShortcut.shiftFlag
    let control = KeyShortcut.controlFlag, option = KeyShortcut.optionFlag

    @Test func Carbon修饰键换算_忽略fn() {
        #expect(ShortcutConflicts.eventModifiers(fromCarbon: 768) == command | shift)
        #expect(ShortcutConflicts.eventModifiers(fromCarbon: 0x20000 | 0x1000) == control)
        #expect(ShortcutConflicts.eventModifiers(fromCarbon: 0x800 | 0x100) == option | command)
    }

    @Test func 内置表能认出系统截屏() {
        let shortcut = KeyShortcut(keyCode: 21, modifiers: command | shift, keyName: "4")
        #expect(ShortcutConflicts.conflict(for: shortcut, systemHotKeys: nil) == "将所选区域截屏")
    }

    @Test func 不同组合或不同修饰键不冲突() {
        #expect(ShortcutConflicts.conflict(for: KeyShortcut(keyCode: 0, modifiers: control | option, keyName: "A"),
                                           systemHotKeys: nil) == nil)
        #expect(ShortcutConflicts.conflict(for: KeyShortcut(keyCode: 21, modifiers: command | option, keyName: "4"),
                                           systemHotKeys: nil) == nil)
    }

    @Test func 系统里关掉的快捷键不算冲突() {
        let off = SystemHotKey(keyCode: 21, modifiers: command | shift, isEnabled: false)
        let shortcut = KeyShortcut(keyCode: 21, modifiers: command | shift, keyName: "4")
        #expect(ShortcutConflicts.conflict(for: shortcut, systemHotKeys: [off]) == nil)
    }

    @Test func 本机表里启用的快捷键_没有中文名时叫系统快捷键() {
        let on = SystemHotKey(keyCode: 7, modifiers: control | option | command, isEnabled: true)
        let shortcut = KeyShortcut(keyCode: 7, modifiers: control | option | command, keyName: "X")
        #expect(ShortcutConflicts.conflict(for: shortcut, systemHotKeys: [on]) == "系统快捷键")
    }

    @Test func 常用App快捷键总是算冲突() {
        let copy = KeyShortcut(keyCode: 8, modifiers: command, keyName: "C")
        #expect(ShortcutConflicts.conflict(for: copy, systemHotKeys: []) == "拷贝")
    }

    @Test func 沙盒里能读到本机系统快捷键() throws {
        let keys = try #require(SystemHotKeys.current())
        #expect(!keys.isEmpty)
    }
}
```

- [ ] **Step 2: `$TEST` 确认编译失败**

- [ ] **Step 3: 实现 `Engine/ShortcutConflicts.swift`**

```swift
import Foundation

/// 一个系统级快捷键（修饰键用 NSEvent 的数值，和 KeyShortcut 一致）
struct SystemHotKey: Equatable, Sendable {
    var keyCode: UInt16
    var modifiers: UInt
    var isEnabled: Bool
}

/// 判断用户录的快捷键是否和系统快捷键冲突
enum ShortcutConflicts {
    private struct Named {
        let keyCode: UInt16
        let modifiers: UInt
        let name: String
    }

    private static let cmd = KeyShortcut.commandFlag, sft = KeyShortcut.shiftFlag
    private static let ctl = KeyShortcut.controlFlag, opt = KeyShortcut.optionFlag

    /// macOS 默认的系统快捷键（读不到本机设置时兜底，也用来给本机设置起中文名）
    private static let system: [Named] = [
        Named(keyCode: 20, modifiers: cmd | sft, name: "将屏幕截屏"),
        Named(keyCode: 20, modifiers: ctl | cmd | sft, name: "将屏幕截屏拷贝到剪贴板"),
        Named(keyCode: 21, modifiers: cmd | sft, name: "将所选区域截屏"),
        Named(keyCode: 21, modifiers: ctl | cmd | sft, name: "将所选区域截屏拷贝到剪贴板"),
        Named(keyCode: 23, modifiers: cmd | sft, name: "截屏和录制选项"),
        Named(keyCode: 49, modifiers: cmd, name: "显示「聚焦」搜索"),
        Named(keyCode: 49, modifiers: opt | cmd, name: "显示「访达」搜索窗口"),
        Named(keyCode: 49, modifiers: ctl, name: "选择上一个输入法"),
        Named(keyCode: 49, modifiers: ctl | opt, name: "选择输入菜单中的下一个输入法"),
        Named(keyCode: 49, modifiers: ctl | cmd, name: "表情与符号"),
        Named(keyCode: 48, modifiers: cmd, name: "切换 App"),
        Named(keyCode: 48, modifiers: cmd | sft, name: "切换 App"),
        Named(keyCode: 50, modifiers: cmd, name: "切换同一 App 的窗口"),
        Named(keyCode: 126, modifiers: ctl, name: "调度中心"),
        Named(keyCode: 125, modifiers: ctl, name: "应用程序窗口"),
        Named(keyCode: 123, modifiers: ctl, name: "向左移动一个空间"),
        Named(keyCode: 124, modifiers: ctl, name: "向右移动一个空间"),
        Named(keyCode: 12, modifiers: ctl | cmd, name: "锁定屏幕"),
        Named(keyCode: 2, modifiers: opt | cmd, name: "隐藏/显示程序坞"),
        Named(keyCode: 53, modifiers: opt | cmd, name: "强制退出"),
        Named(keyCode: 120, modifiers: ctl, name: "将焦点移到菜单栏"),
        Named(keyCode: 99, modifiers: ctl, name: "将焦点移到程序坞"),
        Named(keyCode: 103, modifiers: 0, name: "显示桌面"),
    ]

    /// 几乎所有 App 都在用的菜单快捷键：全局快捷键会抢走它们，总是算冲突
    private static let common: [Named] = [
        Named(keyCode: 8, modifiers: cmd, name: "拷贝"),
        Named(keyCode: 9, modifiers: cmd, name: "粘贴"),
        Named(keyCode: 7, modifiers: cmd, name: "剪切"),
        Named(keyCode: 0, modifiers: cmd, name: "全选"),
        Named(keyCode: 6, modifiers: cmd, name: "撤销"),
        Named(keyCode: 6, modifiers: cmd | sft, name: "重做"),
        Named(keyCode: 1, modifiers: cmd, name: "存储"),
        Named(keyCode: 45, modifiers: cmd, name: "新建"),
        Named(keyCode: 31, modifiers: cmd, name: "打开"),
        Named(keyCode: 35, modifiers: cmd, name: "打印"),
        Named(keyCode: 3, modifiers: cmd, name: "查找"),
        Named(keyCode: 13, modifiers: cmd, name: "关闭窗口"),
        Named(keyCode: 12, modifiers: cmd, name: "退出 App"),
        Named(keyCode: 4, modifiers: cmd, name: "隐藏 App"),
        Named(keyCode: 46, modifiers: cmd, name: "最小化"),
        Named(keyCode: 17, modifiers: cmd, name: "新建标签页"),
        Named(keyCode: 43, modifiers: cmd, name: "偏好设置"),
        Named(keyCode: 3, modifiers: ctl | cmd, name: "进入全屏幕"),
    ]

    /// 冲突时返回冲突功能的中文名，不冲突返回 nil。
    /// systemHotKeys 为本机实际的系统快捷键表；传 nil 表示读不到，用内置表兜底。
    static func conflict(for shortcut: KeyShortcut, systemHotKeys: [SystemHotKey]?) -> String? {
        let mods = shortcut.modifiers & KeyShortcut.allModifierFlags
        func matches(_ code: UInt16, _ m: UInt) -> Bool { code == shortcut.keyCode && m == mods }

        if let hit = common.first(where: { matches($0.keyCode, $0.modifiers) }) { return hit.name }
        if let systemHotKeys {
            guard systemHotKeys.contains(where: { $0.isEnabled && matches($0.keyCode, $0.modifiers) }) else { return nil }
            return system.first { matches($0.keyCode, $0.modifiers) }?.name ?? "系统快捷键"
        }
        return system.first { matches($0.keyCode, $0.modifiers) }?.name
    }

    /// Carbon 的修饰键数值 → NSEvent 的修饰键数值（忽略 fn、大写锁定等）
    static func eventModifiers(fromCarbon carbon: UInt) -> UInt {
        var result: UInt = 0
        if carbon & 0x100 != 0 { result |= cmd }
        if carbon & 0x200 != 0 { result |= sft }
        if carbon & 0x800 != 0 { result |= opt }
        if carbon & 0x1000 != 0 { result |= ctl }
        return result
    }
}
```

`Services/ScreenCapturer.swift` 先只放：
```swift
import AppKit
import Carbon.HIToolbox

/// 读取本机的系统快捷键表（系统设置 › 键盘 › 键盘快捷键 里的那些）
enum SystemHotKeys {
    /// 读不到时返回 nil（调用方用内置表兜底）
    static func current() -> [SystemHotKey]? {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let array = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return nil }
        return array.compactMap { entry in
            guard let code = (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.intValue,
                  code >= 0, code < 0xFFFF,   // 0xFFFF 表示按字符而不是按键，忽略
                  let carbon = (entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uintValue
            else { return nil }
            let enabled = (entry[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue ?? false
            return SystemHotKey(keyCode: UInt16(code),
                                modifiers: ShortcutConflicts.eventModifiers(fromCarbon: carbon),
                                isEnabled: enabled)
        }
    }
}
```

- [ ] **Step 4: `$TEST` 全部通过（重点看「沙盒里能读到本机系统快捷键」；如果失败，`SystemHotKeys.current()` 在沙盒内返回 nil，冲突判断走内置表，把该测试改成只断言不崩溃，并在 CLAUDE.md 记录）**
- [ ] **Step 5: 提交** `git commit -m "快捷键：检测与系统快捷键冲突"`

---

### Task 4: 设置窗口：组件公开、快捷键卡片抽取、冲突提示、「截图」页

**Files:**
- Modify: `RestBreak/RestBreak/UI/SettingsWindow.swift`
- Create: `RestBreak/RestBreak/UI/ScreenshotPage.swift`

- [ ] **Step 1:** `SettingsWindow.swift` 里这些类型去掉 `private`（改为默认 internal），供 `ScreenshotPage.swift` 使用：`Theme`→ 改名 `SettingsTheme` 后 internal（避免与其他模块重名，文件内用到 `Theme.` 的地方全部替换），`Card`、`CardHeader`、`SettingRow`、`RowDivider`、`TimeUnit`、`ValueSlider`、`SmoothSlider`、`BlueSwitchStyle`、`BlueSwitch`、`PillButtonStyle`、`ShortcutField`、`ShortcutRecorder`、`View.cardBackground()`、`View.blueSwitch()`。
- [ ] **Step 2:** `SettingsPage` 加 `case screenshot = "截图"`（位于 `appearance` 和 `shortcuts` 之间），symbol `camera.viewfinder`，`switch page` 加 `case .screenshot: ScreenshotPage()`。
- [ ] **Step 3:** 把 `ShortcutsPage` 里的卡片抽成：
```swift
/// 一组快捷键录制行（「快捷键」页和「截图」页共用）
struct ShortcutCard: View {
    let title: String
    let actions: [ShortcutAction]
    @ObservedObject var recorder: ShortcutRecorder
    @EnvironmentObject private var coordinator: BreakCoordinator
    // body：CardHeader(title) + 每个 action 一行 SettingRow（内容同原来）；
    // 若 recorder.pending?.action == action，在该行下方加一行冲突提示：
    //   HStack { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
    //            Text("与系统「\(name)」冲突，按下时只会触发系统功能")  font 11, orange
    //            Spacer()
    //            Button("仍然使用") { recorder.acceptPending() }.buttonStyle(PillButtonStyle())
    //            Button("重新录制") { recorder.discardPending() }.buttonStyle(PillButtonStyle()) }
    //   .padding(.horizontal, SettingsTheme.cardPadding).padding(.bottom, 12)
    // 原注册失败文案改为「已被其他 App 占用，请换一个」
}
```
`ShortcutsPage` 改为 `ShortcutCard(title: "全局快捷键", actions: ShortcutAction.allCases.filter { !$0.isScreenshot }, recorder: recorder)`。
`ShortcutField` 增加参数 `pending: KeyShortcut?`：录制中且有 pending 时显示 `pending.display`，文字橙色。

- [ ] **Step 4:** `ShortcutRecorder` 增加：
```swift
    /// 录到的组合和系统快捷键冲突，等用户选「仍然使用」或「重新录制」
    struct Pending: Equatable {
        let action: ShortcutAction
        let shortcut: KeyShortcut
        let conflictName: String
    }
    @Published private(set) var pending: Pending?
```
`handle(_:)` 在生成 `shortcut` 后：
```swift
        if let name = ShortcutConflicts.conflict(for: shortcut, systemHotKeys: SystemHotKeys.current()) {
            pending = Pending(action: action, shortcut: shortcut, conflictName: name)
            NSSound.beep()
            return   // 保持录制状态，可以直接按别的组合
        }
        save(shortcut, for: action)
```
把原来「同一组合只给一个操作 + stop + 写设置」提成 `private func save(_:for:)`。新增：
```swift
    func acceptPending() { guard let p = pending else { return }; save(p.shortcut, for: p.action) }
    func discardPending() { pending = nil }
```
`stop()` 里清空 `pending`；`toggle` 开始新录制时也清空。

- [ ] **Step 5:** 创建 `UI/ScreenshotPage.swift`：
```swift
import SwiftUI

/// 设置窗口「截图」页：录屏权限、截图快捷键、截图选项
struct ScreenshotPage: View {
    @EnvironmentObject private var coordinator: BreakCoordinator
    @StateObject private var recorder = ShortcutRecorder()
    @State private var hasPermission = ScreenCapturer.hasPermission

    var body: some View {
        Card {
            SettingRow(title: "录屏权限",
                       subtitle: hasPermission ? "已允许，可以截图" : "截图需要在「系统设置 › 隐私与安全性 › 录屏与系统录音」里允许「歇一会」",
                       subtitleColor: hasPermission ? nil : .orange) {
                HStack(spacing: 8) {
                    Circle().fill(hasPermission ? Color.green : Color.orange).frame(width: 8, height: 8)
                    Text(hasPermission ? "已允许" : "未允许").font(.system(size: 13, weight: .medium))
                    Button("打开系统设置") { ScreenCapturer.openPrivacySettings() }
                        .buttonStyle(PillButtonStyle())
                }
            }
        }
        ShortcutCard(title: "快捷键", actions: ShortcutAction.allCases.filter(\.isScreenshot), recorder: recorder)
        Card {
            CardHeader(title: "选项")
            SettingRow(title: "截图时显示放大镜", subtitle: "光标旁显示放大的像素、坐标和颜色值，按 C 复制颜色") {
                Toggle("", isOn: $coordinator.settings.showMagnifier).blueSwitch()
            }
            RowDivider()
            SettingRow(title: "贴图默认透明度", subtitle: "贴到桌面时的初始透明度，贴图上按住 ⌥ 滚动滚轮可调") {
                ValueSlider(value: Binding(get: { (coordinator.settings.pinOpacity * 10).rounded() },
                                           set: { coordinator.settings.pinOpacity = $0 / 10 }),
                            range: 2...10, unit: .percentTens)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            hasPermission = ScreenCapturer.hasPermission
        }
        .onDisappear { recorder.stop() }
    }
}
```
`TimeUnit` 加 `case percentTens`，`label` 返回 `"\(value * 10)%"`（`seconds` 属性对它返回 1）。

- [ ] **Step 6:** 在 `ScreenCapturer.swift` 加（Task 5 会继续扩充）：
```swift
/// 截屏相关的系统功能
enum ScreenCapturer {
    /// 是否已有录屏权限（不会弹窗）
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// 打开「系统设置 › 隐私与安全性 › 录屏与系统录音」
    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
```
- [ ] **Step 7: `$BUILD` 通过，`$TEST` 全部通过**
- [ ] **Step 8: 提交** `git commit -m "设置：新增「截图」页，快捷键录制提示系统冲突"`

---

### Task 5: ScreenCapturer：截屏和目标读取

**Files:**
- Modify: `RestBreak/RestBreak/Services/ScreenCapturer.swift`
- Modify: `RestBreak/RestBreak/RestBreak.entitlements`

- [ ] **Step 1:** entitlements 中 `com.apple.security.files.user-selected.read-only` 改为 `com.apple.security.files.user-selected.read-write`（读写权限包含只读，照片文件夹不受影响）。

- [ ] **Step 2:** 在 `ScreenCapturer` 里加：
```swift
/// 一块屏幕的定格画面
struct ScreenSnapshot {
    let screen: NSScreen
    /// 整块屏幕的图像（像素）
    let image: CGImage
    /// 像素 / 点
    var scale: CGFloat { CGFloat(image.width) / screen.frame.width }
    /// 这块屏幕上能单击选中的目标（屏幕内坐标，左上角原点）
    var targets: [CaptureTarget]
}
```
- `static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }`
- `static func captureAllScreens() async throws -> [ScreenSnapshot]`：
  1. `let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)`
  2. 对 `NSScreen.screens` 每块屏，用 `screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID` 找到 `content.displays` 中 `displayID` 相同的 `SCDisplay`。
  3. `SCContentFilter(display: display, excludingWindows: [])`；`SCStreamConfiguration`：`width = Int(screen.frame.width * screen.backingScaleFactor)`，`height` 同理，`showsCursor = false`，`captureResolution = .best`，`colorSpaceName = CGColorSpace.sRGB`。
  4. 所有屏幕用 `withThrowingTaskGroup` 并行 `SCScreenshotManager.captureImage(contentFilter:configuration:)`。
  5. 目标 `targets(for: screen)`（见下）在截图之前同步读取一次，保证与定格画面一致。
- `static func targets(for screen: NSScreen) -> [CaptureTarget]`：`CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)`，按顺序遍历（从前到后）：
  - layer 25 → `.menuBarItem`；layer 24 → `.menuBar`；layer 101 → `.menu`；layer 0 → `.window`；owner PID == 自己 且 layer == `NSWindow.Level.floating.rawValue` → `.window`（贴图）；其他层全部跳过。
  - `kCGWindowAlpha` 为 0 的跳过；宽或高 < 4 的跳过。
  - bounds（全局左上角原点）换成该屏幕内左上角坐标：`screenTopLeftGlobal = CGPoint(x: screen.frame.minX, y: mainHeight - screen.frame.maxY)`，`local = bounds.offsetBy(dx: -screenTopLeftGlobal.x, dy: -screenTopLeftGlobal.y)`；与 `CGRect(origin: .zero, size: screen.frame.size)` 求交集，空的跳过。`mainHeight = NSScreen.screens.first!.frame.height`（主屏是 screens[0]）。
- `static func color(at point: CGPoint, in snapshot: ScreenSnapshot) -> (r: Int, g: Int, b: Int)?`：像素坐标 = point × scale 取整；`image.cropping(to: 1×1)` 画进 1×1 sRGB RGBA 上下文读值。

- [ ] **Step 3: `$BUILD` 通过**
- [ ] **Step 4: 提交** `git commit -m "截图：ScreenCaptureKit 截屏和窗口/菜单栏目标读取"`

---

### Task 6: 框选界面 CaptureOverlay

**Files:**
- Create: `RestBreak/RestBreak/UI/CaptureOverlay.swift`

结构：
- `final class CaptureWindow: NSWindow`：同 `BreakOverlayWindow` 的样式（borderless、`.screenSaver`、`[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`、透明、无阴影、`canBecomeKey` true）。
- `enum CaptureAction { case copy, save, pin, cancel }`
- `@MainActor final class CaptureOverlayController`：
  - `init()` 时为每块屏幕创建 `CaptureWindow` + `CaptureView`（预热，隐藏）；监听 `didChangeScreenParametersNotification`：显示中则调用 `onAbort`，然后重建窗口。
  - `func show(_ snapshots: [ScreenSnapshot], showMagnifier: Bool, onAction: @escaping (CaptureAction, CGImage?, NSScreen, CGRect) -> Void)`：把快照交给对应屏幕的 view（`view.load(snapshot)`），全部 `orderFrontRegardless()`，`NSApp.activate()`，鼠标所在屏的窗口 `makeKey()`。
  - `func hide()`、`func temporarilyHide()` / `func restore()`（保存框期间用）。
  - 多屏协作：同一时间只有一个屏幕可以有选区。某个 view 开始拖动时通知 controller，其他 view 清除选区和悬停高亮。
- `final class CaptureView: NSView`（**不翻转**，内部用 `toGeo`/`toView` 在 AppKit 左下角坐标与 CaptureGeometry 左上角坐标之间换算：`y' = bounds.height - y`，矩形 `y' = bounds.height - r.maxY`）：
  - `wantsLayer = true`；子图层：
    1. `imageLayer`：`contents = snapshot.image`，`frame = bounds`，`contentsGravity = .resize`。
    2. `dimLayer: CAShapeLayer`：`fillRule = .evenOdd`，`fillColor = NSColor.black.withAlphaComponent(0.4).cgColor`，路径 = 整屏矩形 + 当前高亮/选区矩形（镂空）。
    3. `borderLayer: CAShapeLayer`：蓝色 `#3D7BF7` 1.5pt 描边；选区确定后加 8 个白底蓝边 7×7 圆点控制点（`handlesLayer`）。
    4. `sizeLabel: CATextLayer`：选区左上角上方（放不下放内部），黑色 70% 圆角底，白色 11pt 等宽数字，内容 `CaptureGeometry.pixelSize`。
    5. `magnifier`（`showMagnifier` 时）：容器 128×150，圆角 10、白边 1、阴影；内含 `zoomLayer`（128×128，`contents = image`，`magnificationFilter = .nearest`，`contentsRect` = 以光标像素为中心 16×16 像素的单位矩形）、`gridLayer`（每 8pt 一条 0.5pt 白 20% 线，中心格蓝框）、`infoLayer`（坐标 `x, y` 和 `#RRGGBB`）。位置：光标右下 20pt，超出屏幕时翻到左/上。
  - 全部图层属性更新包在 `CATransaction.setDisableActions(true)` 里，避免隐式动画拖影。
  - 状态机：`enum Phase { case hovering(CaptureTarget?), dragging(start: CGPoint), selected(CGRect), moving(CGRect, from: CGPoint), resizing(CGRect, SelectionHandle) }`。
  - 鼠标：
    - `mouseMoved`（`NSTrackingArea` `.mouseMoved, .activeAlways, .inVisibleRect`）：hovering 时 `CaptureGeometry.target(at:in:)` 更新高亮；更新放大镜；selected 时按位置设置光标（控制点：macOS 15+ `NSCursor.frameResize(position:directions: .all)`，14 用 `resizeLeftRight`/`resizeUpDown`，角点用 `crosshair`；选区内 `openHand`；其余 `crosshair`）。
    - `mouseDown`：hovering → 记录起点进入 `dragging`；selected → 控制点则 `resizing`，选区内则 `moving`，选区外则重新 `dragging`。
    - `mouseDragged`：dragging 时 `CaptureGeometry.rect(from:to:in:)`（位移 < 3pt 视为没拖）；moving / resizing 分别用 `moved` / `resized`。
    - `mouseUp`：dragging 且没拖动 → 有高亮目标就 `selected(target.frame)`，否则保持 hovering；拖动了 → `selected(rect)`（宽或高 < 2 则回到 hovering）。
    - `rightMouseDown`：selected → 回到 hovering；hovering → `onAction(.cancel)`。
  - 键盘（`keyDown`，`acceptsFirstResponder` true）：`Esc`（53）selected→hovering，hovering→cancel；`Enter`（36/76）、`⌘C` → copy；`Space`（49）→ pin；`⌘S` → save；方向键 123–126 → `nudged`（按住 ⇧ 为 resize）；`C`（8，无修饰键）且有放大镜 → 把当前颜色 `#RRGGBB` 写入剪贴板并在 info 里显示「已复制」。
  - 工具栏：`NSHostingView(rootView: CaptureToolbar(onAction:))`，只在 selected 时显示，位置 `CaptureGeometry.toolbarOrigin`；moving / resizing 时隐藏、松手再出现。
  - 结果：`func croppedImage() -> CGImage?` = `snapshot.image.cropping(to: CaptureGeometry.pixelRect(for: selection, scale: snapshot.scale))`。
- `struct CaptureToolbar: View`：4 个 32×32 图标按钮（`pin`、`square.and.arrow.down`、`xmark`、`checkmark`），`help` 文字「贴到桌面 (Space)」「保存 (⌘S)」「取消 (Esc)」「复制 (Enter)」；`checkmark` 用蓝色强调。背景：
```swift
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        }
```
  按钮悬停时圆形浅色底（`onHover`）。

- [ ] **Step 1:** 按上面写 `CaptureOverlay.swift`
- [ ] **Step 2: `$BUILD` 通过**
- [ ] **Step 3: 提交** `git commit -m "截图：定格框选界面（图层绘制、窗口识别、放大镜、工具栏）"`

---

### Task 7: 贴图窗口 PinWindow

**Files:**
- Create: `RestBreak/RestBreak/UI/PinWindow.swift`

- `final class PinWindow: NSPanel`：`styleMask [.borderless, .nonactivatingPanel]`，`level = .floating`，`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`，`isOpaque = false`，`backgroundColor = .clear`，`hasShadow = true`，`isMovableByWindowBackground = true`，`isReleasedWhenClosed = false`，`canBecomeKey` true。
  - `init(image: CGImage, frame: NSRect, opacity: Double, onClose: @escaping (PinWindow) -> Void)`；`contentView = PinView`（`wantsLayer`，`layer.contents = image`，`contentsGravity = .resize`，`cornerRadius = 6`，`masksToBounds = true`，`borderWidth 0.5` 黑 10%）。
  - `PinView` 事件：双击（`clickCount == 2`）关闭；`Esc` 关闭；`⌘C` 复制；`scrollWheel` 且按住 ⌥：`alphaValue` ± 0.05（`event.scrollingDeltaY` 方向），限制 0.2～1.0，右下角短暂显示百分比（`CATextLayer`，1 秒后淡出）；`menu(for:)` 返回右键菜单：复制 / 保存… / 透明度 ▸（100%/80%/60%/40%，当前项打勾）/ 分隔 / 关闭 / 关闭所有贴图。
  - 窗口移动后（`NSWindow.didMoveNotification`）保证至少 40pt 留在某块屏幕的 `visibleFrame` 内，否则拉回。
- `enum PinFrame { static func fitted(size: CGSize, origin: CGPoint, on screen: NSScreen) -> NSRect }`：尺寸超出屏幕 `visibleFrame` 80% 时等比缩小，再整体挪进屏幕内。
- `enum TextCard { static func render(_ text: String, scale: CGFloat) -> CGImage? }`：最长 2000 字（超出截断加「…」），`NSAttributedString` 13pt 系统字体、深色 `#1C1C1E`，白底，内边距 14，最大宽 480pt，最大高 600pt（`boundingRect` 计算，超出用 `.truncatesLastVisibleLine` 绘制），按 `scale` 渲染成位图。
- `@MainActor enum Toast { static func show(_ text: String, at point: NSPoint) }`：无边框 `.screenSaver + 1` 级小面板，胶囊形 `.ultraThinMaterial` / macOS 26 `glassEffect`，内容 `checkmark.circle.fill` + 文字，0.15 秒淡入、停 1 秒、0.3 秒淡出后关闭，鼠标穿透（`ignoresMouseEvents = true`）。

- [ ] **Step 1:** 写 `PinWindow.swift`
- [ ] **Step 2: `$BUILD` 通过**
- [ ] **Step 3: 提交** `git commit -m "贴图：置顶贴图窗口、透明度、右键菜单、文字卡片、已复制提示"`

---

### Task 8: ScreenshotController + 接入 BreakCoordinator

**Files:**
- Create: `RestBreak/RestBreak/App/ScreenshotController.swift`
- Modify: `RestBreak/RestBreak/App/BreakCoordinator.swift`

`@MainActor final class ScreenshotController`：
- 属性：`overlay = CaptureOverlayController()`（在 init 里创建，即预热）、`pins: [PinWindow]`、`isCapturing`、`previousApp: NSRunningApplication?`。
- `func startCapture(settings: AppSettings)`：
  1. `guard !isCapturing`。
  2. 没权限：若 `UserDefaults` `didRequestScreenCapture` 为 false → 设为 true 并 `ScreenCapturer.requestPermission()`；否则 `showPermissionAlert()`。返回。
  3. 记录 `previousApp`（前台 App 不是自己时）；`isCapturing = true`。
  4. `Task { do { let snaps = try await ScreenCapturer.captureAllScreens(); guard isCapturing else { return }; overlay.show(snaps, showMagnifier: settings.showMagnifier) { ... } } catch { isCapturing = false; NSSound.beep(); Toast.show("截图失败", at: 鼠标位置) } }`
- 动作处理：
  - `.copy`：写剪贴板（`NSImage(cgImage:size: 选区点尺寸)`，`NSPasteboard.general.clearContents(); writeObjects([image])`）→ `finish()` → `Toast.show("已复制", at: 选区中心的全局 AppKit 坐标)`。
  - `.pin`：`finish()` → `pin(image, frame: 选区在全局 AppKit 坐标中的矩形, screen)`。
  - `.save`：`overlay.temporarilyHide()`；`NSSavePanel`：`allowedContentTypes = [.png]`，`nameFieldStringValue = CaptureGeometry.defaultFileName()`，`canCreateDirectories = true`，`level` 默认；`begin { response in ... }`：OK → 写 PNG（`NSBitmapImageRep(cgImage:)`，`size` 设为点尺寸，`representation(using: .png)`），成功 `finish()`，失败 `NSAlert(error:).runModal()` 然后 `overlay.restore()`；取消 → `overlay.restore()`。
  - `.cancel`：`finish()`。
- `func finish()`：`overlay.hide()`；`isCapturing = false`；`previousApp?.activate()`；`previousApp = nil`。
- `func cancel()`：正在截图时调用 `finish()`（休息开始、显示器变化时用）；保存框打开时也一并关闭（`NSApp.abortModal` 不适用于 sheet-less `begin`，用保存面板引用 `cancel(nil)`）。
- `func pinClipboard(settings: AppSettings)`：
  - `NSImage(pasteboard: .general)` → `cgImage(forProposedRect:context:hints:)`，尺寸用 `NSImage.size`（点）；否则 `string(forType: .string)` 非空 → `TextCard.render(text, scale: 鼠标所在屏 backingScaleFactor)`，尺寸 = 像素 / scale；都没有 → `NSSound.beep()`。
  - 位置：鼠标位置为中心，`PinFrame.fitted`。
- `func pin(_ image: CGImage, frame: NSRect, opacity: Double)`：创建 `PinWindow`，`orderFrontRegardless()`，加入 `pins`；`onClose` 从数组移除。
- `func closeAllPins()`。
- `showPermissionAlert()`：`NSAlert`，标题「需要录屏权限」，正文「请在「系统设置 › 隐私与安全性 › 录屏与系统录音」里打开「歇一会」。打开后需要重新打开歇一会才能生效。」按钮：「打开系统设置」「重新打开歇一会」「取消」。重新打开：`NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: { let c = NSWorkspace.OpenConfiguration(); c.createsNewApplicationInstance = true; return c }())` 完成后 `NSApp.terminate(nil)`。弹窗前 `NSApp.activate()`。

`BreakCoordinator`：
- `let screenshots = ScreenshotController()`
- `performShortcut` 加：
```swift
        case .captureScreen:
            // 休息中（含预览）不截图
            if case .onBreak = scheduler.state { return }
            if isPreviewing { return }
            screenshots.startCapture(settings: settings)
        case .pinClipboard:
            screenshots.pinClipboard(settings: settings)
```
- `showOverlay(for:)` 和 `previewOverlay()` 开头调用 `screenshots.cancel()`。

- [ ] **Step 1:** 写 `ScreenshotController.swift`，改 `BreakCoordinator.swift`
- [ ] **Step 2: `$BUILD` 通过，`$TEST` 全部通过**
- [ ] **Step 3: 提交** `git commit -m "截图：流程控制、贴剪贴板，接入全局快捷键"`

---

### Task 9: 验证和收尾

- [ ] **Step 1:** 离屏渲染检查：写一个临时测试，用纯色渐变假图构造 `ScreenSnapshot`（需可注入 `NSScreen.main`），创建 `CaptureView`，设置选区，`view.layer?.render(in:)` 到位图存成 PNG 到 `/tmp`，人工看图确认方向（图像不倒置、镂空位置在左上）。确认后删除临时测试。
- [ ] **Step 2:** `$TEST` 全部通过（含 `DaySimulationTests`）。
- [ ] **Step 3:** 启动 App，在设置「截图」页查看权限状态、录快捷键（试 ⌘⇧4 应出现冲突提示，试 ⌃⌥A 正常保存）。
- [ ] **Step 4:** 更新 `CLAUDE.md`：新增「第四阶段：截图 + 贴图」小节（入口、交互规则、实测的窗口层级、`CopySymbolicHotKeys` 结论、权限、不做清单），侧边栏描述改为 8 组。
- [ ] **Step 5:** 提交 `git commit -m "CLAUDE.md：记录截图 + 贴图"`
- [ ] **Step 6:** 给用户的手动验收清单：权限流程、单/双屏、Retina 清晰度、菜单栏图标/菜单/整条菜单栏识别、复制/保存/贴图/取消、方向键微调、放大镜取色、贴图拖动/双击关闭/⌥滚轮/右键菜单、贴剪贴板（图片、文字、空）、休息开始时截图被取消。
