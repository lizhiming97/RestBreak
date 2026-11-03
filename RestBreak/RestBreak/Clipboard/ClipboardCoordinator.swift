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
        // 读完历史、恢复记录、打开面板时都会走到这里，顺便清掉过期的普通历史。
        store.removeExpired()
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
            store.removeExpired()
            message = store.add(item) ? nil : "固定内容已占满容量，请取消部分固定或提高容量上限。"
        case .tooLarge: message = "已跳过超过 8 MB 的内容。"
        case .ignored, .changedDuringRead: break
        }
    }

    func show() {
        store.removeExpired()
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

    /// 写回系统剪贴板后关闭面板、切回原来的应用，由用户自己按 ⌘V 粘贴。
    func use(_ id: UUID, plainText: Bool = false) {
        guard let item = store.items.first(where: { $0.id == id }),
              ClipboardCapture.write(item, to: monitor.pasteboard, plainText: plainText) else {
            message = "复制失败，请重试。"
            return
        }
        close()
        previousApp?.activate()
    }

    func retry() {
        Task {
            if store.isLoaded { await store.flush() } else { await store.load() }
            reconcile()
        }
    }
}
