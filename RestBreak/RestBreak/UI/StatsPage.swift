import Charts
import SwiftUI

/// 设置窗口里的「统计」页：今日概览、最近 7 / 30 天趋势、连续工作时长
struct StatsPage: View {
    @EnvironmentObject private var coordinator: BreakCoordinator
    @State private var range: StatsRange = .week

    var body: some View {
        let now = Date()
        let today = coordinator.stats.day(for: now)
        let days = coordinator.stats.lastDays(range.days, endingAt: now)

        TodayCard(today: today)
        TrendCard(days: days, range: $range)
        WorkStretchCard(today: today, days: days)
    }
}

enum StatsRange: Int, CaseIterable, Identifiable {
    case week = 7
    case month = 30

    var id: Int { rawValue }
    var days: Int { rawValue }
    var title: String { self == .week ? "7 天" : "30 天" }
}

/// 连续工作超过这个时长就该休息了（图表上的参考线）
private let recommendedStretch: TimeInterval = 60 * 60

// MARK: - 今日概览

private struct TodayCard: View {
    let today: DayStats

    var body: some View {
        StatsCard {
            HStack(spacing: 0) {
                BigNumber(value: "\(today.completed + today.naturalBreaks)", unit: "次", label: "今天已休息")
                StatDivider()
                BigNumber(value: today.completionRate.map { "\(Int(($0 * 100).rounded()))" } ?? "–",
                          unit: today.completionRate == nil ? "" : "%", label: "完成率")
                StatDivider()
                BigNumber(value: StatsFormat.duration(today.restSeconds).value,
                          unit: StatsFormat.duration(today.restSeconds).unit, label: "累计休息")
                StatDivider()
                BigNumber(value: StatsFormat.duration(today.longestWorkStretch).value,
                          unit: StatsFormat.duration(today.longestWorkStretch).unit, label: "最长连续工作",
                          warning: today.longestWorkStretch > recommendedStretch)
            }
            .padding(.vertical, 18)

            StatsDivider()
            HStack(spacing: 18) {
                Legend(color: StatsColors.completed, text: "按时完成 \(today.completed)")
                Legend(color: StatsColors.natural, text: "离开电脑 \(today.naturalBreaks)")
                Legend(color: StatsColors.skipped, text: "跳过 \(today.skipped)")
                Legend(color: StatsColors.postponed, text: "推迟 \(today.postponed)")
                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(height: 44)
        }
    }
}

private struct BigNumber: View {
    let value: String
    let unit: String
    let label: String
    var warning = false

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(unit)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(warning ? StatsColors.warning : StatsColors.textPrimary)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(StatsColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct StatDivider: View {
    var body: some View {
        Rectangle().fill(StatsColors.divider).frame(width: 1, height: 36)
    }
}

// MARK: - 趋势

private struct TrendCard: View {
    let days: [DayStats]
    @Binding var range: StatsRange

    var body: some View {
        StatsCard {
            HStack {
                Text("休息趋势")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StatsColors.textPrimary)
                Spacer()
                RangePicker(range: $range)
            }
            .padding(.horizontal, 18)
            .frame(height: 50)
            StatsDivider()

            Chart {
                ForEach(days, id: \.date) { day in
                    let date = StatsFormat.date(day.date)
                    BarMark(x: .value("日期", date, unit: .day), y: .value("次数", day.completed))
                        .foregroundStyle(by: .value("类型", "按时完成"))
                    BarMark(x: .value("日期", date, unit: .day), y: .value("次数", day.naturalBreaks))
                        .foregroundStyle(by: .value("类型", "离开电脑"))
                    BarMark(x: .value("日期", date, unit: .day), y: .value("次数", day.skipped))
                        .foregroundStyle(by: .value("类型", "跳过"))
                }
            }
            .chartForegroundStyleScale(["按时完成": StatsColors.completed,
                                        "离开电脑": StatsColors.natural,
                                        "跳过": StatsColors.skipped])
            .chartLegend(.hidden)
            .chartXAxis { dayAxis }
            .chartYAxis { countAxis }
            .frame(height: 160)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .animation(.snappy(duration: 0.25), value: range)

            StatsDivider()
            HStack(spacing: 18) {
                Legend(color: StatsColors.completed, text: "按时完成")
                Legend(color: StatsColors.natural, text: "离开电脑")
                Legend(color: StatsColors.skipped, text: "跳过")
                Spacer()
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(StatsColors.textSecondary)
            }
            .padding(.horizontal, 18)
            .frame(height: 44)
        }
    }

    private var summary: String {
        let rested = days.reduce(0) { $0 + $1.completed + $1.naturalBreaks }
        let completed = days.reduce(0) { $0 + $1.completed }
        let skipped = days.reduce(0) { $0 + $1.skipped }
        guard rested + skipped > 0 else { return "还没有记录，休息几次后这里会显示趋势" }
        let rate = completed + skipped == 0 ? "" : "，完成率 \(Int((Double(completed) / Double(completed + skipped) * 100).rounded()))%"
        return "近 \(range.title)共休息 \(rested) 次\(rate)"
    }

    @AxisContentBuilder private var dayAxis: some AxisContent {
        AxisMarks(values: .stride(by: .day, count: range == .week ? 1 : 5)) { _ in
            AxisValueLabel(format: range == .week ? .dateTime.weekday(.narrow) : .dateTime.month(.defaultDigits).day(),
                           centered: true)
                .foregroundStyle(StatsColors.textSecondary)
        }
    }

    @AxisContentBuilder private var countAxis: some AxisContent {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
            AxisGridLine().foregroundStyle(StatsColors.divider)
            AxisValueLabel().foregroundStyle(StatsColors.textSecondary)
        }
    }
}

/// 「7 天 / 30 天」切换，浅灰底 + 白色选中块（和 macOS 分段控件同样的观感）
private struct RangePicker: View {
    @Binding var range: StatsRange
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(StatsRange.allCases) { item in
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(item == range ? StatsColors.textPrimary : StatsColors.textSecondary)
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background {
                        if item == range {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.white)
                                .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                                .matchedGeometryEffect(id: "selected", in: selection)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.snappy(duration: 0.2)) { range = item }
                    }
                    .accessibilityAddTraits(item == range ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(Color(red: 0.94, green: 0.94, blue: 0.95), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - 连续工作时长

private struct WorkStretchCard: View {
    let today: DayStats
    let days: [DayStats]

    var body: some View {
        StatsCard {
            VStack(alignment: .leading, spacing: 3) {
                Text("最长连续工作")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StatsColors.textPrimary)
                Text("每天最长一次连续用电脑多久没休息。建议不超过 60 分钟，超过的那天会标成橙色")
                    .font(.system(size: 11))
                    .foregroundStyle(StatsColors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            StatsDivider()

            Chart {
                ForEach(days, id: \.date) { day in
                    BarMark(x: .value("日期", StatsFormat.date(day.date), unit: .day),
                            y: .value("分钟", day.longestWorkStretch / 60))
                        .foregroundStyle(day.longestWorkStretch > recommendedStretch
                                         ? StatsColors.warning : StatsColors.completed.opacity(0.75))
                        .cornerRadius(3)
                }
                RuleMark(y: .value("建议", recommendedStretch / 60))
                    .foregroundStyle(StatsColors.warning.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("60 分钟")
                            .font(.system(size: 10))
                            .foregroundStyle(StatsColors.warning)
                    }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: days.count <= 7 ? 1 : 5)) { _ in
                    AxisValueLabel(format: days.count <= 7 ? .dateTime.weekday(.narrow) : .dateTime.month(.defaultDigits).day(),
                                   centered: true)
                        .foregroundStyle(StatsColors.textSecondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(StatsColors.divider)
                    AxisValueLabel {
                        if let minutes = value.as(Double.self) { Text("\(Int(minutes))分") }
                    }
                    .foregroundStyle(StatsColors.textSecondary)
                }
            }
            .chartYScale(domain: 0...max(90, (days.map(\.longestWorkStretch).max() ?? 0) / 60 * 1.1))
            .frame(height: 140)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
    }
}

// MARK: - 小组件

private struct Legend: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(StatsColors.textSecondary)
        }
    }
}

/// 和设置页一样的白色圆角卡片
private struct StatsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(.white, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(StatsColors.cardBorder, lineWidth: 1))
    }
}

private struct StatsDivider: View {
    var body: some View {
        Rectangle().fill(StatsColors.divider).frame(height: 1)
    }
}

private enum StatsColors {
    static let completed = Color(red: 0.24, green: 0.48, blue: 0.97)
    static let natural = Color(red: 0.55, green: 0.73, blue: 0.99)
    static let skipped = Color(red: 0.80, green: 0.80, blue: 0.82)
    static let postponed = Color(red: 0.98, green: 0.73, blue: 0.30)
    static let warning = Color(red: 0.96, green: 0.55, blue: 0.16)
    static let textPrimary = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let textSecondary = Color(red: 0.54, green: 0.54, blue: 0.56)
    static let divider = Color(red: 0.918, green: 0.918, blue: 0.925)
    static let cardBorder = Color(red: 0.906, green: 0.906, blue: 0.914)
}

enum StatsFormat {
    /// 时长：2 小时以内显示「63 分」，更长显示「2.5 时」
    static func duration(_ seconds: TimeInterval) -> (value: String, unit: String) {
        let minutes = seconds / 60
        if minutes < 120 { return ("\(Int(minutes.rounded()))", "分") }
        return (String(format: "%.1f", minutes / 60), "时")
    }

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(_ key: String) -> Date {
        parser.date(from: key) ?? Date()
    }
}
