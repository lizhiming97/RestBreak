import Foundation

/// 一次正在进行的休息
struct BreakSession: Equatable, Sendable {
    let kind: BreakKind
    let startedAt: Date
    let endsAt: Date
    /// 这次休息开始前已经被推迟过几次
    let postponeCount: Int

    var duration: TimeInterval { endsAt.timeIntervalSince(startedAt) }
}

/// 每种休息各自的计时器
struct BreakTimer: Equatable, Sendable {
    /// 什么时候到期
    var dueDate: Date
    /// 已经推迟了几次（跳过或完成后清零）
    var postponeCount: Int = 0
}

/// 调度器的整体状态
enum SchedulerState: Equatable, Sendable {
    /// 正常计时中
    case running
    /// 用户离开了（闲置太久 / 睡眠 / 锁屏），从 since 开始算
    case away(since: Date)
    /// 正在休息
    case onBreak(BreakSession)
    /// 已暂停；until 为 nil 表示「直到手动恢复」
    case paused(until: Date?)
}

/// 休息为什么结束
enum BreakEndReason: Equatable, Sendable {
    case completed    // 休息时间走完了
    case postponed    // 用户点了推迟
    case skipped      // 用户点了跳过
    case interrupted  // 被暂停 / 重置打断
    case meetingStarted  // 休息中开始开会，先收起，会后补上
}

/// 调度器告诉外层「发生了什么」，外层据此显示/关闭遮罩、播放声音等
enum SchedulerEvent: Equatable, Sendable {
    case breakStarted(BreakSession)
    case breakEnded(BreakKind, BreakEndReason)
    /// 用户离开后回来了；completed 是因为离开够久而算作「已完成」的休息
    case naturalBreakDetected(awayDuration: TimeInterval, completed: [BreakKind])
    case pauseEnded
}

/// 休息调度引擎：纯逻辑，不碰任何界面，只依赖 Foundation。
/// 所有方法都显式传入 now（当前时间），这样单元测试可以随意「快进时间」。
struct BreakScheduler: Sendable {
    /// 更高优先级的休息在这个时间内也要到期时，就跳过低优先级的休息
    static let higherPriorityLookahead: TimeInterval = 5 * 60
    /// 麦克风关闭后再等这么久才算会议结束（防止静音时麦克风短暂关闭被误判）
    static let meetingGracePeriod: TimeInterval = 60
    /// 提前到日程前的休息，要在日程开始前这么久结束
    static let calendarBuffer: TimeInterval = 60
    /// 休息最多为日程提前这么久；离日程开始超过 15 分钟才到期的休息不提前
    static let calendarPullWindow: TimeInterval = 15 * 60

    private(set) var settings: AppSettings
    private(set) var state: SchedulerState = .running
    private(set) var timers: [BreakKind: BreakTimer]
    /// 是否正在开会（含会后 1 分钟缓冲期）；关闭会议检测时始终为 false
    private(set) var isInMeeting = false
    /// 最近一次检测到麦克风在用的时刻
    private var lastMicActiveAt: Date?
    /// 上一次 tick 时麦克风是否在用，用来判断「会议刚开始」
    private var micWasActive = false
    /// 上一次 tick 时是否在开会或全屏
    private var wasWatching = false
    /// 前台 App 是否全屏（关闭全屏检测时始终为 false）
    private(set) var isFullscreen = false
    /// 前台是否是用户指定的 App（关闭指定 App 规则时始终为 false）
    private(set) var isUsingFocusApp = false
    /// 是否有到期的休息正在因为全屏或指定 App 等待
    private(set) var isDeferringBreak = false
    /// 已经累计推迟了多久。只累计真正在推迟的时间，中间开会、离开的时间不算
    private var deferredFor: TimeInterval = 0
    /// 上一次累计推迟时间的时刻
    private var lastDeferralTickAt: Date?
    /// 推迟最晚到什么时候（到了照样休息）；没在推迟时为 nil
    private(set) var deferralEndsAt: Date?
    /// 现在是否处于「到点先推迟」的状态（全屏或使用指定 App）
    private var wantsDeferral: Bool { isFullscreen || isUsingFocusApp }
    /// 最近一次在开会或全屏的时刻。这期间不碰键盘鼠标不算闲置
    private var lastWatchingAt: Date?
    /// 暂停中手动开始休息时记下暂停状态，休息结束后恢复
    private var stateAfterBreak: SchedulerState?
    /// 当前及之后的日历日程（只含参与排程的日历，已去掉全天和「空闲」日程）
    private(set) var calendarEvents: [DateInterval] = []
    /// 现在是否在日程中
    private(set) var isInCalendarEvent = false

    /// 推迟检查的结果
    private enum DeferralDecision {
        case none          // 不需要推迟，照常处理
        case hold          // 继续推迟
        case limitReached  // 推迟满上限，现在就休息
    }

    init(settings: AppSettings, now: Date) {
        self.settings = settings
        self.timers = Dictionary(uniqueKeysWithValues: BreakKind.allCases.map {
            ($0, BreakTimer(dueDate: now + settings[$0].interval))
        })
    }

    // MARK: - 每秒调用一次

    /// 外层按 nextTickInterval 调用（逐秒或放慢到最多 15 秒一次）。
    /// - idleSeconds: 距离上次键盘/鼠标操作过了多少秒
    /// - systemAway: 是否处于睡眠或锁屏
    /// - inMeeting: 是否有 App 正在使用麦克风
    /// - fullscreen: 前台 App 是否全屏（看视频、做演示）
    /// - focusApp: 前台是否是用户指定的 App
    /// - calendarEvents: 日历上的日程（关闭日历排程时传空）
    mutating func tick(now: Date, idleSeconds: TimeInterval, systemAway: Bool = false,
                       inMeeting micActive: Bool = false, fullscreen: Bool = false,
                       focusApp: Bool = false, calendarEvents: [DateInterval] = []) -> [SchedulerEvent] {
        self.calendarEvents = calendarEvents
        isInCalendarEvent = currentCalendarEvent(at: now) != nil
        let meetingJustStarted = updateMeetingState(micActive: micActive, now: now)
        isFullscreen = settings.postponeDuringFullscreen && fullscreen
        isUsingFocusApp = settings.postponeDuringFocusApps && focusApp

        // 开会、全屏看视频时可能很久不碰键盘鼠标，但人一直在看屏幕，这段时间不算闲置：
        // 闲置从「最后一次操作」和「最后一次在开会/全屏」两者中较晚的那个算起
        // 刚结束的那一刻也记下（tick 放慢后，上一次 tick 可能是几十秒前；外层在开会/全屏变化时会立刻 tick）
        let watching = isInMeeting || isFullscreen
        if watching || wasWatching { lastWatchingAt = now }
        wasWatching = watching
        let idle = lastWatchingAt.map { min(idleSeconds, max(0, now.timeIntervalSince($0))) } ?? idleSeconds

        switch state {
        case .paused(let until):
            // 定时暂停到点了 → 自动恢复，所有休息从现在重新计时
            guard let until, now >= until else { return [] }
            resetAllTimers(now: now)
            state = .running
            return [.pauseEnded]

        case .onBreak(let session):
            // 休息中有电话/会议进来：立即收起遮罩，免得挡住接听按钮
            if meetingJustStarted {
                return finishBreak(session, reason: .meetingStarted, now: now)
            }
            // 休息中不检测闲置（休息时本来就不该动电脑）
            guard now >= session.endsAt else { return [] }
            return finishBreak(session, reason: .completed, now: now)

        case .away(let since):
            // 还没回来
            if systemAway || idle >= settings.awayThreshold { return [] }
            // 用户真正回来的时刻 = 现在 - 刚才闲置的秒数（开会、全屏时闲置为 0，说明人就在电脑前）
            let returnedAt = max(since, now - idle)
            return returnFromAway(awayDuration: returnedAt.timeIntervalSince(since), returnedAt: returnedAt)

        case .running:
            if systemAway {
                state = .away(since: now)
                return []
            }
            // 开会时到期的休息先不弹（开会时间也不计入全屏/指定 App 的推迟时长）
            if isInMeeting { return [] }
            if idle >= settings.awayThreshold {
                // 离开是从最后一次操作（或最后一次开会/全屏）的时刻开始的
                state = .away(since: now - idle)
                return []
            }
            // 日程进行中到期的休息先不弹，日程结束后再休息（日程时间也不计入全屏推迟时长）
            if isInCalendarEvent { return [] }
            // 快到日程了：把快到点的休息提前，赶在日程开始前休息完
            if !wantsDeferral, let next = nextBreak(),
               let pulled = pulledForward(kind: next.kind, dueDate: next.dueDate, now: now),
               now >= pulled.start, now + settings[next.kind].duration <= pulled.eventStart {
                return startBreak(next.kind, now: now)
            }
            switch deferIfNeeded(now: now) {
            case .hold:
                return []
            case .limitReached:
                // 推迟满上限：直接开始预告过的那个休息，不再套用「高优先级快到了就跳过」的规则，
                // 否则低优先级休息被跳过、高优先级休息又重新推迟，用户会很久都休息不了
                if let next = nextBreak() { return startBreak(next.kind, now: now) }
            case .none:
                break
            }
            let events = startDueBreakIfNeeded(now: now)
            return events
        }
    }

    // MARK: - 用户操作

    /// 系统要睡眠时外层立即调用（睡眠后 tick 就不跑了，所以要提前记下离开时刻）
    mutating func enterAway(now: Date) {
        if case .running = state {
            state = .away(since: now)
        }
    }

    /// 菜单里的「现在开始微/长休息」。暂停中手动开始的休息，结束后回到暂停状态
    mutating func startBreakNow(_ kind: BreakKind, now: Date) -> [SchedulerEvent] {
        if case .onBreak = state { return [] }
        if case .paused = state { stateAfterBreak = state }
        return startBreak(kind, now: now)
    }

    /// 当前休息还能不能推迟
    var canPostponeCurrentBreak: Bool {
        guard case .onBreak(let session) = state, !settings.strictMode else { return false }
        return session.postponeCount < settings.maxPostpones
    }

    /// 当前休息能不能跳过
    var canSkipCurrentBreak: Bool {
        guard case .onBreak = state else { return false }
        return !settings.strictMode
    }

    mutating func postpone(now: Date) -> [SchedulerEvent] {
        guard canPostponeCurrentBreak, case .onBreak(let session) = state else { return [] }
        return finishBreak(session, reason: .postponed, now: now)
    }

    mutating func skip(now: Date) -> [SchedulerEvent] {
        guard canSkipCurrentBreak, case .onBreak(let session) = state else { return [] }
        return finishBreak(session, reason: .skipped, now: now)
    }

    /// 还没开始的下一次休息能不能跳过（快捷键「跳过下一次休息」）
    var canSkipUpcoming: Bool {
        guard case .running = state, !settings.strictMode else { return false }
        return nextBreak() != nil
    }

    /// 跳过还没开始的下一次休息：从现在重新计时
    mutating func skipUpcoming(now: Date) {
        guard canSkipUpcoming, let next = nextBreak() else { return }
        timers[next.kind] = BreakTimer(dueDate: now + settings[next.kind].interval)
    }

    /// 暂停。until 为 nil 表示直到手动恢复。正在休息的话会先结束休息。
    /// 严格模式下休息中不能暂停（否则按两次暂停快捷键就绕过了严格模式）
    mutating func pause(until: Date?, now: Date) -> [SchedulerEvent] {
        if case .onBreak = state, settings.strictMode { return [] }
        let events = interruptBreakIfNeeded(now: now)
        state = .paused(until: until)
        return events
    }

    /// 手动恢复：所有休息从现在重新计时
    mutating func resume(now: Date) {
        guard case .paused = state else { return }
        resetAllTimers(now: now)
        state = .running
    }

    /// 菜单里的「重置计时」：所有休息从现在重新计时（暂停状态保持不变）
    mutating func resetTimers(now: Date) -> [SchedulerEvent] {
        let events = interruptBreakIfNeeded(now: now)
        resetAllTimers(now: now)
        if case .away = state { state = .running }
        return events
    }

    /// 设置变化时调用。只有「间隔」或「启用」变了的休息才重新计时。
    mutating func updateSettings(_ newSettings: AppSettings, now: Date) {
        for kind in BreakKind.allCases {
            let old = settings[kind], new = newSettings[kind]
            if old.interval != new.interval || old.isEnabled != new.isEnabled {
                timers[kind] = BreakTimer(dueDate: now + new.interval)
            }
        }
        settings = newSettings
    }

    // MARK: - 查询

    /// 下一次真正会弹出的休息（已考虑「高优先级快到了就跳过低优先级」的规则）
    func nextBreak() -> (kind: BreakKind, dueDate: Date)? {
        let enabled = enabledKinds
        guard let earliest = enabled.min(by: { due($0) < due($1) }) else { return nil }
        // 如果有更高优先级的休息在 earliest 之后 5 分钟内到期，earliest 会被跳过
        let winner = enabled
            .filter { priority($0) <= priority(earliest)
                && due($0) <= due(earliest) + Self.higherPriorityLookahead }
            .min(by: { priority($0) < priority($1) }) ?? earliest
        return (winner, due(winner))
    }

    /// 下一次休息实际会在什么时候开始：考虑日程中暂缓、日程前提前（不含全屏/指定 App 推迟）
    func nextBreakStart(now: Date) -> (kind: BreakKind, date: Date)? {
        guard let next = nextBreak() else { return nil }
        if let event = currentCalendarEvent(at: now) {
            return (next.kind, max(next.dueDate, event.end))
        }
        if let pulled = pulledForward(kind: next.kind, dueDate: next.dueDate, now: now) {
            return (next.kind, pulled.start)
        }
        return (next.kind, next.dueDate)
    }

    /// 现在进行中的日程
    func currentCalendarEvent(at now: Date) -> DateInterval? {
        calendarEvents.first { $0.start <= now && now < $0.end }
    }

    // MARK: - 内部实现

    /// 休息会在下一个日程开始前后到期 → 返回提前后的开始时间和日程开始时间
    private func pulledForward(kind: BreakKind, dueDate: Date, now: Date) -> (start: Date, eventStart: Date)? {
        guard dueDate > now,
              let event = calendarEvents.filter({ $0.start > now }).min(by: { $0.start < $1.start })
        else { return nil }
        // 最晚这时开始，才能在日程前（留 1 分钟缓冲）休息完
        let latestStart = event.start - settings[kind].duration - Self.calendarBuffer
        guard dueDate > latestStart, dueDate <= event.start + Self.calendarPullWindow else { return nil }
        return (max(latestStart, dueDate - Self.calendarPullWindow), event.start)
    }

    private var enabledKinds: [BreakKind] {
        BreakKind.allCases.filter { settings[$0].isEnabled }
    }

    private func due(_ kind: BreakKind) -> Date { timers[kind]?.dueDate ?? .distantFuture }
    private func priority(_ kind: BreakKind) -> Int { settings[kind].priority }

    private mutating func startDueBreakIfNeeded(now: Date) -> [SchedulerEvent] {
        let enabled = enabledKinds
        // 已到期的里面取优先级最高的
        guard let candidate = enabled
            .filter({ due($0) <= now })
            .min(by: { priority($0) < priority($1) }) else { return [] }

        // 更高优先级的休息 5 分钟内也要到期 → 跳过这个低优先级休息
        let higherComingSoon = enabled.contains {
            priority($0) < priority(candidate) && due($0) <= now + Self.higherPriorityLookahead
        }
        if higherComingSoon {
            timers[candidate] = BreakTimer(dueDate: now + settings[candidate].interval)
            return []
        }
        return startBreak(candidate, now: now)
    }

    private mutating func startBreak(_ kind: BreakKind, now: Date) -> [SchedulerEvent] {
        let session = BreakSession(
            kind: kind,
            startedAt: now,
            endsAt: now + settings[kind].duration,
            postponeCount: timers[kind]?.postponeCount ?? 0
        )
        // 防止长休息刚推迟/刚开始，微休息就紧接着弹出来
        resetLowerPriorityTimers(than: kind, now: now)
        clearDeferral()
        state = .onBreak(session)
        return [.breakStarted(session)]
    }

    private mutating func finishBreak(_ session: BreakSession, reason: BreakEndReason, now: Date) -> [SchedulerEvent] {
        let kind = session.kind
        if reason == .meetingStarted {
            // 保持到期状态、不计推迟次数：会议结束后马上补上这次休息
            timers[kind]?.dueDate = now
        } else if reason == .postponed {
            var timer = timers[kind] ?? BreakTimer(dueDate: now)
            timer.dueDate = now + settings[kind].postponeDuration
            timer.postponeCount += 1
            timers[kind] = timer
        } else {
            timers[kind] = BreakTimer(dueDate: now + settings[kind].interval)
        }
        // 高优先级休息完成后，低优先级的休息再从头算
        if reason == .completed {
            resetLowerPriorityTimers(than: kind, now: now)
        }
        state = stateAfterBreak ?? .running
        stateAfterBreak = nil
        return [.breakEnded(kind, reason)]
    }

    /// 全屏或使用指定 App 时有休息到期 → 先不弹，累计推迟时长，满上限后照样休息
    private mutating func deferIfNeeded(now: Date) -> DeferralDecision {
        let dueKinds = enabledKinds.filter { due($0) <= now }
        // 用户主动推迟过的休息按推迟时长准时回来，不再因为全屏/指定 App 重新推迟
        guard wantsDeferral, !dueKinds.isEmpty,
              !dueKinds.contains(where: wasPostponedByUser) else {
            clearDeferral()
            return .none
        }
        if isDeferringBreak, let last = lastDeferralTickAt {
            // 只累计连续推迟的时间：两次推迟之间隔得久（中间在开会或离开），多出来的不算
            deferredFor += min(max(now.timeIntervalSince(last), 0), 2)
        }
        isDeferringBreak = true
        lastDeferralTickAt = now
        deferralEndsAt = now + max(settings.maxDeferral - deferredFor, 0)
        return deferredFor < settings.maxDeferral ? .hold : .limitReached
    }

    private mutating func clearDeferral() {
        isDeferringBreak = false
        deferredFor = 0
        lastDeferralTickAt = nil
        deferralEndsAt = nil
    }

    private func wasPostponedByUser(_ kind: BreakKind) -> Bool {
        (timers[kind]?.postponeCount ?? 0) > 0
    }

    /// 更新会议状态，返回「会议是否刚刚开始」（麦克风从关变开）
    private mutating func updateMeetingState(micActive: Bool, now: Date) -> Bool {
        guard settings.postponeDuringMeetings else {
            isInMeeting = false
            micWasActive = false
            lastMicActiveAt = nil
            return false
        }
        let justStarted = micActive && !micWasActive
        // 麦克风刚关掉的那一刻也算「最后在用」：外层在麦克风变化时会立刻 tick，这一刻就是关掉的时刻
        if micActive || micWasActive { lastMicActiveAt = now }
        micWasActive = micActive
        if let last = lastMicActiveAt {
            isInMeeting = now.timeIntervalSince(last) < Self.meetingGracePeriod
        } else {
            isInMeeting = false
        }
        return justStarted
    }

    private mutating func interruptBreakIfNeeded(now: Date) -> [SchedulerEvent] {
        guard case .onBreak(let session) = state else { return [] }
        return finishBreak(session, reason: .interrupted, now: now)
    }

    /// returnedAt 是用户真正回来的时刻（不是发现的时刻）：空闲时 tick 放慢后，可能回来十几秒才发现
    private mutating func returnFromAway(awayDuration: TimeInterval, returnedAt now: Date) -> [SchedulerEvent] {
        var completed: [BreakKind] = []
        for kind in BreakKind.allCases {
            if awayDuration >= settings[kind].duration {
                // 离开的时间够一次休息了 → 算已完成
                timers[kind] = BreakTimer(dueDate: now + settings[kind].interval)
                completed.append(kind)
            } else {
                // 不够 → 离开的这段时间不计入，到期时间往后顺延
                timers[kind]?.dueDate += awayDuration
            }
        }
        state = .running
        return [.naturalBreakDetected(awayDuration: awayDuration, completed: completed)]
    }

    private mutating func resetLowerPriorityTimers(than kind: BreakKind, now: Date) {
        for other in BreakKind.allCases where priority(other) > priority(kind) {
            timers[other] = BreakTimer(dueDate: now + settings[other].interval)
        }
    }

    private mutating func resetAllTimers(now: Date) {
        for kind in BreakKind.allCases {
            timers[kind] = BreakTimer(dueDate: now + settings[kind].interval)
        }
    }
}

// MARK: - 省电：下一次 tick 隔多久

extension BreakScheduler {
    /// 什么事都没有时最长多久 tick 一次（菜单栏倒计时按分钟显示，一分钟醒一次就够）
    static let slowTickInterval: TimeInterval = 60

    /// 外层下一次调用 tick 之前该等多久，以及要不要准时（准时的会用很小的唤醒误差）。
    /// 原则：只在「状态可能变化」的时刻醒来——休息该开始/结束、暂停到点、会后缓冲期结束、倒计时换数字。
    /// 其余变化（开会、切 App、全屏、醒来、回到电脑前、用户操作）由外层收到事件后立刻 tick。
    func nextTick(now: Date) -> (interval: TimeInterval, precise: Bool) {
        func until(_ date: Date) -> TimeInterval { max(0.05, date.timeIntervalSince(now)) }
        switch state {
        case .onBreak(let session):
            // 遮罩上的圆环倒计时自己会动，引擎只需要在结束那一刻醒
            return (until(session.endsAt), true)
        case .paused(let until_):
            guard let until_ else { return (Self.slowTickInterval * 10, false) }
            return (min(until(until_), Self.slowTickInterval), true)
        case .away:
            // 鼠标回来、醒来、解锁都会立刻唤醒；只用键盘回来的靠这个兜底（回来的时刻由闲置秒数倒推，不影响计时）
            return (15, false)
        case .running:
            // 推迟中按秒累计推迟时长
            if isDeferringBreak { return (1, true) }
            // 开会：麦克风开关会立刻唤醒；麦克风关掉后要在缓冲期结束那一刻醒
            if isInMeeting {
                if let end = meetingGraceEndsAt { return (until(end), true) }
                return (Self.slowTickInterval * 10, false)
            }
            guard let next = nextBreakStart(now: now) else { return (Self.slowTickInterval * 10, false) }
            let remaining = next.date.timeIntervalSince(now)
            if remaining <= 0 { return (1, true) }
            // 倒计时按「向上取整的分钟」显示，remaining 每跨过一个整 60 秒数字就变一次
            let untilDisplayChange = remaining - ((remaining - 0.001) / 60).rounded(.down) * 60 + 0.05
            if remaining <= min(untilDisplayChange, Self.slowTickInterval) { return (remaining, true) }
            return (min(untilDisplayChange, Self.slowTickInterval), false)
        }
    }

    /// 兼容旧调用：只要间隔
    func nextTickInterval(now: Date) -> TimeInterval { nextTick(now: now).interval }

    /// 麦克风已经关了、还在会后缓冲期：缓冲期结束的时刻
    var meetingGraceEndsAt: Date? {
        guard isInMeeting, !micWasActive, let last = lastMicActiveAt else { return nil }
        return last + Self.meetingGracePeriod
    }
}
