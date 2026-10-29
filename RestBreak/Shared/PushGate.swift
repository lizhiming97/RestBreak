import Foundation

/// 推送出口的关卡：AI 的每条推送都先过这里，防止管家变烦
enum PushGate {
    enum Decision: Equatable, Sendable {
        case allow
        case block(String)
    }

    static let sameIntentGap: TimeInterval = 30 * 60

    /// 已经推出去的（显示过、用户处理过的），被拦下和还在排队的不算
    private static func delivered(_ p: PushRecord) -> Bool {
        [.waiting, .shown, .acted, .dismissed, .muted].contains(p.status)
    }

    /// 这条推送算在哪个时刻（显示的时刻；还没显示的按处理时刻）
    private static func when(_ p: PushRecord) -> Date {
        p.shownAt ?? p.handledAt ?? p.createdAt
    }

    private static func deliveredToday(_ b: ButlerData, now: Date, calendar: Calendar) -> [PushRecord] {
        b.pushes.filter { delivered($0) && calendar.isDate(when($0), inSameDayAs: now) }
    }

    static func remainingBudget(_ b: ButlerData, now: Date, calendar: Calendar) -> Int {
        max(0, b.prefs.dailyBudget - deliveredToday(b, now: now, calendar: calendar).filter { $0.intent != .due }.count)
    }

    static func check(_ push: PushRecord, butler b: ButlerData, now: Date, calendar: Calendar) -> Decision {
        // 「到点了」是用户自己交代的事，只看去重
        if push.intent != .due, b.prefs.mutedIntents.contains(push.intent) {
            return .block("你设置了少提醒「\(push.intent.label)」这类")
        }
        let today = deliveredToday(b, now: now, calendar: calendar).filter { $0.id != push.id }
        if let key = push.dedupeKey, today.contains(where: { $0.dedupeKey == key }) {
            return .block("同一件事今天已经说过了")
        }
        guard push.intent != .due else { return .allow }
        if today.contains(where: { $0.intent == push.intent && now.timeIntervalSince(when($0)) < sameIntentGap }) {
            return .block("30 分钟内已经提醒过「\(push.intent.label)」")
        }
        if remainingBudget(b, now: now, calendar: calendar) <= 0 {
            return .block("今天的打扰预算（\(b.prefs.dailyBudget) 条）用完了")
        }
        return .allow
    }
}
