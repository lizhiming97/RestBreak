import AppKit
import SwiftUI

/// 仅通过 LaunchServices 打开独立应用，不链接 GPL 模块，不启动继承沙盒的子进程。
/// 菜单栏组件的权限、状态和退出都由组件自身管理。
@MainActor
final class MenuBarCompanionClient: ObservableObject {
    static let shared = MenuBarCompanionClient()
    static let bundleID = "com.lizhiming.MenuBarShelfLab"
    static let appName = "星期五菜单栏.app"

    /// settings 打开组件设置；panel 在星期五图标下弹出开关面板；launch 星期五启动时后台拉起（之前启用过才留下）。
    enum Action: String { case settings, panel, launch }
    /// 用户用过一次「菜单栏图标…」：之后星期五启动时自动在后台拉起组件。
    private static let usedKey = "MenuBarCompanion.Used"
    @Published private(set) var message = ""
    @Published private(set) var isOpening = false

    static func commandURL(_ action: Action) -> URL {
        // 固定命令集：不传入密钥、用户内容或本机路径。
        URL(string: "friday-menubar://\(action.rawValue)")!
    }

    static func siblingURL(mainAppURL: URL) -> URL {
        mainAppURL.deletingLastPathComponent().appendingPathComponent(appName, isDirectory: true)
    }

    static func isCompanion(at url: URL) -> Bool {
        url.pathExtension == "app" && Bundle(url: url)?.bundleIdentifier == bundleID
    }

    /// 发行包里组件放在 星期五.app/Contents/Helpers/ 内；Xcode 直接运行时没有内嵌，再找同目录和已注册的位置。
    static func embeddedURL(mainAppURL: URL) -> URL {
        mainAppURL.appendingPathComponent("Contents/Helpers", isDirectory: true).appendingPathComponent(appName, isDirectory: true)
    }

    func installedURL() -> URL? {
        let embedded = Self.embeddedURL(mainAppURL: Bundle.main.bundleURL)
        if Self.isCompanion(at: embedded) { return embedded }
        let sibling = Self.siblingURL(mainAppURL: Bundle.main.bundleURL)
        if Self.isCompanion(at: sibling) { return sibling }
        if let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID),
           Self.isCompanion(at: registered) { return registered }
        return nil
    }

    func launchInBackgroundIfUsed() {
        guard UserDefaults.standard.bool(forKey: Self.usedKey), let url = installedURL() else { return }
        launch(.launch, at: url)
    }

    /// 菜单里的操作：命令名、图标标识（应用 bundle ID + 序号）和左右键，不带其他内容。
    static func commandURL(_ command: String, key: String?, button: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "friday-menubar"
        components.host = command
        var query: [URLQueryItem] = []
        if let key { query.append(URLQueryItem(name: "key", value: key)) }
        if let button { query.append(URLQueryItem(name: "button", value: button)) }
        components.queryItems = query.isEmpty ? nil : query
        return components.url
    }

    func send(_ command: String, key: String?, button: String?) {
        guard let app = installedURL(), let url = Self.commandURL(command, key: key, button: button) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { _, _ in }
    }

    func open(_ action: Action) {
        guard !isOpening else { return }
        if action != .launch { UserDefaults.standard.set(true, forKey: Self.usedKey) }
        guard let url = installedURL() else {
            message = "尚未找到菜单栏组件。请把发行包中的“星期五菜单栏”也放进应用程序，或点击“选择组件”。"
            return
        }
        launch(action, at: url)
    }

    func chooseApplication() {
        let picker = NSOpenPanel()
        picker.title = "选择星期五菜单栏组件"
        picker.message = "请选择“星期五菜单栏.app”。首次使用需单独授予辅助功能和屏幕录制权限。"
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        picker.begin { [weak self] result in
            MainActor.assumeIsolated {
                guard result == .OK, let url = picker.url, let self else { return }
                guard Self.isCompanion(at: url) else {
                    self.message = "所选应用不是星期五菜单栏组件，请重新选择。"
                    return
                }
                UserDefaults.standard.set(true, forKey: Self.usedKey)
                self.launch(.settings, at: url)
            }
        }
    }

    private func launch(_ action: Action, at url: URL) {
        isOpening = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = action == .settings
        configuration.addsToRecentItems = false
        NSWorkspace.shared.open([Self.commandURL(action)], withApplicationAt: url, configuration: configuration) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                self.isOpening = false
                if let error { self.message = "打开组件失败：\(error.localizedDescription)" }
                else if action != .launch { self.message = "已打开菜单栏组件。" }
            }
        }
    }
}

struct MenuBarCompanionPage: View {
    @ObservedObject private var client = MenuBarCompanionClient.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "tray.full").font(.system(size: 30)).foregroundStyle(SettingsTheme.accent)
            Text("把低频图标收起来").font(.system(size: 18, weight: .semibold))
            Text("启用后，星期五菜单里会出现已收起的图标，点一下就能打开它的菜单；在「菜单栏图标」子菜单里勾选收起哪些。")
                .font(.system(size: 13)).foregroundStyle(SettingsTheme.textSecondary)
            Divider()
            Text("首次使用").font(.headline)
            Text("1. 打开收纳设置，给「星期五菜单栏」授予辅助功能和屏幕录制权限。\n2. 点「启用收纳」。一开始不会收起任何图标。\n3. 在星期五菜单的「菜单栏图标」里勾选想收起的图标。")
                .font(.system(size: 13)).lineSpacing(6)
            HStack {
                Button("打开收纳设置") { client.open(.settings) }.buttonStyle(.borderedProminent)

            }.disabled(client.isOpening)
            Button("选择组件…") { client.chooseApplication() }.disabled(client.isOpening)
            if !client.message.isEmpty { Text(client.message).font(.callout).foregroundStyle(SettingsTheme.textSecondary) }
            Divider()
            Text("支持多块屏幕，收起时所有屏幕一起收起。菜单栏收纳是星期五包内的独立组件，单独授权；星期五退出时它也退出，所有图标回到菜单栏。")
                .font(.caption).foregroundStyle(SettingsTheme.textSecondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: SettingsTheme.cardRadius))
    }
}
