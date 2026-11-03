# 菜单栏收纳多屏支持 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让菜单栏收纳组件支持多块屏幕：在哪块屏点托盘，就在哪块屏展开并在那一排图标上点击、归位。

**Architecture:** 新增纯函数模块 `DisplayChain`，以每块屏幕上的分隔符窗口副本为锚点，沿首尾相接的窗口串出该屏的收纳链和常显链；控制器把「目标屏幕」贯穿展开、点击、归位；位置校验改为同一排几何相邻；「单独空间」模式下按屏取当前桌面。设计见 `2026-11-03-multi-display-design.md`。

**Tech Stack:** Swift 6 编译器 / Swift 5 语言模式，AppKit，CoreGraphics 私有 CGS，Swift Testing。

**工作目录：** `/Users/lizhiming/Desktop/lizhiming/个人项目验证/开源项目研究/friday-menu-bar`，分支 `feature/menu-bar-shelf`。不推送、不合并。

**组件测试命令：** `swift test --build-system native --package-path MenuBarCompanion`

---

## 文件结构

| 文件 | 责任 |
|---|---|
| 新建 `MenuBarCompanion/Sources/MenuBarShelf/DisplayChain.swift` | 纯函数：选分隔符副本、串链、几何相邻、跨屏共享来源信息、可点击左界、桌面解析 |
| 改 `MenuBarCompanion/Sources/MenuBarShelf/Models.swift` | 错误类型；删除被取代的 `areAdjacent`、`isHidden`、`shouldExpandOnEnvironmentChange` |
| 改 `MenuBarCompanion/Sources/MenuBarShelf/SystemBridge.swift` | 当前桌面集合、按屏当前桌面 |
| 改 `MenuBarCompanion/Sources/MenuBarShelf/IceCore/ItemEventDriver.swift` | 位置校验改用 `DisplayChain.adjacent` |
| 改 `MenuBarCompanion/Sources/MenuBarShelf/ShelfController.swift` | 去掉单屏判断，目标屏幕贯穿全流程 |
| 改 `MenuBarCompanion/Tests/MenuBarShelfTests/ShelfTests.swift` | 新增多屏测试，替换被删函数的测试 |
| 改文案 `ShelfLabApp.swift`、`RestBreak/RestBreak/UI/MenuBarCompanionPage.swift` 与文档 | 去掉「单屏」 |

**设计修订（实施时确定）：** 设计稿写「目标屏拔出时在主屏归位」。拔屏后那块屏上的窗口副本随之消失，无法可靠映射到主屏副本，改为：目标屏拔出时清除待归位记录、展开占位，提示「临时图标留在可见区域，可在设置列表重新收纳」。同步修改设计稿。

---

### Task 1: DisplayChain 纯函数与单测

**Files:**
- Create: `MenuBarCompanion/Sources/MenuBarShelf/DisplayChain.swift`
- Modify: `MenuBarCompanion/Tests/MenuBarShelfTests/ShelfTests.swift`

- [ ] **Step 1: 写失败测试**（追加到 `ShelfTests.swift` 末尾；`item` 助手增加 `title` 参数）

```swift
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
        let shared = DisplayChain.shareAttribution([a, b])
        #expect(shared[1][1].sourceProcessID == 777)
        #expect(shared[1][1].accessibilityName == "CC Switch")
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
}
```

- [ ] **Step 2: 运行确认失败**：组件测试命令 → 编译错误 `cannot find 'DisplayChain'`。

- [ ] **Step 3: 实现** `DisplayChain.swift`

```swift
// SPDX-License-Identifier: GPL-3.0-only
import CoreGraphics
import Foundation

/// 多屏：macOS 26 给每块屏幕各画一份图标窗口，顺序相同。离屏的收纳项没有可靠的屏幕归属，
/// 所以以「本屏那份分隔符」为锚点，沿首尾相接的窗口串出本屏的收纳链与常显链。
enum DisplayChain {
    /// 坐标取整误差。
    static let tolerance: CGFloat = 2
    /// 相邻图标之间允许的系统间距；超过即视为断链（另一屏的副本至少差两屏右边缘之差）。
    static let maxGap: CGFloat = 8

    struct Chain {
        let divider: MenuBarItem
        /// 分隔符左侧（收纳区），从左到右。
        let hidden: [MenuBarItem]
        /// 分隔符右侧（常显区），从左到右。
        let visible: [MenuBarItem]
        var ordered: [MenuBarItem] { hidden + [divider] + visible }
    }

    static func sameRow(_ a: CGRect, _ b: CGRect) -> Bool { abs(a.minY - b.minY) <= tolerance }

    /// 多份同名窗口里，选出位于该屏菜单栏那一排、右边缘落在该屏内的那份。
    static func copy(titled title: String, on display: CGRect, in items: [MenuBarItem]) -> MenuBarItem? {
        items.first {
            $0.title == title && abs($0.frame.minY - display.minY) <= tolerance
                && $0.frame.maxX >= display.minX && $0.frame.maxX <= display.maxX + tolerance
        }
    }

    static func chain(anchoredAt divider: MenuBarItem, in items: [MenuBarItem], display: CGRect) -> Chain {
        let row = items.filter { $0.id != divider.id && $0.frame.width > 0 && sameRow($0.frame, divider.frame) }
        var used: Set<CGWindowID> = [divider.id]
        var hidden: [MenuBarItem] = []
        var edge = divider.frame.minX
        // 向左：取右边缘最贴近当前边缘的那一个。
        while let next = row.filter({ !used.contains($0.id) && $0.frame.maxX <= edge + tolerance && edge - $0.frame.maxX <= maxGap })
            .max(by: { $0.frame.maxX < $1.frame.maxX }) {
            used.insert(next.id); hidden.insert(next, at: 0); edge = next.frame.minX
        }
        var visible: [MenuBarItem] = []
        edge = divider.frame.maxX
        while let next = row.filter({ !used.contains($0.id) && $0.frame.minX >= edge - tolerance && $0.frame.minX - edge <= maxGap
                                       && $0.frame.maxX <= display.maxX + tolerance })
            .min(by: { $0.frame.minX < $1.frame.minX }) {
            used.insert(next.id); visible.append(next); edge = next.frame.maxX
        }
        return Chain(divider: divider, hidden: hidden, visible: visible)
    }

    /// 同一排、左项右边缘与右项左边缘之间不超过系统间距。
    static func adjacent(left: CGRect, right: CGRect) -> Bool {
        sameRow(left, right) && left.maxX <= right.minX + tolerance && right.minX - left.maxX <= maxGap
    }

    /// AX 只报告一份图标的位置；各屏链顺序相同，长度一致时按位置把来源进程和名称补到其他副本。
    static func shareAttribution(_ chains: [[MenuBarItem]]) -> [[MenuBarItem]] {
        guard let count = chains.first?.count, chains.allSatisfy({ $0.count == count }) else { return chains }
        var result = chains
        for index in 0..<count {
            guard let source = chains.map({ $0[index] }).first(where: { $0.sourceProcessID != nil }) else { continue }
            for display in result.indices where result[display][index].sourceProcessID == nil {
                result[display][index].sourceProcessID = source.sourceProcessID
                result[display][index].accessibilityName = source.accessibilityName
            }
        }
        return result
    }

    /// 临时图标必须完整落在此值右侧：避开应用菜单与刘海；取不到应用菜单时保守地只用右半屏。
    static func clickableLeftLimit(display: CGRect, menuRightEdge: CGFloat?, notchRightEdge: CGFloat?) -> CGFloat {
        max(menuRightEdge.map { $0 + 8 } ?? display.midX, notchRightEdge.map { $0 + 20 } ?? display.minX, display.minX)
    }

    /// 解析 CGSCopyManagedDisplaySpaces：屏幕标识 → 当前桌面 ID。私有格式，缺字段的屏幕跳过。
    static func currentSpaces(from managed: [[String: Any]]) -> [String: UInt] {
        var result: [String: UInt] = [:]
        for display in managed {
            guard let id = display["Display Identifier"] as? String,
                  let current = display["Current Space"] as? [String: Any],
                  let space = (current["id64"] as? NSNumber ?? current["ManagedSpaceID"] as? NSNumber)?.uintValue else { continue }
            result[id] = space
        }
        return result
    }
}
```

- [ ] **Step 4: 运行确认通过**：组件测试命令 → 新增 8 项通过。
- [ ] **Step 5: 提交** `git commit -m "菜单栏组件：按屏幕串图标链的纯函数及测试"`

### Task 2: 桌面识别与位置校验按屏

**Files:** `SystemBridge.swift`、`IceCore/ItemEventDriver.swift`、`Models.swift`、`ShelfTests.swift`

- [ ] **Step 1:** `SystemBridge.swift` 增加私有声明与两个属性，`menuBarItems()` 改用当前桌面集合：

```swift
@_silgen_name("CGSCopyManagedDisplaySpaces") private func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> Unmanaged<CFArray>?

    /// 「显示器具有单独的空间」打开时每块屏各有当前桌面；关闭时只有一个活动桌面。
    static var currentSpaceIDs: Set<UInt> {
        let active = activeSpace
        guard NSScreen.screensHaveSeparateSpaces,
              let managed = CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?.takeRetainedValue() as? [[String: Any]] else { return [active] }
        return Set(DisplayChain.currentSpaces(from: managed).values).union([active])
    }

    static func currentSpace(of displayID: CGDirectDisplayID) -> UInt {
        guard NSScreen.screensHaveSeparateSpaces,
              let managed = CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?.takeRetainedValue() as? [[String: Any]],
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let key = CFUUIDCreateString(nil, uuid) as String?,
              let space = DisplayChain.currentSpaces(from: managed)[key] else { return activeSpace }
        return space
    }
```
`menuBarItems()` 中 `let activeSpace = CGSGetActiveSpace(connection)` 改为 `let spaces = currentSpaceIDs`，过滤条件改为 `!windowSpaces.isEmpty, windowSpaces.allSatisfy({ !spaces.contains($0) })`。

- [ ] **Step 2:** `ItemEventDriver.itemHasCorrectPosition` 改为：

```swift
        let target = getTargetItem(for: destination)
        let ordered = Bridging.menuBarItems()
        guard let current = ordered.first(where: { $0.id == item.id }),
              let anchor = ordered.first(where: { $0.id == target.id }) else {
            throw EventError(code: .invalidItem, item: item)
        }
        switch destination {
        case .leftOfItem: return DisplayChain.adjacent(left: current.frame, right: anchor.frame)
        case .rightOfItem: return DisplayChain.adjacent(left: anchor.frame, right: current.frame)
        }
```

- [ ] **Step 3:** `Models.swift` 删除 `areAdjacent`、`isHidden`、`shouldExpandOnEnvironmentChange`；`ShelfError` 用 `dividerMissing`、`spaceChanged`、`displayRemoved` 取代 `unsupportedDisplay`：

```swift
        case .dividerMissing: "这块屏幕上暂时找不到收纳分隔符，请稍后重试或点“刷新”。"
        case .spaceChanged: "桌面已切换。请回到原来的桌面再操作，或点击“恢复临时图标”。"
        case .displayRemoved: "外接屏已断开，临时图标留在可见区域，可在设置列表里重新收纳。"
```
测试：删除 `adjacencyUsesWindowOrderAndAllowsSystemSpacing` 中的 `areAdjacent` 断言（保留 `CGWindowID(exactly:)` 断言，测试改名 `virtualWindowNumberIsRejected`）、删除 `wideDividerPartitionsHiddenItemsWithoutIncludingOtherScreenRow`、`spaceOrWakeKeepsShelfCollapsedUnlessUnsafe`（由 DisplayChainTests 取代）。

- [ ] **Step 4:** 此时控制器尚未改，编译失败属预期；与 Task 3 一起编译。

### Task 3: 控制器去掉单屏限制

**Files:** `ShelfController.swift`

- [ ] **Step 1:** `ReturnContext` 增加 `let displayID: CGDirectDisplayID`；新增：

```swift
    private var attribution: [CGWindowID: MenuBarItem] = [:]

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }
    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { Self.displayID(of: $0) == displayID }
    }
    /// 托盘被点击时鼠标所在的屏幕。
    private var pointerScreen: NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }
    /// 设置页列表、收纳/常显移动使用主屏（菜单栏所在的原点屏）的链。
    private var listDisplayID: CGDirectDisplayID? { NSScreen.screens.first.map(Self.displayID(of:)) }

    private func layout(on displayID: CGDirectDisplayID, items all: [MenuBarItem] = Bridging.menuBarItems()) -> DisplayChain.Chain? {
        let bounds = CGDisplayBounds(displayID)
        guard let divider = DisplayChain.copy(titled: autosaveName, on: bounds, in: all) else { return nil }
        return DisplayChain.chain(anchoredAt: divider, in: all, display: bounds)
    }
```

- [ ] **Step 2:** `refresh()` 计算全部屏幕的链，跨屏共享来源信息，列表取主屏：

```swift
    public func refresh() {
        guard isEnabled, !isBusy, let listDisplayID else { return }
        let all = Bridging.menuBarItems()
        let isManaged: (MenuBarItem) -> Bool = { !$0.title.hasPrefix("MenuBarShelfLab.") }
        let displays = NSScreen.screens.map(Self.displayID(of:))
        let chains = displays.compactMap { id in layout(on: id, items: all).map { (id, $0) } }
        guard let listChain = chains.first(where: { $0.0 == listDisplayID })?.1 else { items = []; hiddenIDs = []; return }
        let attributed = DisplayChain.shareAttribution(chains.map { Bridging.attributedItems($0.1.ordered.filter(isManaged)) })
        attribution = Dictionary(attributed.flatMap { $0 }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        items = listChain.ordered.filter(isManaged).compactMap { attribution[$0.id] }
        hiddenIDs = Set(listChain.hidden.filter(isManaged).map(\.id))
    }
```
`resolvedItem` 改用 `attribution[id]` 取缓存（原来用 `items`）。

- [ ] **Step 3:** `start` 删除屏幕数判断；`toggleCollapsed`、`perform` 删除屏幕数判断。
- [ ] **Step 4:** `environmentChanged` 改为：

```swift
        dismissShelf()
        // 插拔屏幕、切换桌面、唤醒都保持收起；只有临时图标待归位时才展开，且不在另一块屏或桌面自动移动。
        if isCollapsed, pending != nil {
            divider?.length = 22
            divider?.button?.title = "│"
            isCollapsed = false
        }
        returnTask?.cancel()
        returnTask = nil
        if let pending, Self.screen(for: pending.displayID) == nil {
            clearPending()
            message = ShelfError.displayRemoved.localizedDescription
        } else if pending != nil {
            message = "屏幕或桌面已变化，临时图标保留可见。回到原来的屏幕和桌面后点击“恢复临时图标”。"
        }
        refresh()
```

- [ ] **Step 5:** `setHidden` 的分隔符改为 `listDisplayID.flatMap { layout(on: $0)?.divider }`。
- [ ] **Step 6:** `showShelf(on requested: NSScreen? = nil)`：屏幕取 `requested ?? pointerScreen`；`guard let chain = layout(on: displayID)` 否则 `dividerMissing`；`hidden = chain.hidden.filter(isManaged).map { attribution[$0.id] ?? $0 }`；锚点 X 取 `DisplayChain.copy(titled: "MenuBarShelfLab.Launcher", on: CGDisplayBounds(displayID), in: all)?.frame.midX ?? screen.frame.midX`；`onClick` 传入 `displayID`。
- [ ] **Step 7:** `activate(_:button:displayID:)` 改用目标屏：

```swift
            guard pending == nil else { throw ShelfError.pendingRestore }
            guard let screen = Self.screen(for: displayID) else { throw ShelfError.displayRemoved }
            let all = Bridging.menuBarItems()
            guard let item = resolvedItem(id) else { throw ShelfError.missingItem }
            guard let chain = layout(on: displayID, items: all) else { throw ShelfError.dividerMissing }
            let display = CGDisplayBounds(displayID)
            let leftLimit = DisplayChain.clickableLeftLimit(
                display: display, menuRightEdge: Bridging.applicationMenuRightEdge(displayBounds: display),
                notchRightEdge: screen.auxiliaryTopRightArea?.minX)
            let alreadyAccessible = item.isOnScreen && item.frame.minX >= leftLimit && item.frame.maxX <= display.maxX
```
`returnAnchor` 用 `chain.ordered`；`insertionTarget` 用 `chain.visible.filter { $0.id != item.id && $0.isMovable }`；`ReturnContext` 传 `displayID` 和 `Bridging.currentSpace(of: displayID)`；点击前桌面判断抛 `spaceChanged`，删除屏幕数判断。
- [ ] **Step 8:** `restoreIfPossible` 开头先判断 `Self.screen(for: context.displayID) != nil`，否则 `clearPending(); throw ShelfError.displayRemoved`；桌面比较改为 `context.spaceID == Bridging.currentSpace(of: context.displayID)`，否则 `spaceChanged`；邻居退出时回退到 `layout(on: context.displayID)?.divider`。
- [ ] **Step 9:** 删除 `dividerItem`、`dividerFrame` 属性；运行组件测试命令 → 全部通过，再 `swift build -c release` 无错误。
- [ ] **Step 10:** 提交 `git commit -m "菜单栏组件支持多屏：在点击的屏幕展开、点击与归位"`

### Task 4: 文案与文档

- [ ] `ShelfLabApp.swift`：`单屏实验版 · 基于 Ice · GPL-3.0` → `实验版 · 基于 Ice · GPL-3.0`。
- [ ] `MenuBarCompanionPage.swift`：说明改为「支持多块屏幕：在哪块屏幕点托盘图标就在哪块下方展开；收起时所有屏幕一起收起。菜单栏收纳作为独立组件运行；退出组件会展开图标，星期五的休息与提醒继续运行。」
- [ ] README、组件 README、UPSTREAM、`2026-11-01-design.md`、`2026-11-01-validation.md`、`docs/项目细节.md`、`CLAUDE.md`：去掉单屏限制，写明「所有屏幕一起收起」与未实测范围；设计稿按「设计修订」更新拔屏行为。
- [ ] 运行主程序 `cd RestBreak && xcodebuild test -scheme RestBreak -destination platform=macOS -derivedDataPath /tmp/FridayMultiDisplay -allowProvisioningUpdates` → 275 项通过。
- [ ] 提交 `git commit -m "菜单栏收纳多屏：文案与文档"`

### Task 5: 构建并交给用户真机试用

- [ ] `python3 MenuBarCompanion/scripts/build_app.py --configuration release --output 发布/星期五-菜单栏实验版`；退出旧组件后 `open` 新组件。
- [ ] 真机清单见设计稿「测试 · 真机」。
