import AppKit
import CoreAudio
import CoreGraphics
import ServiceManagement

/// 检测用户闲置了多久（多久没碰键盘鼠标）。沙盒内可用，不需要辅助功能权限。
enum IdleMonitor {
    static func secondsSinceLastInput() -> TimeInterval {
        // kCGAnyInputEventType 在 C 里是 ~0，Swift 没有直接导出这个常量
        if let anyInput = CGEventType(rawValue: ~0) {
            return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        }
        // 拿不到时，退回到多个常见事件类型里取最小值
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                    .leftMouseDragged, .scrollWheel, .keyDown, .flagsChanged]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
    }
}

/// 检测麦克风是否正被某个 App 使用（用来判断「在开会」）。
/// 只读取设备的运行状态，不会录音，所以不需要麦克风权限。
/// 腾讯会议、飞书、钉钉、Zoom、Teams、微信语音等都能识别。
enum MicrophoneMonitor {
    static func isMicrophoneInUse() -> Bool {
        deviceIDs(withStreamsIn: kAudioObjectPropertyScopeInput).contains(where: isRunningSomewhere)
    }

    /// 列出所有在指定方向（输入 = 麦克风，输出 = 扬声器）有音频通道的设备
    static func deviceIDs(withStreamsIn scope: AudioObjectPropertyScope) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.filter { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: scope,
                                                     mElement: kAudioObjectPropertyElementMain)
            var streamsSize: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamsSize) == noErr && streamsSize > 0
        }
    }

    /// 这个设备是否正被任意一个 App 使用
    static func isRunningSomewhere(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &running) == noErr && running != 0
    }
}

/// 检测前台 App 是否全屏（看视频、做演示、全屏浏览器等）。
/// 只读取窗口的大小和所属 App，不读窗口内容和标题，所以不需要录屏权限。
@MainActor
enum FullscreenMonitor {
    static func isFrontmostAppFullscreen() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]]
        else { return false }

        let screenSizes = fullscreenSizes()
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == front.processIdentifier,
                  (window[kCGWindowLayer as String] as? Int) == 0,   // 普通 App 窗口层
                  let boundsDict = window[kCGWindowBounds as String] as! CFDictionary?,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { return false }
            return screenSizes.contains(bounds.size)
        }
    }

    /// 全屏窗口可能的尺寸：整块屏幕；带刘海的屏幕上全屏 App 默认在刘海下方，高度要减掉刘海区域
    private static func fullscreenSizes() -> [CGSize] {
        NSScreen.screens.flatMap { screen -> [CGSize] in
            let full = screen.frame.size
            let notch = screen.safeAreaInsets.top
            return notch > 0 ? [full, CGSize(width: full.width, height: full.height - notch)] : [full]
        }
    }
}

/// 监听系统睡眠/唤醒、锁屏/解锁。
/// 睡眠和锁屏分开记录，两者都解除才算「回来了」。
@MainActor
final class SystemStateMonitor: NSObject {
    private(set) var isSleeping = false
    private(set) var isLocked = false
    var isAway: Bool { isSleeping || isLocked }

    /// 刚进入睡眠或锁屏时回调
    var onBecameAway: (() -> Void)?
    /// 醒来或解锁时回调
    var onReturned: (() -> Void)?

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep),
                              name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake),
                              name: NSWorkspace.didWakeNotification, object: nil)

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(screenLocked),
                                name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(screenUnlocked),
                                name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    @objc private func willSleep(_ notification: Notification) {
        isSleeping = true
        onBecameAway?()
    }

    @objc private func didWake(_ notification: Notification) {
        isSleeping = false
        onReturned?()
    }

    @objc private func screenLocked(_ notification: Notification) {
        isLocked = true
        onBecameAway?()
    }

    @objc private func screenUnlocked(_ notification: Notification) {
        isLocked = false
        onReturned?()
    }
}

/// 开机自动启动（macOS 13+ 的 SMAppService，沙盒内可用）
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("设置开机启动失败：\(error.localizedDescription)")
        }
    }
}

/// 休息统计存成 JSON 文件：~/Library/Containers/com.lizhiming.RestBreak/Data/Library/Application Support/RestBreak/stats.json
enum StatsStore {
    private static var fileURL: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return support.appendingPathComponent("RestBreak", isDirectory: true).appendingPathComponent("stats.json")
    }

    static func load() -> [String: DayStats] {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let days = try? JSONDecoder().decode([String: DayStats].self, from: data) else { return [:] }
        return days
    }

    static func save(_ days: [String: DayStats]) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(days) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// 把设置以 JSON 形式存进 UserDefaults
enum SettingsStore {
    private static let key = "settings.v1"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return .default }   // 没存过或格式不对，就用默认值
        return settings
    }

    static func save(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// 麦克风占用状态：改为「系统通知我」而不是每秒去问（每次查询要和 coreaudiod 进程通信，约 0.5 毫秒，
/// 还会把它也唤醒）。监听设备列表变化和每个输入设备的「是否在用」，结果缓存在 inUse 里。
@MainActor
final class MicrophoneWatcher {
    private(set) var inUse = false
    /// 开会状态变了（用来立刻唤醒放慢的 tick）
    var onChange: (() -> Void)?
    private var watched: [AudioObjectID] = []
    private let queue = DispatchQueue.main
    private lazy var deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.rewatch() }
    }
    private lazy var runningListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.refresh() }
    }
    private static var devicesAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                                  mElement: kAudioObjectPropertyElementMain)
    private static var runningAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                                  mElement: kAudioObjectPropertyElementMain)

    func start() {
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.devicesAddress, queue, deviceListener)
        rewatch()
    }

    /// 插拔耳机、蓝牙连上断开时，重新挂一遍每个输入设备的监听
    private func rewatch() {
        for id in watched { AudioObjectRemovePropertyListenerBlock(id, &Self.runningAddress, queue, runningListener) }
        watched = MicrophoneMonitor.deviceIDs(withStreamsIn: kAudioObjectPropertyScopeInput)
        for id in watched { AudioObjectAddPropertyListenerBlock(id, &Self.runningAddress, queue, runningListener) }
        refresh()
    }

    private func refresh() {
        let now = watched.contains(where: MicrophoneMonitor.isRunningSomewhere)
        guard now != inUse else { return }
        inUse = now
        onChange?()
    }
}

/// 全屏状态缓存：CGWindowListCopyWindowInfo 要问 WindowServer 要整张窗口表（约 0.5 毫秒），不每秒调用。
/// 进入/退出全屏一定伴随切 App 或切桌面空间，所以只在这些事件发生时重新判断；
/// 另外每 needsCheck 秒兜底查一次（由调用方决定：只有快要休息或正在推迟时才需要）。
@MainActor
final class FullscreenWatcher: NSObject {
    private(set) var isFullscreen = false
    private var dirty = true
    private var checkedAt = Date.distantPast
    /// 切了 App / 桌面空间 / 屏幕（用来立刻唤醒放慢的 tick）
    var onChange: (() -> Void)?

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            center.addObserver(self, selector: #selector(markDirty), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(markDirty),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func markDirty() {
        dirty = true
        onChange?()
    }

    /// interval：没有事件时最多多久兜底查一次
    func current(now: Date, interval: TimeInterval) -> Bool {
        if dirty || now.timeIntervalSince(checkedAt) >= interval {
            // 切桌面空间的动画要一会儿，事件来了之后下一秒再确认一次
            let wasDirty = dirty
            isFullscreen = FullscreenMonitor.isFrontmostAppFullscreen()
            checkedAt = wasDirty ? now.addingTimeInterval(-interval + 1) : now
            dirty = false
        }
        return isFullscreen
    }
}
