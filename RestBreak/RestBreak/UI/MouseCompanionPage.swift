import AppKit
import SwiftUI

/// 可删除的外部组件入口：主 App 不链接 Mos，不取得输入拦截权限。
@MainActor
final class MouseCompanionClient: ObservableObject {
    static let shared = MouseCompanionClient()
    static let bundleID = "com.lizhiming.FridayMouse"
    static let appName = "星期五鼠标.app"
    private static let usedKey = "MouseCompanion.Used"
    @Published private(set) var message = ""
    @Published private(set) var opening = false
    enum Action: String { case settings, launch }

    static func commandURL(_ action: Action) -> URL { URL(string: "friday-mouse://\(action.rawValue)")! }
    static func embeddedURL(mainApp: URL) -> URL {
        mainApp.appendingPathComponent("Contents/Helpers", isDirectory: true).appendingPathComponent(appName)
    }
    static func siblingURL(mainApp: URL) -> URL { mainApp.deletingLastPathComponent().appendingPathComponent(appName) }
    static func isCompanion(_ url: URL) -> Bool {
        url.pathExtension == "app" && Bundle(url: url)?.bundleIdentifier == bundleID
    }
    private func installedURL() -> URL? {
        let candidates = [Self.embeddedURL(mainApp: Bundle.main.bundleURL), Self.siblingURL(mainApp: Bundle.main.bundleURL),
                          NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID)].compactMap { $0 }
        return candidates.first(where: Self.isCompanion)
    }
    func launchIfUsed() {
        guard UserDefaults.standard.bool(forKey: Self.usedKey) else { return }
        open(.launch)
    }
    func open(_ action: Action = .settings) {
        guard !opening else { return }
        guard let url = installedURL() else {
            if action == .settings { message = "尚未找到鼠标组件，请使用包含组件的验证包，或将“星期五鼠标”放在星期五旁边。" }
            return
        }
        opening = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = action == .settings
        configuration.addsToRecentItems = false
        NSWorkspace.shared.open([Self.commandURL(action)], withApplicationAt: url, configuration: configuration) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                self.opening = false
                if let error { self.message = "打开鼠标组件失败：\(error.localizedDescription)" }
                else if action == .settings {
                    UserDefaults.standard.set(true, forKey: Self.usedKey)
                    self.message = "已打开鼠标设置。"
                }
            }
        }
    }
}

struct MouseCompanionPage: View {
    @ObservedObject private var client = MouseCompanionClient.shared
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 18) {
                Label("让鼠标滚轮更顺滑", systemImage: "computermouse").font(.title3.weight(.semibold))
                Text("分别调整鼠标上下、左右滚动的方向，开启平滑滚动，并按手感调节速度。触控板保持原有习惯。")
                    .font(.callout).foregroundStyle(.secondary)
                Divider()
                Text("首次使用").font(.headline)
                Text("1. 打开鼠标设置。\n2. 为“星期五鼠标”授予辅助功能权限。\n3. 开启鼠标增强，按需要调整方向和手感。")
                    .font(.callout).lineSpacing(7)
                Button("打开鼠标设置") { client.open() }
                    .buttonStyle(.borderedProminent).disabled(client.opening)
                if !client.message.isEmpty { Text(client.message).font(.caption).foregroundStyle(.secondary) }
                Text("如已运行 Mos，请先退出它。可为不适合平滑滚动的应用添加排除项。关闭增强后恢复系统原生滚动。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
