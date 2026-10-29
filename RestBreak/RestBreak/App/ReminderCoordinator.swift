import AppKit
import Foundation

extension Notification.Name {
    /// 共享文件夹里的提醒数据变了（小程序发 Darwin 通知，转成进程内通知）
    static let reminderStoreChanged = Notification.Name("reminderStoreChanged")
}

/// 提醒的总指挥：到点（最晚 30 秒一次）处理到期提醒，用刘海灵动岛提醒用户；
/// 系统通知只作兜底（比响铃晚 90 秒登记，星期五在运行时会先处理掉、撤销它）
@MainActor
final class ReminderCoordinator: NSObject, ObservableObject {   // NSObject：系统通知用 selector 方式监听
    @Published private(set) var data = ReminderData()
    @Published private(set) var errorText: String?

    /// 休息中、开会、全屏时提醒先等一等（最多 30 分钟），由 BreakCoordinator 提供
    var isBusy: () -> Bool = { false }
    /// 点通知打开「提醒」页
    var onOpenPage: (() -> Void)?

    private let store: ReminderStore?
    private let notifier = ReminderNotifier()
    private var calendar: Calendar { Calendar.current }
    private let island = NotchIsland()
    /// 因为忙而在等的提醒
    private var waiting: [(item: IslandItem, fire: Fire?, since: Date)] = []
    private var lastPlan: [Fire] = []
    /// 内存里的「处理到哪了」（见 check）
    private var memoryCheckedAt: Date?
    private var lastPlanAt = Date.distantPast
    private var task: Task<Void, Never>?
    private static let maxCardWait: TimeInterval = 30 * 60

    init(store: ReminderStore? = try? ReminderStore.shared()) {
        self.store = store
        super.init()
        if store == nil { errorText = StoreError.noContainer.description }
    }

    func start() {
        notifier.start()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(center, nil, { _, _, _, _, _ in
            DispatchQueue.main.async { NotificationCenter.default.post(name: .reminderStoreChanged, object: nil) }
        }, DarwinNotice.remindersChanged as CFString, nil, .deliverImmediately)
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged), name: .reminderStoreChanged, object: nil)
        // 改了系统时间、时区，过了零点，从睡眠醒来：重新处理并重新登记
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            NotificationCenter.default.addObserver(self, selector: #selector(clockChanged), name: name, object: nil)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(clockChanged),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        check()
        // 系统通知只在星期五没运行时兜底，仍然要权限
        if !data.reminders.isEmpty { notifier.requestAuthorization() }
        // 只在有事的时候醒：下一次响铃、强提醒的再提醒、等着的提醒。没事就睡（数据变化、改时间、醒来都会立刻处理）
        task = Task { [weak self] in
            while !Task.isCancelled {
                let wait = self?.secondsUntilNextWork() ?? 30
                try? await Task.sleep(for: .seconds(wait), tolerance: .milliseconds(wait > 60 ? 2000 : 200))
                self?.check()
            }
        }
    }

    private func secondsUntilNextWork(now: Date = Date()) -> Double {
        var wait: Double = 3600   // 没事时一小时兜底一次（顺便清理 90 天前的记录）
        if let next = lastPlan.first?.ringAt { wait = min(wait, next.timeIntervalSince(now) + 0.2) }
        // 强提醒在等你处理：每分钟看一次要不要再提醒
        if data.occurrences.contains(where: { $0.outcome == .pending }) { wait = min(wait, 60) }
        // 因为忙（休息、开会、全屏）在等的提醒：30 秒看一次还忙不忙
        if !waiting.isEmpty { wait = min(wait, 30) }
        return max(0.5, wait)
    }

    @objc private func storeChanged() {
        lastPlan = []   // 改了标题、文案或强度时响铃时间不变，但登记的横幅内容要换
        reload()
        check()
    }

    @objc private func clockChanged() {
        lastPlan = []   // 强制重新登记
        check()
    }

    // MARK: - 处理

    func check(now: Date = Date()) {
        guard let store else { return }
        let report: ProcessReport
        do {
            report = try store.update(notify: false) { data in
                // checkedAt 只是「处理到哪了」，每次都变。只为它写盘太浪费：放在内存里，
                // 只有提醒、记录真的变了才连同它一起写。星期五重启后从磁盘上较早的 checkedAt 补处理，结果一样
                let original = data
                if let memory = memoryCheckedAt, memory > (data.checkedAt ?? .distantPast) { data.checkedAt = memory }
                let report = ReminderPlanner.process(&data, now: now, calendar: calendar)
                memoryCheckedAt = data.checkedAt
                var withoutClock = data
                withoutClock.checkedAt = original.checkedAt
                if original.checkedAt != nil, withoutClock == original { data = original }   // 只有 checkedAt 变了：不写盘
                return report
            }
            errorText = nil
        } catch {
            errorText = "\(error)"
            return
        }
        reload()
        for fire in report.rings + report.cards { present(ringItem(fire), fire: fire, now: now) }
        for fire in report.nags { present(ringItem(fire, nag: true), fire: fire, now: now) }
        for fire in report.expired { island.dismiss(key: key(fire)) }
        if !report.lateTitles.isEmpty { present(summaryItem(report.lateTitles), fire: nil, now: now) }
        for r in report.created { present(createdItem(r), fire: nil, now: now) }
        // 等着的：不忙了就弹；等了 30 分钟还在忙就不等了（强提醒没处理会照常再提醒）
        waiting = waiting.filter { entry in
            if let fire = entry.fire, data.reminder(fire.reminderID) == nil { return false }
            if let fire = entry.fire, fire.reminderID.isEmpty == false,
               let outcome = data.occurrence(fire.reminderID, at: fire.scheduledAt)?.outcome,
               outcome != .pending && outcome != .notified { return false }
            if !isBusy() { island.show(entry.item); return false }
            if now.timeIntervalSince(entry.since) >= Self.maxCardWait {
                entry.item.onDropped?()
                return false
            }
            return true
        }
        reschedule(now: now)
    }

    private func reload() {
        guard let store else { return }
        do {
            data = try store.load()
        } catch {
            errorText = "\(error)"
        }
    }

    /// 接下来 7 天最多 50 条登记成系统定时通知（系统上限 64，留 14 条给休息通知）。没变就不重登，最多每小时强制一次
    private func reschedule(now: Date) {
        let plan = ReminderPlanner.plan(data, from: now, days: 7, limit: 50, calendar: calendar)
        guard plan != lastPlan || now.timeIntervalSince(lastPlanAt) > 3600 else { return }
        lastPlan = plan
        lastPlanAt = now
        var ordinals: [String: Int] = [:]
        let items = plan.compactMap { fire -> (fire: Fire, reminder: Reminder, message: String)? in
            guard let r = data.reminder(fire.reminderID) else { return nil }
            let base = data.occurrences.filter { $0.reminderID == r.id }.count
            let ordinal = base + ordinals[r.id, default: 0]
            ordinals[r.id, default: 0] += 1
            return (fire, r, ReminderPlanner.message(r, fire: fire, ordinal: ordinal))
        }
        notifier.schedule(items, calendar: calendar)
    }

    private func message(_ r: Reminder, _ fire: Fire) -> String {
        let ordinal = data.occurrences.filter { $0.reminderID == r.id && $0.scheduledAt < fire.scheduledAt }.count
        return ReminderPlanner.message(r, fire: fire, ordinal: ordinal)
    }

    // MARK: - 灵动岛

    private func key(_ fire: Fire) -> String { "\(fire.reminderID)|\(fire.scheduledAt.timeIntervalSince1970)" }

    private func present(_ item: IslandItem?, fire: Fire?, now: Date) {
        guard let item else { return }
        if isBusy() { waiting.append((item, fire, now)) } else { island.show(item) }
    }

    /// 到点或再提醒：普通提醒展开 15 秒后自动收起，强提醒点了才收
    private func ringItem(_ fire: Fire, nag: Bool = false) -> IslandItem? {
        guard let r = data.reminder(fire.reminderID) else { return nil }
        let firm = r.style == .firm
        var actions: [IslandItem.Action] = [
            .init(title: "10 分钟后") { [weak self] in self?.snooze(fire) },
            .init(title: "完成", primary: true) { [weak self] in self?.act(fire, .done) },
        ]
        if firm { actions.insert(.init(title: "跳过这次") { [weak self] in self?.act(fire, .skipped) }, at: 0) }
        let count = data.occurrence(fire.reminderID, at: fire.scheduledAt)?.nagCount ?? 0
        return IslandItem(key: key(fire), intent: .due, symbol: IslandTheme.symbol(for: r.title),
                          kind: nag ? "第 \(count + 1) 次提醒" : nil,
                          compact: String(r.title.prefix(4)),
                          title: r.title,
                          message: message(r, fire),
                          trailing: TimeText.hourMinute(fire.scheduledAt),
                          firm: firm,
                          autoDismiss: firm ? nil : 15,
                          actions: actions)
    }

    private func createdItem(_ r: Reminder) -> IslandItem {
        let next = ReminderPlanner.next(r, after: Date(), count: 1, calendar: calendar).first
        return IslandItem(key: "created|\(r.id)", intent: .info, symbol: "sparkles", kind: "新提醒",
                          compact: "已记下",
                          title: "\(ClientNames.display(r.createdBy)) 帮你记下了「\(r.title)」",
                          message: ScheduleText.describe(r.schedule, calendar: calendar)
                              + (next.map { "，下次 \(ScheduleText.fireText($0.scheduledAt, now: Date(), calendar: calendar))" } ?? ""),
                          autoDismiss: 8,
                          actions: [.init(title: "撤销") { [weak self] in self?.delete(r.id) },
                                    .init(title: "好的", primary: true) { [weak self] in self?.island.dismiss(key: "created|\(r.id)") }])
    }

    private func summaryItem(_ titles: [String]) -> IslandItem {
        IslandItem(key: "summary|\(Date().timeIntervalSince1970)", intent: .forgot, symbol: "clock.arrow.circlepath",
                   kind: "你不在时", compact: "\(titles.count) 条",
                   title: "你不在的时候有 \(titles.count) 条提醒",
                   message: Array(Set(titles)).sorted().joined(separator: "、"),
                   autoDismiss: 12,
                   actions: [.init(title: "知道了") { [weak self] in self?.island.dismiss(prefix: "summary|") },
                             .init(title: "看看", primary: true) { [weak self] in self?.onOpenPage?() }])
    }

    /// 管家推送也走这里：忙（休息、开会、全屏）时先等，最多 30 分钟
    func showIsland(_ item: IslandItem) {
        present(item, fire: nil, now: Date())
    }

    func dismissIsland(key: String) {
        island.dismiss(key: key)
        waiting.removeAll { $0.item.key == key }
    }

    /// 改管家设置（打扰预算、关注方向、恢复被屏蔽的来意）
    /// 不发「提醒变了」通知：设置不影响响铃，发了主 App 自己会再读一遍、重新登记兜底通知
    func updateButlerPrefs(_ change: (inout ButlerPrefs) -> Void) {
        try? store?.update(notify: false) { change(&$0.butler.prefs) }
        reload()
    }

    // MARK: - 用户操作

    func act(_ fire: Fire, _ outcome: Outcome, now: Date = Date()) {
        try? store?.update { $0.setOutcome(fire.reminderID, scheduledAt: fire.scheduledAt, leadDays: fire.leadDays, outcome, now: now) }
        island.dismiss(key: key(fire))
        notifier.removeDelivered(fire)
        reload()
    }

    func snooze(_ fire: Fire, now: Date = Date()) {
        try? store?.update {
            $0.setOutcome(fire.reminderID, scheduledAt: fire.scheduledAt, leadDays: fire.leadDays, .snoozed,
                          now: now, snoozedUntil: now.addingTimeInterval(ReminderPlanner.nagInterval))
        }
        island.dismiss(key: key(fire))
        notifier.removeDelivered(fire)
        reload()
        reschedule(now: now)
    }

    func togglePause(_ id: String) {
        try? store?.update { data in
            guard let i = data.reminders.firstIndex(where: { $0.id == id }) else { return }
            data.reminders[i].state = data.reminders[i].state == .paused ? .active : .paused
            data.reminders[i].updatedAt = Date()
        }
        reload()
        reschedule(now: Date())
    }

    func delete(_ id: String) {
        try? store?.update { data in
            data.reminders.removeAll { $0.id == id }
            data.occurrences.removeAll { $0.reminderID == id }
        }
        island.dismiss(prefix: "\(id)|")
        island.dismiss(key: "created|\(id)")
        waiting.removeAll { $0.fire?.reminderID == id || $0.item.key == "created|\(id)" }
        reload()
        reschedule(now: Date())
    }

    /// 通知上的按钮
    func handle(_ reply: NotificationReply) {
        guard let id = reply.info["id"] else { return }
        guard let at = reply.info["at"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) else {
            onOpenPage?()
            return
        }
        let ring = reply.info["ring"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) ?? at
        let fire = Fire(reminderID: id, scheduledAt: at, ringAt: ring, leadDays: Int(reply.info["lead"] ?? "") ?? 0)
        switch reply.action {
        case ReminderNotifier.Action.done.rawValue: act(fire, .done)
        case ReminderNotifier.Action.snooze.rawValue: snooze(fire)
        case ReminderNotifier.Action.skip.rawValue: act(fire, .skipped)
        default: onOpenPage?()   // 点了横幅本身
        }
    }

    // MARK: - 给界面用

    /// 接下来要响的（菜单里显示最近 3 条）
    func upcoming(now: Date = Date(), limit: Int) -> [(date: Date, title: String)] {
        ReminderPlanner.plan(data, from: now, days: 7, limit: limit, calendar: calendar).compactMap { fire in
            data.reminder(fire.reminderID).map { (fire.ringAt, $0.title) }
        }
    }

    func subtitle(for r: Reminder, now: Date = Date()) -> String {
        var parts = [ScheduleText.describe(r.schedule, calendar: calendar)]
        if let next = ReminderPlanner.next(r, after: now, count: 1, calendar: calendar).first {
            parts.append("下次 \(ScheduleText.fireText(next.scheduledAt, now: now, calendar: calendar))")
        }
        if let status = ScheduleText.status(r, now: now, calendar: calendar) { parts.append(status) }
        return parts.joined(separator: " · ")
    }

    /// 最近几天每次的结果，详情里显示
    func history(_ id: String, days: Int, now: Date = Date()) -> [String] {
        let since = now.addingTimeInterval(-Double(days) * 86400)
        return data.occurrences.filter { $0.reminderID == id && $0.scheduledAt >= since }
            .sorted { $0.scheduledAt > $1.scheduledAt }
            .map { "\(ScheduleText.fireText($0.scheduledAt, now: now, calendar: calendar))　\(ReminderTools.outcomeText($0.outcome))" }
    }
}
