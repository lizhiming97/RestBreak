import Foundation

/// 管家为什么现在来找你（设计文档「五种来意」）
enum PushIntent: String, Codable, CaseIterable, Sendable {
    case due        // 到点了：你交代过的事
    case urgent     // 快来不及了
    case forgot     // 你可能忘了
    case pause      // 你该停一停了
    case info       // 值得让你知道

    var label: String {
        switch self {
        case .due: "到点了"
        case .urgent: "快来不及了"
        case .forgot: "可能忘了"
        case .pause: "该停一停"
        case .info: "告诉你一声"
        }
    }
}

/// 一次推送（来自 AI 的 push）
struct PushRecord: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case pending    // 等主 App 处理
        case waiting    // 过了关卡，等时机显示（用户在休息、开会、全屏）
        case shown      // 已显示，用户还没点
        case acted      // 点了主按钮
        case dismissed  // 点了「知道了」或自动收起
        case muted      // 点了「少提醒这类」
        case blocked    // 被关卡拦下（reason 里写原因）
        case expired    // 等太久没能显示（reason 里写原因）
    }

    var id: String
    var intent: PushIntent
    var title: String
    /// 为什么是现在
    var why: String
    /// 主按钮文字（如「去看看」），nil 时用「好的」
    var primaryAction: String?
    /// 同一件事的标识，一天只推一次
    var dedupeKey: String?
    /// 推送的 AI 客户端名
    var source: String
    var createdAt: Date
    var status: Status = .pending
    var reason: String?
    var handledAt: Date?
    /// 真正显示在灵动岛上的时刻（打扰预算按这一天算）
    var shownAt: Date?
}

extension PushRecord {
    /// 设置页「记录」里的状态说法
    var statusText: String {
        switch status {
        case .pending: "排队中"
        case .waiting: "等时机显示"
        case .expired: "没推：\(reason ?? "过时了")"
        case .shown: "已显示"
        case .acted, .dismissed: "已看"
        case .muted: "已设为少提醒"
        case .blocked: "没推：\(reason ?? "")"
        }
    }
}

struct ButlerPrefs: Codable, Equatable, Sendable {
    /// 主动推送（不含「到点了」）每天最多几条
    var dailyBudget = 8
    /// 点过「少提醒这类」的来意
    var mutedIntents: [PushIntent] = []

    init() {}

    /// 缺的字段用默认值；认不出的来意跳过（更新版本加的）；旧文件里的关注方向、下班时间读时丢弃
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dailyBudget = try c.decodeIfPresent(Int.self, forKey: .dailyBudget) ?? dailyBudget
        if let raw = try c.decodeIfPresent([String].self, forKey: .mutedIntents) {
            mutedIntents = raw.compactMap(PushIntent.init(rawValue:))
        }
    }
}

/// store.json 里管家的部分
struct ButlerData: Codable, Equatable, Sendable {
    var pushes: [PushRecord] = []
    var prefs = ButlerPrefs()

    /// 只保留 14 天的推送记录
    mutating func prune(now: Date) {
        pushes.removeAll { now.timeIntervalSince($0.createdAt) > 14 * 86400 }
    }
}

extension ButlerContext {
    /// context.json 的时间用「秒（带小数）」存：ISO 8601 只到整秒，小程序会把刚写的现状误判成旧的
    static var fileEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    static var fileDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}

/// 主 App 给 AI 看的现状（只在 AI 来要时生成）
struct ButlerContext: Codable, Equatable, Sendable {
    struct Event: Codable, Equatable, Sendable {
        var title: String
        var start: String
        var end: String
    }

    var generatedAt: Date
    /// 「在电脑前」「离开了」「开会中」「休息中」「暂停提醒中」
    var state: String
    /// 离开了多少分钟（不在离开状态时为 nil）
    var awayMinutes: Int?
    /// 这一段已经连续工作多少分钟
    var workingStretchMinutes: Int
    /// 今天第一次开始用电脑的时刻（HH:mm）
    var firstActiveToday: String?
    var breaksCompletedToday: Int
    var breaksSkippedToday: Int
    /// 今天剩下的日程（没开「按日历安排」时为 nil）
    var todayEvents: [Event]?
}
