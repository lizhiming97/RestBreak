import Foundation

/// 管家的 2 个工具：看现状、推送。和 ReminderTools 一样只依赖 Foundation；
/// situation 由调用方提供：小程序向主 App 要，测试里直接给
enum ButlerTools {
    static let instructions = """
    看现状和推送：
    - 想主动跟用户说什么之前，先调用 get_context 看看用户现在的状况。
    - push：只推说得清「为什么是现在」的事；intent 选最贴切的来意。每天有打扰预算，被拦下时会告诉你原因，不要换个说法重推。
    - 记住用户的事（承诺、截止、在吃的药）用你自己的记忆，星期五不替你记。
    """

    static let specs: [ToolSpec] = [
        ToolSpec(name: "get_context",
                 description: "看用户现在的状况：本地时间和星期几、是否在电脑前/开会/休息、连续工作多久、今天的休息和日程、到点提醒（接下来 24 小时和最近错过的）、今天推过什么、还剩几条推送预算。决定要不要 push 之前先调用它。",
                 schema: #"{"type":"object","properties":{}}"#, readOnly: true, destructive: false, autoApprove: true),
        ToolSpec(name: "push",
                 description: "让管家现在主动对用户说一件事（显示在灵动岛）。会先经过打扰预算、去重、时机检查；被拦下时返回原因。",
                 schema: #"""
                 {"type":"object","required":["intent","title","why"],"properties":{
                  "intent":{"type":"string","enum":["due","urgent","forgot","pause","info"],"description":"来意：due 到点了 / urgent 快来不及了 / forgot 你可能忘了 / pause 该停一停 / info 值得让你知道"},
                  "title":{"type":"string","description":"一句话说什么事，20 字以内，如「产品评审 10:30 开始」"},
                  "why":{"type":"string","description":"为什么是现在，60 字以内，如「你昨天说要带转化数据，那张表今天还没打开过」"},
                  "primaryAction":{"type":"string","description":"主按钮文字，6 字以内，如「知道了」「这就去」；不填为「好的」"},
                  "dedupeKey":{"type":"string","description":"同一件事的标识，一天只会推一次，如「quote-zhangsan-1026」"}}}
                 """#, readOnly: false, destructive: false, autoApprove: true),
    ]

    /// 不是管家的工具时返回 nil（交给 ReminderTools）
    static func call(_ name: String, arguments args: [String: Any], context c: ToolContext,
                     situation: () -> ButlerContext?) -> ToolResult? {
        do {
            switch name {
            case "get_context": return try getContext(c, situation: situation())
            case "push": return try push(args, c)
            default: return nil
            }
        } catch let error as ToolError {
            return ToolResult(text: error.message, isError: true, changed: false)
        } catch let error as StoreError {
            return ToolResult(text: error.description, isError: true, changed: false)
        } catch {
            return ToolResult(text: "星期五出错了：\(error.localizedDescription)", isError: true, changed: false)
        }
    }

    private static func getContext(_ c: ToolContext, situation: ButlerContext?) throws -> ToolResult {
        let data = try c.store.load()
        let todayPushes = data.butler.pushes.filter { c.calendar.isDate($0.createdAt, inSameDayAs: c.now) }.map {
            ["title": $0.title, "intent": $0.intent.label, "status": $0.status.rawValue] as [String: Any]
        }
        var object: [String: Any] = [
            "now": ReminderTools.nowInfo(c),
            "reminders": ReminderTools.overview(data, c),
            "pushesToday": todayPushes,
            "remainingPushBudget": PushGate.remainingBudget(data.butler, now: c.now, calendar: c.calendar),
        ]
        if let s = situation, let json = try? JSONSerialization.jsonObject(with: ReminderStore.encoder.encode(s)) {
            object["situation"] = json
        } else {
            object["situation"] = "星期五没在运行或没有回应，拿不到电脑前的状况"
        }
        return ReminderTools.result(object, changed: false)
    }

    private static func push(_ args: [String: Any], _ c: ToolContext) throws -> ToolResult {
        guard let raw = args["intent"] as? String, let intent = PushIntent(rawValue: raw) else {
            throw ToolError("intent 必须是 due / urgent / forgot / pause / info 之一")
        }
        let title = try text(args, "title", max: 20, required: true)!
        let why = try text(args, "why", max: 60, required: true)!
        let primary = try text(args, "primaryAction", max: 6, required: false)
        let key = try text(args, "dedupeKey", max: 60, required: false)
        return try c.store.update { data in
            var record = PushRecord(id: ReminderData.newID(existing: Set(data.butler.pushes.map(\.id))), intent: intent,
                                    title: title, why: why, primaryAction: primary, dedupeKey: key,
                                    source: c.client, createdAt: c.now)
            // 排队中的同一件事也算重复
            if let key, data.butler.pushes.contains(where: { $0.status == .pending && $0.dedupeKey == key }) {
                return ReminderTools.result(["result": "没有推送：同一件事已经在排队了"], changed: false)
            }
            if case .block(let reason) = PushGate.check(record, butler: data.butler, now: c.now, calendar: c.calendar) {
                return ReminderTools.result(["result": "没有推送：\(reason)"], changed: false)
            }
            record.status = .pending
            data.butler.pushes.append(record)
            data.butler.prune(now: c.now)
            return ReminderTools.result(["result": "已交给星期五，会在合适的时机显示",
                           "remainingPushBudget": PushGate.remainingBudget(data.butler, now: c.now, calendar: c.calendar)],
                          changed: true)
        }
    }

    private static func text(_ args: [String: Any], _ key: String, max: Int, required: Bool) throws -> String? {
        guard let value = (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            if required { throw ToolError("缺少 \(key)") }
            return nil
        }
        guard value.count <= max else { throw ToolError("\(key) 最多 \(max) 个字") }
        return value
    }

}

/// 星期五对 AI 提供的全部工具（小程序注册、「连接 AI」页、测试都用这一份）
enum AllTools {
    static let specs = ButlerTools.specs + ReminderTools.specs

    /// 按名字调用一个工具。situation：主 App 的现状（小程序向主 App 要，主 App 直接给）
    static func call(_ name: String, arguments: [String: Any], context: ToolContext,
                     situation: () -> ButlerContext?) -> ToolResult {
        ButlerTools.call(name, arguments: arguments, context: context, situation: situation)
            ?? ReminderTools.call(name, arguments: arguments, context: context)
    }
}
