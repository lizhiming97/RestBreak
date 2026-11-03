// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import MenuBarShelf

@MainActor
final class LabDelegate: NSObject, NSApplicationDelegate {
    let controller = ShelfController()
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var quitting = false
    /// 观察星期五进程是否结束。星期五是纯菜单栏 App，系统不会为它发 didTerminateApplication 通知。
    private var fridayObservation: NSKeyValueObservation?
    /// KVO 不会持有被观察对象；不保留它，它被释放时注销观察会崩溃。
    private var friday: NSRunningApplication?

    static let fridayBundleID = "com.lizhiming.RestBreak"
    /// 收到过星期五的命令：以后只要星期五在运行，就由星期五的图标做入口。
    private let hostedKey = "MenuBarShelf.HostedByFriday"
    /// 用户启用过收纳：下次由星期五拉起时自动启用。用户点“关闭收纳”才清除。
    static let autoEnableKey = "MenuBarShelf.AutoEnable"

    private var fridayIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.fridayBundleID).isEmpty
    }
    /// 位于另一个 App 的包内（星期五.app/Contents/Helpers/），或星期五发过命令。
    private var isHosted: Bool {
        fridayIsRunning && (Bundle.main.bundleURL.path.contains(".app/Contents/") || UserDefaults.standard.bool(forKey: hostedKey))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !ProcessInfo.processInfo.arguments.contains("--build-info") else {
            print("MenuBarShelfLab 0.2.0 | standalone GPL-3.0 | macOS 14+")
            NSApp.terminate(nil)
            return
        }
        // 专属 bundle ID，不参加星期五的 SingleInstance 协议。
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != getpid() }) {
            NSApp.terminate(nil)
            return
        }
        controller.pinnedBundleIDs = [Self.fridayBundleID]
        UserDefaults.standard.register(defaults: ["NSStatusItem Preferred Position MenuBarShelfLab.Launcher": 0])
        updateLauncher()
        watchFriday()
        // 由 URL 拉起时（星期五）交给 application(_:open:) 决定；用户直接打开组件时显示设置。
        let isDefaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        if isDefaultLaunch {
            if UserDefaults.standard.bool(forKey: Self.autoEnableKey) { enable() }
            if !controller.isEnabled { showSettings() }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, url.scheme == "friday-menubar" else { return }
        UserDefaults.standard.set(true, forKey: hostedKey)
        watchFriday()
        updateLauncher()
        switch url.host {
        case "launch":
            // 星期五启动时在后台拉起：之前启用过就自动启用，否则安静退出，不占菜单栏。
            if UserDefaults.standard.bool(forKey: Self.autoEnableKey) { enable() }
            if !controller.isEnabled && window?.isVisible != true { quitAfterCleanup() }
        case "diagnose":
            controller.writeDiagnostics()
        case "hide", "show", "open", "reveal-all", "refresh", "restore":
            // 星期五菜单里的操作。参数只有窗口编号和按键。
            if !controller.isEnabled, UserDefaults.standard.bool(forKey: Self.autoEnableKey) { enable() }
            guard controller.isEnabled else { showSettings(); return }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let key = query.first { $0.name == "key" }?.value
            let button: CGMouseButton = query.first { $0.name == "button" }?.value == "right" ? .right : .left
            controller.handle(command: url.host ?? "", key: key, button: button)
        case "panel", "toggle":
            if !controller.isEnabled, UserDefaults.standard.bool(forKey: Self.autoEnableKey) { enable() }
            if controller.isEnabled { controller.showShelf(anchorBundleID: isHosted ? Self.fridayBundleID : nil) }
            else { showSettings() }
        default:
            showSettings()
        }
    }

    /// 星期五托管时不创建自己的图标；星期五不在时总要有入口。
    private func updateLauncher() {
        if isHosted {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: 28)
        item.autosaveName = "MenuBarShelfLab.Launcher"
        item.button?.image = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: "菜单栏图标")
        item.button?.toolTip = "菜单栏图标 · 左键选择收起哪些，右键更多"
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    /// 入口随星期五一起消失：收纳也结束，所有图标回到菜单栏。
    private func watchFriday() {
        guard fridayObservation == nil,
              let friday = NSRunningApplication.runningApplications(withBundleIdentifier: Self.fridayBundleID).first else { return }
        self.friday = friday
        fridayObservation = friday.observe(\.isTerminated, options: [.initial, .new]) { [weak self] app, _ in
            guard app.isTerminated else { return }
            Task { @MainActor in
                guard let self, UserDefaults.standard.bool(forKey: self.hostedKey) else { return }
                self.quitAfterCleanup()
            }
        }
    }

    /// 先收尾再退出。不能在 Task 或主队列块里直接 terminate：terminate 会在嵌套循环里等收尾 Task，
    /// 而那个 Task 排在被占住的主队列后面，实测会卡死在 _shouldTerminate。
    private func quitAfterCleanup() {
        guard !quitting else { return }
        quitting = true
        Task {
            await controller.stop()
            NSApp.terminate(nil)   // quitting 已为 true，applicationShouldTerminate 立即放行
        }
    }

    private func enable() {
        controller.start(launcher: statusItem)
        if controller.isEnabled { UserDefaults.standard.set(true, forKey: Self.autoEnableKey) }
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showContextMenu() }
        else if controller.isEnabled { controller.showShelf() }
        else { showSettings() }
    }

    private func showContextMenu() {
        guard let statusItem else { return }
        controller.dismissShelf()
        let menu = NSMenu()
        for (title, action) in [("收纳设置…", #selector(showSettings)), ("放回临时图标", #selector(restore)), ("退出菜单栏收纳", #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = action != #selector(restore) || controller.hasPendingRestore
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func restore() { controller.restoreTemporaryItem() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc func showSettings() {
        controller.dismissShelf()
        if window == nil {
            let content = LabSettings(controller: controller,
                                      enable: { [weak self] in self?.enable() },
                                      disable: { [weak self] in
                                          UserDefaults.standard.set(false, forKey: Self.autoEnableKey)
                                          Task { await self?.controller.stop() }
                                      },
                                      quit: { NSApp.terminate(nil) })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "菜单栏图标"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: content)
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        controller.refresh()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateNow }
        quitting = true
        Task {
            await controller.stop()
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}

struct LabSettings: View {
    @ObservedObject var controller: ShelfController
    let enable: () -> Void
    let disable: () -> Void
    let quit: () -> Void
    @State private var accessibility = false
    @State private var recording = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "menubar.rectangle").font(.system(size: 30)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("让菜单栏轻一点").font(.title2.bold())
                    Text("启用后，在星期五菜单的「菜单栏图标」里选择收起哪些图标。").foregroundStyle(.secondary)
                }
            }
            GroupBox {
                VStack(spacing: 10) {
                    permissionRow("辅助功能", detail: "移动图标、打开原应用菜单", allowed: accessibility) {
                        ShelfPermissions.requestAccessibility()
                        ShelfPermissions.openSettings(screenRecording: false)
                    }
                    Divider()
                    permissionRow("屏幕录制", detail: "读取菜单栏图标的图像", allowed: recording) {
                        ShelfPermissions.requestScreenRecording()
                        ShelfPermissions.openSettings(screenRecording: true)
                    }
                }.padding(8)
            }
            HStack {
                if controller.isEnabled {
                    Button("关闭收纳，显示全部图标", action: disable)
                } else {
                    Button("启用收纳", action: enable).buttonStyle(.borderedProminent)
                        .disabled(!accessibility || !recording)
                }
                Spacer()
                Button("刷新") { refreshPermissions(); controller.refresh() }
            }.disabled(controller.isBusy)
            HStack(alignment: .top, spacing: 8) {
                if controller.isBusy { ProgressView().controlSize(.small) }
                else { Image(systemName: "info.circle").foregroundStyle(.secondary) }
                Text(controller.message).font(.callout).fixedSize(horizontal: false, vertical: true)
            }.frame(minHeight: 38, alignment: .topLeading)
            if controller.hasPendingRestore {
                Button("放回临时图标") { controller.restoreTemporaryItem() }.disabled(controller.isBusy)
            }
            if controller.isEnabled {
                Text("打开开关即收起该图标，关闭即在菜单栏显示。所有屏幕一起生效。").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(controller.items) { item in
                            HStack {
                                Text(item.displayName).lineLimit(1)
                                Spacer()
                                if !item.isMovable || item.sourceBundleID == LabDelegate.fridayBundleID {
                                    Text("固定").font(.caption).foregroundStyle(.secondary)
                                } else if controller.movingIDs.contains(item.id) {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Toggle("收起", isOn: Binding(get: { controller.hiddenIDs.contains(item.id) },
                                                               set: { controller.setHidden(item.id, hidden: $0) }))
                                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                                        .disabled(controller.hasPendingRestore)
                                }
                            }.padding(.vertical, 7).padding(.horizontal, 10)
                            Divider()
                        }
                    }
                }.background(.background, in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label("先授权，再启用；首次启动不会自动隐藏图标。", systemImage: "1.circle")
                    Label("启用后打开想收起的图标的开关。", systemImage: "2.circle")
                    Label("收起的图标在入口面板顶部，点一下就能打开它的菜单。", systemImage: "3.circle")
                }.font(.callout).foregroundStyle(.secondary).padding(.top, 8)
                Spacer()
            }
            Divider()
            HStack {
                Text("基于开源项目 Ice · GPL-3.0").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("退出", action: quit)
            }
        }
        .padding(24).frame(width: 560, height: 600)
        .onAppear { refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshPermissions() }
    }

    private func permissionRow(_ title: String, detail: String, allowed: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: allowed ? "checkmark.circle.fill" : "circle").foregroundStyle(allowed ? .green : .secondary)
            VStack(alignment: .leading) { Text(title); Text(detail).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button(allowed ? "已授权" : "去授权", action: action).disabled(allowed)
        }
    }
    private func refreshPermissions() {
        accessibility = ShelfPermissions.accessibility
        recording = ShelfPermissions.screenRecording
    }
}

@main
struct ShelfLabMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = LabDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
