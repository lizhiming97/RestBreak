import Foundation

/// 一天的休息统计
struct DayStats: Codable, Equatable, Sendable {
    /// 当天日期，如 "2026-10-20"
    var date: String
    /// 完成的休息次数（倒计时走完）
    var completed = 0
    /// 跳过的休息次数
    var skipped = 0
    /// 点「推迟」的次数（一次休息可能推迟多次）
    var postponed = 0
    /// 离开电脑被算作休息的次数
    var naturalBreaks = 0
    /// 累计休息时长（完成的休息 + 离开电脑的时间），单位秒
    var restSeconds: TimeInterval = 0
    /// 当天最长一次连续工作没休息的时长，单位秒
    var longestWorkStretch: TimeInterval = 0

    /// 完成率 = 完成 /（完成 + 跳过）；还没有休息时为 nil
    var completionRate: Double? {
        let total = completed + skipped
        return total == 0 ? nil : Double(completed) / Double(total)
    }
}

/// 休息统计记录器：接收调度引擎的事件和每秒的工作状态，按天汇总。
/// 只依赖 Foundation，方便单元测试；保存由外层负责（days 编码成 JSON）。
struct StatsRecorder: Sendable {
    /// 只保留最近这么多天
    static let retentionDays = 90

    private(set) var days: [String: DayStats]
    private let calendar: Calendar
    /// 当前这段连续工作从什么时候开始（没在工作时为 nil）
    private var stretchStart: Date?
    /// 上一次计入连续工作的时刻
    private var lastWorkingAt: Date?
    /// 正在进行的休息，结束时用来算时长
    private var currentBreak: BreakSession?

    init(days: [String: DayStats] = [:], calendar: Calendar = .current) {
        self.days = days
        self.calendar = calendar
    }

    /// 每秒调用一次。isWorking：正常计时中（不在休息、离开、暂停）
    mutating func tick(now: Date, isWorking: Bool) {
        guard isWorking else {
            // 离开、暂停、休息时连续工作中断；离开够久由 naturalBreakDetected 记为休息
            stretchStart = nil
            lastWorkingAt = nil
            return
        }
        // 两次工作 tick 隔得太久，从现在重新算。tick 只在状态可能变化时才醒（最长约 10 分钟），
        // 睡眠、锁屏、离开都会先变成「不在工作」，所以这里只防程序卡住：阈值 15 分钟
        if let last = lastWorkingAt, now.timeIntervalSince(last) > 15 * 60 { stretchStart = nil }
        let start = stretchStart ?? now
        stretchStart = start
        lastWorkingAt = now
        update(now) { day in
            day.longestWorkStretch = max(day.longestWorkStretch, now.timeIntervalSince(start))
        }
    }

    /// 这一段连续工作了多久（没在工作时为 0）
    func currentStretch(now: Date) -> TimeInterval {
        stretchStart.map { now.timeIntervalSince($0) } ?? 0
    }

    /// 记录调度引擎发出的事件
    mutating func record(_ event: SchedulerEvent, now: Date) {
        switch event {
        case .breakStarted(let session):
            currentBreak = session
        case .breakEnded(_, let reason):
            let started = currentBreak
            currentBreak = nil
            switch reason {
            case .completed:
                update(now) { day in
                    day.completed += 1
                    if let started { day.restSeconds += now.timeIntervalSince(started.startedAt) }
                }
                // 好好休息过了，连续工作重新算
                stretchStart = nil
                lastWorkingAt = nil
            case .skipped:
                update(now) { $0.skipped += 1 }
            case .postponed:
                update(now) { $0.postponed += 1 }
            case .interrupted, .meetingStarted:
                break   // 被暂停或会议打断，不算完成也不算跳过
            }
        case .naturalBreakDetected(let awayDuration, let completed):
            guard !completed.isEmpty else { break }
            update(now) { day in
                day.naturalBreaks += 1
                day.restSeconds += awayDuration
            }
            stretchStart = nil
            lastWorkingAt = nil
        case .pauseEnded:
            break
        }
    }

    /// 某一天的统计（没有记录时返回全 0）
    func day(for date: Date) -> DayStats {
        let key = Self.key(for: date, calendar: calendar)
        return days[key] ?? DayStats(date: key)
    }

    /// 截止到 endingAt 那天的最近 n 天，从早到晚排列，没有记录的日子补 0
    func lastDays(_ n: Int, endingAt end: Date) -> [DayStats] {
        let today = calendar.startOfDay(for: end)
        return (0..<n).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { day(for: $0) }
        }
    }

    // MARK: - 内部实现

    private mutating func update(_ now: Date, _ change: (inout DayStats) -> Void) {
        let key = Self.key(for: now, calendar: calendar)
        var day = days[key] ?? DayStats(date: key)
        change(&day)
        if days[key] == nil { pruneOldDays(before: now) }
        days[key] = day
    }

    /// 删掉 90 天以前的记录
    private mutating func pruneOldDays(before now: Date) {
        guard let cutoff = calendar.date(byAdding: .day, value: -(Self.retentionDays - 1),
                                         to: calendar.startOfDay(for: now)) else { return }
        let cutoffKey = Self.key(for: cutoff, calendar: calendar)
        days = days.filter { $0.key >= cutoffKey }   // "yyyy-MM-dd" 按字符串比较即按日期比较
    }

    static func key(for date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
