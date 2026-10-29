import AppKit
import SwiftUI

/// 自己管理的设置窗口（菜单栏 App 里用 SwiftUI 的 Settings 场景不好唤出）
/// 样式参考豆包输入法：左侧浅灰侧边栏，右侧白色圆角卡片。
@MainActor
final class SettingsWindowController: NSObject {   // NSObject：用 selector 方式监听窗口关闭
    private let coordinator: BreakCoordinator
    private var window: NSWindow?
    /// 设置窗口当前显示哪一页（菜单里点「今天已休息…」时跳到统计页）
    private let navigation = SettingsNavigation()

    init(coordinator: BreakCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    /// 设置窗口：760×600，无标题栏（红绿灯按钮浮在侧边栏上）。
    /// SwiftUI 视图外面包一层普通 NSView 再放进窗口（2026-10-23 实测）：
    /// NSHostingView 直接做窗口内容时，会在 600 之外再要 32pt 标题栏安全区，把窗口撑到 632，
    /// 底部多出一条白边（关掉 sizingOptions、safeAreaRegions 都没用）。包一层后窗口大小只由这里决定。
    static let size = NSSize(width: 760, height: 600)

    static func makeWindow(_ content: some View) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        window.contentView = container
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "星期五 · 设置"
        window.appearance = NSAppearance(named: .aqua)   // 配色按浅色设计
        window.isReleasedWhenClosed = false   // 关掉后还能再打开
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
        return window
    }

    func show(page: SettingsPage? = nil) {
        if let page { navigation.page = page }
        // 从菜单「接下来的提醒」、灵动岛「看看」打开的，都是关于某条提醒，直接看「记录」
        if page == .reminders { navigation.remindersTab = .history }
        // 设置窗口开着时临时变成普通 App（Dock 里出现图标）：
        // 菜单栏 App（accessory）的窗口会直接盖在别的 App 的全屏界面上；普通 App 的窗口不会进全屏空间，
        // 系统会先切回桌面再显示，和其他 App 的习惯一致（2026-10-24 用户要求）。
        // 注意顺序（2026-10-26 修）：切换 activation policy 是异步生效的，窗口必须在切换「之后」再建、再激活，
        // 否则窗口还是按菜单栏 App 的规则放进当前的全屏空间。0.4 版窗口常驻、只建一次，所以以前没暴露；
        // 改成关掉就释放后，每次打开都重建，问题就出来了
        // 激活必须在这里同步调用（2026-10-28 用日志查实）：macOS 14 起，App 只有「紧跟着用户点击」时请求激活才会被允许。
        // 以前放到下一轮 runloop 才激活，第一次打开时请求被拒，窗口建好了却压在当前 App 后面，看着像没反应；
        // 第二次 policy 已是 regular、同步激活，所以能出来。窗口仍然在下一轮再建（理由见上）
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            DispatchQueue.main.async { [weak self] in self?.present() }
        } else {
            present()
        }
    }

    private func present() {
        if window == nil {
            let window = Self.makeWindow(SettingsView(navigation: navigation).environmentObject(coordinator))
            window.center()
            NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose),
                                                   name: NSWindow.willCloseNotification, object: window)
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// 关掉设置窗口后变回菜单栏 App，Dock 图标消失
    @objc private func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // 关掉就释放：否则隐藏的 SwiftUI 界面还会跟着引擎每次 tick 重新计算
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
        DispatchQueue.main.async { [weak self] in
            self?.window?.contentView = nil
            self?.window = nil
        }
    }
}

// MARK: - 配色和尺寸（对照豆包输入法截图）

enum SettingsTheme {
    static let sidebarTop = Color(red: 0.925, green: 0.925, blue: 0.933)
    static let sidebarTint = Color(red: 0.863, green: 0.925, blue: 0.910)   // 侧边栏中下部的淡青色
    static let contentBackground = Color(red: 0.969, green: 0.969, blue: 0.973)
    static let cardBorder = Color(red: 0.906, green: 0.906, blue: 0.914)
    static let divider = Color(red: 0.918, green: 0.918, blue: 0.925)
    static let textPrimary = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let textSecondary = Color(red: 0.54, green: 0.54, blue: 0.56)
    static let accent = Color(red: 0.24, green: 0.48, blue: 0.97)
    static let selectedRow = Color.white.opacity(0.9)
    /// 输入框底色
    static let fieldBackground = Color(red: 0.94, green: 0.94, blue: 0.95)

    static let sidebarWidth: CGFloat = 212
    static let cardRadius: CGFloat = 14
    static let cardSpacing: CGFloat = 20
    static let cardPadding: CGFloat = 18
    static let rowHeight: CGFloat = 62
}

// MARK: - 窗口整体

/// 设置窗口当前在哪一页
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var page: SettingsPage
    /// 「休息」页当前显示哪一组
    @Published var restTab: RestTab = .schedule
    /// 「外观与快捷键」页当前显示哪一组
    @Published var personalTab: PersonalTab = .appearance
    /// 「提醒」页当前显示哪一组
    @Published var remindersTab: RemindersTab = .setup

    /// 点菜单「设置…」默认打开「休息安排」；点「今天已休息…」打开统计页
    init(page: SettingsPage = .rest) {
        self.page = page
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case stats = "统计"
    case rest = "休息"
    case reminders = "提醒"
    case smart = "智能避让"
    case personal = "外观与快捷键"
    case screenshot = "截图"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .stats: "chart.bar"
        case .rest: "clock"
        case .reminders: "bell"
        case .smart: "sparkles"
        case .personal: "paintpalette"
        case .screenshot: "camera.viewfinder"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var navigation: SettingsNavigation

    init(navigation: SettingsNavigation) {
        self.navigation = navigation
    }

    /// 测试和预览用：直接指定显示哪一页
    init(page: SettingsPage) {
        self.navigation = SettingsNavigation(page: page)
    }

    private var page: SettingsPage { navigation.page }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(page: $navigation.page)
                .frame(width: SettingsTheme.sidebarWidth)

            ScrollView {
                VStack(alignment: .leading, spacing: SettingsTheme.cardSpacing) {
                    HStack {
                        Text(page.rawValue)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(SettingsTheme.textPrimary)
                        Spacer()
                        if page == .rest {
                            SegmentPicker(selection: $navigation.restTab)
                        } else if page == .personal {
                            SegmentPicker(selection: $navigation.personalTab)
                        } else if page == .reminders {
                            SegmentPicker(selection: $navigation.remindersTab)
                        }
                    }
                    .padding(.leading, 14)
                    .padding(.top, 2)
                    .frame(height: 28)

                    switch page {
                    case .stats: StatsPage()
                    case .rest: RestPage()
                    case .reminders: RemindersPage()
                    case .smart: SmartPage()
                    case .personal: PersonalPage()
                    case .screenshot: ScreenshotPage()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.never)
            .background(SettingsTheme.contentBackground)
        }
        .frame(width: 760, height: 600)
        .ignoresSafeArea()
        .environmentObject(navigation)   // 「休息」页读写当前分段
    }
}

// MARK: - 侧边栏

private struct Sidebar: View {
    @Binding var page: SettingsPage
    @EnvironmentObject private var coordinator: BreakCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // App 名称（顶部留出红绿灯按钮的位置）
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(.white)
                    Image(systemName: "cup.and.saucer.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(SettingsTheme.accent)
                }
                .frame(width: 30, height: 30)
                .overlay(Circle().stroke(SettingsTheme.cardBorder, lineWidth: 1))

                Text("星期五")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(SettingsTheme.textPrimary)
            }
            .padding(.leading, 18)
            .padding(.top, 58)
            .padding(.bottom, 14)

            VStack(spacing: 0) {
                ForEach(SettingsPage.allCases) { item in
                    SidebarRow(item: item, isSelected: item == page)
                        .onTapGesture { page = item }
                }
            }
            .padding(.horizontal, 8)

            Spacer()

            Rectangle().fill(SettingsTheme.divider).frame(height: 1)
            StatusFooter(scheduler: coordinator.scheduler, deferralReason: coordinator.deferralReason,
                         eventTitle: coordinator.currentEventTitle)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
        }
        .background(
            LinearGradient(stops: [.init(color: SettingsTheme.sidebarTop, location: 0),
                                   .init(color: SettingsTheme.sidebarTop, location: 0.42),
                                   .init(color: SettingsTheme.sidebarTint, location: 0.62),
                                   .init(color: SettingsTheme.sidebarTop, location: 0.95)],
                           startPoint: .top, endPoint: .bottom)
        )
    }
}

private struct SidebarRow: View {
    let item: SettingsPage
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.symbol)
                .font(.system(size: 15))
                .frame(width: 20)
            Text(item.rawValue)
                .font(.system(size: 15, weight: .medium))
            Spacer()
        }
        .foregroundStyle(SettingsTheme.textPrimary)
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(isSelected ? SettingsTheme.selectedRow : .clear, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }
}

/// 侧边栏底部：当前状态
private struct StatusFooter: View {
    let scheduler: BreakScheduler
    let deferralReason: String?
    let eventTitle: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(lines.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SettingsTheme.textPrimary)
                if let detail = lines.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsTheme.textSecondary)
                }
            }
        }
    }

    private var dotColor: Color {
        switch scheduler.state {
        case .running: scheduler.isInMeeting || scheduler.isDeferringBreak ? .orange : .green
        case .onBreak: SettingsTheme.accent
        case .paused: .orange
        case .away: .gray
        }
    }

    private var lines: (title: String, detail: String?) {
        switch scheduler.state {
        case .onBreak(let session):
            return ("正在\(session.kind.displayName)", nil)
        case .paused(let until):
            return ("已暂停", until.map { "\(TimeText.hourMinute($0)) 自动恢复" } ?? "需手动恢复")
        case .away:
            return ("检测到你已离开", "计时暂停中")
        case .running:
            if scheduler.isInMeeting { return ("会议中", "到点的休息会在会后开始") }
            if let event = scheduler.currentCalendarEvent(at: Date()) {
                return (eventTitle.map { "日程：\($0)" } ?? "日程中",
                        "休息在 \(TimeText.hourMinute(event.end)) 日程结束后开始")
            }
            if let deadline = scheduler.deferralEndsAt {
                let title = deferralReason == "全屏" ? "全屏中" : "正在使用 \(deferralReason ?? "指定 App")"
                return (title, "休息已推迟，最晚 \(TimeText.hourMinute(deadline)) 开始")
            }
            guard let next = scheduler.nextBreakStart(now: Date()) else { return ("所有休息都已关闭", nil) }
            return ("下次：\(next.kind.displayName)",
                    "\(TimeText.hourMinute(next.date))（\(TimeText.relative(next.date.timeIntervalSinceNow))）")
        }
    }
}

// MARK: - 各个页面

/// 「休息」页：原来的「休息安排」「提醒方式」「休息规则」合成一页，用标题右侧的分段切换两组内容，
/// 每组都能在 760×600 的窗口里一屏放下，不用滚动。
enum RestTab: String, CaseIterable, Identifiable {
    case schedule = "休息安排"
    case behavior = "提醒与规则"

    var id: Self { self }
}

private struct RestPage: View {
    @EnvironmentObject private var coordinator: BreakCoordinator
    @EnvironmentObject private var navigation: SettingsNavigation

    var body: some View {
        switch navigation.restTab {
        case .schedule:
            // 每种休息的所有设置（开关、间隔、时长、推迟）放在同一张卡片里
            breakCard(.micro, subtitle: "放松眼睛和肩颈",
                      interval: 5...60, durationUnit: .seconds, duration: 10...300, postpone: 1...10)
            breakCard(.long, subtitle: "起身活动，喝水拉伸",
                      interval: 15...180, durationUnit: .minutes, duration: 1...20, postpone: 1...30)
        case .behavior:
            // 分段已经写明「提醒与规则」，卡片不再加小标题，省出高度保证一屏放下
            Card {
                SettingRow(title: "菜单栏显示倒计时", subtitle: "图标旁显示距下次休息的时间") {
                    Toggle("", isOn: $coordinator.settings.showCountdownInMenuBar).blueSwitch()
                }
                RowDivider()
                SettingRow(title: "开机自动启动", subtitle: "登录 Mac 后自动在菜单栏运行") {
                    Toggle("", isOn: $coordinator.launchAtLoginEnabled).blueSwitch()
                }
            }
            Card {
                SettingRow(title: "最多推迟次数", subtitle: "每次休息最多能推迟几次") {
                    ValueSlider(value: Binding(get: { Double(coordinator.settings.maxPostpones) },
                                               set: { coordinator.settings.maxPostpones = Int($0) }),
                                range: 0...5, unit: .times)
                }
                .disabled(coordinator.settings.strictMode)
                RowDivider()
                SettingRow(title: "严格模式", subtitle: "休息时不显示「推迟」和「跳过」") {
                    Toggle("", isOn: $coordinator.settings.strictMode).blueSwitch()
                }
                RowDivider()
                SettingRow(title: "离开判定", subtitle: "多久不碰键盘鼠标算作已休息") {
                    ValueSlider(value: Binding(get: { coordinator.settings.awayThreshold / 60 },
                                               set: { coordinator.settings.awayThreshold = $0 * 60 }),
                                range: 1...30, unit: .minutes)
                }
            }
            HStack {
                Spacer()
                Button("恢复默认设置") { coordinator.restoreDefaults() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.textSecondary)
                    .help("所有设置恢复为初始值")
            }
            .padding(.trailing, 14)
            .padding(.top, -6)
        }
    }

    /// 一种休息的卡片：标题行带开关，下面是间隔 / 时长 / 推迟三个滑条
    private func breakCard(_ kind: BreakKind, subtitle: String,
                           interval: ClosedRange<Double>, durationUnit: TimeUnit,
                           duration: ClosedRange<Double>, postpone: ClosedRange<Double>) -> some View {
        let isEnabled = coordinator.settings[kind].isEnabled
        return Card {
            SettingRow(title: kind.displayName, subtitle: subtitle, emphasized: true) {
                Toggle("", isOn: $coordinator.settings[kind].isEnabled).blueSwitch()
            }
            Group {
                RowDivider()
                SettingRow(title: "间隔", subtitle: "每隔多久休息一次") {
                    ValueSlider(value: binding(kind, \.interval, unit: .minutes), range: interval, unit: .minutes)
                }
                RowDivider()
                SettingRow(title: "时长", subtitle: "每次休息多久") {
                    ValueSlider(value: binding(kind, \.duration, unit: durationUnit), range: duration, unit: durationUnit)
                }
                RowDivider()
                SettingRow(title: "推迟", subtitle: "点「推迟」后多久再提醒") {
                    ValueSlider(value: binding(kind, \.postponeDuration, unit: .minutes), range: postpone, unit: .minutes)
                }
                .disabled(coordinator.settings.strictMode)
            }
            .disabled(!isEnabled)
        }
    }

    private func binding(_ kind: BreakKind, _ keyPath: WritableKeyPath<BreakConfig, TimeInterval>,
                         unit: TimeUnit) -> Binding<Double> {
        Binding(
            get: { coordinator.settings[kind][keyPath: keyPath] / unit.seconds },
            set: { coordinator.settings[kind][keyPath: keyPath] = $0 * unit.seconds }
        )
    }
}

/// 浅灰底 + 白色选中块的分段切换（和统计页「7 天 / 30 天」同样的观感）
struct SegmentPicker<Item: Hashable & Identifiable & RawRepresentable & CaseIterable>: View
    where Item.RawValue == String, Item.AllCases: RandomAccessCollection {
    @Binding var selection: Item
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Item.allCases) { item in
                Text(item.rawValue)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(item == selection ? SettingsTheme.textPrimary : SettingsTheme.textSecondary)
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background {
                        if item == selection {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.white)
                                .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                                .matchedGeometryEffect(id: "selected", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy(duration: 0.2)) { selection = item } }
                    .accessibilityAddTraits(item == selection ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(Color(red: 0.94, green: 0.94, blue: 0.95), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SmartPage: View {
    @EnvironmentObject private var coordinator: BreakCoordinator

    var body: some View {
        Card {
            SettingRow(title: "开会时自动推迟",
                       subtitle: "有 App 正在使用麦克风时视为开会，会议结束 1 分钟后再休息") {
                Toggle("", isOn: $coordinator.settings.postponeDuringMeetings).blueSwitch()
            }
        }

        Card {
            SettingRow(title: "全屏时推迟",
                       subtitle: "看视频、做演示时不打扰，退出全屏后立即休息") {
                Toggle("", isOn: $coordinator.settings.postponeDuringFullscreen).blueSwitch()
            }
        }

        Card {
            SettingRow(title: "使用指定 App 时推迟",
                       subtitle: "比如演示、录屏、玩游戏时不打扰，切到别的 App 后立即休息") {
                Toggle("", isOn: $coordinator.settings.postponeDuringFocusApps).blueSwitch()
            }
            Group {
                ForEach(coordinator.settings.focusApps) { app in
                    RowDivider()
                    FocusAppRow(app: app) {
                        coordinator.settings.focusApps.removeAll { $0.bundleID == app.bundleID }
                    }
                }
                RowDivider()
                SettingRow(title: coordinator.settings.focusApps.isEmpty ? "还没有添加 App" : "添加更多",
                           subtitle: "从正在运行的 App 中选择；想加的 App 没在列表里，先把它打开") {
                    AddFocusAppMenu()
                }
            }
            .disabled(!coordinator.settings.postponeDuringFocusApps)
        }

        CalendarCard()

        Card {
            SettingRow(title: "最多推迟", subtitle: "超过这个时间照样休息") {
                ValueSlider(value: Binding(get: { coordinator.settings.maxDeferral / 60 },
                                           set: { coordinator.settings.maxDeferral = $0 * 60 }),
                            range: 5...60, unit: .minutes)
            }
            .disabled(!coordinator.settings.postponeDuringFullscreen
                      && !coordinator.settings.postponeDuringFocusApps)
        }
    }
}

/// 「按日历安排休息」卡片：开关 + 权限提示 + 日历勾选列表
private struct CalendarCard: View {
    @EnvironmentObject private var coordinator: BreakCoordinator

    var body: some View {
        let service = coordinator.calendarService
        Card {
            SettingRow(title: "按日历安排休息",
                       subtitle: "日程进行中不弹休息；快到日程时，把休息提前到日程开始前") {
                Toggle("", isOn: $coordinator.settings.followCalendar).blueSwitch()
            }
            if coordinator.settings.followCalendar {
                RowDivider()
                SettingRow(title: "日程来源", subtitle: "以哪里的日程为准") {
                    SourcePicker(source: $coordinator.settings.calendarSource)
                }
                switch coordinator.settings.calendarSource {
                case .mac: CalendarList(service: service)
                case .dingtalk: DingTalkRow(service: coordinator.dingTalk)
                }
            }
        }
    }
}

/// 「Mac 日历 / 钉钉日历」切换，浅灰底 + 白色选中块
private struct SourcePicker: View {
    @Binding var source: CalendarSource
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CalendarSource.allCases, id: \.self) { item in
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(item == source ? SettingsTheme.textPrimary : SettingsTheme.textSecondary)
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background {
                        if item == source {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.white)
                                .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                                .matchedGeometryEffect(id: "selected", in: selection)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy(duration: 0.2)) { source = item } }
                    .accessibilityAddTraits(item == source ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(Color(red: 0.94, green: 0.94, blue: 0.95), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 钉钉日历：登录状态 + 登录 / 退出按钮
private struct DingTalkRow: View {
    @ObservedObject var service: DingTalkCalendar

    var body: some View {
        RowDivider()
        switch service.status {
        case .loggedOut:
            SettingRow(title: "连接钉钉日历",
                       subtitle: "在浏览器里登录钉钉并授权，只读取你的日程时间，不会修改日程") {
                Button("登录钉钉") { service.login() }.buttonStyle(PillButtonStyle())
            }
        case .loggingIn:
            SettingRow(title: "正在等待授权…", subtitle: "请在浏览器里完成钉钉登录和授权") {
                Button("取消") { service.cancelLogin() }.buttonStyle(PillButtonStyle())
            }
        case .connected:
            SettingRow(title: "已连接钉钉日历", subtitle: syncText) {
                HStack(spacing: 8) {
                    Button("立即同步") { Task { await service.refresh() } }.buttonStyle(PillButtonStyle())
                    Button("退出登录") { service.logout() }.buttonStyle(PillButtonStyle())
                }
            }
        case .failed(let message):
            SettingRow(title: service.isLoggedIn ? "钉钉日历同步失败" : "没有连上钉钉日历",
                       subtitle: message, subtitleColor: .red) {
                HStack(spacing: 8) {
                    if service.isLoggedIn {
                        Button("重试") { Task { await service.refresh() } }.buttonStyle(PillButtonStyle())
                        Button("退出登录") { service.logout() }.buttonStyle(PillButtonStyle())
                    } else {
                        Button("重新登录") { service.login() }.buttonStyle(PillButtonStyle())
                    }
                }
            }
        }
    }

    private var syncText: String {
        guard let sync = service.lastSync else { return "正在读取日程…" }
        let count = sync.count == 0 ? "接下来 12 小时没有日程" : "接下来 12 小时有 \(sync.count) 个日程"
        return "\(count)，\(TimeText.hourMinute(sync.date)) 同步，每 5 分钟自动更新"
    }
}

private struct CalendarList: View {
    @EnvironmentObject private var coordinator: BreakCoordinator
    @ObservedObject var service: CalendarService

    var body: some View {
        content.onAppear { service.activate() }
    }

    @ViewBuilder private var content: some View {
        switch service.authorization {
        case .fullAccess:
            if service.calendars.isEmpty {
                RowDivider()
                SettingRow(title: "没有找到日历", subtitle: "在「日历」App 里添加账户后会出现在这里") { EmptyView() }
            }
            ForEach(service.calendars) { calendar in
                RowDivider()
                CalendarRow(calendar: calendar, isOn: selection(for: calendar.id))
            }
        case .notDetermined:
            RowDivider()
            SettingRow(title: "需要访问日历", subtitle: "只读取日程的开始和结束时间，不会修改你的日历") {
                Button("允许访问") { Task { _ = await service.requestAccess() } }
                    .buttonStyle(PillButtonStyle())
            }
        default:
            RowDivider()
            SettingRow(title: "没有日历访问权限",
                       subtitle: "请在「系统设置 › 隐私与安全性 › 日历」里允许「星期五」",
                       subtitleColor: .red) {
                Button("打开系统设置") { service.openPrivacySettings() }
                    .buttonStyle(PillButtonStyle())
            }
        }
    }

    private func selection(for id: String) -> Binding<Bool> {
        Binding(
            get: { coordinator.settings.calendarIDs.contains(id) },
            set: { isOn in
                coordinator.settings.calendarIDs.removeAll { $0 == id }
                if isOn { coordinator.settings.calendarIDs.append(id) }
            }
        )
    }
}

/// 日历列表的一行：颜色圆点 + 名字 + 账户 + 勾选
private struct CalendarRow: View {
    let calendar: CalendarInfo
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(nsColor: calendar.color))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(calendar.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SettingsTheme.textPrimary)
                if !calendar.source.isEmpty {
                    Text(calendar.source)
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsTheme.textSecondary)
                }
            }
            Spacer()
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(isOn ? SettingsTheme.accent : SettingsTheme.textSecondary.opacity(0.5))
                .animation(.snappy(duration: 0.15), value: isOn)
        }
        .padding(.horizontal, SettingsTheme.cardPadding)
        .frame(height: 50)
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "已选" : "未选")
    }
}

/// 指定 App 列表里的一行：图标 + 名字 + 删除按钮
private struct FocusAppRow: View {
    let app: FocusApp
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: AppIcon.forBundleID(app.bundleID))
                .resizable()
                .frame(width: 28, height: 28)
            Text(app.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SettingsTheme.textPrimary)
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(SettingsTheme.textSecondary.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("移除")
            .accessibilityLabel("移除 \(app.name)")
        }
        .padding(.horizontal, SettingsTheme.cardPadding)
        .frame(height: 50)
    }
}

/// 「添加 App」按钮：点开列出正在运行、还没添加过的 App
private struct AddFocusAppMenu: View {
    @EnvironmentObject private var coordinator: BreakCoordinator

    var body: some View {
        Menu {
            let candidates = runningApps()
            if candidates.isEmpty {
                Text("没有可添加的 App")
            }
            ForEach(candidates, id: \.bundleID) { app in
                Button {
                    coordinator.settings.focusApps.append(app)
                } label: {
                    Label {
                        Text(app.name)
                    } icon: {
                        Image(nsImage: AppIcon.forBundleID(app.bundleID, size: 16))
                    }
                }
            }
        } label: {
            Label("添加 App", systemImage: "plus")
                .font(.system(size: 13, weight: .medium))
        }
        .menuStyle(.button)
        .buttonStyle(PillButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// 正在运行的普通 App（有 Dock 图标的），去掉自己和已添加的，按名字排序
    private func runningApps() -> [FocusApp] {
        let added = Set(coordinator.settings.focusApps.map(\.bundleID))
        let ownID = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> FocusApp? in
                guard let id = app.bundleIdentifier, id != ownID, !added.contains(id),
                      seen.insert(id).inserted else { return nil }
                return FocusApp(bundleID: id, name: app.localizedName ?? id)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// 根据 bundle ID 取 App 图标；找不到 App 时用系统通用图标
@MainActor
private enum AppIcon {
    static func forBundleID(_ bundleID: String, size: CGFloat = 32) -> NSImage {
        let image: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        image.size = NSSize(width: size, height: size)
        return image
    }
}

/// 「外观与快捷键」页：原来的「外观」「快捷键」两页合成一页，用标题右侧的分段切换，
/// 两组内容加起来放不进一屏，所以分开显示，每组都不用滚动。
enum PersonalTab: String, CaseIterable, Identifiable {
    case appearance = "外观"
    case shortcuts = "快捷键"

    var id: Self { self }
}

private struct PersonalPage: View {
    @EnvironmentObject private var navigation: SettingsNavigation

    var body: some View {
        switch navigation.personalTab {
        case .appearance: AppearancePage()
        case .shortcuts: ShortcutsPage()
        }
    }
}

private struct ShortcutsPage: View {
    @StateObject private var recorder = ShortcutRecorder()

    var body: some View {
        ShortcutCard(title: "全局快捷键", actions: ShortcutAction.allCases.filter { !$0.isScreenshot },
                     recorder: recorder)

        Text("点击右侧方框后按下想要的组合键，至少包含 ⌃、⌥、⌘ 之一（F1～F20 可单独使用）。录制时按 Esc 取消，按删除键清除。")
            .font(.system(size: 11))
            .foregroundStyle(SettingsTheme.textSecondary)
            .padding(.horizontal, 14)
            .onDisappear { recorder.stop() }
    }
}

/// 一组快捷键录制行（「快捷键」页和「截图」页共用）。
/// 录到的组合和系统快捷键冲突时，在那一行下面提示，并让用户选「仍然使用」或「重新录制」。
struct ShortcutCard: View {
    let title: String
    let actions: [ShortcutAction]
    @ObservedObject var recorder: ShortcutRecorder
    @EnvironmentObject private var coordinator: BreakCoordinator

    var body: some View {
        Card {
            CardHeader(title: title)
            ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                if index > 0 { RowDivider() }
                let failed = coordinator.shortcutConflicts.contains(action)
                let pending = recorder.pending?.action == action ? recorder.pending : nil
                SettingRow(title: action.title,
                           subtitle: failed ? "已被其他 App 占用，请换一个" : action.subtitle,
                           subtitleColor: failed ? .red : nil) {
                    ShortcutField(shortcut: coordinator.settings.shortcuts[action],
                                  pending: pending?.shortcut,
                                  isRecording: recorder.recording == action,
                                  onTap: { recorder.toggle(action, coordinator: coordinator) },
                                  onClear: { coordinator.settings.shortcuts[action] = nil })
                }
                if let pending {
                    conflictRow(pending)
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: recorder.pending)
    }

    private func conflictRow(_ pending: ShortcutRecorder.Pending) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("与系统「\(pending.conflictName)」冲突，按下时只会触发系统功能")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("仍然使用") { recorder.acceptPending() }
                .buttonStyle(PillButtonStyle())
            Button("重新录制") { recorder.discardPending() }
                .buttonStyle(PillButtonStyle())
        }
        .padding(.horizontal, SettingsTheme.cardPadding)
        .padding(.bottom, 14)
        .transition(.opacity)
    }
}

/// 快捷键录制框：浅灰圆角底，右侧 ⓧ 清除（样式参考豆包输入法）
struct ShortcutField: View {
    let shortcut: KeyShortcut?
    /// 录制中录到、但和系统冲突还没确认的组合
    var pending: KeyShortcut?
    let isRecording: Bool
    let onTap: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 13, weight: shortcut == nil || isRecording ? .regular : .medium))
                .foregroundStyle(labelColor)
                .frame(maxWidth: .infinity, alignment: .leading)
            if shortcut != nil && !isRecording {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(SettingsTheme.textSecondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("清除")
                .accessibilityLabel("清除快捷键")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 150, height: 30)
        .background(Color(red: 0.94, green: 0.94, blue: 0.95), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(isRecording ? SettingsTheme.accent : .clear, lineWidth: 1.5))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(perform: onTap)
        .animation(.snappy(duration: 0.15), value: isRecording)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(label)
    }

    private var labelColor: Color {
        if isRecording && pending != nil { return .orange }
        return shortcut == nil || isRecording ? SettingsTheme.textSecondary : SettingsTheme.textPrimary
    }

    private var label: String {
        if isRecording, let pending { return pending.display }
        if isRecording { return "请按下快捷键…" }
        return shortcut?.display ?? "点击录制"
    }
}

/// 负责「录制快捷键」：监听设置窗口里的按键，录到合法组合后写进设置
@MainActor
final class ShortcutRecorder: NSObject, ObservableObject {
    /// 录到的组合和系统快捷键冲突，等用户选「仍然使用」或「重新录制」
    struct Pending: Equatable {
        let action: ShortcutAction
        let shortcut: KeyShortcut
        let conflictName: String
    }

    @Published private(set) var recording: ShortcutAction?
    @Published private(set) var pending: Pending?
    private var monitor: Any?
    private weak var coordinator: BreakCoordinator?

    func toggle(_ action: ShortcutAction, coordinator: BreakCoordinator) {
        if recording == action { stop(); return }
        stop()
        self.coordinator = coordinator
        recording = action
        coordinator.isRecordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return nil   // 吞掉按键，免得触发窗口里的其他操作
        }
        // 关掉设置窗口或切到别的 App 时自动结束录制，否则全局快捷键会一直处于注销状态
        if let window = NSApp.keyWindow {
            NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey),
                                                   name: NSWindow.didResignKeyNotification, object: window)
        }
    }

    @objc private func windowResignedKey(_ notification: Notification) {
        stop()
    }

    func stop() {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        pending = nil
        coordinator?.isRecordingShortcut = false
    }

    private func handle(_ event: NSEvent) {
        guard let action = recording, let coordinator else { return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
            & KeyShortcut.allModifierFlags
        // 不带修饰键的 ⎋ 取消、⌫ 清除
        if modifiers == 0 && event.keyCode == 53 { stop(); return }
        if modifiers == 0 && (event.keyCode == 51 || event.keyCode == 117) {
            coordinator.settings.shortcuts[action] = nil
            stop()
            return
        }
        guard KeyShortcut.isAllowed(keyCode: event.keyCode, modifiers: modifiers) else {
            NSSound.beep()
            return
        }
        let characters = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? ""
        let shortcut = KeyShortcut(keyCode: event.keyCode, modifiers: modifiers,
                                   keyName: KeyShortcut.keyName(forKeyCode: event.keyCode, characters: characters))
        // 和系统快捷键冲突：先不保存，保持录制状态，可以直接按别的组合
        if let name = ShortcutConflicts.conflict(for: shortcut, systemHotKeys: SystemHotKeys.current()) {
            pending = Pending(action: action, shortcut: shortcut, conflictName: name)
            NSSound.beep()
            return
        }
        save(shortcut, for: action)
    }

    /// 冲突提示上点「仍然使用」
    func acceptPending() {
        guard let pending else { return }
        save(pending.shortcut, for: pending.action)
    }

    /// 冲突提示上点「重新录制」：清掉提示，继续等用户按键
    func discardPending() {
        pending = nil
    }

    private func save(_ shortcut: KeyShortcut, for action: ShortcutAction) {
        guard let coordinator else { return }
        // 同一个组合只能给一个操作用
        var shortcuts = coordinator.settings.shortcuts
        for (other, existing) in shortcuts where existing == shortcut { shortcuts[other] = nil }
        shortcuts[action] = shortcut
        stop()   // 先恢复注册状态，再写设置，设置变化会触发重新注册
        coordinator.settings.shortcuts = shortcuts
    }
}

// MARK: - 通用小组件

/// 白色圆角卡片
struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .cardBackground()
    }
}

/// 卡片里的分组小标题（如截图中的「语音输入模式」）
struct CardHeader: View {
    let title: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SettingsTheme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, SettingsTheme.cardPadding)
            .frame(height: 46)
            // 小标题下面是通栏分隔线
            Rectangle().fill(SettingsTheme.divider).frame(height: 1)
        }
    }
}

/// 一行设置：左边标题 + 说明，右边控件
struct SettingRow<Control: View>: View {
    let title: String
    var subtitle: String?
    var subtitleColor: Color?
    var emphasized = false
    @ViewBuilder let control: Control

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: emphasized ? 14 : 13, weight: emphasized ? .semibold : .medium))
                    .foregroundStyle(SettingsTheme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(subtitleColor ?? SettingsTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, SettingsTheme.cardPadding)
        .frame(minHeight: SettingsTheme.rowHeight)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// 卡片里两行之间的分隔线（左右缩进，和截图一致）
struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(SettingsTheme.divider)
            .frame(height: 1)
            .padding(.horizontal, SettingsTheme.cardPadding)
    }
}

enum TimeUnit {
    case seconds, minutes, times
    /// 十分之一，显示为百分比（如 8 → 80%），用于透明度
    case percentTens

    var seconds: TimeInterval { self == .minutes ? 60 : 1 }

    func label(_ value: Int) -> String {
        switch self {
        case .seconds: "\(value) 秒"
        case .minutes: "\(value) 分钟"
        case .times: value == 0 ? "不允许" : "\(value) 次"
        case .percentTens: "\(value * 10)%"
        }
    }
}

/// 可拖动的滑条 + 右侧数值。每档 1 个单位（秒、分钟或次）。
struct ValueSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: TimeUnit

    /// 拖动中的值。拖动时只更新它和右侧数字，松手才写进设置——
    /// 否则每经过一格都会保存一次设置、重置一次倒计时
    @State private var draft: Double?
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shown = draft ?? value
        HStack(spacing: 10) {
            SmoothSlider(value: Binding(get: { draft ?? value }, set: { draft = $0 }),
                         range: range,
                         onEditingEnded: {
                             if let draft, draft != value { value = draft }
                             draft = nil
                         })
                .frame(width: 176)
                .accessibilityValue(unit.label(Int(shown.rounded())))
            // 数值放在浅灰胶囊里，和开关、录制框同一套视觉；拖动时变成蓝色
            Text(unit.label(Int(shown.rounded())))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(draft != nil ? SettingsTheme.accent : SettingsTheme.textPrimary)
                .contentTransition(.numericText(value: shown))
                .animation(.snappy(duration: 0.2), value: shown)
                .frame(width: 64, height: 22)
                .background(draft != nil ? SettingsTheme.accent.opacity(0.1) : Color.black.opacity(0.045),
                            in: Capsule())
                .opacity(isEnabled ? 1 : 0.5)
                .animation(.easeOut(duration: 0.15), value: draft != nil)
        }
    }
}

/// 自己画的滑条，和蓝色开关同一套造型：22pt 高的胶囊轨道，左边已选部分填蓝色，
/// 白色圆形滑块嵌在轨道里（四周留 2pt，和开关的滑块一样大）。
/// - 拖动时滑块紧跟手指，数值按整数实时变化；松手后平滑落到对应整数的位置
/// - 点轨道任意位置直接跳过去；鼠标悬停时轨道稍微加深，按住时滑块拉长一点（同开关）
/// - 支持旁白和键盘方向键；键盘选中时滑块外圈出现蓝色细环，不用系统的方形聚焦框
/// 不用系统 Slider：它在窗口失焦时变灰，样式也和设置页不统一。
struct SmoothSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// 一次调整结束（松手、按一下方向键）时调用
    var onEditingEnded: () -> Void = {}

    @Environment(\.isEnabled) private var isEnabled
    /// 拖动中滑块的位置（0～1）；没在拖时为 nil，按数值显示
    @State private var dragFraction: CGFloat?
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    private let height: CGFloat = 22
    private let inset: CGFloat = 2
    private var knob: CGFloat { height - inset * 2 }

    var body: some View {
        GeometryReader { geometry in
            // 滑块中心可移动的范围：从左端到右端各留半个滑块 + 内边距
            let travel = max(geometry.size.width - knob - inset * 2, 1)
            let x = travel * (dragFraction ?? fraction(of: value))
            let pressed = dragFraction != nil
            let knobWidth = knob + (pressed ? 6 : 0)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(isHovering && isEnabled ? 0.09 : 0.065))
                Capsule()
                    .fill(isEnabled ? SettingsTheme.accent : Color.black.opacity(0.18))
                    .frame(width: x + knob + inset * 2)
                Capsule()
                    .fill(.white)
                    .frame(width: knobWidth, height: knob)
                    .shadow(color: .black.opacity(0.18), radius: 1.2, y: 0.6)
                    .overlay(Capsule().strokeBorder(SettingsTheme.accent.opacity(isFocused ? 0.9 : 0), lineWidth: 1.5)
                        .padding(-3))
                    .offset(x: inset + min(x, travel - (knobWidth - knob)))
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard isEnabled else { return }
                        let f = min(max((drag.location.x - inset - knob / 2) / travel, 0), 1)
                        withAnimation(.interactiveSpring(duration: 0.12)) { dragFraction = f }
                        let newValue = (range.lowerBound + Double(f) * span).rounded()
                        if newValue != value { value = newValue }
                    }
                    .onEnded { _ in
                        withAnimation(.snappy(duration: 0.22)) { dragFraction = nil }
                        onEditingEnded()
                    }
            )
            .animation(.snappy(duration: 0.15), value: pressed)
        }
        .frame(height: height)
        .opacity(isEnabled ? 1 : 0.55)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityElement()
        .accessibilityAddTraits(.allowsDirectInteraction)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(+1)
            case .decrement: step(-1)
            @unknown default: break
            }
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()   // 去掉系统那个方形蓝框
        .onKeyPress(.rightArrow) { step(+1); return .handled }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
    }

    private var span: Double { range.upperBound - range.lowerBound }

    /// 键盘或旁白调一格，立即生效
    private func step(_ delta: Double) {
        value = min(max(value + delta, range.lowerBound), range.upperBound)
        onEditingEnded()
    }

    private func fraction(of v: Double) -> CGFloat {
        guard span > 0 else { return 0 }
        return CGFloat((min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / span)
    }
}

/// 自己画的蓝色开关，尺寸和动画参照 macOS 系统开关；按住时滑块会拉长一点
struct BlueSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        BlueSwitch(isOn: configuration.$isOn)
    }
}

struct BlueSwitch: View {
    @Binding var isOn: Bool
    @State private var isPressed = false

    private let width: CGFloat = 38
    private let height: CGFloat = 22
    private let inset: CGFloat = 2

    var body: some View {
        let knobHeight = height - inset * 2
        Capsule()
            .fill(isOn ? SettingsTheme.accent : Color.black.opacity(0.1))
            .frame(width: width, height: height)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(.white)
                    .frame(width: knobHeight + (isPressed ? 5 : 0), height: knobHeight)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 0.75)
                    .padding(inset)
            }
            .animation(.snappy(duration: 0.2), value: isOn)
            .animation(.snappy(duration: 0.15), value: isPressed)
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressed = true }
                    .onEnded { _ in
                        isPressed = false
                        isOn.toggle()
                    }
            )
            .accessibilityElement()
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(isOn ? "开" : "关")
            .accessibilityAction { isOn.toggle() }
    }
}

/// 浅灰胶囊按钮（对应截图里「左^」那种浅灰底）
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(SettingsTheme.textPrimary)
            .padding(.horizontal, 16)
            .frame(height: 28)
            .background(Color(red: 0.94, green: 0.94, blue: 0.95)
                .opacity(configuration.isPressed ? 0.6 : 1),
                        in: RoundedRectangle(cornerRadius: 8))
    }
}

extension View {
    func cardBackground() -> some View {
        background(.white, in: RoundedRectangle(cornerRadius: SettingsTheme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: SettingsTheme.cardRadius).stroke(SettingsTheme.cardBorder, lineWidth: 1))
    }

    /// 蓝色开关（截图里的样式）
    func blueSwitch() -> some View {
        labelsHidden()
            .toggleStyle(BlueSwitchStyle())
    }
}
