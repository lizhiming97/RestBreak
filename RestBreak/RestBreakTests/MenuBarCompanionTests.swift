import AppKit
import Testing
@testable import RestBreak

@MainActor
struct MenuBarCompanionTests {
    @Test func 组件只接收固定命令_不带用户内容和文件路径() {
        for action in [MenuBarCompanionClient.Action.settings, .panel, .launch] {
            let url = MenuBarCompanionClient.commandURL(action)
            #expect(url.scheme == "friday-menubar")
            #expect(url.host == action.rawValue)
            #expect(url.query == nil)
            #expect(url.path.isEmpty)
        }
    }

    @Test func 菜单命令只带图标标识和按键() {
        let url = MenuBarCompanionClient.commandURL("open", key: "com.ccswitch.desktop#0", button: "right")
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(url?.host == "open")
        #expect(items?.first { $0.name == "key" }?.value == "com.ccswitch.desktop#0")
        #expect(items?.first { $0.name == "button" }?.value == "right")
        #expect(MenuBarCompanionClient.commandURL("reveal-all", key: nil, button: nil)?.absoluteString == "friday-menubar://reveal-all")
    }

    @Test func 同目录安装支持中文和空格路径() {
        let main = URL(fileURLWithPath: "/tmp/我的 App/星期五.app", isDirectory: true)
        let companion = MenuBarCompanionClient.siblingURL(mainAppURL: main)
        #expect(companion.path == "/tmp/我的 App/星期五菜单栏.app")
        let embedded = MenuBarCompanionClient.embeddedURL(mainAppURL: main)
        #expect(embedded.path == "/tmp/我的 App/星期五.app/Contents/Helpers/星期五菜单栏.app")
    }

    @Test func 拒绝将星期五本体或普通文件当作组件() {
        #expect(!MenuBarCompanionClient.isCompanion(at: Bundle.main.bundleURL))
        #expect(!MenuBarCompanionClient.isCompanion(at: URL(fileURLWithPath: "/tmp/not-an-app.txt")))
    }

    @Test func 收纳页有独立入口且不改已有页面标识() {
        #expect(SettingsPage.menuBar.symbol == "tray.full")
        #expect(SettingsPage.allCases.contains(.menuBar))
        #expect(SettingsPage.reminders.rawValue == "Agent主动关怀")
        #expect(SettingsPage.screenshot.rawValue == "截图")
    }
}
