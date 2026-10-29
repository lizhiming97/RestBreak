import AppKit
import SwiftUI

/// 「提醒 › 功能接入」：这个功能是干什么的（带一块真实的灵动岛示意）+ 连接只需两步 + 连接状态。
/// 「留意什么」由用户写在 Agent 的定时任务里，App 不重复配置；App 只管打扰上限
/// 接法和瑞幸 MCP 一样：把地址 + 密钥交给用户的 Agent，它自己配好；不扫描用户装了哪些 App（2026-10-28 用户要求）
struct ReminderOverview: View {
    @ObservedObject var model: ReminderCoordinator
    @ObservedObject var server: LocalMCPServer
    @State private var copied: String?
    @State private var confirmReset = false
    @State private var showAdvanced = false

    var body: some View {
        Card {
            IslandPreview()
                .padding([.horizontal, .top], 14)
            VStack(alignment: .leading, spacing: 8) {
                Text("让你的 AI 当管家，挑最该说的那句")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SettingsTheme.textPrimary)
                Text("你的 Agent 定时来看看你：在不在电脑前、连续工作了多久、今天有什么日程和提醒，再结合它对你的了解，挑一件此刻最值得说的事，从刘海轻轻弹出来。说了明确时间的事（「每晚 9 点提醒我吃药」），星期五到点准时提醒。")
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Image(systemName: "heart.text.square")
                    Text("下一站：你的个人健康管家——喝水、久坐、作息，它替你记着")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(IslandTheme.rose.opacity(0.95))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(IslandTheme.rose.opacity(0.10), in: Capsule())
                .padding(.top, 2)
            }
            .padding(.horizontal, SettingsTheme.cardPadding)
            .padding(.top, 14)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        Card {
            CardHeader(title: "连接只需两步")
            StepRow(number: 1, title: "把接入指令交给你的 Agent",
                    detail: "复制后发给 Codex 等支持 MCP 的 Agent，它会自己配好。配好后新开一个对话才能用。") {
                copyButton("setup", "复制接入指令", enabled: server.url != nil) {
                    server.url.map { AIIntegration.setupText(url: $0, token: server.token) }
                }
            }
            RowDivider()
            StepRow(number: 2, title: "设一个定时任务",
                    detail: "在 Agent 里新建定时任务，把下面这段贴进说明，最后一条写上你想让它留意的事。每 30～60 分钟运行一次。") {
                copyButton("patrol", "复制任务说明") { AIIntegration.patrolPrompt }
            }
            Text(AIIntegration.patrolPrompt)
                .font(.system(size: 11))
                .foregroundStyle(SettingsTheme.textSecondary)
                .lineSpacing(2)
                .lineLimit(5)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SettingsTheme.fieldBackground, in: RoundedRectangle(cornerRadius: 8))
                .padding(.leading, SettingsTheme.cardPadding + 34)
                .padding(.trailing, SettingsTheme.cardPadding)
                .padding(.bottom, 16)
            RowDivider()
            connectionRow
            if showAdvanced { advanced }
        }
        .alert("换一个新密钥？", isPresented: $confirmReset) {
            Button("换", role: .destructive) { server.resetToken(); copied = nil }
            Button("取消", role: .cancel) {}
        } message: {
            Text("已经接入的 Agent 会立即连不上，要重新复制接入指令给它们。")
        }

        Text("星期五不调用任何 AI；提醒只存在这台 Mac 上，只有你的 Agent 来读时才会作为对话内容发送出去。")
            .font(.system(size: 11))
            .foregroundStyle(SettingsTheme.textSecondary)
            .padding(.horizontal, 14)
    }

    /// 最近用过的 Agent；点「更多」展开本机地址、换密钥、Codex 手动配置
    private var connectionRow: some View {
        let latest = model.data.clients.max { $0.lastSeen < $1.lastSeen }
        return SettingRow(title: latest.map { "已连接：\(ClientNames.display($0.name))" } ?? "还没有 Agent 连上",
                          subtitle: latest.map { "\(ScheduleText.ago($0.lastSeen, now: Date()))用过" }
                              ?? "接好以后，在新对话里说「看看我星期五里的提醒」试试") {
            Button(showAdvanced ? "收起" : "更多") { withAnimation(.snappy(duration: 0.2)) { showAdvanced.toggle() } }
                .buttonStyle(PillButtonStyle())
        }
    }

    @ViewBuilder
    private var advanced: some View {
        let prefs = model.data.butler.prefs
        RowDivider()
        SettingRow(title: "每天最多主动推送", subtitle: "防止 Agent 推得太勤；不含到点提醒") {
            ValueSlider(value: Binding(get: { Double(prefs.dailyBudget) },
                                       set: { v in model.updateButlerPrefs { $0.dailyBudget = Int(v) } }),
                        range: 0...20, unit: .times)
        }
        if !prefs.mutedIntents.isEmpty {
            RowDivider()
            SettingRow(title: "已少提醒", subtitle: prefs.mutedIntents.map(\.label).joined(separator: "、")) {
                Button("全部恢复") { model.updateButlerPrefs { $0.mutedIntents = [] } }.buttonStyle(PillButtonStyle())
            }
        }
        RowDivider()
        SettingRow(title: "本机地址", subtitle: server.url.map { "\($0)　只有这台 Mac 能连，星期五 App 要开着" }
                   ?? server.failure ?? "正在打开…", subtitleColor: server.failure == nil ? nil : .red) {
            Button("换密钥") { confirmReset = true }.buttonStyle(PillButtonStyle())
        }
        RowDivider()
        SettingRow(title: "Codex 手动配置", subtitle: "Codex 没能自己配好时，把这段贴到 ~/.codex/config.toml 末尾") {
            copyButton("codex", "复制", enabled: server.url != nil) {
                server.url.map { AIIntegration.codexSnippet(url: $0, token: server.token) }
            }
        }
    }

    /// text 只在点击时生成；本机地址还没开好时 enabled 为 false
    private func copyButton(_ key: String, _ title: String, enabled: Bool = true,
                            _ text: @escaping () -> String?) -> some View {
        Button(copied == key ? "已复制" : title) {
            guard let value = text() else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied = key
        }
        .buttonStyle(PillButtonStyle())
        .disabled(!enabled)
    }
}

/// 带圆形序号的一步
private struct StepRow<Control: View>: View {
    let number: Int
    let title: String
    let detail: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SettingsTheme.accent)
                .frame(width: 22, height: 22)
                .background(SettingsTheme.accent.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SettingsTheme.textPrimary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, SettingsTheme.cardPadding)
        .padding(.vertical, 16)
    }
}

/// 灵动岛示意：一块「屏幕顶部」的小画面，上面是真正的灵动岛组件（展开态），和实际弹出的一模一样
struct IslandPreview: View {
    @StateObject private var model: IslandModel = {
        let model = IslandModel()
        model.item = IslandItem(key: "preview", intent: .urgent, symbol: "calendar", kind: nil, compact: "10:30",
                                title: "产品评审 10:30 开始",
                                message: "你昨天说要带转化数据，那张表今天还没打开过。",
                                trailing: "10:22", autoDismiss: nil,
                                actions: [.init(title: "知道了") {}, .init(title: "打开表格", primary: true) {}])
        model.stage = .expanded
        return model
    }()

    private static let notch = CGSize(width: 150, height: 30)
    static let height: CGFloat = 170

    var body: some View {
        ZStack(alignment: .top) {
            // 桌面：浅色渐变 + 菜单栏
            LinearGradient(colors: [Color(red: 0.80, green: 0.90, blue: 0.93), Color(red: 0.90, green: 0.88, blue: 0.97)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // 展开的岛宽 400，左右只露出一点菜单栏：只放两头的图标，不放会被盖住的文字
            HStack {
                Image(systemName: "apple.logo")
                Spacer()
                Image(systemName: "cup.and.saucer")
            }
            .font(.system(size: 11))
            .foregroundStyle(.black.opacity(0.65))
            .padding(.horizontal, 14)
            .frame(height: Self.notch.height)
            .background(.white.opacity(0.45))
            IslandView(model: model, notch: Self.notch)
                .allowsHitTesting(false)
        }
        .frame(height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("示意：刘海处弹出一条提醒「产品评审 10:30 开始」")
    }
}
