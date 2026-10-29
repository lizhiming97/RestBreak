import AppKit
import Combine

/// App 的「总指挥」：每秒驱动调度引擎，把引擎发出的事件变成界面动作
/// （弹出/关闭休息遮罩、播放提示音、刷新菜单栏）。
@MainActor
final class BreakCoordinator: ObservableObject {
    /// 调度引擎（纯逻辑）
    @Published private(set) var scheduler: BreakScheduler

    /// 当前设置。设置窗口直接绑定到这里，一改就自动保存并通知引擎。
    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            SettingsStore.save(settings)
            scheduler.updateSettings(settings, now: Date())
            if settings.shortcuts != oldValue.shortcuts, !isRecordingShortcut {
                registerShortcuts()
            }
            let macCalendarNow = settings.followCalendar && settings.calendarSource == .mac
            let macCalendarBefore = oldValue.followCalendar && oldValue.calendarSource == .mac
            if macCalendarNow && !macCalendarBefore {
                enableCalendar()
            }
            onUpdate?()
            kickTick()
        }
    }

    /// 状态变化后回调，用来刷新菜单栏
    var onUpdate: (() -> Void)?

    /// 注册失败（被其他 App 或系统占用）的快捷键
    @Published private(set) var shortcutConflicts: Set<ShortcutAction> = []

    /// 设置里正在录制快捷键时暂时注销所有快捷键，免得按下已有组合时触发操作
    var isRecordingShortcut = false {
        didSet {
            guard isRecordingShortcut != oldValue else { return }
            if isRecordingShortcut { hotkeys.unregisterAll() } else { registerShortcuts() }
        }
    }

    /// 休息统计（统计页直接读它）
    @Published var stats = StatsRecorder(days: StatsStore.load())
    /// 上一次保存统计的时间；连续工作时长每分钟存一次，其他变化立即存
    private var statsSavedAt = Date.distantPast
    /// 统计有没写盘的变化
    private var statsDirty = false

    /// 读取系统日历（设置页也用它列出日历）
    let calendarService = CalendarService()
    /// 钉钉日历（OAuth 登录 + 官方 MCP）
    let dingTalk = DingTalkCalendar()
    /// 正在进行的日程标题（不在日程中时为 nil）
    private(set) var currentEventTitle: String?

    /// 当前在前台的指定 App 名字（不是指定 App 时为 nil）
    private(set) var activeFocusAppName: String?

    /// 休息正在被推迟的原因，用于菜单栏和设置窗口显示，如「全屏」「Keynote」
    var deferralReason: String? {
        guard scheduler.isDeferringBreak else { return nil }
        return scheduler.isFullscreen ? "全屏" : activeFocusAppName
    }

    private let systemMonitor = SystemStateMonitor()
    private let microphone = MicrophoneWatcher()
    private let fullscreenWatcher = FullscreenWatcher()
    private let overlay = BreakOverlayController()
    private let hotkeys = HotkeyManager()
    /// 截图和贴图
    let screenshots = ScreenshotController()
    /// AI 派的提醒
    let reminders = ReminderCoordinator()
    /// 管家（AI 推送的出口、给 AI 的现状）
    private(set) lazy var butler = ButlerCoordinator(reminders: reminders)
    /// 本机 MCP 地址：用户的 AI 通过它接入
    private(set) lazy var localMCP = LocalMCPServer()
    /// 休息背景：照片文件夹、风景渐变（设置页也用它选文件夹）
    let photos = PhotoFolderService()
    /// 正在预览休息画面
    private var isPreviewing = false
    private var suggestions = BreakSuggestions()
    /// 休息开始前的前台 App，休息结束后把焦点还给它
    private var previousApp: NSRunningApplication?
    private var tickTask: Task<Void, Never>?
    /// 离开状态下监听鼠标：人一回来就立刻 tick（放慢后最多要等 10 秒才发现）
    private var returnMonitor: Any?

    init() {
        let settings = SettingsStore.load()
        self.settings = settings
        self.scheduler = BreakScheduler(settings: settings, now: Date())
    }

    /// 启动：开始监听系统状态，并每秒 tick 一次
    func start() {
        systemMonitor.onBecameAway = { [weak self] in
            if self?.statsDirty == true { self?.saveStats() }
            self?.scheduler.enterAway(now: Date())
            self?.onUpdate?()
        }
        systemMonitor.onReturned = { [weak self] in self?.kickTick() }
        systemMonitor.start()
        microphone.onChange = { [weak self] in self?.kickTick() }
        microphone.start()
        fullscreenWatcher.onChange = { [weak self] in self?.kickTick() }
        fullscreenWatcher.start()

        // 系统通知只剩提醒的兜底通知，回调交给 reminders
        NotificationRouter.shared.install()
        NotificationRouter.shared.onReminderReply = { [weak self] reply in self?.reminders.handle(reply) }
        // 休息中、开会、全屏时，强提醒卡片先等一等
        reminders.isBusy = { [weak self] in
            guard let self else { return false }
            if case .onBreak = self.scheduler.state { return true }
            return self.scheduler.isInMeeting || self.scheduler.isFullscreen
        }
        reminders.start()
        butler.situation = { [weak self] in self?.butlerContext() }
        butler.start()
        localMCP.situation = { [weak self] in self?.butlerContext() }
        localMCP.start()

        hotkeys.onAction = { [weak self] action in self?.performShortcut(action) }
        screenshots.onAnnotationStyleChange = { [weak self] tool, style in
            self?.settings.annotationStyles[tool] = style
        }
        registerShortcuts()

        startTickLoop(immediate: false)
    }

    /// 驱动引擎的循环。间隔由引擎决定（nextTickInterval）：快到休息、休息中、推迟中逐秒，其余最慢 15 秒一次。
    /// 允许系统把唤醒和别的程序合并（逐秒时误差 0.2 秒，放慢时 1 秒），省电
    private func startTickLoop(immediate: Bool) {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            if immediate { self?.tick() }
            while !Task.isCancelled {
                let next = self?.scheduler.nextTick(now: Date()) ?? (interval: 1, precise: true)
                do {
                    // 要准时的（休息开始/结束、暂停到点）误差 0.1 秒；只是刷新倒计时的允许 2 秒，让系统合并唤醒
                    try await Task.sleep(for: .seconds(next.interval),
                                         tolerance: next.precise ? .milliseconds(100) : .seconds(2))
                } catch { return }   // 被 kickTick 取消
                self?.tick()
            }
        }
    }

    /// 状态可能变了（用户操作、开会、切 App、醒来、回到电脑前）：立刻 tick 一次，并按新状态重新安排间隔
    private func kickTick() {
        startTickLoop(immediate: true)
    }

    /// 离开时装上鼠标监听，回来后拆掉。全局鼠标监听不需要辅助功能权限；键盘需要，所以只听鼠标
    private func updateReturnMonitor() {
        let away: Bool = if case .away = scheduler.state { true } else { false }
        if away, returnMonitor == nil {
            returnMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.removeReturnMonitor()
                    self?.kickTick()
                }
            }
        } else if !away {
            removeReturnMonitor()
        }
    }

    private func removeReturnMonitor() {
        if let monitor = returnMonitor { NSEvent.removeMonitor(monitor) }
        returnMonitor = nil
    }

    private func tick() {
        // 关闭会议检测时不去查麦克风，省点开销
        let micInUse = settings.postponeDuringMeetings && microphone.inUse
        // 全屏只在「快要休息或正在推迟」时才需要精确，其余时候靠切 App / 切桌面事件更新，30 秒兜底一次
        let soon = scheduler.isDeferringBreak
            || (scheduler.nextBreakStart(now: Date()).map { $0.date.timeIntervalSinceNow < 90 } ?? false)
        let fullscreen = settings.postponeDuringFullscreen
            && fullscreenWatcher.current(now: Date(), interval: soon ? 2 : 30)
        activeFocusAppName = frontmostFocusAppName()
        let now = Date()
        let calendarEvents: [CalendarEvent] = switch (settings.followCalendar, settings.calendarSource) {
        case (false, _): []
        case (true, .mac): calendarService.events(now: now, calendarIDs: settings.calendarIDs)
        case (true, .dingtalk): dingTalk.events(now: now)
        }
        currentEventTitle = calendarEvents.first { $0.interval.contains(now) && $0.interval.end > now }?.title
        let events = scheduler.tick(now: now,
                                    idleSeconds: IdleMonitor.secondsSinceLastInput(),
                                    systemAway: systemMonitor.isAway,
                                    inMeeting: micInUse,
                                    fullscreen: fullscreen,
                                    focusApp: activeFocusAppName != nil,
                                    calendarEvents: calendarEvents.map(\.interval))
        handle(events)
        if case .running = scheduler.state, !scheduler.isInMeeting { butler.userIsActive(now: now) }
        updateReturnMonitor()
        let isWorking: Bool = if case .running = scheduler.state { true } else { false }
        let before = stats.days
        stats.tick(now: now, isWorking: isWorking)
        if stats.days != before { statsDirty = true }
        // 「最长连续工作」这类小变化攒着，最多 15 分钟写一次盘（有休息事件、睡眠、退出时会立即写）
        if statsDirty, now.timeIntervalSince(statsSavedAt) >= 15 * 60 { saveStats(now: now) }
        onUpdate?()
    }

    private func saveStats(now: Date = Date()) {
        StatsStore.save(stats.days)
        statsSavedAt = now
        statsDirty = false
    }

    /// 打开日历排程：请求日历权限；第一次打开时默认勾选常用日历
    private func enableCalendar() {
        Task {
            guard await calendarService.requestAccess() else { return }
            if settings.calendarIDs.isEmpty {
                settings.calendarIDs = calendarService.defaultCalendarIDs
            }
        }
    }

    /// 前台 App 如果在「指定 App」列表里，返回它的名字
    private func frontmostFocusAppName() -> String? {
        guard settings.postponeDuringFocusApps,
              let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        else { return nil }
        return settings.focusApps.first { $0.bundleID == bundleID }?.name
    }

    // MARK: - 菜单 / 遮罩上的操作

    func startBreakNow(_ kind: BreakKind) { apply { $0.startBreakNow(kind, now: $1) } }
    func postpone() { apply { $0.postpone(now: $1) } }
    func skip() { apply { $0.skip(now: $1) } }
    func pause(until date: Date?) { apply { $0.pause(until: date, now: $1) } }
    func resetTimers() { apply { $0.resetTimers(now: $1) } }

    func resume() {
        scheduler.resume(now: Date())
        onUpdate?()
        kickTick()
    }

    /// 给 AI 看的现状（只在 AI 调 get_context 时生成）
    private func butlerContext(now: Date = Date()) -> ButlerContext {
        let state: String
        var awayMinutes: Int?
        switch scheduler.state {
        case .running: state = scheduler.isInMeeting ? "开会中" : "在电脑前"
        case .away(let since):
            state = "离开了"
            awayMinutes = Int(now.timeIntervalSince(since) / 60)
        case .onBreak: state = "休息中"
        case .paused: state = "暂停提醒中"
        }
        let today = stats.day(for: now)
        var events: [ButlerContext.Event]?
        if settings.followCalendar {
            let all: [CalendarEvent] = settings.calendarSource == .mac
                ? calendarService.events(now: now, calendarIDs: settings.calendarIDs)
                : dingTalk.events(now: now)
            events = all.filter { $0.interval.end > now && Calendar.current.isDate($0.interval.start, inSameDayAs: now) }
                .map { .init(title: $0.title, start: TimeText.hourMinute($0.interval.start), end: TimeText.hourMinute($0.interval.end)) }
        }
        return ButlerContext(generatedAt: now, state: state, awayMinutes: awayMinutes,
                             workingStretchMinutes: Int(stats.currentStretch(now: now) / 60),
                             firstActiveToday: butler.firstActiveToday(now: now),
                             breaksCompletedToday: today.completed + today.naturalBreaks,
                             breaksSkippedToday: today.skipped, todayEvents: events)
    }

    /// 退出前把没写盘的统计存下来
    func flush() {
        if statsDirty { saveStats() }
    }

    func restoreDefaults() {
        settings = .default
    }

    /// 开机启动的状态由系统保存，这里只是转发
    var launchAtLoginEnabled: Bool {
        get { LaunchAtLogin.isEnabled }
        set {
            objectWillChange.send()
            LaunchAtLogin.setEnabled(newValue)
        }
    }

    private func registerShortcuts() {
        shortcutConflicts = hotkeys.register(settings.shortcuts)
    }

    /// 全局快捷键被按下
    /// 菜单开着时由菜单自己处理过的快捷键（同一次按键系统还会在菜单关掉后再送来一次，要忽略）
    private var handledInMenu: (action: ShortcutAction, at: Date)?

    /// 星期五自己的菜单开着时按了快捷键（见 StatusBarController 的按键检测）
    func performShortcutFromMenu(_ action: ShortcutAction) {
        handledInMenu = (action, Date())
        performShortcut(action, fromMenu: true)
    }

    private func performShortcut(_ action: ShortcutAction, fromMenu: Bool = false) {
        if !fromMenu, let handled = handledInMenu, handled.action == action, Date().timeIntervalSince(handled.at) < 3 {
            handledInMenu = nil
            return
        }
        switch action {
        case .startMicroBreak:
            startBreakNow(.micro)
        case .togglePause:
            if case .paused = scheduler.state { resume() } else { pause(until: nil) }
        case .skipNextBreak:
            // 休息中跳过当前这次，否则跳过下一次
            if case .onBreak = scheduler.state {
                skip()
            } else {
                scheduler.skipUpcoming(now: Date())
                onUpdate?()
                kickTick()
            }
        case .captureScreen:
            // 休息中（含预览休息画面）不截图
            if case .onBreak = scheduler.state { return }
            if isPreviewing { return }
            screenshots.startCapture(settings: settings)
        case .pinClipboard:
            screenshots.pinClipboard(settings: settings)
        }
    }

    /// 预览休息画面 8 秒（设置「外观」页用），点「跳过」或按时间自动关闭
    func previewOverlay() {
        if case .onBreak = scheduler.state { return }
        screenshots.cancel()
        let now = Date()
        let content = BreakOverlayContent(
            title: "预览",
            suggestion: suggestions.next(for: .micro),
            startedAt: now,
            endsAt: now + 8,
            postponeMinutes: 0,
            canPostpone: false,
            canSkip: true,
            background: photos.background(for: settings, maxPixelSize: Self.largestScreenPixelSize)
        )
        isPreviewing = true
        overlay.show(content, onPostpone: {}, onSkip: { [weak self] in self?.endPreview() })
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            self?.endPreview()
        }
    }

    private func endPreview() {
        guard isPreviewing else { return }
        isPreviewing = false
        overlay.hide()
    }

    /// 最大那块屏幕的像素尺寸，照片按它缩小载入
    private static var largestScreenPixelSize: CGFloat {
        NSScreen.screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }.max() ?? 3000
    }

    /// 对引擎执行一个操作，然后处理它返回的事件
    private func apply(_ action: (inout BreakScheduler, Date) -> [SchedulerEvent]) {
        let events = action(&scheduler, Date())
        handle(events)
        onUpdate?()
        kickTick()
    }

    // MARK: - 处理引擎事件

    private func handle(_ events: [SchedulerEvent]) {
        let now = Date()
        for event in events { stats.record(event, now: now) }
        if !events.isEmpty { saveStats(now: now) }
        for event in events {
            switch event {
            case .breakStarted(let session):
                showOverlay(for: session)
            case .breakEnded:
                overlay.hide()
                previousApp?.activate()
                previousApp = nil
            case .naturalBreakDetected, .pauseEnded:
                break   // 菜单栏会在 onUpdate 里自动刷新
            }
        }
    }

    private func showOverlay(for session: BreakSession) {
        // 正在截图时休息开始：先取消截图，免得框选窗口和休息遮罩叠在一起
        screenshots.cancel()
        // 记住当前前台 App（排除自己，比如设置窗口开着时）
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }

        let content = BreakOverlayContent(
            title: session.kind.displayName,
            suggestion: suggestions.next(for: session.kind),
            startedAt: session.startedAt,
            endsAt: session.endsAt,
            postponeMinutes: Int((settings[session.kind].postponeDuration / 60).rounded()),
            canPostpone: scheduler.canPostponeCurrentBreak,
            canSkip: scheduler.canSkipCurrentBreak,
            background: photos.background(for: settings, maxPixelSize: Self.largestScreenPixelSize)
        )
        isPreviewing = false
        overlay.show(content,
                     onPostpone: { [weak self] in self?.postpone() },
                     onSkip: { [weak self] in self?.skip() })
    }
}
