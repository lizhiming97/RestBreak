import AppKit
import Foundation

/// 管家：把 AI 推来的记录过关卡、显示到灵动岛；AI 要现状时生成 context.json。
/// App 不自己决定说什么，说什么全由用户的 AI 巡视后 push
@MainActor
final class ButlerCoordinator: NSObject {
    /// 由 BreakCoordinator 提供：生成现状
    var situation: () -> ButlerContext? = { nil }

    private let store: ReminderStore?
    private let reminders: ReminderCoordinator
    private var calendar: Calendar { Calendar.current }
    /// 「今天第一次开始用电脑」，存成 "yyyy-MM-dd HH:mm"（只用一个键，不按天新增），get_context 里给 AI 看
    private static let firstActiveKey = "butlerFirstActive"
    /// 下次需要检查的时刻（今天 6 点或明天 0 点）：之前的 tick 只比较一次时间就返回
    private var nextCheck = Date.distantPast

    init(store: ReminderStore? = try? ReminderStore.shared(), reminders: ReminderCoordinator) {
        self.store = store
        self.reminders = reminders
        super.init()
    }

    func start() {
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged), name: .reminderStoreChanged, object: nil)
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            DispatchQueue.main.async { NotificationCenter.default.post(name: .butlerContextRequested, object: nil) }
        }, DarwinNotice.contextRequest as CFString, nil, .deliverImmediately)
        NotificationCenter.default.addObserver(self, selector: #selector(writeContext), name: .butlerContextRequested, object: nil)
        processPending()
    }

    @objc private func storeChanged() {
        processPending()
    }

    // MARK: - AI 要现状

    @objc private func writeContext() {
        guard let url = AppGroup.contextURL, let context = situation(),
              let data = try? ButlerContext.fileEncoder.encode(context) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - 推送出口

    /// pending 放太久（比如 AI 推送时星期五没在运行）就不再显示：过了时机的话不如不说
    static let pendingTTL: TimeInterval = 60 * 60

    /// 取出 pending 的记录：过关卡，放行的交给灵动岛（真正显示时才记为 shown），拦下的写原因
    func processPending(now: Date = Date()) {
        guard let store else { return }
        let toShow: [PushRecord] = (try? store.update(notify: false) { data in
            var shown: [PushRecord] = []
            for i in data.butler.pushes.indices where data.butler.pushes[i].status == .pending {
                data.butler.pushes[i].handledAt = now
                if now.timeIntervalSince(data.butler.pushes[i].createdAt) > Self.pendingTTL {
                    data.butler.pushes[i].status = .expired
                    data.butler.pushes[i].reason = "星期五当时没在运行，等到现在已经过时了"
                    continue
                }
                let decision = PushGate.check(data.butler.pushes[i], butler: data.butler, now: now, calendar: calendar)
                switch decision {
                case .allow:
                    data.butler.pushes[i].status = .waiting
                    shown.append(data.butler.pushes[i])
                case .block(let reason):
                    data.butler.pushes[i].status = .blocked
                    data.butler.pushes[i].reason = reason
                }
            }
            return shown
        }) ?? []
        for push in toShow { reminders.showIsland(item(for: push)) }
    }

    private func item(for push: PushRecord) -> IslandItem {
        let intent = IslandIntent(push.intent)
        var actions: [IslandItem.Action] = []
        if push.intent != .due {
            actions.append(.init(title: "少提醒这类") { [weak self] in self?.finish(push, .muted) })
        }
        actions.append(.init(title: "知道了") { [weak self] in self?.finish(push, .dismissed) })
        if let primary = push.primaryAction, primary != "知道了" {
            actions.append(.init(title: primary, primary: true) { [weak self] in self?.finish(push, .acted) })
        } else {
            actions[actions.count - 1] = .init(title: "知道了", primary: true) { [weak self] in self?.finish(push, .dismissed) }
        }
        return IslandItem(key: "push|\(push.id)", intent: intent, symbol: symbol(push.intent), kind: nil,
                          compact: String(push.title.prefix(4)), title: push.title, message: push.why,
                          trailing: TimeText.hourMinute(push.createdAt), firm: false, autoDismiss: 20, actions: actions,
                          onTimeout: { [weak self] in self?.record(push, .dismissed) },
                          onShown: { [weak self] in self?.markShown(push) },
                          onDropped: { [weak self] in self?.record(push, .expired, reason: "你一直在休息、开会或全屏，等了 30 分钟没能显示") })
    }

    private func symbol(_ intent: PushIntent) -> String {
        switch intent {
        case .due: "bell.fill"
        case .urgent: "clock.badge.exclamationmark.fill"
        case .forgot: "exclamationmark.bubble.fill"
        case .pause: "cup.and.saucer.fill"
        case .info: "sun.horizon.fill"
        }
    }

    private func finish(_ push: PushRecord, _ status: PushRecord.Status) {
        reminders.dismissIsland(key: "push|\(push.id)")
        record(push, status)
    }

    private func markShown(_ push: PushRecord) {
        _ = try? store?.update(notify: false) { data in
            guard let i = data.butler.pushes.firstIndex(where: { $0.id == push.id }),
                  data.butler.pushes[i].status == .waiting else { return }
            data.butler.pushes[i].status = .shown
            data.butler.pushes[i].shownAt = Date()
        }
    }

    private func record(_ push: PushRecord, _ status: PushRecord.Status, reason: String? = nil) {
        _ = try? store?.update(notify: false) { data in
            guard let i = data.butler.pushes.firstIndex(where: { $0.id == push.id }) else { return }
            data.butler.pushes[i].status = status
            data.butler.pushes[i].handledAt = Date()
            if let reason { data.butler.pushes[i].reason = reason }
            if status == .muted, !data.butler.prefs.mutedIntents.contains(push.intent) {
                data.butler.prefs.mutedIntents.append(push.intent)
            }
        }
    }

    // MARK: - 今天第一次开始用电脑

    /// BreakCoordinator 在人在电脑前工作时（每次 tick）调用：记下今天第一次开始用电脑的时刻（6 点以后）
    func userIsActive(now: Date = Date()) {
        guard now >= nextCheck else { return }
        let startOfDay = calendar.startOfDay(for: now)
        guard let sixAM = calendar.date(byAdding: .hour, value: 6, to: startOfDay),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return }
        guard now >= sixAM else { nextCheck = sixAM; return }
        nextCheck = tomorrow
        let today = StatsRecorder.key(for: now, calendar: calendar)
        if UserDefaults.standard.string(forKey: Self.firstActiveKey)?.hasPrefix(today) != true {
            UserDefaults.standard.set("\(today) \(TimeText.hourMinute(now))", forKey: Self.firstActiveKey)
        }
    }

    /// 今天第一次开始用电脑的时刻（HH:mm），今天还没记过为 nil
    func firstActiveToday(now: Date) -> String? {
        let today = StatsRecorder.key(for: now, calendar: calendar)
        return UserDefaults.standard.string(forKey: Self.firstActiveKey)
            .flatMap { $0.hasPrefix(today) ? String($0.suffix(5)) : nil }
    }
}

extension Notification.Name {
    static let butlerContextRequested = Notification.Name("butlerContextRequested")
}
