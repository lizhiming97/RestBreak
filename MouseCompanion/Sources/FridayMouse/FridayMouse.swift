// CC BY-NC 4.0. Mos-derived optional component, hosted by Friday.
// 没有自己的窗口和菜单：设置在星期五「设置 › 鼠标」里，经 App Group 的 config.json 传过来；
// 运行状态写回 status.json 给星期五显示。星期五退出、或用户关闭增强时，本组件随即退出。
import AppKit
import MosScrollCore

@MainActor
final class MouseModel: NSObject {
    private(set) var configuration = SharedStore.readConfiguration()
    private let engine = ScrollEngine()
    private var suspended: Set<String> = []
    private var observesSystem = false
    private var lastStatus: MouseStatus?

    override init() {
        super.init()
        // 引擎自己停下（监听被系统暂停且恢复失败）时，按权限情况告诉星期五。
        engine.onStatus = { [weak self] text in
            guard let self, !self.engine.running, self.configuration.enabled else { return }
            self.report(AXIsProcessTrusted() ? "failed" : "permission", text)
        }
    }

    func startObserving() {
        guard !observesSystem else { return }
        observesSystem = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            center.addObserver(self, selector: #selector(suspend(_:)), name: name, object: nil)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            center.addObserver(self, selector: #selector(resume(_:)), name: name, object: nil)
        }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            center.addObserver(self, selector: #selector(cancelMotion), name: name, object: nil)
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(self, selector: #selector(applicationsChanged), name: name, object: nil)
        }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(suspend(_:)), name: .init("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(resume(_:)), name: .init("com.apple.screenIsUnlocked"), object: nil)
        // 辅助功能授权变化时系统发这条通知（代替定时检查）：撤销立即停，刚授权自动开启，不用再点重试。
        distributed.addObserver(self, selector: #selector(accessibilityChanged), name: .init("com.apple.accessibility.api"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // 星期五改了设置：Darwin 通知不能带内容，转到主线程后重新读 config.json。
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            DispatchQueue.main.async { NotificationCenter.default.post(name: .mouseConfigChanged, object: nil) }
        }, SharedStore.configChanged as CFString, nil, .deliverImmediately)
        NotificationCenter.default.addObserver(self, selector: #selector(configChanged), name: .mouseConfigChanged, object: nil)
    }

    func apply() {
        engine.update(configuration)
        guard configuration.enabled else { report("off", "已关闭 · 使用系统原生滚动"); return }
        guard suspended.isEmpty else { engine.stop(); report("paused", "已暂停 · 解锁或唤醒后自动恢复"); return }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.caldis.Mos").isEmpty,
              NSRunningApplication.runningApplications(withBundleIdentifier: "com.caldis.Mos.debug").isEmpty else {
            engine.stop()
            report("mos", "检测到 Mos 正在运行。退出 Mos 后会自动接管，避免重复处理滚轮。")
            return
        }
        if engine.start() { report("running", "已开启 · 普通鼠标滚轮增强") }
        else if !AXIsProcessTrusted() { report("permission", "需要给「星期五鼠标」打开辅助功能权限。") }
        else { report("failed", "无法接管滚轮，原生滚动可用。点「重试」再试一次。") }
    }

    func shutdown() {
        engine.stop()
        report("off", "已关闭 · 使用系统原生滚动")
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        observesSystem = false
    }

    func authorize() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// 状态没变就不写盘、不通知。
    private func report(_ state: String, _ message: String) {
        let status = MouseStatus(state: state, message: message)
        guard status != lastStatus else { return }
        lastStatus = status
        SharedStore.write(status)
    }

    @objc private func configChanged() {
        configuration = SharedStore.readConfiguration()
        apply()
        // 用户在星期五里关掉增强：组件没有别的事，直接退出，不占资源。
        if !configuration.enabled { NSApp.terminate(nil) }
    }
    @objc private func cancelMotion() { engine.cancelMotion() }
    @objc private func screenChanged() { engine.stop(); apply() }
    @objc private func applicationsChanged() { apply() }
    @objc private func accessibilityChanged() {
        // 通知先于授权结果更新，稍等再读。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.observesSystem else { return }
            self.engine.stop(); self.apply()
        }
    }
    @objc private func suspend(_ notice: Notification) {
        suspended.insert(reason(notice.name)); apply()
    }
    @objc private func resume(_ notice: Notification) {
        suspended.remove(reason(notice.name)); apply()
    }
    private func reason(_ name: Notification.Name) -> String {
        switch name {
        case NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification: "sleep"
        case NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification: "session"
        default: "lock"
        }
    }
}

extension Notification.Name {
    static let mouseConfigChanged = Notification.Name("FridayMouse.configChanged")
}

@MainActor
final class MouseDelegate: NSObject, NSApplicationDelegate {
    let model = MouseModel()
    private var host: NSRunningApplication?
    private var hostObservation: NSKeyValueObservation?
    /// 只为长截图自动滚动而启动（没开鼠标增强）时：一段时间没收到滚动命令就退出
    private var idleQuit: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0.processIdentifier != getpid() }) else { NSApp.terminate(nil); return }
        // 星期五用网址拉起（长截图自动滚动）：没开增强也先留下，空闲一会儿再退出
        let launchedByURL = (notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool) == false
        if !model.configuration.enabled, launchedByURL, watchHost() {
            scheduleIdleQuit()
            return
        }
        // 只为星期五服务：没开增强、或星期五没在运行（比如直接双击了组件），就不留下。
        guard model.configuration.enabled, watchHost() else {
            SharedStore.write(MouseStatus(state: "off", message: "已关闭 · 使用系统原生滚动"))
            NSApp.terminate(nil); return
        }
        model.startObserving()
        model.apply()
    }

    /// 星期五发来的命令：launch 重新应用设置（也用作「重试」），authorize 弹出系统授权提示。
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, url.scheme == "friday-mouse" else { return }
        switch url.host {
        case "authorize": model.authorize()
        case "launch": model.apply()
        case "scroll":
            // 长截图自动滚动：往 (x, y)（全局坐标，左上角原点）下面那个窗口往下滚 dy 点（负数往上）
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func number(_ name: String) -> Double? { query.first { $0.name == name }?.value.flatMap(Double.init) }
            guard let x = number("x"), let y = number("y"), let dy = number("dy") else { return }
            if !model.configuration.enabled { scheduleIdleQuit() }
            if !AutoScroll.post(at: CGPoint(x: x, y: y), down: dy) {
                // 没有辅助功能权限：告诉星期五改回手动滚动
                CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                     CFNotificationName(AutoScroll.deniedNotice as CFString), nil, nil, true)
            }
        default: break
        }
    }

    @discardableResult
    private func watchHost() -> Bool {
        if hostObservation != nil { return true }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.lizhiming.RestBreak").first else { return false }
        host = app
        hostObservation = app.observe(\.isTerminated, options: [.initial, .new]) { application, _ in
            guard application.isTerminated else { return }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return true
    }

    private func scheduleIdleQuit() {
        idleQuit?.cancel()
        idleQuit = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, let self, !self.model.configuration.enabled else { return }
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }
}

/// 长截图的自动滚动：替星期五发滚动事件（星期五在沙盒里不能给别的应用发事件）。
/// 思路参考 Snow Shot：找到选区中间那个窗口，把滚动事件**直接发给它的进程**并写上窗口内的位置，
/// 系统就不会去挪光标（只设屏幕位置再发，系统会把光标拽过去，2026-11-09 实测）。
/// 发的是触控板那种连续的像素滚动：负数往下（实测），不受自然滚动和鼠标增强反转影响，应用也不再叠加动画。
@MainActor
enum AutoScroll {
    static let deniedNotice = "com.lizhiming.RestBreak.mouse.autoscroll.denied"
    /// 一次命令拆成 4 小段、每 50 毫秒一段：星期五每 0.2 秒发一次命令，连起来是匀速往下走
    static let pieces = 4

    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    /// CoreGraphics 导出了、但公开 SDK 里没有声明的函数：给发往进程的事件写上窗口内位置。找不到就不发（绝不挪光标）
    private static let setWindowLocation: SetWindowLocation? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else { return nil }
        return unsafeBitCast(symbol, to: SetWindowLocation.self)
    }()

    private struct Target {
        let pid: pid_t
        let windowNumber: Int
        let bounds: CGRect   // 全局坐标，左上角原点
    }

    /// point 下面最上层的普通窗口（跳过星期五和本组件自己的窗口，比如长截图的描边和面板）
    private static func target(at point: CGPoint) -> Target? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let skipped = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.lizhiming.RestBreak")
            .map(\.processIdentifier) + [getpid()])
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, !skipped.contains(pid),
                  let number = info[kCGWindowNumber as String] as? Int,
                  let dict = info[kCGWindowBounds as String] as! CFDictionary?,
                  let bounds = CGRect(dictionaryRepresentation: dict), bounds.contains(point),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            return Target(pid: pid, windowNumber: number, bounds: bounds)
        }
        return nil
    }

    /// 返回 false 表示没权限或找不到窗口（星期五改回手动滚动）
    static func post(at point: CGPoint, down distance: Double) -> Bool {
        guard AXIsProcessTrusted(), let setWindowLocation, let target = target(at: point) else { return false }
        let total = Int(distance.rounded())
        guard total != 0 else { return true }
        Task { @MainActor in
            var sent = 0
            for index in 1...pieces {
                let goal = total * index / pieces
                let delta = goal - sent
                sent = goal
                if delta != 0 { send(delta, to: target, at: point, setWindowLocation: setWindowLocation) }
                if index < pieces { try? await Task.sleep(for: .milliseconds(50)) }
            }
        }
        return true
    }

    private static func send(_ delta: Int, to target: Target, at point: CGPoint, setWindowLocation: SetWindowLocation) {
        // 借一个带目标窗口编号的「鼠标移动」事件当载体，改成滚动事件（这样事件里的窗口字段都是对的）
        guard let carrier = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: target.windowNumber, context: nil, eventNumber: 0,
                                               clickCount: 0, pressure: 0)?.cgEvent?.copy(),
              let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: Int32(-delta), wheel2: 0, wheel3: 0) else { return }
        wheel.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        carrier.type = .scrollWheel
        for field: CGEventField in [.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2,
                                    .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2,
                                    .scrollWheelEventIsContinuous] {
            carrier.setIntegerValueField(field, value: wheel.getIntegerValueField(field))
        }
        for field: CGEventField in [.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2] {
            carrier.setDoubleValueField(field, value: wheel.getDoubleValueField(field))
        }
        // 带上组件标记，鼠标增强不会再处理一遍
        carrier.setIntegerValueField(.eventSourceUserData, value: ScrollEventAdapter.marker)
        carrier.location = point
        setWindowLocation(carrier, CGPoint(x: point.x - target.bounds.minX, y: point.y - target.bounds.minY))
        carrier.postToPid(target.pid)
    }
}

@main
struct FridayMouseApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = MouseDelegate()
        // 没有 Dock 图标；也不建菜单栏图标和窗口。
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
