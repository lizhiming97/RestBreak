// CC BY-NC 4.0. Standalone Mos-derived optional component.
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MosScrollCore

@MainActor
final class MouseModel: NSObject, ObservableObject {
    @Published var configuration: ScrollConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            if let data = try? JSONEncoder().encode(configuration) { defaults.set(data, forKey: "scroll.v1") }
            apply()
        }
    }
    @Published var status = "尚未开启"
    @Published var active = false
    private let defaults = UserDefaults.standard
    private let engine = ScrollEngine()
    private var suspended: Set<String> = []
    private var observesSystem = false
    var onUpdate: (() -> Void)?

    override init() {
        var settings = UserDefaults.standard.data(forKey: "scroll.v1")
            .flatMap { try? JSONDecoder().decode(ScrollConfiguration.self, from: $0) } ?? ScrollConfiguration()
        settings.normalize()
        configuration = settings
        super.init()
        engine.onStatus = { [weak self] text in self?.status = text }
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
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func apply() {
        active = false
        engine.update(configuration)
        guard configuration.enabled else { status = "已关闭 · 使用系统原生滚动"; onUpdate?(); return }
        guard suspended.isEmpty else { engine.stop(); status = "已暂停 · 返回后自动恢复"; onUpdate?(); return }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.caldis.Mos").isEmpty,
              NSRunningApplication.runningApplications(withBundleIdentifier: "com.caldis.Mos.debug").isEmpty else {
            engine.stop()
            status = "检测到 Mos 正在运行。请先退出 Mos，再点击重试，避免重复处理滚轮。"
            onUpdate?(); return
        }
        active = engine.start()
        if active { status = "已开启 · 普通鼠标滚轮增强" }
        onUpdate?()
    }

    func shutdown() {
        engine.stop()
        active = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        observesSystem = false
    }

    func authorize() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
    @objc private func cancelMotion() { engine.cancelMotion() }
    @objc private func screenChanged() { engine.stop(); apply() }
    @objc private func applicationsChanged() { apply() }
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

@MainActor
final class MouseDelegate: NSObject, NSApplicationDelegate {
    let model = MouseModel()
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var host: NSRunningApplication?
    private var hostObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0.processIdentifier != getpid() }) else { NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--preview") { showSettings(); return }
        model.onUpdate = { [weak self] in self?.updateMenu() }
        model.startObserving()
        model.apply()
        watchHost()
        let defaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        if defaultLaunch { showSettings() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, url.scheme == "friday-mouse", ["settings", "launch"].contains(url.host ?? "") else { return }
        watchHost()
        if url.host == "settings" { showSettings() }
        else if !model.configuration.enabled { NSApp.terminate(nil) }
    }

    private func watchHost() {
        guard hostObservation == nil,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.lizhiming.RestBreak").first else {
            updateMenu(); return
        }
        host = app
        hostObservation = app.observe(\.isTerminated, options: [.initial, .new]) { application, _ in
            guard application.isTerminated else { return }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        updateMenu()
    }

    private func updateMenu() {
        // 星期五托管时不增加菜单栏图标；单独运行保留入口，随时可关闭。
        if host != nil {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil; return
        }
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            statusItem?.button?.image = NSImage(systemSymbolName: "computermouse", accessibilityDescription: "星期五鼠标")
        }
        let menu = NSMenu()
        for (title, action) in [("鼠标设置…", #selector(showSettings)), ("退出鼠标增强", #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        statusItem?.menu = menu
    }

    @objc func showSettings() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 630),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "星期五 · 鼠标"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MouseSettings(model: model))
            window.center(); self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }
}

struct MouseSettings: View {
    @ObservedObject var model: MouseModel
    var body: some View {
        Form {
            Section {
                Toggle("鼠标增强", isOn: $model.configuration.enabled).tint(.blue)
                Text(model.status).font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("授权辅助功能") { model.authorize() }
                    Button("重试") { model.apply() }
                }
            } header: { Text("普通鼠标滚轮") }
            Section("滚动方向") {
                Toggle("反转上下滚动", isOn: $model.configuration.reverseVertical)
                Toggle("反转左右滚动", isOn: $model.configuration.reverseHorizontal)
                Text("相对于 macOS 当前设置反转；触控板、Magic Mouse 和连续滚动事件保持原样。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("平滑滚动") {
                Toggle("平滑上下滚动", isOn: $model.configuration.smoothVertical)
                Toggle("平滑左右滚动", isOn: $model.configuration.smoothHorizontal)
                HStack { Text("速度"); Slider(value: $model.configuration.speed, in: 0.5...5); Text(model.configuration.speed, format: .number.precision(.fractionLength(2))).monospacedDigit().frame(width: 42) }
                HStack { Text("平滑程度"); Slider(value: $model.configuration.duration, in: 1...5); Text(model.configuration.duration, format: .number.precision(.fractionLength(2))).monospacedDigit().frame(width: 42) }
                HStack { Text("最小步长"); Slider(value: $model.configuration.step, in: 1...100); Text(model.configuration.step, format: .number.precision(.fractionLength(1))).monospacedDigit().frame(width: 42) }
                Button("恢复 Mos 默认手感") {
                    model.configuration.speed = 2.7; model.configuration.duration = 4.35; model.configuration.step = 33.6
                }
            }
            Section("这些应用使用原生滚动") {
                ForEach(model.configuration.excludedApps, id: \.self) { id in
                    HStack {
                        Text(NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.deletingPathExtension().lastPathComponent ?? id)
                        Spacer()
                        Button("移除") { model.configuration.excludedApps.removeAll { $0 == id } }
                    }
                }
                Button("添加应用…", action: chooseApplication)
            }
            Section {
                Text("平滑核心源自 Caldis/Mos · CC BY-NC 4.0 · 非商业使用")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Link("Mos 项目", destination: URL(string: "https://github.com/Caldis/Mos")!)
                    Link("许可", destination: URL(string: "https://creativecommons.org/licenses/by-nc/4.0/")!)
                }.font(.caption)
            }
        }.formStyle(.grouped).toggleStyle(MouseSwitchStyle()).tint(.blue).frame(width: 550, height: 630)
    }
    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier, !model.configuration.excludedApps.contains(id) else { return }
        model.configuration.excludedApps.append(id)
    }
}

/// 在非激活辅助窗口中也明确区分开/关，避免系统开关都呈灰色而难以判断。
private struct MouseSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            Button { configuration.isOn.toggle() } label: {
                HStack(spacing: 7) {
                    Text(configuration.isOn ? "开" : "关").font(.caption)
                        .foregroundStyle(configuration.isOn ? Color.blue : Color.secondary)
                    ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                        Capsule().fill(configuration.isOn ? Color.blue : Color.gray.opacity(0.3))
                        Circle().fill(.white).padding(2)
                            .frame(width: 22, height: 22)
                    }.frame(width: 38, height: 22)
                }
            }.buttonStyle(.plain)
                .accessibilityLabel(configuration.isOn ? "已开启，点击关闭" : "已关闭，点击开启")
        }.accessibilityElement(children: .combine)
    }
}

@main
struct FridayMouseApp {
    static func main() {
        let app = NSApplication.shared
        if let flag = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > flag + 1 {
            // 独立渲染路径：不调用 startObserving/apply，不安装 tap、不修改用户的偏好。
            app.setActivationPolicy(.prohibited)
            let view = NSHostingView(rootView: MouseSettings(model: MouseModel()).environment(\.controlActiveState, .key))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 630),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            view.sizingOptions = []
            window.contentView = view
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                do {
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
                } catch { fputs("Preview failed: \(error)\n", stderr); exit(1) }
            } else { exit(1) }
            window.orderOut(nil)
            return
        }
        let delegate = MouseDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
