import AppKit

/// 菜单栏图标 + 下拉菜单
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    /// 菜单开着时检测截图快捷键的计时器（菜单开着时系统把全局快捷键压到菜单关掉才送来）
    private var keyWatch: Timer?
    private var keyWasDown = false
    private let coordinator: BreakCoordinator
    private let openSettings: (SettingsPage?) -> Void

    // 记住上次显示的内容，没变就不重设，避免菜单栏每秒抖动
    private var lastTitle = ""
    private var lastSymbol = ""

    init(coordinator: BreakCoordinator, openSettings: @escaping (SettingsPage?) -> Void) {
        self.coordinator = coordinator
        self.openSettings = openSettings
        super.init()
        menu.delegate = self   // 每次打开菜单前会调用 menuNeedsUpdate 重建内容
        menu.autoenablesItems = false   // 菜单项是否可点由我们自己决定
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageLeading
        refresh()
    }

    // MARK: - 菜单栏图标和文字

    func refresh() {
        let scheduler = coordinator.scheduler
        let symbol: String
        var title = ""

        switch scheduler.state {
        case .running:
            symbol = scheduler.isInMeeting ? "mic.fill"
                : scheduler.isInCalendarEvent ? "calendar"
                : scheduler.isFullscreen ? "arrow.up.left.and.arrow.down.right"
                : scheduler.isDeferringBreak ? "hourglass" : "cup.and.saucer"
            // 按实际开始时间倒计时（已考虑日程中暂缓、日程前提前）
            if coordinator.settings.showCountdownInMenuBar, let next = scheduler.nextBreakStart(now: Date()) {
                let remaining = next.date.timeIntervalSinceNow
                if scheduler.isInMeeting && remaining <= 0 {
                    // 开会时休息已到期、正在等会议结束：显示「会后」而不是停在「0秒」
                    title = "会后"
                } else if let deadline = scheduler.deferralEndsAt {
                    // 全屏或指定 App 推迟中：显示最晚还有多久必须休息
                    title = TimeText.menuBarCountdown(deadline.timeIntervalSinceNow)
                } else {
                    title = TimeText.menuBarCountdown(remaining)
                }
            }
        case .onBreak:
            symbol = "cup.and.saucer.fill"
            title = "休息中"
        case .paused:
            symbol = "pause.circle"
        case .away:
            symbol = "moon.zzz"
        }

        guard let button = statusItem.button else { return }
        if symbol != lastSymbol {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "星期五")
            image?.isTemplate = true   // 自动适配深色/浅色菜单栏
            button.image = image
            lastSymbol = symbol
        }
        if title != lastTitle {
            button.title = title.isEmpty ? "" : " \(title)"
            lastTitle = title
        }
    }

    // MARK: - 下拉菜单

    // MARK: - 菜单开着时的截图快捷键
    // 菜单开着时，主线程在「跟踪菜单」，Carbon 全局快捷键要等菜单关掉才送到（用户发现按了没反应、关菜单才出来）。
    // 所以菜单开着的这段时间，每 0.05 秒看一次键盘状态；按下截图快捷键就立刻截（定格画面里带着这个菜单），
    // 截好、框选界面出来后再把菜单收起。只在菜单开着时运行，平时没有任何开销

    func menuWillOpen(_ menu: NSMenu) {
        keyWasDown = true   // 打开菜单那一下如果正按着快捷键，不算
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkShortcutKeys() }
        }
        RunLoop.main.add(timer, forMode: .common)   // 菜单跟踪时也要跑
        keyWatch = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        keyWatch?.invalidate()
        keyWatch = nil
    }

    private func checkShortcutKeys() {
        let flags = UInt(CGEventSource.flagsState(.combinedSessionState).rawValue) & KeyShortcut.allModifierFlags
        let shortcuts = coordinator.settings.shortcuts
        let pressed = [ShortcutAction.captureScreen, .pinClipboard].first { action in
            guard let s = shortcuts[action] else { return false }
            return s.modifiers == flags && CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(s.keyCode))
        }
        defer { keyWasDown = pressed != nil }
        guard let action = pressed, !keyWasDown else { return }
        if action == .captureScreen {
            coordinator.screenshots.onOverlayShown = { [weak self] in self?.menu.cancelTracking() }
            coordinator.performShortcutFromMenu(action)
        } else {
            menu.cancelTracking()
            coordinator.performShortcutFromMenu(action)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let scheduler = coordinator.scheduler
        let settings = coordinator.settings
        let now = Date()

        // 0. 今日统计，点击打开统计页
        let today = coordinator.stats.day(for: now)
        let rate = today.completionRate.map { "，完成率 \(Int(($0 * 100).rounded()))%" } ?? ""
        let statsItem = menuItem("今天已休息 \(today.completed + today.naturalBreaks) 次\(rate)", #selector(showStats))
        statsItem.image = NSImage(systemSymbolName: "chart.bar", accessibilityDescription: nil)
        menu.addItem(statsItem)
        menu.addItem(.separator())

        // 1. 状态说明（灰色）+ 每种休息一行：左边倒计时，右边灰色「立即开始」，点这一行就开始这种休息
        let isOnBreak: Bool = if case .onBreak = scheduler.state { true } else { false }
        for line in statusNotes(scheduler: scheduler, settings: settings, now: now) {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        let kinds = isOnBreak ? [] : BreakKind.allCases.filter { settings[$0].isEnabled }
        let breakTexts = kinds.map { breakLine($0, scheduler: scheduler, now: now) }
        // 2 的内容先算出来：右侧小字的位置按所有行里最长的那行定，菜单不会被撑宽
        let soon = coordinator.reminders.upcoming(now: now, limit: 2).filter { $0.date.timeIntervalSince(now) < 24 * 3600 }
        let reminderTexts = soon.map { "\(ScheduleText.fireText($0.date, now: now, calendar: .current))　\($0.title)" }
        let tab = Self.tabLocation(for: breakTexts + reminderTexts)
        for (kind, text) in zip(kinds, breakTexts) {
            let item = menuItem("", kind == .micro ? #selector(startMicroBreak) : #selector(startLongBreak))
            item.attributedTitle = Self.rowTitle(text, hint: "立即开始", tab: tab)
            menu.addItem(item)
        }

        // 2. 接下来 24 小时内有提醒才显示，最多 2 条，点了打开「提醒」页
        if !soon.isEmpty {
            menu.addItem(.separator())
            for text in reminderTexts {
                let item = menuItem("", #selector(showReminders))
                item.attributedTitle = Self.rowTitle(text, hint: "提醒", tab: tab)
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())

        // 3. 暂停 / 恢复 / 重置
        if case .paused = scheduler.state {
            addItem("恢复", #selector(resume))
        } else {
            let pauseItem = NSMenuItem(title: "暂停", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for (title, minutes) in [("30 分钟", 30), ("1 小时", 60), ("2 小时", 120)] {
                let item = NSMenuItem(title: title, action: #selector(pauseForDuration(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = TimeInterval(minutes * 60)
                submenu.addItem(item)
            }
            submenu.addItem(menuItem("到明早 8 点", #selector(pauseUntilMorning)))
            submenu.addItem(menuItem("直到手动恢复", #selector(pauseIndefinitely)))
            pauseItem.submenu = submenu
            menu.addItem(pauseItem)
        }
        addItem("重置计时", #selector(resetTimers))
        menu.addItem(.separator())

        // 4. 设置 / 退出（开机自动启动在设置窗口「休息安排」里）
        addItem("设置…", #selector(showSettings), key: ",")
        menu.addItem(.separator())
        addItem("退出星期五", #selector(quit), key: "q")
    }

    /// 菜单顶部的状态说明（灰色）：暂停、离开、开会、日程、推迟这类情况
    private func statusNotes(scheduler: BreakScheduler, settings: AppSettings, now: Date) -> [String] {
        switch scheduler.state {
        case .onBreak(let session):
            return ["正在\(session.kind.displayName)"]
        case .paused(let until):
            if let until { return ["已暂停，\(TimeText.hourMinute(until)) 自动恢复"] }
            return ["已暂停，需手动恢复"]
        case .away:
            return ["检测到你已离开，计时暂停中"]
        case .running:
            if !BreakKind.allCases.contains(where: { settings[$0].isEnabled }) { return ["所有休息都已关闭"] }
            if scheduler.isInMeeting { return ["正在开会，到点的休息会在会后开始"] }
            if let event = scheduler.currentCalendarEvent(at: now) {
                let title = coordinator.currentEventTitle.map { "「\($0)」" } ?? ""
                return ["日程\(title)进行中，休息在 \(TimeText.hourMinute(event.end)) 后开始"]
            }
            if let next = scheduler.nextBreakStart(now: now), let due = scheduler.nextBreak()?.dueDate, next.date < due {
                return ["为了避开日程，\(next.kind.displayName)提前到 \(TimeText.hourMinute(next.date))"]
            }
            if let deadline = scheduler.deferralEndsAt, let reason = coordinator.deferralReason {
                let leaving = reason == "全屏" ? "退出全屏" : "离开「\(reason)」"
                return ["休息已推迟到\(leaving)后，最晚 \(TimeText.hourMinute(deadline))"]
            }
            return []
        }
    }

    /// 一种休息的那一行：计时中显示时刻和倒计时，暂停或离开时只显示名字
    private func breakLine(_ kind: BreakKind, scheduler: BreakScheduler, now: Date) -> String {
        guard case .running = scheduler.state else { return kind.displayName }
        let timer = scheduler.timers[kind] ?? BreakTimer(dueDate: now)
        var line = "\(kind.displayName)　\(TimeText.hourMinute(timer.dueDate))（\(TimeText.relative(timer.dueDate.timeIntervalSince(now)))）"
        if timer.postponeCount > 0 { line += " 已推迟 \(timer.postponeCount) 次" }
        return line
    }

    /// 右侧小字的位置：最长那行正文的宽度 + 「立即开始」的宽度 + 一点间距
    static func tabLocation(for texts: [String]) -> CGFloat {
        let body = NSFont.menuFont(ofSize: 0)
        let small = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        let widest = texts.map { ($0 as NSString).size(withAttributes: [.font: body]).width }.max() ?? 0
        let hint = ("立即开始" as NSString).size(withAttributes: [.font: small]).width
        return ceil(widest + 20 + hint)
    }

    /// 左边正文、右边对齐的灰色小字（和系统菜单右侧的快捷键位置一致）
    static func rowTitle(_ text: String, hint: String, tab: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: tab)]
        let result = NSMutableAttributedString(string: text, attributes: [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: paragraph])
        result.append(NSAttributedString(string: "\t\(hint)", attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]))
        return result
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func addItem(_ title: String, _ action: Selector, key: String = "", enabled: Bool = true) {
        let item = menuItem(title, action, key: key)
        item.isEnabled = enabled
        menu.addItem(item)
    }

    // MARK: - 菜单动作

    @objc private func startMicroBreak() { coordinator.startBreakNow(.micro) }
    @objc private func startLongBreak() { coordinator.startBreakNow(.long) }
    @objc private func resume() { coordinator.resume() }
    @objc private func resetTimers() { coordinator.resetTimers() }

    @objc private func pauseForDuration(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        coordinator.pause(until: Date().addingTimeInterval(seconds))
    }

    @objc private func pauseUntilMorning() {
        coordinator.pause(until: TimeText.nextMorning(after: Date()))
    }

    @objc private func pauseIndefinitely() { coordinator.pause(until: nil) }

    @objc private func showSettings() { openSettings(nil) }
    @objc private func showStats() { openSettings(.stats) }
    @objc private func showReminders() { openSettings(.reminders) }
    @objc private func quit() { NSApp.terminate(nil) }
}
