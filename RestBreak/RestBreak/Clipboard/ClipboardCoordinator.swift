import AppKit

struct ClipboardPreferences: Codable, Equatable {
    var enabled = false
    var maxItems = 200
    var maxMegabytes = 64
    var excludedApps: [String] = []

    mutating func normalize() {
        maxItems = min(500, max(1, maxItems))
        maxMegabytes = min(128, max(8, maxMegabytes))
        excludedApps = Array(Set(excludedApps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })).sorted()
    }
}

@MainActor
final class ClipboardCoordinator: NSObject, ObservableObject {
    @Published var preferences: ClipboardPreferences {
        didSet {
            guard oldValue != preferences else { return }
            if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: Self.settingsKey) }
            configure()
        }
    }
    @Published private(set) var paused = false
    @Published private(set) var isRecording = false
    @Published private(set) var message: String?
    let store: ClipboardStore
    let monitor: ClipboardMonitor
    var onOpenSettings: (() -> Void)?
    private let defaults: UserDefaults
    private var panel: ClipboardPanelController?
    private var started = false
    private var suspendedReasons: Set<String> = []
    private var previousApp: NSRunningApplication?
    static let settingsKey = "friday.clipboard.settings.v1"

    init(store: ClipboardStore = ClipboardStore(), monitor: ClipboardMonitor = ClipboardMonitor(),
         defaults: UserDefaults = .standard) {
        self.store = store
        self.monitor = monitor
        self.defaults = defaults
        var settings = defaults.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode(ClipboardPreferences.self, from: $0) } ?? ClipboardPreferences()
        settings.normalize()
        preferences = settings
        super.init()
        monitor.onCapture = { [weak self] result in self?.receive(result) }
    }

    func start() {
        guard !started else { return }
        started = true
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(self, selector: #selector(suspend(_:)), name: name, object: nil)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(self, selector: #selector(resume(_:)), name: name, object: nil)
        }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(suspend(_:)), name: .init("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(resume(_:)), name: .init("com.apple.screenIsUnlocked"), object: nil)
        configure()
    }

    func stop() {
        started = false
        monitor.setRunning(false)
        isRecording = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        panel?.close()
        panel = nil
    }

    func togglePause() {
        paused.toggle()
        reconcile()
    }

    func configure() {
        store.maxItems = preferences.maxItems
        store.maxBytes = preferences.maxMegabytes * 1024 * 1024
        store.enforceLimits()
        monitor.excludedApps = preferences.excludedApps
        monitor.resetBaseline()
        reconcile()
        if preferences.enabled && !store.isLoaded {
            Task { [weak self] in
                guard let self else { return }
                await store.load()
                reconcile()
            }
        }
    }

    private func reconcile() {
        let running = started && preferences.enabled && !paused && suspendedReasons.isEmpty && store.isLoaded
        monitor.setRunning(running)
        isRecording = running
    }

    @objc func suspend(_ notification: Notification) {
        suspendedReasons.insert(reason(notification.name))
        reconcile()
        panel?.close()
        Task { await store.flush() }
    }
    @objc func resume(_ notification: Notification) {
        suspendedReasons.remove(reason(notification.name))
        reconcile()
    }
    private func reason(_ name: Notification.Name) -> String {
        switch name {
        case NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification: "sleep"
        case NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification: "display"
        case NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification: "session"
        default: "lock"
        }
    }

    private func receive(_ result: ClipboardCapture.Result) {
        switch result {
        case .item(let item):
            message = store.add(item) ? nil : "固定内容已占满容量，请取消部分固定或提高容量上限。"
        case .tooLarge: message = "已跳过超过 8 MB 的内容。"
        case .ignored, .changedDuringRead: break
        }
    }

    func show() {
        previousApp = NSWorkspace.shared.frontmostApplication
        if previousApp?.processIdentifier == ProcessInfo.processInfo.processIdentifier { previousApp = nil }
        NSApp.activate()
        if panel == nil { panel = ClipboardPanelController(coordinator: self) }
        panel?.show()
        Task { [weak self] in
            guard let self else { return }
            await store.load()
            reconcile()
        }
    }

    func close() {
        panel?.close()
        panel = nil
    }

    func dismiss() {
        close()
        previousApp?.activate()
    }

    /// 复制是完整可用的基础路径；自动粘贴作为可选动作，权限不足时不影响复制。
    func use(_ id: UUID, plainText: Bool = false, paste: Bool = false) {
        guard let item = store.items.first(where: { $0.id == id }),
              ClipboardCapture.write(item, to: monitor.pasteboard, plainText: plainText) else {
            message = "复制失败，请重试。"
            return
        }
        guard paste else {
            close()
            previousApp?.activate()
            return
        }
        guard AXIsProcessTrusted(), let target = previousApp, !target.isTerminated else {
            message = "已复制。自动粘贴需要辅助功能权限和目标窗口；也可关闭面板后按 ⌘V。"
            return
        }
        close()
        target.activate()
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            // 用户已切到别处时不发送按键，避免向错误窗口粘贴。
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else { return }
            let source = CGEventSource(stateID: .combinedSessionState)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down)
                event?.flags = .maskCommand
                event?.post(tap: .cgSessionEventTap)
            }
        }
    }

    func requestPastePermission() {
        // C 头文件把这个固定键声明为可变全局变量；使用其官方键值以兼容 Swift 6 严格并发。
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func retry() {
        Task {
            if store.isLoaded { await store.flush() } else { await store.load() }
            reconcile()
        }
    }
}
