import SwiftUI

/// 某一天弹过的东西：Agent 的推送 + 到点提醒（纯逻辑，方便测试）
enum ReminderHistory {
    struct Entry: Identifiable, Equatable {
        let id: String
        let time: Date
        let intent: PushIntent
        let title: String
        /// 第二行：推送写「为什么是现在」，到点提醒写结果
        let detail: String
        /// 第三行：来意 · 状态 · 来源
        let meta: String
    }

    /// 被关卡拦下、过期的推送没有真的弹出来，也列出来（写原因），方便看 Agent 推了什么
    static func entries(_ data: ReminderData, on day: Date, calendar: Calendar) -> [Entry] {
        let pushes = data.butler.pushes.compactMap { p -> Entry? in
            let time = p.shownAt ?? p.createdAt
            guard calendar.isDate(time, inSameDayAs: day) else { return nil }
            return Entry(id: "push|\(p.id)", time: time, intent: p.intent, title: p.title, detail: p.why,
                         meta: "\(p.intent.label) · \(p.statusText) · \(ClientNames.display(p.source))")
        }
        let reminders = data.occurrences.compactMap { o -> Entry? in
            guard calendar.isDate(o.scheduledAt, inSameDayAs: day), let r = data.reminder(o.reminderID) else { return nil }
            let lead = o.leadDays > 0 ? "（提前 \(o.leadDays) 天预告）" : ""
            return Entry(id: "fire|\(o.reminderID)|\(o.scheduledAt.timeIntervalSince1970)", time: o.scheduledAt, intent: .due,
                         title: r.title, detail: ReminderTools.outcomeText(o.outcome) + lead,
                         meta: "到点提醒 · \(r.style == .firm ? "强提醒" : "普通") · \(ClientNames.display(r.createdBy))")
        }
        return (pushes + reminders).sorted { $0.time > $1.time }
    }
}

/// 「提醒 › 记录」：还在生效的定时提醒 + 最近 7 天，选一天看那天弹过的推送和到点提醒
struct ReminderHistoryPage: View {
    @ObservedObject var model: ReminderCoordinator
    @State private var selected = Calendar.current.startOfDay(for: Date())

    private var calendar: Calendar { .current }

    var body: some View {
        let today = calendar.startOfDay(for: Date())
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }.reversed()
        let entries = ReminderHistory.entries(model.data, on: selected, calendar: calendar)

        ReminderList(model: model)

        HStack(spacing: 6) {
            ForEach(Array(days), id: \.self) { day in
                dayChip(day, count: ReminderHistory.entries(model.data, on: day, calendar: calendar).count,
                        isToday: day == today)
            }
        }

        Card {
            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 24))
                        .foregroundStyle(SettingsTheme.textSecondary.opacity(0.6))
                    Text(selected == today ? "今天还没有提醒" : "这天没有提醒")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(SettingsTheme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            }
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { RowDivider() }
                row(entry)
            }
        }
        Text("Agent 的推送保留 14 天，到点提醒的记录保留 90 天。")
            .font(.system(size: 11))
            .foregroundStyle(SettingsTheme.textSecondary)
            .padding(.horizontal, 14)
    }

    private func dayChip(_ day: Date, count: Int, isToday: Bool) -> some View {
        let isSelected = day == selected
        let weekday = "周" + ScheduleText.weekdayNames[ReminderPlanner.isoWeekday(day, calendar: calendar) - 1]
        return VStack(spacing: 3) {
            Text(isToday ? "今天" : weekday)
                .font(.system(size: 11, weight: .medium))
            Text("\(calendar.component(.day, from: day))")
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
            Circle()
                .fill(count > 0 ? (isSelected ? Color.white : SettingsTheme.accent) : .clear)
                .frame(width: 5, height: 5)
        }
        .foregroundStyle(isSelected ? .white : SettingsTheme.textPrimary)
        .frame(maxWidth: .infinity)
        .frame(height: 62)
        .background(isSelected ? SettingsTheme.accent : .white, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? .clear : SettingsTheme.cardBorder, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.15)) { selected = day } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(isToday ? "今天" : weekday) \(calendar.component(.day, from: day)) 日，\(count) 条")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func row(_ entry: ReminderHistory.Entry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(TimeText.hourMinute(entry.time))
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(SettingsTheme.textSecondary)
                .frame(width: 40, alignment: .leading)
            Circle()
                .fill(IslandIntent(entry.intent).tint)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SettingsTheme.textPrimary)
                Text(entry.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.textPrimary.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                Text(entry.meta)
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SettingsTheme.cardPadding)
        .padding(.vertical, 12)
        .textSelection(.enabled)
    }
}
