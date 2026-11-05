// SPDX-License-Identifier: GPL-3.0-only
// Extraction boundary around Ice's ControlItem / IceBar / tempShowItem behavior.
import AppKit
import Combine

@MainActor
public final class ShelfController: NSObject, ObservableObject {
    @Published public private(set) var isEnabled = false
    @Published public private(set) var isCollapsed = false
    @Published public private(set) var isBusy = false
    @Published public private(set) var hasPendingRestore = false
    @Published public private(set) var message = "开启后，把低频图标放到分隔符左侧，再收起。"
    @Published public private(set) var items: [MenuBarItem] = []
    @Published public private(set) var hiddenIDs: Set<CGWindowID> = []
    /// 下拉面板当前所在屏幕的图标（从左到右）；面板关闭时为空。
    @Published public private(set) var panelRows: [ShelfRow] = []
    /// 已排队或正在移动的开关。
    @Published public private(set) var movingIDs: Set<CGWindowID> = []
    public private(set) var panelDisplayID: CGDirectDisplayID?
    public private(set) var isStopping = false
    /// 宿主应用（星期五）的 bundle ID：它的图标是入口，固定显示，不允许收纳。
    public var pinnedBundleIDs: Set<String> = []

    private var divider: NSStatusItem?
    private let driver = ItemEventDriver()
    private var panel: ShelfMenuPanel?
    /// 面板打开期间的图标截图；关闭面板即释放。
    private var panelImages: [CGWindowID: CGImage] = [:]
    private var toggleQueue: [(id: CGWindowID, key: String?, hidden: Bool, displayID: CGDirectDisplayID?)] = []
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var returnTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var pending: ReturnContext?
    private let autosaveName = "MenuBarShelfLab.Divider"
    /// 分隔符始终处于收起宽度：它左侧的图标被挤出屏幕，它本身就是那段空白，看不到任何线条。
    private let collapsedWidth: CGFloat = 10_000
    /// 临时图标待归位又遇到换屏/换桌面时放开占位；不显示内容。
    private let expandedWidth: CGFloat = 4
    private let firstLayoutKey = "MenuBarShelf.FirstLayoutDone"
    /// macOS 只在用户亲手拖过状态项时才保存它的位置；分隔符从没被拖过，重启后会落到最左侧。
    /// 自己记住分隔符右边缘到主屏右缘的距离和收起了哪些图标，启动时放回并核对。
    private let dividerOffsetKey = "MenuBarShelf.DividerOffset"
    private let hiddenKeysKey = "MenuBarShelf.HiddenKeys"
    /// 启动后核对完收起状态之前，不覆盖保存的选择。
    private var layoutRestored = false
    /// 每块屏的每份图标窗口及其来源应用；AX 只报告其中一份，刷新时按顺序补到其他屏的副本。
    private var attribution: [CGWindowID: MenuBarItem] = [:]

    private struct ReturnContext {
        let item: MenuBarItem
        let rightNeighbor: MenuBarItem
        /// 临时移动和点击发生的屏幕；归位只在这块屏的图标链上校验。
        let displayID: CGDirectDisplayID
        let spaceID: UInt
        let interfacePID: pid_t
        let windowsBefore: Set<CGWindowID>
        var transientWindows: Set<CGWindowID> = []
        var checkCount = 0
        var failureCount = 0
    }

    public override init() { super.init() }

    /// 必须由用户启用；首次启用不收起任何图标（分隔符放在最左侧）。`launcher` 为组件自己的托盘图标，由星期五托管时为 nil。
    public func start(launcher: NSStatusItem? = nil) {
        guard !isEnabled, shutdownTask == nil else { return }
        guard ShelfPermissions.accessibility else {
            message = ShelfError.permission.localizedDescription; publishSnapshot(status: "permission"); return
        }
        guard ShelfPermissions.screenRecording else {
            message = ShelfError.screenRecording.localizedDescription; publishSnapshot(status: "permission"); return
        }
        // Preferred Position 是距右侧的点数，不是第几个图标。
        let defaults = UserDefaults.standard
        let dividerKey = "NSStatusItem Preferred Position \(autosaveName)"
        layoutRestored = false
        if defaults.object(forKey: dividerOffsetKey) != nil {
            defaults.set(defaults.double(forKey: dividerOffsetKey), forKey: dividerKey)
        } else if !defaults.bool(forKey: firstLayoutKey), let primary = listDisplayID,
           let position = ShelfGeometry.leftmostPreferredPosition(items: Bridging.menuBarItems(), display: CGDisplayBounds(primary)) {
            defaults.set(position, forKey: dividerKey)
            defaults.set(true, forKey: firstLayoutKey)
        }
        if let launcher {
            // 分隔符不能排在托盘图标右侧，否则会把入口自己收掉。
            let launcherPosition = defaults.double(forKey: "NSStatusItem Preferred Position MenuBarShelfLab.Launcher")
            if defaults.object(forKey: dividerKey) == nil || defaults.double(forKey: dividerKey) <= launcherPosition {
                defaults.set(launcherPosition + max(launcher.length, 28), forKey: dividerKey)
            }
        }
        let item = NSStatusBar.system.statusItem(withLength: collapsedWidth)
        item.autosaveName = autosaveName
        item.button?.title = ""
        item.button?.setAccessibilityElement(false)
        divider = item
        isStopping = false
        isEnabled = true
        isCollapsed = true
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(environmentChanged),
                                                         name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(environmentChanged),
                                                         name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(environmentChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(applicationsChanged), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationActive),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        message = "已启用。点星期五菜单里的「菜单栏图标」选择收起哪些图标。"
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
                                        { _, observer, _, _, _ in
                                            guard let observer else { return }
                                            let controller = Unmanaged<ShelfController>.fromOpaque(observer).takeUnretainedValue()
                                            Task { @MainActor in controller.refresh() }
                                        }, SnapshotStore.requestNotice as CFString, nil, .deliverImmediately)
        // 远端状态项首次注册异步完成；只在启动时有限重试，不引入常驻轮询。
        Task { [weak self] in
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.isEnabled else { return }
                self.refresh()
                if !self.items.isEmpty { self.restoreSavedLayout(); return }
            }
            self?.layoutRestored = true
        }
    }

    /// 应用启动/退出会增减菜单栏图标；等它注册完窗口再刷新一次。
    @objc private func applicationsChanged() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.isEnabled, !self.isBusy else { return }
            self.refresh()
        }
    }

    @objc private func applicationActive() { if isEnabled && !isBusy { refresh() } }

    @objc private func environmentChanged() {
        dismissShelf()
        // 插拔屏幕、切换桌面、唤醒都保持收起。点开收起图标的菜单时，对方应用常会切换桌面或激活窗口，
        // 以前这里会放开占位（所有图标都跑出来）并停掉自动归位，开关也一直灰着；现在只继续按退避重试归位，
        // 归位本身会检查桌面是否一致，不会在另一个桌面上移动。
        if let pending, Self.screen(for: pending.displayID) == nil {
            // 那块屏上的窗口副本已随屏幕消失，无法可靠归位；图标留在可见区域。
            clearPending()
            message = ShelfError.displayRemoved.localizedDescription
        } else if pending != nil {
            scheduleRestore()
        }
        refresh()
    }

    public func refresh() {
        guard isEnabled, !isBusy, let listDisplayID else { return }
        let all = Bridging.menuBarItems()
        let chains = NSScreen.screens.map(Self.displayID(of:)).compactMap { id in layout(on: id, items: all).map { (id, $0) } }
        // 分隔符刚创建时远端窗口可能尚未注册；保持空列表，由启动重试或下次刷新补上。
        guard let listChain = chains.first(where: { $0.0 == listDisplayID })?.1 else { items = []; hiddenIDs = []; return }
        // 一次 AX 查询覆盖全部屏幕，再按链拆回各屏。
        let managed = chains.map { $0.1.ordered.filter(Self.isManaged) }
        var flat = Bridging.attributedItems(managed.flatMap { $0 })[...]
        let split = managed.map { chain -> [MenuBarItem] in defer { flat = flat.dropFirst(chain.count) }; return Array(flat.prefix(chain.count)) }
        let previous = attribution
        let fresh = DisplayChain.shareAttribution(split.map { $0.map { DisplayChain.keepingAttribution($0, previous: previous[$0.id]) } })
        attribution = Dictionary(fresh.flatMap { $0 }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // 同一图标在各屏的副本：macOS 26 多屏时主屏的第三方图标截不到图，换另一块屏的副本截。
        copies = [:]
        if let primary = managed.first(where: { $0.map(\.id) == listChain.ordered.filter(Self.isManaged).map(\.id) }) {
            for item in primary {
                copies[item.id] = managed.compactMap { DisplayChain.counterpart(of: item.id, from: primary, to: $0) }
                    .filter { $0 != item.id }
            }
        }
        items = listChain.ordered.filter(Self.isManaged).map { attribution[$0.id] ?? $0 }
        hiddenIDs = Set(listChain.hidden.filter(Self.isManaged).map(\.id))
        saveLayout(divider: listChain.divider)
        publishSnapshot()
    }

    private func saveLayout(divider: MenuBarItem) {
        guard layoutRestored, toggleQueue.isEmpty, movingIDs.isEmpty, pending == nil, let listDisplayID else { return }
        let defaults = UserDefaults.standard
        defaults.set(Double(CGDisplayBounds(listDisplayID).maxX - divider.frame.maxX), forKey: dividerOffsetKey)
        let keys = ShelfGeometry.layoutKeys(items)
        defaults.set(zip(items, keys).filter { hiddenIDs.contains($0.0.id) }.map(\.1), forKey: hiddenKeysKey)
    }

    /// 启动时核对：分隔符放回后仍不一致的图标（应用增减、位置被系统调整）逐个收起或放出。
    private func restoreSavedLayout() {
        defer { layoutRestored = true }
        guard let saved = UserDefaults.standard.stringArray(forKey: hiddenKeysKey) else { return }
        let wanted = Set(saved)
        let keys = ShelfGeometry.layoutKeys(items)
        for (item, key) in zip(items, keys) where !isPinned(item) && item.sourceBundleID != nil {
            let isHidden = hiddenIDs.contains(item.id)
            if wanted.contains(key) != isHidden { setHidden(item.id, hidden: !isHidden, on: listDisplayID) }
        }
    }

    private func isPinned(_ item: MenuBarItem) -> Bool {
        !item.isMovable || item.sourceBundleID.map(pinnedBundleIDs.contains) == true
    }

    /// 写给星期五菜单显示的快照（主屏图标链）。没有 App Group 权限时什么都不做。
    private func publishSnapshot(status: String? = nil) {
        let snapshot = ShelfSnapshot(enabled: isEnabled, pendingRestore: hasPendingRestore, status: status,
                                     entries: zip(items, ShelfGeometry.layoutKeys(items)).map { item, key in
            .init(id: item.id, name: item.displayName, hidden: hiddenIDs.contains(item.id), pinned: isPinned(item), image: nil, template: false,
                  bundleID: item.sourceBundleID, key: key)
        })
        guard snapshot != lastSnapshot else { return }
        if SnapshotStore.write(snapshot, image: { [self] in captureImage($0) }) {
            lastSnapshot = snapshot
            SnapshotStore.post(SnapshotStore.changedNotice)
        }
    }
    private var lastSnapshot: ShelfSnapshot?
    private var copies: [CGWindowID: [CGWindowID]] = [:]

    private func captureImage(_ id: CGWindowID) -> CGImage? {
        for candidate in [id] + (copies[id] ?? []) {
            guard let item = Bridging.item(candidate), let image = Bridging.image(of: item).flatMap(SnapshotStore.trimmed) else { continue }
            return image
        }
        return nil
    }

    /// 排查用：把本组件看到的权限和菜单栏窗口写进共享文件夹（不含截图）。
    public func writeDiagnostics() {
        guard let directory = SnapshotStore.directory else { return }
        let all = Bridging.menuBarItems()
        let lines = ["enabled=\(isEnabled) busy=\(isBusy) ax=\(ShelfPermissions.accessibility) screen=\(ShelfPermissions.screenRecording)",
                     "screens=" + NSScreen.screens.map { "\(Self.displayID(of: $0)):\(CGDisplayBounds(Self.displayID(of: $0)))" }.joined(separator: " ")]
            + all.map { "\($0.id) \($0.ownerName) title=\($0.title) frame=\($0.frame) on=\($0.isOnScreen)" }
        try? lines.joined(separator: "\n").write(to: directory.appendingPathComponent("diagnose.txt"), atomically: true, encoding: .utf8)
    }

    /// 某块屏上图标链里的图标（含来源应用）及其稳定标识。
    private func keyedItems(on displayID: CGDirectDisplayID) -> [(item: MenuBarItem, key: String)] {
        guard let chain = layout(on: displayID) else { return [] }
        let managed = chain.ordered.filter(Self.isManaged).map { attribution[$0.id] ?? $0 }
        return Array(zip(managed, ShelfGeometry.layoutKeys(managed)))
    }

    private func currentItem(forKey key: String, on displayID: CGDirectDisplayID) -> MenuBarItem? {
        keyedItems(on: displayID).first { $0.key == key }.flatMap { resolvedItem($0.item.id) }
    }

    /// 窗口编号对应的稳定标识（应用 + 序号），在所有屏上找。
    private func stableKey(for id: CGWindowID) -> String? {
        for screen in NSScreen.screens {
            if let match = keyedItems(on: Self.displayID(of: screen)).first(where: { $0.item.id == id }) { return match.key }
        }
        return nil
    }

    /// 星期五菜单发来的命令。图标用稳定标识（应用 + 序号）指定：macOS 26 会让同一图标的窗口编号在两块屏之间互换，
    /// 星期五拿到的编号到执行时可能已指向另一块屏。
    public func handle(command: String, key: String?, button: CGMouseButton = .left) {
        guard isEnabled else { return }
        if command == "refresh" { refresh(); return }
        if command == "diagnose" { writeDiagnostics(); return }
        if command == "restore" { restoreTemporaryItem(); return }
        if command == "reveal-all" {
            for item in items.filter({ hiddenIDs.contains($0.id) && !isPinned($0) }).reversed() {
                setHidden(item.id, hidden: false, on: listDisplayID)
            }
            return
        }
        guard let key, let listDisplayID else { return }
        guard let item = keyedItems(on: listDisplayID).first(where: { $0.key == key })?.item,
              !isPinned(item) || command == "open" else { message = ShelfError.missingItem.localizedDescription; return }
        switch command {
        case "hide": setHidden(item.id, hidden: true, on: listDisplayID)
        case "show": setHidden(item.id, hidden: false, on: listDisplayID)
        case "open":
            // 在主屏那份图标上打开。实测在外接屏的副本上临时移动会连续失败；macOS 26 各屏图标位置联动，
            // 主屏移出来后外接屏也会出现，点击直接发给来源应用。
            let target = listDisplayID
            guard let copy = keyedItems(on: target).first(where: { $0.key == key })?.item else {
                message = ShelfError.dividerMissing.localizedDescription; return
            }
            activate(copy.id, button: button, displayID: target)
        default: break
        }
    }

    /// 组件自己的分隔符和托盘图标不列出、不收纳。
    private static func isManaged(_ item: MenuBarItem) -> Bool { !DisplayChain.isOwn(item, bundleID: ownBundleID) }
    static let ownBundleID = "com.lizhiming.MenuBarShelfLab"

    private func resolvedItem(_ id: CGWindowID) -> MenuBarItem? {
        guard var item = Bridging.item(id) else { return nil }
        if let cached = attribution[id], ShelfGeometry.sameWindow(item, as: cached) {
            item.sourceProcessID = cached.sourceProcessID
            item.accessibilityName = cached.accessibilityName
            item.sourceBundleID = cached.sourceBundleID
        }
        if item.sourceProcessID == nil { item = Bridging.attributedItems([item]).first ?? item }
        return item
    }

    /// 收纳或显示一个图标。多个请求排队，依次模拟 ⌘ 拖动（每次约 1 秒）。
    /// `displayID` 为图标副本所在的屏幕；顺序全局一致，所有屏一起生效。
    public func setHidden(_ id: CGWindowID, hidden: Bool, on displayID: CGDirectDisplayID? = nil) {
        guard isEnabled, !isStopping else { return }
        // 有临时图标没归位时不再拒绝：执行前先把它放回去（见 drainToggles）
        guard !movingIDs.contains(id) else { return }
        toggleQueue.append((id, stableKey(for: id), hidden, displayID))
        movingIDs.insert(id)
        drainToggles()
    }

    /// 「全部显示」：从最右边的收纳项开始依次移到分隔符右侧，保持原来的左右顺序。
    public func revealAll() {
        for row in panelRows.filter({ $0.isHidden && !$0.isPinned }).reversed() {
            setHidden(row.id, hidden: false, on: panelDisplayID)
        }
    }

    private func drainToggles() {
        guard !isBusy, !toggleQueue.isEmpty else { return }
        let request = toggleQueue.removeFirst()
        let started = perform(completion: { [weak self] in
            guard let self else { return }
            self.movingIDs.remove(request.id)
            // 一批开关全部移完后再刷新一次，保存最终的收起选择
            if self.toggleQueue.isEmpty { self.refresh() }
            self.reloadPanel()
            self.drainToggles()
        }) { [self] in
            if pending != nil {
                do { try await restoreIfPossible(force: true) }
                catch { clearPending() }   // 放不回原位也不卡住开关；图标留在常显区，可再收起
            }
            guard let displayID = request.displayID ?? listDisplayID,
                  let separator = layout(on: displayID)?.divider else { throw ShelfError.dividerMissing }
            // 排队期间窗口编号可能已换到另一块屏：按稳定标识在目标屏上重新找到这个图标。
            let current = request.key.flatMap { currentItem(forKey: $0, on: displayID) }
            guard let item = current ?? resolvedItem(request.id), item.isMovable else { throw ShelfError.missingItem }
            let destination: ItemEventDriver.MoveDestination = request.hidden ? .leftOfItem(separator) : .rightOfItem(separator)
            try await driver.slowMove(item: item, to: destination, sideOnly: true)
            message = request.hidden ? "已收起 \(item.displayName)。" : "已显示 \(item.displayName)。"
        }
        if !started {
            // 权限被撤回或正在退出：放弃整条队列，开关回到实际状态。
            toggleQueue.removeAll()
            movingIDs.removeAll()
            reloadPanel()
        }
    }

    // 在指定屏幕（默认鼠标所在屏幕，即入口图标被点击的那块）的菜单栏下方打开下拉面板。
    /// `anchorBundleID` 为入口图标所属应用（星期五托管时），找不到时用组件自己的托盘图标或鼠标位置。
    public func showShelf(on requested: NSScreen? = nil, anchorBundleID: String? = nil) {
        guard isEnabled, !isStopping else { return }
        if panel != nil { dismissShelf(); return }
        guard ShelfPermissions.screenRecording else { message = ShelfError.screenRecording.localizedDescription; return }
        let pointer = NSEvent.mouseLocation
        guard let screen = requested ?? pointerScreen else { message = ShelfError.dividerMissing.localizedDescription; return }
        let displayID = Self.displayID(of: screen)
        guard !UserDefaults.standard.bool(forKey: "_HIHideMenuBar"),
              !NSApp.presentationOptions.contains(.autoHideMenuBar),
              !NSApp.presentationOptions.contains(.hideMenuBar) else {
            message = ShelfError.automaticMenuBar.localizedDescription
            return
        }
        panelDisplayID = displayID
        guard reloadPanel(force: true) else {
            panelDisplayID = nil
            message = ShelfError.dividerMissing.localizedDescription
            return
        }
        let bounds = CGDisplayBounds(displayID)
        let all = Bridging.menuBarItems()
        let anchorItem = anchorBundleID.flatMap { id in
            layout(on: displayID, items: all)?.visible.first { attribution[$0.id]?.sourceBundleID == id }
        } ?? DisplayChain.ownCopy(.launcher, on: bounds, in: all, bundleID: Self.ownBundleID)
        let menuHeight = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        let height = ShelfGeometry.menuPanelHeight(rows: panelRows.count, hasPendingRestore: hasPendingRestore)
        let frame = ShelfGeometry.menuPanelFrame(screen: screen.frame, menuBarHeight: menuHeight,
                                                 size: CGSize(width: 300, height: height),
                                                 anchorMinX: anchorItem?.frame.minX ?? pointer.x)
        let newPanel = ShelfMenuPanel(controller: self, frame: frame,
                                      dark: ShelfMenuPanel.prefersDark(Array(panelImages.values)),
                                      onOpen: { [weak self] id, button in self?.activate(id, button: button, displayID: displayID) },
                                      onDismiss: { [weak self] in self?.dismissShelf() })
        panel = newPanel
        newPanel.makeKeyAndOrderFront(nil)
        // 只在面板可见期间监听点击，不安装常驻鼠标移动监听。开关移动时投递的模拟点击不能把面板关掉。
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isBusy, self.movingIDs.isEmpty else { return }
                self.dismissShelf()
            }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, event.window !== self.panel, !self.isBusy, self.movingIDs.isEmpty { self.dismissShelf() }
            return event
        }
    }

    /// 重新读取面板所在屏幕的图标链；新出现的图标补一张截图。
    @discardableResult
    private func reloadPanel(force: Bool = false) -> Bool {
        guard let displayID = panelDisplayID, panel != nil || force else { return false }
        refresh()
        guard let chain = layout(on: displayID) else { return false }
        let hiddenSet = Set(chain.hidden.map(\.id))
        panelRows = chain.ordered.filter(Self.isManaged).map { raw in
            let item = attribution[raw.id] ?? raw
            if panelImages[item.id] == nil, let image = Bridging.image(of: item) { panelImages[item.id] = image }
            let pinned = !item.isMovable || item.sourceBundleID.map(pinnedBundleIDs.contains) == true
            return ShelfRow(item: item, image: panelImages[item.id], isHidden: hiddenSet.contains(item.id), isPinned: pinned)
        }
        panel?.resize(height: ShelfGeometry.menuPanelHeight(rows: panelRows.count, hasPendingRestore: hasPendingRestore))
        return true
    }

    public func dismissShelf() {
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        globalClickMonitor = nil
        localClickMonitor = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        panelImages = [:]
        panelRows = []
        panelDisplayID = nil
    }

    private func activate(_ id: CGWindowID, button: CGMouseButton, displayID: CGDirectDisplayID) {
        dismissShelf()
        perform { [self] in
            guard pending == nil else { throw ShelfError.pendingRestore }
            guard let screen = Self.screen(for: displayID) else { throw ShelfError.displayRemoved }
            guard let item = resolvedItem(id) else { throw ShelfError.missingItem }
            guard let chain = layout(on: displayID) else { throw ShelfError.dividerMissing }
            let display = CGDisplayBounds(displayID)
            // 避开该屏的应用菜单与刘海；外接屏取不到应用菜单时只用右半屏，不盲点。
            let leftLimit = DisplayChain.clickableLeftLimit(
                display: display, menuRightEdge: Bridging.applicationMenuRightEdge(displayBounds: display),
                notchRightEdge: screen.auxiliaryTopRightArea?.minX)
            let alreadyAccessible = item.isOnScreen && item.frame.minX >= leftLimit && item.frame.maxX <= display.maxX
            let interfacePID = item.eventPID
            if !alreadyAccessible {
                guard let rightID = ShelfGeometry.returnAnchor(for: item, in: chain.ordered),
                      let rightNeighbor = chain.ordered.first(where: { $0.id == rightID }),
                      let target = ShelfGeometry.insertionTarget(
                        items: chain.visible.filter { $0.id != item.id && $0.isMovable },
                        width: item.frame.width, leftLimit: leftLimit) else { throw ShelfError.noSpace }
                // 在移动前记录归位目标；点击失败也必须能恢复。
                pending = ReturnContext(item: item, rightNeighbor: rightNeighbor, displayID: displayID,
                                        spaceID: Bridging.currentSpace(of: displayID),
                                        interfacePID: interfacePID,
                                        windowsBefore: Bridging.interfaceWindows(ownerPID: interfacePID))
                hasPendingRestore = true
                publishSnapshot()
                do {
                    try await driver.move(item: item, to: .leftOfItem(target))
                    // 系统隐私指示灯可插入邻居之间；临时点击验证完整可点击区域，归位仍验证顺序。
                    try await Task.sleep(for: .milliseconds(100))
                    guard let moved = Bridging.item(id), moved.isOnScreen,
                          moved.frame.minX >= leftLimit, moved.frame.maxX <= display.maxX else {
                        throw ShelfError.movementFailed
                    }
                } catch {
                    scheduleRestore()
                    throw error
                }
            }
            do {
                if let pending, pending.spaceID != Bridging.currentSpace(of: displayID) { throw ShelfError.spaceChanged }
                try await driver.click(item: item, with: button)
                try await Task.sleep(for: .milliseconds(200))
                if var context = pending {
                    context.transientWindows = Bridging.interfaceWindows(ownerPID: context.interfacePID).subtracting(context.windowsBefore)
                    pending = context
                    scheduleRestore()
                }
                message = "已点击 \(item.displayName)。菜单关闭后会恢复图标。"
            } catch {
                if pending != nil { scheduleRestore() }
                throw error
            }
        }
    }

    private func scheduleRestore(after delay: Duration = .seconds(2)) {
        returnTask?.cancel()
        // 只在一个图标等待归位期间工作；菜单开着时两秒一次最多 60 次，失败后按退避间隔有限重试。
        returnTask = Task { [weak self] in
            do { try await Task.sleep(for: delay, tolerance: .milliseconds(200)) } catch { return }
            guard let self, !self.isStopping else { return }
            self.automaticRestore()
        }
    }

    /// 用户点击“恢复临时图标”：不再等待应用面板关闭，直接强制归位。
    public func restoreTemporaryItem() {
        guard pending != nil else { return }
        guard !isBusy else { message = "正在处理上一个操作，请稍后再点“恢复临时图标”。"; return }
        returnTask?.cancel()
        returnTask = nil
        perform { [self] in try await restoreIfPossible(force: true) }
    }

    private func automaticRestore() {
        guard pending != nil else { return }
        if isBusy { scheduleRestore(); return }
        perform { [self] in
            do { try await restoreIfPossible(force: false) }
            catch {
                // 单次失败（移动超时、鼠标正在使用、桌面不一致等）不能让归位链就此停止。
                guard var context = pending else { throw error }
                if let delay = ShelfGeometry.restoreRetryDelay(afterFailures: context.failureCount) {
                    context.failureCount += 1
                    pending = context
                    scheduleRestore(after: delay)
                    message = "图标归位暂未完成（\(error.localizedDescription)），稍后自动重试。"
                } else {
                    message = "自动归位多次失败：\(error.localizedDescription) 请点击“恢复临时图标”强制归位。"
                }
            }
        }
    }

    private func restoreIfPossible(force: Bool) async throws {
        guard var context = pending else { return }
        guard Self.screen(for: context.displayID) != nil else { clearPending(); throw ShelfError.displayRemoved }
        guard let current = resolvedItem(context.item.id), ShelfGeometry.sameWindow(current, as: context.item) else {
            clearPending(); return // 原应用已退出，不把旧窗口 ID 用在其他应用上。
        }
        guard context.spaceID == Bridging.currentSpace(of: context.displayID) else { throw ShelfError.spaceChanged }
        if !force {
            let visible = Bridging.interfaceWindows(ownerPID: context.interfacePID)
            // 覆盖稍晚出现的菜单/浮窗，避免 200ms 之后才打开时过早收回。
            context.transientWindows.formUnion(visible.subtracting(context.windowsBefore))
            let mouseDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
                || CGEventSource.buttonState(.combinedSessionState, button: .right)
            if mouseDown || !context.transientWindows.isDisjoint(with: visible) {
                context.checkCount += 1
                pending = context
                if context.checkCount < 60 { scheduleRestore() }
                else { message = "应用面板仍开着，图标暂留可见。关闭面板或点击“恢复临时图标”即可归位。" }
                return
            }
        }
        // 邻居退出时退回分隔符左侧，至少回到正确的区域。
        let neighbor = Bridging.item(context.rightNeighbor.id).flatMap {
            ShelfGeometry.sameWindow($0, as: context.rightNeighbor) ? $0 : nil
        }
        guard let target = neighbor ?? layout(on: context.displayID)?.divider else { throw ShelfError.missingItem }
        try await driver.slowMove(item: current, to: .leftOfItem(target))
        clearPending()
        message = "图标已恢复到收纳区。"
    }

    private func clearPending() {
        returnTask?.cancel()
        returnTask = nil
        pending = nil
        hasPendingRestore = false
        // 旧版本或异常情况下占位被放开过：归位完成后收回去
        if isEnabled, !isStopping, !isCollapsed, let divider {
            divider.length = collapsedWidth
            isCollapsed = true
        }
        reloadPanel()
        publishSnapshot()
    }

    /// 退出前先等待正在进行的点击/拖动，再尝试恢复临时项，最后移除占位。
    public func stop() async {
        // 设置页关闭与应用退出可以同时到达；共享同一次收尾，不能并发投递两组归位事件。
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        isStopping = true
        let task = Task { [self] in await finishStopping() }
        shutdownTask = task
        await task.value
        shutdownTask = nil
    }

    private func finishStopping() async {
        returnTask?.cancel()
        toggleQueue.removeAll()
        movingIDs.removeAll()
        dismissShelf()
        // 进行中的操作都有超时；这里再加一道上限，确保退出永远不会无限等待。
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while isBusy && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        if isBusy {
            // 不与仍在投递的事件并发归位，只移除占位，让所有图标回到可见区域。
            message = "上一个操作未能结束，已跳过归位并展开全部图标。"
        } else if pending != nil {
            do { try await restoreIfPossible(force: true) }
            catch { message = "图标归位未完成，已展开全部图标：\(error.localizedDescription)" }
        }
        clearPending()
        if let divider {
            let key = "NSStatusItem Preferred Position \(autosaveName)"
            let position = UserDefaults.standard.object(forKey: key)
            NSStatusBar.system.removeStatusItem(divider)
            if let position { UserDefaults.standard.set(position, forKey: key) }
        }
        divider = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
        isEnabled = false
        isCollapsed = false
        items = []
        hiddenIDs = []
        publishSnapshot()
        isStopping = false
    }

    /// 串行执行一次移动/点击。返回 false 表示没有开始（忙、正在退出或缺少辅助功能权限）。
    @discardableResult
    private func perform(completion: (@MainActor () -> Void)? = nil,
                         _ operation: @escaping @MainActor () async throws -> Void) -> Bool {
        guard !isBusy, !isStopping else { return false }
        guard ShelfPermissions.accessibility else { message = ShelfError.permission.localizedDescription; return false }
        isBusy = true
        Task { [self] in
            do { try await operation() }
            catch { message = error.localizedDescription }
            isBusy = false
            // 批量开关还没移完时不刷新：每次刷新要问一遍所有应用的菜单栏信息，会让每个图标之间多停半秒以上。
            if toggleQueue.isEmpty { refresh() }
            completion?()
        }
        return true
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { Self.displayID(of: $0) == displayID }
    }

    /// 托盘被点击时鼠标所在的屏幕；远端绘制的按钮窗口可能拿不到 screen。
    private var pointerScreen: NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// 设置页列表、收纳/常显移动使用主屏的链；顺序全局一致，所有屏一起生效。
    private var listDisplayID: CGDirectDisplayID? { NSScreen.screens.first.map(Self.displayID(of:)) }

    /// 指定屏幕上的分隔符副本，及以它为锚点的本屏图标链。
    private func layout(on displayID: CGDirectDisplayID, items all: [MenuBarItem] = Bridging.menuBarItems()) -> DisplayChain.Chain? {
        let bounds = CGDisplayBounds(displayID)
        guard let divider = DisplayChain.ownCopy(.divider, on: bounds, in: all, bundleID: Self.ownBundleID) else { return nil }
        return DisplayChain.chain(anchoredAt: divider, in: all, display: bounds)
    }
}
