import AppKit
import SwiftUI

/// 鼠标组件的设置。字段和组件里的 ScrollConfiguration 一一对应，以 JSON 存在 App Group 的
/// MouseCompanion/config.json；主 App 不链接 Mos 代码，只写这份文件（改字段名两边要一起改）。
struct MouseSettings: Codable, Equatable {
    var enabled = false
    var smoothVertical = true
    var smoothHorizontal = true
    var reverseVertical = false
    var reverseHorizontal = false
    // Mos 的默认手感
    var step = 33.6
    var speed = 2.7
    var duration = 4.35
    var excludedApps: [String] = []

    static let mosDefaults = MouseSettings()
}

/// 组件写回的运行状态（state：off / permission / running / paused / mos / failed）。
struct MouseStatus: Codable, Equatable {
    var state: String
    var message: String
}

/// 可删除的外部组件入口：设置界面在星期五里，滚轮接管由包内独立的「星期五鼠标」完成。
/// 两边只通过 App Group 里的两个文件和两个 Darwin 通知交流，主 App 不取得输入拦截权限。
@MainActor
final class MouseCompanionClient: ObservableObject {
    static let shared = MouseCompanionClient()
    static let bundleID = "com.lizhiming.FridayMouse"
    static let appName = "星期五鼠标.app"
    static let configChanged = "com.lizhiming.RestBreak.mouse.config"
    static let statusChanged = "com.lizhiming.RestBreak.mouse.status"

    @Published var settings: MouseSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
            // 打开增强时拉起组件；关闭时组件收到通知后自己退出。
            if settings.enabled && (!oldValue.enabled || !isRunning) { send(.launch) }
        }
    }
    @Published private(set) var status: MouseStatus?
    @Published private(set) var isRunning = false
    @Published private(set) var launchError: String?

    enum Action: String { case launch, authorize }

    static func commandURL(_ action: Action) -> URL { URL(string: "friday-mouse://\(action.rawValue)")! }
    static func embeddedURL(mainApp: URL) -> URL {
        mainApp.appendingPathComponent("Contents/Helpers", isDirectory: true).appendingPathComponent(appName)
    }
    static func siblingURL(mainApp: URL) -> URL { mainApp.deletingLastPathComponent().appendingPathComponent(appName) }
    static func isCompanion(_ url: URL) -> Bool {
        url.pathExtension == "app" && Bundle(url: url)?.bundleIdentifier == bundleID
    }
    private static var folder: URL? { AppGroup.containerURL?.appendingPathComponent("MouseCompanion", isDirectory: true) }

    private init() {
        settings = Self.folder.flatMap { try? Data(contentsOf: $0.appendingPathComponent("config.json")) }
            .flatMap { try? JSONDecoder().decode(MouseSettings.self, from: $0) } ?? MouseSettings()
        // 组件状态变了：Darwin 通知不能带内容，转到主线程后重读 status.json。
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            DispatchQueue.main.async { NotificationCenter.default.post(name: .mouseStatusChanged, object: nil) }
        }, Self.statusChanged as CFString, nil, .deliverImmediately)
        NotificationCenter.default.addObserver(forName: .mouseStatusChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MouseCompanionClient.shared.reloadStatus() }
        }
        reloadStatus()
    }

    var isInstalled: Bool { installedURL() != nil }

    private func installedURL() -> URL? {
        let candidates = [Self.embeddedURL(mainApp: Bundle.main.bundleURL), Self.siblingURL(mainApp: Bundle.main.bundleURL),
                          NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID)].compactMap { $0 }
        return candidates.first(where: Self.isCompanion)
    }

    /// 星期五启动时：开着增强才在后台拉起组件。
    func launchIfEnabled() {
        if settings.enabled { send(.launch) }
    }

    func reloadStatus() {
        isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
        status = Self.folder.flatMap { try? Data(contentsOf: $0.appendingPathComponent("status.json")) }
            .flatMap { try? JSONDecoder().decode(MouseStatus.self, from: $0) }
    }

    /// launch 拉起组件或让它重新应用设置（也是「重试」）；authorize 让组件弹出系统的辅助功能授权提示。
    func send(_ action: Action) {
        guard let url = installedURL() else { return }
        launchError = nil
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.open([Self.commandURL(action)], withApplicationAt: url, configuration: configuration) { _, error in
            let text = error.map { "启动鼠标组件失败：\($0.localizedDescription)" }
            Task { @MainActor in
                MouseCompanionClient.shared.launchError = text
                MouseCompanionClient.shared.reloadStatus()
            }
        }
    }

    private func save() {
        guard let folder = Self.folder, let data = try? JSONEncoder().encode(settings) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appendingPathComponent("config.json"), options: .atomic)
        DarwinNotice.post(Self.configChanged)
    }

    /// 开关行下面的说明：优先显示组件报来的状态。
    var statusText: String {
        if !isInstalled { return "没有找到鼠标组件，请使用包含组件的星期五安装包。" }
        if let launchError { return launchError }
        guard settings.enabled else { return "让普通鼠标滚轮平滑滚动，可分别反转上下、左右方向" }
        if isRunning, let status, status.state != "off" { return status.message }
        return "正在启动鼠标组件…"
    }

    var needsPermission: Bool { settings.enabled && isRunning && status?.state == "permission" }
    var canRetry: Bool {
        settings.enabled && isInstalled && (launchError != nil || !isRunning || status?.state == "failed")
    }
}

extension Notification.Name {
    static let mouseStatusChanged = Notification.Name("MouseCompanion.statusChanged")
}

struct MouseCompanionPage: View {
    @ObservedObject private var client = MouseCompanionClient.shared

    var body: some View {
        let enabled = client.settings.enabled
        Card {
            SettingRow(title: "鼠标增强", subtitle: client.statusText,
                       subtitleColor: client.needsPermission || client.canRetry ? .orange : nil, emphasized: true) {
                HStack(spacing: 10) {
                    if client.needsPermission {
                        Button("去授权") { client.send(.authorize) }.buttonStyle(PillButtonStyle())
                            .help("系统会请你在「隐私与安全性 › 辅助功能」里打开「星期五鼠标」")
                    } else if client.canRetry {
                        Button("重试") { client.send(.launch) }.buttonStyle(PillButtonStyle())
                    }
                    Toggle("", isOn: $client.settings.enabled).blueSwitch()
                }
            }
            .disabled(!client.isInstalled)
        }

        Card {
            axisRow("上下滚动", reverse: $client.settings.reverseVertical, smooth: $client.settings.smoothVertical)
            RowDivider()
            axisRow("左右滚动", reverse: $client.settings.reverseHorizontal, smooth: $client.settings.smoothHorizontal)
        }
        .disabled(!enabled)

        Card {
            SettingRow(title: "速度", subtitle: "每格滚动的距离倍数") {
                ValueSlider(value: tenths(\.speed), range: 5...50, unit: .tenths)
            }
            RowDivider()
            SettingRow(title: "平滑程度", subtitle: "越大滑行越久") {
                ValueSlider(value: tenths(\.duration), range: 10...50, unit: .tenths)
            }
            RowDivider()
            SettingRow(title: "最小步长", subtitle: "轻轻拨一格也至少滚这么多") {
                ValueSlider(value: $client.settings.step, range: 1...100, unit: .points)
            }
        }
        .disabled(!enabled || !(client.settings.smoothVertical || client.settings.smoothHorizontal))
        HStack {
            Spacer()
            Button("恢复默认手感") {
                client.settings.speed = MouseSettings.mosDefaults.speed
                client.settings.duration = MouseSettings.mosDefaults.duration
                client.settings.step = MouseSettings.mosDefaults.step
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(SettingsTheme.textSecondary)
        }
        .padding(.trailing, 14)
        .padding(.top, -6)
        .disabled(!enabled)

        Card {
            ForEach(client.settings.excludedApps, id: \.self) { id in
                FocusAppRow(app: FocusApp(bundleID: id, name: Self.appName(id))) {
                    client.settings.excludedApps.removeAll { $0 == id }
                }
                RowDivider()
            }
            SettingRow(title: client.settings.excludedApps.isEmpty ? "这些 App 使用原生滚动" : "添加更多",
                       subtitle: "从正在运行的 App 中选择；想加的 App 没在列表里，先把它打开") {
                AddFocusAppMenu(excluded: Set(client.settings.excludedApps)) {
                    client.settings.excludedApps.append($0.bundleID)
                }
            }
        }
        .disabled(!enabled)

        Text("只作用于普通鼠标滚轮，触控板和 Magic Mouse 保持原样；如果装了 Mos，请先退出它。平滑核心来自开源项目 [Mos](https://github.com/Caldis/Mos)，按 [CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/)（非商业）提供。")
            .font(.system(size: 11))
            .foregroundStyle(SettingsTheme.textSecondary)
            .padding(.horizontal, 14)
            .onAppear { client.reloadStatus() }
    }

    /// 一个方向一行：右边两个小开关「反转」「平滑」
    private func axisRow(_ title: String, reverse: Binding<Bool>, smooth: Binding<Bool>) -> some View {
        SettingRow(title: title, subtitle: "反转是相对系统当前的滚动方向") {
            HStack(spacing: 18) {
                labeledSwitch("反转", reverse)
                labeledSwitch("平滑", smooth)
            }
        }
    }

    private func labeledSwitch(_ label: String, _ isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(SettingsTheme.textSecondary)
            Toggle(label, isOn: isOn).blueSwitch()
        }
    }

    /// 速度、平滑程度按 0.1 一档：滑条用整数，存的时候除以 10
    private func tenths(_ keyPath: WritableKeyPath<MouseSettings, Double>) -> Binding<Double> {
        Binding(get: { client.settings[keyPath: keyPath] * 10 },
                set: { client.settings[keyPath: keyPath] = $0 / 10 })
    }

    private static func appName(_ bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
    }
}
