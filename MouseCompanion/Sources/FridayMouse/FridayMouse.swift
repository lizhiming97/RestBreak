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

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0.processIdentifier != getpid() }) else { NSApp.terminate(nil); return }
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

    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }
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
