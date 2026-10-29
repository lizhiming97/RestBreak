import AppKit
import EventKit

/// 设置里显示的一个日历
struct CalendarInfo: Identifiable {
    let id: String
    let title: String
    /// 所属账户，如「iCloud」「Exchange」
    let source: String
    let color: NSColor
}

/// 一个参与排程的日程
struct CalendarEvent {
    let title: String
    let interval: DateInterval
}

extension CalendarEvent {
    /// 设置页显示的「接下来 12 小时有 N 个日程」：只算还没结束、并且 12 小时内开始的。
    /// 查询范围往前多取了 8 小时（为了算上正在开的长会），已经开完的不能算进来
    static func upcomingCount(_ events: [CalendarEvent], now: Date) -> Int {
        events.filter { $0.interval.end > now && $0.interval.start < now + 12 * 3600 }.count
    }
}

/// 读取系统日历（EventKit）。只读日程的标题和起止时间，不修改日历。
/// 日历内容变化（系统会通知）或勾选的日历变了时立即重读；查询窗口是 12 小时，所以平时 10 分钟重读一次就够。
/// 不用日历时完全不碰 EventKit（连 EKEventStore 都不建），不占资源。
@MainActor
final class CalendarService: NSObject, ObservableObject {
    @Published private(set) var authorization = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var calendars: [CalendarInfo] = []

    private lazy var store: EKEventStore = {
        let store = EKEventStore()
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged),
                                               name: .EKEventStoreChanged, object: store)
        return store
    }()
    private var activated = false
    private var cachedEvents: [CalendarEvent] = []
    private var cachedFor: Set<String> = []
    private var fetchedAt: Date?
    private static let refreshInterval: TimeInterval = 600

    var hasAccess: Bool { authorization == .fullAccess }

    /// 真正要用日历时（打开日历设置、开启按日历安排）才连上 EventKit
    func activate() {
        guard !activated else { return }
        activated = true
        if hasAccess { reloadCalendars() }
    }

    /// 第一次调用时系统会弹窗问是否允许访问日历
    func requestAccess() async -> Bool {
        activate()
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        authorization = EKEventStore.authorizationStatus(for: .event)
        if granted { reloadCalendars() }
        return granted
    }

    /// 默认勾选的日历：去掉生日、订阅的节假日这类不代表「我有事」的日历
    var defaultCalendarIDs: [String] {
        store.calendars(for: .event)
            .filter { $0.type != .birthday && $0.type != .subscription }
            .map(\.calendarIdentifier)
    }

    /// 勾选的日历里，从现在往前 1 小时到往后 12 小时的日程。
    /// 全天日程、标为「空闲」的日程、已取消或已拒绝的日程不算。
    func events(now: Date, calendarIDs: [String]) -> [CalendarEvent] {
        activate()
        let selected = Set(calendarIDs)
        let isFresh = fetchedAt.map { now.timeIntervalSince($0) < Self.refreshInterval } ?? false
        if isFresh && selected == cachedFor { return cachedEvents }

        cachedFor = selected
        fetchedAt = now
        let chosen = store.calendars(for: .event).filter { selected.contains($0.calendarIdentifier) }
        guard hasAccess, !chosen.isEmpty else {
            cachedEvents = []
            return []
        }
        let predicate = store.predicateForEvents(withStart: now - 3600, end: now + 12 * 3600, calendars: chosen)
        cachedEvents = store.events(matching: predicate)
            .filter { event in
                !event.isAllDay
                    && event.availability != .free
                    && event.status != .canceled
                    && event.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined
                    && event.endDate > event.startDate
            }
            .map { CalendarEvent(title: $0.title ?? "日程",
                                 interval: DateInterval(start: $0.startDate, end: $0.endDate)) }
            .sorted { $0.interval.start < $1.interval.start }
        return cachedEvents
    }

    /// 打开「系统设置 › 隐私与安全性 › 日历」
    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    private func reloadCalendars() {
        calendars = store.calendars(for: .event)
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title,
                                source: $0.source?.title ?? "", color: $0.color) }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
    }

    @objc private func storeChanged(_ notification: Notification) {
        fetchedAt = nil   // 下次 tick 重新读
        reloadCalendars()
    }
}
