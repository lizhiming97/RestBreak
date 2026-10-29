import AppKit
import SwiftUI

/// 「提醒」页的分段（2026-10-29 用户要求只留两个：留意什么写在 Agent 的定时任务里，App 不再重复配置）
enum RemindersTab: String, CaseIterable, Identifiable {
    case setup = "功能接入"
    case history = "记录"

    var id: Self { self }
}

struct RemindersPage: View {
    @EnvironmentObject private var coordinator: BreakCoordinator
    @EnvironmentObject private var navigation: SettingsNavigation

    var body: some View {
        switch navigation.remindersTab {
        case .setup: ReminderOverview(model: coordinator.reminders, server: coordinator.localMCP)
        case .history: ReminderHistoryPage(model: coordinator.reminders)
        }
    }
}

/// 「记录」页顶上的「定时提醒」卡片：还在生效的到点提醒，只能看、暂停、删除。
/// 新建、修改都跟 Agent 说（这正是要避开的传统写法），所以不做表单；没有就不显示
struct ReminderList: View {
    @ObservedObject var model: ReminderCoordinator
    @State private var expanded: String?
    @State private var pendingDelete: Reminder?

    var body: some View {
        let reminders = model.data.reminders.filter { $0.state != .finished }.sorted { a, b in
            a.state == b.state ? a.createdAt > b.createdAt : order(a.state) < order(b.state)
        }
        if !reminders.isEmpty {
            Card {
                CardHeader(title: "定时提醒")
                ForEach(Array(reminders.enumerated()), id: \.element.id) { index, reminder in
                    if index > 0 { RowDivider() }
                    row(reminder)
                }
            }
            .alert("删除「\(pendingDelete?.title ?? "")」？", isPresented: Binding(get: { pendingDelete != nil },
                                                                          set: { if !$0 { pendingDelete = nil } })) {
                Button("删除", role: .destructive) { pendingDelete.map { model.delete($0.id) } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("完成记录也会一起删掉。")
            }
        }
        if let error = model.errorText {
            Text(error).font(.system(size: 11)).foregroundStyle(.red).padding(.horizontal, 14)
        }
    }

    private func order(_ state: ReminderState) -> Int {
        switch state {
        case .active: 0
        case .paused: 1
        case .finished: 2
        }
    }

    @ViewBuilder
    private func row(_ reminder: Reminder) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(title: reminder.title, subtitle: model.subtitle(for: reminder)) {
                HStack(spacing: 8) {
                    if reminder.style == .firm { Tag(text: "强提醒") }
                    Tag(text: ClientNames.display(reminder.createdBy))
                    if reminder.state != .finished {
                        Button(reminder.state == .paused ? "恢复" : "暂停") { model.togglePause(reminder.id) }
                            .buttonStyle(PillButtonStyle())
                    }
                    Button { pendingDelete = reminder } label: { Image(systemName: "trash") }
                        .buttonStyle(PillButtonStyle())
                        .accessibilityLabel("删除")
                }
                .fixedSize()   // 标签和按钮不被挤小，左边的说明文字换行
            }
            .contentShape(Rectangle())
            .onTapGesture { expanded = expanded == reminder.id ? nil : reminder.id }
            if expanded == reminder.id { details(reminder) }
        }
    }

    private func details(_ reminder: Reminder) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reason = reminder.reason { Text("来源：\(reason)") }
            Text("提醒文案：" + reminder.messages.joined(separator: " / "))
            let history = model.history(reminder.id, days: 7)
            Text(history.isEmpty ? "最近 7 天：还没响过" : "最近 7 天：\n" + history.prefix(10).joined(separator: "\n"))
        }
        .font(.system(size: 11))
        .foregroundStyle(SettingsTheme.textSecondary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SettingsTheme.cardPadding)
        .padding(.bottom, 14)
    }
}

private struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(SettingsTheme.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Color(red: 0.94, green: 0.94, blue: 0.95), in: Capsule())
    }
}
