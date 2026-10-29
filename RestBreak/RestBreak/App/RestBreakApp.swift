import SwiftUI

/// 程序入口。
/// 这是一个只在菜单栏显示的 App（Info.plist 里 LSUIElement = YES，没有 Dock 图标），
/// 真正的启动逻辑在 AppDelegate 里。
@main
struct RestBreakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // SwiftUI 要求至少有一个 Scene；设置窗口我们自己管理，这里放个空的占位
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // 这几个对象要一直活着，所以用属性持有
    private var coordinator: BreakCoordinator?
    private var statusBar: StatusBarController?
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 跑单元测试时 App 也会被启动，这时不要弹菜单栏图标和休息窗口
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        SingleInstance.takeOver()

        let coordinator = BreakCoordinator()
        let settingsWindow = SettingsWindowController(coordinator: coordinator)
        let statusBar = StatusBarController(coordinator: coordinator,
                                            openSettings: { settingsWindow.show(page: $0) })
        coordinator.onUpdate = { [weak statusBar] in statusBar?.refresh() }
        coordinator.screenshots.onOpenSettings = { settingsWindow.show(page: .screenshot) }
        coordinator.reminders.onOpenPage = { settingsWindow.show(page: .reminders) }
        coordinator.start()

        self.coordinator = coordinator
        self.settingsWindow = settingsWindow
        self.statusBar = statusBar
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.flush()
    }
}

/// 保证只有一个「星期五」在运行：新启动的通知旧的退出（新的留下）。
/// 例如开机启动的那个还在时又在 Xcode 里点了运行，不会出现两个菜单栏图标、两次提醒。
/// 用系统范围的通知（沙盒里只能带字符串 object，不能带 userInfo），object 是发送者的进程号，收到自己发的就忽略。
@MainActor
enum SingleInstance {
    private static let name = Notification.Name("com.lizhiming.RestBreak.newInstanceLaunched")
    private static let observer = Observer()

    static func takeOver() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(observer, selector: #selector(Observer.otherLaunched(_:)), name: name, object: nil)
        center.postNotificationName(name, object: String(ProcessInfo.processInfo.processIdentifier),
                                    userInfo: nil, deliverImmediately: true)
    }

    private final class Observer: NSObject {
        @objc func otherLaunched(_ notification: Notification) {
            guard let sender = notification.object as? String,
                  sender != String(ProcessInfo.processInfo.processIdentifier) else { return }
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
