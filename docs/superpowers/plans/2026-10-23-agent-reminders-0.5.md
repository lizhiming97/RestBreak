# 0.5「AI 派提醒」Implementation Plan

> **状态：已完成（v0.5.0，2026-10-24）。** 下面的勾选框没有逐条打勾，以本行为准；实际实现以代码和 docs/项目细节.md 为准。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** 让 Claude Code / Codex / Claude Desktop 通过 MCP 在歇一会里建、改、查、删提醒。歇一会负责准时提醒：时间到了弹系统横幅；强提醒还会弹一张卡片，过一会儿再提醒；Mac 合盖期间错过的会汇总告诉你；AI 新建的提醒会弹横幅，可以撤销。设置里新增「提醒」页：「我的提醒」列出所有提醒，「连接 AI」负责安装。

**Architecture:**
- 纯逻辑都放在 `Shared/`（主 App、命令行小程序、测试三方共用，只依赖 Foundation）：
  - 数据模型 `Reminder.swift`；
  - 文件存储 `ReminderStore.swift`（App Group 里的 `store.json`，用 `flock` 加锁、原子写入，写完发 Darwin 通知）；
  - 排期 `ReminderPlanner.swift`：算响铃时间、到期判断，以及唯一的处理入口 `process()`；
  - 中文描述 `ScheduleText.swift`；
  - 5 个 MCP 工具 `ReminderTools.swift`：参数解析、校验、结果，不依赖 MCP SDK。
- 小程序 `RestBreakMCP` 只负责把 SDK 接到 `ReminderTools`。
- 主 App 的 `ReminderCoordinator` 每 30 秒在锁里调用一次 `ReminderPlanner.process()`，再根据返回结果弹卡片、发通知、重新登记系统定时通知。
- 系统只允许一个通知代理，改由 `NotificationRouter` 统一接收通知回调，再分发给休息和提醒两边。

**设计文档:** `docs/superpowers/specs/2026-10-23-agent-reminders-design.md`（第 1～7 节）、`docs/superpowers/specs/2026-10-23-agent-step0-findings.md`

**和设计文档的差异（实现时以这里为准，Task 13 回写设计文档）：**
1. `ReminderPlanner`、`ScheduleText` 从 `Engine/` 改放到 `Shared/`：小程序返回「接下来 3 次」也要用。
2. 休息通知的分类仍然叫 `upcoming.*`，不改成 `break.*`，免得白改现有代码。路由规则是：分类以 `reminder.` 开头的归提醒，其余都归休息。
3. Claude Desktop 在 0.5 只提供「复制配置」。`.mcpb` 导出要等手动验证第 2 项有结果再说（Task 14 里有备注）。
4. 小程序里第 0 步留下的 `hook`、`statusline` 子命令和验证代码一并删掉，0.6 再按正式设计加回来。`HookEvent`、`UsageParser` 和它们的测试保留。

**Tech Stack:** Swift 6、SwiftUI + AppKit、UserNotifications、MCP Swift SDK 0.12.x、Swift Testing。

**变量**（每个终端会话先执行一次。编译和测试都用单独的目录，不碰你在 Xcode 里运行的那份）：
```bash
cd "/Users/lizhiming/Desktop/lizhiming/个人项目验证/桌面闹钟/有趣的项目--桌面提醒工具/RestBreak"
DD="$HOME/Library/Developer/Xcode/DerivedData/RestBreak-xieyihui-spike"
APP="$DD/Build/Products/Debug/RestBreak.app"; MCP="$APP/Contents/MacOS/restbreak-mcp"
BUILD='xcodebuild -scheme RestBreak -configuration Debug -derivedDataPath "$DD" build -allowProvisioningUpdates 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"'
TEST='xcodebuild test -scheme RestBreak -destination platform=macOS -derivedDataPath "$DD" -allowProvisioningUpdates 2>&1 | grep -E "error:|✘|Test run with"'
```
只跑一个测试套件：在 `$TEST` 的 `test` 后面加 `-only-testing:RestBreakTests/<套件名>`。直接运行小程序的命令都要放在沙盒外执行。

**文件结构**
| 文件 | 作用 |
|---|---|
| `Shared/AppGroup.swift`（改） | App Group、Darwin 通知名；删掉第 0 步的验证代码 |
| `Shared/Reminder.swift`（新） | `ClockTime`、`Schedule`、`Reminder`、`Occurrence`、`ReminderData` 及修改数据的方法 |
| `Shared/ReminderStore.swift`（新） | `store.json` 读写、锁、版本号 |
| `Shared/ReminderPlanner.swift`（新） | 响铃时间、`due`、`plan`、`process`、文案轮换 |
| `Shared/ScheduleText.swift`（新） | 中文描述、客户端显示名 |
| `Shared/ReminderTools.swift`（新） | 5 个工具：说明、JSON Schema、解析、执行 |
| `RestBreakMCP/main.swift`、`MCPCommand.swift`（改） | MCP 服务器；改完数据后在需要时拉起主 App |
| `RestBreakMCP/HookCommand.swift`、`SpikeCommands.swift`（删） | 第 0 步的验证代码 |
| `RestBreak/Services/NotificationRouter.swift`（新） | 统一的通知代理和通知分类 |
| `RestBreak/Services/BreakNotifier.swift`（改） | 不再当代理，分类交给路由 |
| `RestBreak/Services/ReminderNotifier.swift`（新） | 系统定时通知、再次提醒、汇总、AI 新建通知 |
| `RestBreak/App/ReminderCoordinator.swift`（新） | 30 秒一次的循环、监听数据变化、用户操作、卡片 |
| `RestBreak/App/AIIntegration.swift`（新） | 生成 Claude Code 插件、Codex / Claude Desktop 配置片段 |
| `RestBreak/UI/ReminderCard.swift`（新） | 强提醒卡片 |
| `RestBreak/UI/RemindersPage.swift`（新） | 「提醒」页的两个分段 |
| `RestBreak/UI/SettingsWindow.swift`、`UI/StatusBarController.swift`、`App/BreakCoordinator.swift`、`App/RestBreakApp.swift`（改） | 把上面这些接进来 |
| `RestBreakTests/ReminderTestSupport.swift` 等 7 个测试文件（新） | 见各任务 |

---

### Task 1: 删掉第 0 步的验证代码

**Files:** Delete `RestBreakMCP/HookCommand.swift`、`RestBreakMCP/SpikeCommands.swift`；Modify `Shared/AppGroup.swift`、`RestBreakMCP/main.swift`、`RestBreakMCP/MCPCommand.swift`

- [ ] **Step 1: 删文件**：`git rm RestBreakMCP/HookCommand.swift RestBreakMCP/SpikeCommands.swift`
- [ ] **Step 2: `Shared/AppGroup.swift` 改成**
```swift
import Foundation

/// 主 App 和命令行小程序（restbreak-mcp）共用的 App Group 信息。
/// 两个程序开了同一个 App Group，才能读写同一个文件夹。
enum AppGroup {
    /// 用团队 ID 当前缀：macOS 15 起不会弹「访问其他 App 的数据」提示
    static let identifier = "B45N72QF4V.com.lizhiming.RestBreak"
    static let appBundleID = "com.lizhiming.RestBreak"

    /// 共享文件夹：~/Library/Group Containers/<identifier>/
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}

/// Darwin 通知：跨进程的「有东西变了」信号，只有名字，不能带内容
enum DarwinNotice {
    static let remindersChanged = "com.lizhiming.RestBreak.reminders.changed"

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name as CFString), nil, nil, true)
    }
}
```
- [ ] **Step 3: `RestBreakMCP/main.swift` 改成**
```swift
import Foundation

// 歇一会的命令行小程序，放在 歇一会.app/Contents/MacOS/restbreak-mcp。
// Claude / Codex 启动它，通过标准输入输出说 MCP 协议，替用户建、改、查提醒。
try await MCPCommand.run()
```
- [ ] **Step 4:** 先把 `RestBreakMCP/MCPCommand.swift` 的 `Ping` 删掉，只保留空服务器（Task 7 再写完整）：
```swift
import MCP

/// MCP 服务器（Task 7 接入提醒工具）
enum MCPCommand {
    static func run() async throws {
        let server = Server(name: "xieyihui", version: "0.5.0", title: "歇一会",
                            capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: []) }
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}
```
- [ ] **Step 5:** `eval $BUILD` 得到 `BUILD SUCCEEDED`，`eval $TEST` 全部通过（原有 169 个测试）。
- [ ] **Step 6: 提交**「0.5：删掉第 0 步验证代码」（每次提交信息末尾都加 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`）

### Task 2: 数据模型 `Shared/Reminder.swift`（先写测试）

**Files:** Create `Shared/Reminder.swift`、`RestBreakTests/ReminderTestSupport.swift`、`RestBreakTests/ReminderModelTests.swift`

- [ ] **Step 1: 测试辅助 `RestBreakTests/ReminderTestSupport.swift`**
```swift
import Foundation
@testable import RestBreak

/// 提醒相关测试的公共工具。时间一律按北京时间，2026-10-23 是周五
enum RT {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        c.locale = Locale(identifier: "zh_CN")
        return c
    }()

    /// "2026-10-23 15:12" → Date（北京时间）
    static func d(_ text: String) -> Date { ReminderTools.parseDateTime(text, calendar: calendar)! }
    static func t(_ text: String) -> ClockTime { ClockTime(text)! }

    static func reminder(_ schedule: Schedule, id: String = "r1", title: String = "吃药",
                         created: String = "2026-10-23 08:00", style: ReminderStyle = .gentle,
                         start: Date? = nil, end: Date? = nil, max: Int? = nil,
                         messages: [String] = ["该吃药啦"], createdBy: String = "claude-code") -> Reminder {
        Reminder(id: id, title: title, messages: messages, schedule: schedule, style: style, reason: nil,
                 createdBy: createdBy, createdAt: d(created), updatedAt: d(created),
                 startDate: start, endDate: end, maxOccurrences: max, state: .active, announced: true)
    }

    static func tempStore() -> ReminderStore {
        ReminderStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("reminders-\(UUID().uuidString)", isDirectory: true))
    }

    static func context(_ now: String, store: ReminderStore, client: String = "claude-code") -> ToolContext {
        ToolContext(now: d(now), calendar: calendar, client: client, store: store)
    }

    /// 工具返回的 JSON 文本 → 字典
    static func object(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }
}
```
- [ ] **Step 2: 写测试 `RestBreakTests/ReminderModelTests.swift`**
```swift
import Foundation
import Testing
@testable import RestBreak

/// 提醒的数据模型：时刻解析、时间安排的编解码、完成记录的写入
struct ReminderModelTests {
    @Test func 时刻解析() {
        #expect(ClockTime("9:05")?.description == "09:05")
        #expect(ClockTime("21:00")?.minutes == 21 * 60)
        #expect(ClockTime("24:00") == nil)
        #expect(ClockTime("9点") == nil)
        #expect(RT.t("08:00") < RT.t("09:30"))
    }

    @Test(arguments: [
        Schedule.once(at: Date(timeIntervalSince1970: 1_792_000_020)),
        .daily(times: [RT.t("09:00"), RT.t("21:00")], weekdays: [1, 2, 3]),
        .interval(everyMinutes: 90, from: RT.t("09:00"), to: RT.t("18:00"), weekdays: []),
        .monthly(days: [10, 31], times: [RT.t("09:00")]),
        .yearly(month: 11, day: 5, times: [RT.t("09:00")], leadDays: [5]),
    ])
    func 时间安排编解码往返(_ schedule: Schedule) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(schedule)
        #expect(try decoder.decode(Schedule.self, from: data) == schedule)
    }

    @Test func 不写weekdays时为每天() throws {
        let json = #"{"kind":"daily","times":["09:00"]}"#
        let schedule = try JSONDecoder().decode(Schedule.self, from: Data(json.utf8))
        #expect(schedule == .daily(times: [RT.t("09:00")], weekdays: []))
    }

    @Test func 不认识的kind解码失败() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Schedule.self, from: Data(#"{"kind":"hourly"}"#.utf8))
        }
    }

    @Test func 写完成记录_新增和覆盖() {
        var data = ReminderData()
        let at = RT.d("2026-10-23 09:00")
        data.setOutcome("r1", scheduledAt: at, .pending, now: at)
        data.setOutcome("r1", scheduledAt: at, .done, now: RT.d("2026-10-23 09:03"))
        #expect(data.occurrences.count == 1)
        #expect(data.occurrences[0].outcome == .done)
        #expect(data.occurrences[0].actedAt == RT.d("2026-10-23 09:03"))
    }

    @Test func 推迟时记下再响时间并清零再提醒次数() {
        var data = ReminderData()
        let at = RT.d("2026-10-23 09:00")
        data.setOutcome("r1", scheduledAt: at, .pending, now: at)
        data.occurrences[0].nagCount = 2
        data.setOutcome("r1", scheduledAt: at, .snoozed, now: RT.d("2026-10-23 09:05"),
                        snoozedUntil: RT.d("2026-10-23 09:15"))
        #expect(data.occurrences[0].snoozedUntil == RT.d("2026-10-23 09:15"))
        #expect(data.occurrences[0].nagCount == 0)
    }

    @Test func 记录客户端() {
        var data = ReminderData()
        data.recordClient("claude-code", now: RT.d("2026-10-23 09:00"))
        data.recordClient("claude-code", now: RT.d("2026-10-23 10:00"))
        data.recordClient("codex-mcp-client", now: RT.d("2026-10-23 10:00"))
        #expect(data.clients.count == 2)
        #expect(data.clients.first { $0.name == "claude-code" }?.lastSeen == RT.d("2026-10-23 10:00"))
    }

    @Test func 新id不重复() {
        let existing: Set<String> = ["abc123"]
        let id = ReminderData.newID(existing: existing)
        #expect(id.count == 6 && !existing.contains(id))
    }
}
```
- [ ] **Step 3:** `eval $TEST`，确认编译失败（`ClockTime` 未定义）。
- [ ] **Step 4: 实现 `Shared/Reminder.swift`**
```swift
import Foundation

/// 一天里的某个时刻（本地时间），存成 "09:00"
struct ClockTime: Hashable, Comparable, Sendable, CustomStringConvertible {
    var hour: Int
    var minute: Int

    init?(hour: Int, minute: Int) {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }

    /// 接受 "9:00"、"09:00"
    init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        self.init(hour: h, minute: m)
    }

    var minutes: Int { hour * 60 + minute }
    var description: String { String(format: "%02d:%02d", hour, minute) }
    static func < (a: ClockTime, b: ClockTime) -> Bool { a.minutes < b.minutes }
}

extension ClockTime: Codable {
    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = ClockTime(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "时刻格式不对：\(text)"))
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// 什么时候响。星期用 1 = 周一 … 7 = 周日，空数组 = 每天
enum Schedule: Equatable, Sendable {
    case once(at: Date)
    case daily(times: [ClockTime], weekdays: [Int])
    /// 每隔 everyMinutes 分钟，从 from 到 to（含 to，如果正好落在上面）
    case interval(everyMinutes: Int, from: ClockTime, to: ClockTime, weekdays: [Int])
    /// 31 号在小月改成当月最后一天
    case monthly(days: [Int], times: [ClockTime])
    /// 2 月 29 日在平年改成 2 月 28 日；leadDays：提前几天也预告一次
    case yearly(month: Int, day: Int, times: [ClockTime], leadDays: [Int])

    var kind: String {
        switch self {
        case .once: "once"
        case .daily: "daily"
        case .interval: "interval"
        case .monthly: "monthly"
        case .yearly: "yearly"
        }
    }
}

extension Schedule: Codable {
    private enum Key: String, CodingKey {
        case kind, at, times, weekdays, everyMinutes, from, to, days, month, day, leadDays
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "once":
            self = .once(at: try c.decode(Date.self, forKey: .at))
        case "daily":
            self = .daily(times: try c.decode([ClockTime].self, forKey: .times),
                          weekdays: try c.decodeIfPresent([Int].self, forKey: .weekdays) ?? [])
        case "interval":
            self = .interval(everyMinutes: try c.decode(Int.self, forKey: .everyMinutes),
                             from: try c.decode(ClockTime.self, forKey: .from),
                             to: try c.decode(ClockTime.self, forKey: .to),
                             weekdays: try c.decodeIfPresent([Int].self, forKey: .weekdays) ?? [])
        case "monthly":
            self = .monthly(days: try c.decode([Int].self, forKey: .days),
                            times: try c.decode([ClockTime].self, forKey: .times))
        case "yearly":
            self = .yearly(month: try c.decode(Int.self, forKey: .month),
                           day: try c.decode(Int.self, forKey: .day),
                           times: try c.decode([ClockTime].self, forKey: .times),
                           leadDays: try c.decodeIfPresent([Int].self, forKey: .leadDays) ?? [])
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "不认识的 kind：\(kind)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .once(let at):
            try c.encode(at, forKey: .at)
        case .daily(let times, let weekdays):
            try c.encode(times, forKey: .times)
            try c.encode(weekdays, forKey: .weekdays)
        case .interval(let every, let from, let to, let weekdays):
            try c.encode(every, forKey: .everyMinutes)
            try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to)
            try c.encode(weekdays, forKey: .weekdays)
        case .monthly(let days, let times):
            try c.encode(days, forKey: .days)
            try c.encode(times, forKey: .times)
        case .yearly(let month, let day, let times, let leadDays):
            try c.encode(month, forKey: .month)
            try c.encode(day, forKey: .day)
            try c.encode(times, forKey: .times)
            try c.encode(leadDays, forKey: .leadDays)
        }
    }
}

/// gentle：只弹横幅；firm：横幅 + 处理了才消失的卡片，没处理会再提醒
enum ReminderStyle: String, Codable, Sendable { case gentle, firm }

/// finished：过了结束日期、响满次数、一次性提醒已经响过
enum ReminderState: String, Codable, Sendable { case active, paused, finished }

struct Reminder: Codable, Identifiable, Equatable, Sendable {
    /// 6 位短 id，方便 AI 引用
    var id: String
    var title: String
    /// 每次响铃轮换使用的文案（AI 按用户语气写）
    var messages: [String]
    var schedule: Schedule
    var style: ReminderStyle
    /// 为什么建这个提醒，显示在 App 里
    var reason: String?
    /// 建它的客户端名（MCP clientInfo.name）
    var createdBy: String
    var createdAt: Date
    var updatedAt: Date
    var startDate: Date?
    /// 结束时刻（含）：AI 给的日期会换成那一天的 23:59:59
    var endDate: Date?
    var maxOccurrences: Int?
    var state: ReminderState
    /// 主 App 已经弹过「AI 帮你建了提醒」
    var announced: Bool
}

/// 一次响铃的结果。pending：强提醒的卡片还没处理
enum Outcome: String, Codable, Sendable { case pending, notified, done, snoozed, skipped, missed }

/// 一次响铃的记录，用 (reminderID, scheduledAt) 区分
struct Occurrence: Codable, Equatable, Sendable {
    var reminderID: String
    var scheduledAt: Date
    var leadDays: Int
    var outcome: Outcome
    /// 最后一次改变状态的时间
    var actedAt: Date?
    /// 强提醒已经再次提醒了几次
    var nagCount: Int
    /// 「10 分钟后」再响的时间；再响后保留，作为再次提醒的计时起点
    var snoozedUntil: Date?
}

struct ClientRecord: Codable, Equatable, Sendable {
    var name: String
    var lastSeen: Date
}

/// store.json 的全部内容
struct ReminderData: Codable, Equatable, Sendable {
    static let currentSchema = 1

    var schemaVersion = ReminderData.currentSchema
    var reminders: [Reminder] = []
    var occurrences: [Occurrence] = []
    var clients: [ClientRecord] = []
    /// 主 App 上次处理到期提醒的时间；它之后到点的还没处理过
    var checkedAt: Date?

    func reminder(_ id: String) -> Reminder? { reminders.first { $0.id == id } }

    func occurrence(_ id: String, at scheduledAt: Date) -> Occurrence? {
        occurrences.first { $0.reminderID == id && $0.scheduledAt == scheduledAt }
    }

    /// 写一次响铃的结果：已有记录就覆盖，没有就新增
    mutating func setOutcome(_ id: String, scheduledAt: Date, leadDays: Int = 0, _ outcome: Outcome,
                             now: Date, snoozedUntil: Date? = nil) {
        if let i = occurrences.firstIndex(where: { $0.reminderID == id && $0.scheduledAt == scheduledAt }) {
            occurrences[i].outcome = outcome
            occurrences[i].actedAt = now
            if let snoozedUntil { occurrences[i].snoozedUntil = snoozedUntil }
            if outcome == .snoozed { occurrences[i].nagCount = 0 }
        } else {
            occurrences.append(Occurrence(reminderID: id, scheduledAt: scheduledAt, leadDays: leadDays,
                                          outcome: outcome, actedAt: now, nagCount: 0, snoozedUntil: snoozedUntil))
        }
    }

    mutating func recordClient(_ name: String, now: Date) {
        if let i = clients.firstIndex(where: { $0.name == name }) {
            clients[i].lastSeen = now
        } else {
            clients.append(ClientRecord(name: name, lastSeen: now))
        }
    }

    static func newID(existing: Set<String>) -> String {
        let letters = Array("abcdefghjkmnpqrstuvwxyz23456789")
        while true {
            let id = String((0..<6).map { _ in letters.randomElement()! })
            if !existing.contains(id) { return id }
        }
    }
}
```
- [ ] **Step 5:** 这一步还编不过，因为 `RT` 里用到了 `ReminderTools`、`ReminderStore`、`ToolContext`，这些到 Task 3、Task 6 才有。先在 `ReminderTestSupport.swift` 里把 `d(_:)` 临时改成用 DateFormatter，并注释掉 `tempStore` 和 `context`：
```swift
    static func d(_ text: String) -> Date {
        let f = DateFormatter()
        f.calendar = calendar; f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: text)!
    }
```
Task 6 改回 `ReminderTools.parseDateTime`，并恢复那两个函数。然后跑 `-only-testing:RestBreakTests/ReminderModelTests`，全部通过。
- [ ] **Step 6: 提交**「0.5：提醒数据模型」

### Task 3: 存储 `Shared/ReminderStore.swift`（先写测试）

**Files:** Create `Shared/ReminderStore.swift`、`RestBreakTests/ReminderStoreTests.swift`；恢复 `ReminderTestSupport.swift` 里的 `tempStore`

- [ ] **Step 1: 测试**
```swift
import Foundation
import Testing
@testable import RestBreak

/// store.json：读写、加锁、版本号
struct ReminderStoreTests {
    @Test func 没有文件时是空数据() throws {
        #expect(try RT.tempStore().load() == ReminderData())
    }

    @Test func 写入后能读回() throws {
        let store = RT.tempStore()
        let r = RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []))
        try store.update { $0.reminders.append(r) }
        #expect(try store.load().reminders == [r])
    }

    @Test func 修改过程中出错就不写() throws {
        let store = RT.tempStore()
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try store.update { data in
                data.reminders.append(RT.reminder(.once(at: RT.d("2026-10-24 09:00"))))
                throw Boom()
            }
        }
        #expect(try store.load().reminders.isEmpty)
    }

    @Test func 新版本的数据拒绝读写() throws {
        let store = RT.tempStore()
        try store.update { $0.checkedAt = RT.d("2026-10-23 09:00") }
        let newer = #"{"schemaVersion":99,"reminders":[],"occurrences":[],"clients":[]}"#
        try Data(newer.utf8).write(to: store.fileURL)
        #expect(throws: StoreError.newerSchema(99)) { try store.load() }
        #expect(throws: StoreError.newerSchema(99)) { try store.update { $0.checkedAt = nil } }
        #expect(String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self) == newer)   // 没被覆盖
    }

    @Test func 坏文件报错且不覆盖() throws {
        let store = RT.tempStore()
        try store.update { $0.checkedAt = nil }
        try Data("{不是 json".utf8).write(to: store.fileURL)
        #expect(throws: StoreError.self) { try store.update { $0.checkedAt = nil } }
        #expect(String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self) == "{不是 json")
    }

    @Test func 同时写200次不丢数据() throws {
        let store = RT.tempStore()
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            try? store.update { $0.reminders.append(RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []), id: "r\(i)")) }
        }
        #expect(try store.load().reminders.count == 200)
    }
}
```
- [ ] **Step 2:** 跑一次，确认编译失败。
- [ ] **Step 3: 实现**
```swift
import Foundation

enum StoreError: Error, Equatable, CustomStringConvertible {
    case noContainer
    case newerSchema(Int)
    case corrupt(String)
    case io(String)

    var description: String {
        switch self {
        case .noContainer: "拿不到歇一会的共享文件夹（App Group 权限没配好）"
        case .newerSchema(let v): "提醒数据是新版歇一会写的（版本 \(v)），请更新歇一会"
        case .corrupt(let detail): "提醒数据文件损坏：\(detail)"
        case .io(let detail): "读写提醒数据失败：\(detail)"
        }
    }
}

/// 提醒数据存在 App Group 共享文件夹里的 Reminders/store.json。
/// 主 App 和多个小程序（Claude、Codex 各启动一个）可能同时写，
/// 所以「读 → 改 → 写」整个过程都放在文件锁里，写的时候先写临时文件再替换（.atomic）。
struct ReminderStore: Sendable {
    let fileURL: URL

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("store.json")
    }

    /// 正式的数据位置。环境变量 XIEYIHUI_STORE=test 时用 Reminders-test，端到端测试不碰真实数据
    static func shared() throws -> ReminderStore {
        guard let base = AppGroup.containerURL else { throw StoreError.noContainer }
        let folder = ProcessInfo.processInfo.environment["XIEYIHUI_STORE"] == "test" ? "Reminders-test" : "Reminders"
        return ReminderStore(directory: base.appendingPathComponent(folder, isDirectory: true))
    }

    func load() throws -> ReminderData {
        try withLock(LOCK_SH) { try read() }
    }

    /// 在锁里读出数据交给 body 修改；改了才写回，写完发 Darwin 通知（notify 为 false 时不发）
    @discardableResult
    func update<T>(notify: Bool = true, _ body: (inout ReminderData) throws -> T) throws -> T {
        let (result, changed) = try withLock(LOCK_EX) { () throws -> (T, Bool) in
            var data = try read()
            let before = data
            let result = try body(&data)
            let changed = data != before
            if changed { try write(data) }
            return (result, changed)
        }
        if changed && notify { DarwinNotice.post(DarwinNotice.remindersChanged) }
        return result
    }

    private func read() throws -> ReminderData {
        guard let raw = try? Data(contentsOf: fileURL) else { return ReminderData() }   // 还没有文件
        struct Header: Decodable { var schemaVersion: Int }
        guard let header = try? Self.decoder.decode(Header.self, from: raw) else {
            throw StoreError.corrupt("没有版本号")
        }
        if header.schemaVersion > ReminderData.currentSchema { throw StoreError.newerSchema(header.schemaVersion) }
        do {
            return try Self.decoder.decode(ReminderData.self, from: raw)
        } catch {
            throw StoreError.corrupt(error.localizedDescription)
        }
    }

    private func write(_ data: ReminderData) throws {
        do {
            try Self.encoder.encode(data).write(to: fileURL, options: .atomic)
        } catch {
            throw StoreError.io(error.localizedDescription)
        }
    }

    /// 锁加在单独的 .lock 文件上：store.json 每次都被整个替换，锁不能加在它身上
    private func withLock<T>(_ operation: Int32, _ body: () throws -> T) throws -> T {
        let folder = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw StoreError.io(error.localizedDescription)
        }
        let fd = open(folder.appendingPathComponent(".lock").path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { throw StoreError.io("打不开锁文件") }
        defer { close(fd) }
        guard flock(fd, operation) == 0 else { throw StoreError.io("加锁失败") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
```
- [ ] **Step 4:** 跑 `ReminderStoreTests`，全部通过。
- [ ] **Step 5: 提交**「0.5：提醒数据存储（文件锁 + 原子写 + 版本号）」

### Task 4: 排期 `Shared/ReminderPlanner.swift` 第一部分：响铃时间（先写测试）

**Files:** Create `Shared/ReminderPlanner.swift`、`RestBreakTests/ReminderPlannerTests.swift`

- [ ] **Step 1: 测试**
```swift
import Foundation
import Testing
@testable import RestBreak

/// 每种时间安排在一段时间里该响哪些时刻
struct ReminderPlannerTests {
    let cal = RT.calendar

    func dates(_ r: Reminder, _ from: String, _ to: String) -> [Date] {
        ReminderPlanner.fires(r, from: RT.d(from), to: RT.d(to), calendar: cal).map(\.scheduledAt)
    }

    @Test func 每天两次_跨零点() {
        let r = RT.reminder(.daily(times: [RT.t("21:00"), RT.t("09:00")], weekdays: []))
        #expect(dates(r, "2026-10-23 00:00", "2026-10-25 00:00")
                == ["2026-10-23 09:00", "2026-10-23 21:00", "2026-10-24 09:00", "2026-10-24 21:00"].map(RT.d))
    }

    @Test func 建之前的时刻不算() {
        let r = RT.reminder(.daily(times: [RT.t("09:00"), RT.t("21:00")], weekdays: []), created: "2026-10-23 15:00")
        #expect(dates(r, "2026-10-23 00:00", "2026-10-24 00:00") == [RT.d("2026-10-23 21:00")])
    }

    @Test func 只在工作日() {
        // 10-23 周五，24、25 是周末，26 周一
        let r = RT.reminder(.daily(times: [RT.t("10:00")], weekdays: [1, 2, 3, 4, 5]))
        #expect(dates(r, "2026-10-23 00:00", "2026-10-27 00:00") == ["2026-10-23 10:00", "2026-10-26 10:00"].map(RT.d))
    }

    @Test func 每隔90分钟_含结束时刻() {
        let r = RT.reminder(.interval(everyMinutes: 90, from: RT.t("09:00"), to: RT.t("12:00"), weekdays: []))
        #expect(dates(r, "2026-10-23 00:00", "2026-10-24 00:00")
                == ["2026-10-23 09:00", "2026-10-23 10:30", "2026-10-23 12:00"].map(RT.d))
    }

    @Test func 每月31号_小月改成最后一天() {
        let r = RT.reminder(.monthly(days: [31], times: [RT.t("09:00")]))
        #expect(dates(r, "2026-10-23 00:00", "2027-01-01 00:00")
                == ["2026-10-31 09:00", "2026-11-30 09:00", "2026-12-31 09:00"].map(RT.d))
    }

    @Test func 每月30号和31号_小月只响一次() {
        let r = RT.reminder(.monthly(days: [30, 31], times: [RT.t("09:00")]))
        #expect(dates(r, "2026-11-01 00:00", "2026-12-01 00:00") == [RT.d("2026-11-30 09:00")])
    }

    @Test func 每年2月29日_平年改成28日() {
        let r = RT.reminder(.yearly(month: 2, day: 29, times: [RT.t("09:00")], leadDays: []))
        #expect(dates(r, "2026-10-23 00:00", "2028-12-31 00:00") == ["2027-02-28 09:00", "2028-02-29 09:00"].map(RT.d))
    }

    @Test func 每年_提前预告() {
        let r = RT.reminder(.yearly(month: 11, day: 5, times: [RT.t("09:00")], leadDays: [5]))
        let fires = ReminderPlanner.fires(r, from: RT.d("2026-10-23 00:00"), to: RT.d("2026-12-01 00:00"), calendar: cal)
        #expect(fires.map(\.scheduledAt) == ["2026-10-31 09:00", "2026-11-05 09:00"].map(RT.d))
        #expect(fires.map(\.leadDays) == [5, 0])
    }

    @Test func 每年_提前预告跨年() {
        let r = RT.reminder(.yearly(month: 1, day: 2, times: [RT.t("09:00")], leadDays: [5]))
        #expect(dates(r, "2026-12-01 00:00", "2027-01-03 00:00") == ["2026-12-28 09:00", "2027-01-02 09:00"].map(RT.d))
    }

    @Test func 一次性() {
        let r = RT.reminder(.once(at: RT.d("2026-10-23 18:30")))
        #expect(dates(r, "2026-10-23 00:00", "2026-10-24 00:00") == [RT.d("2026-10-23 18:30")])
        #expect(dates(r, "2026-10-23 18:31", "2026-10-24 00:00").isEmpty)
    }

    @Test func 结束日期当天还响_之后结束() {
        let r = RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []), end: RT.d("2026-10-25 23:59"))
        #expect(dates(r, "2026-10-23 00:00", "2026-10-30 00:00").count == 3)
        #expect(!ReminderPlanner.shouldFinish(r, now: RT.d("2026-10-25 08:00"), calendar: cal))
        #expect(ReminderPlanner.shouldFinish(r, now: RT.d("2026-10-25 10:00"), calendar: cal))
    }

    @Test func 响满次数后结束() {
        let r = RT.reminder(.daily(times: [RT.t("09:00"), RT.t("21:00")], weekdays: []), max: 3)
        #expect(dates(r, "2026-10-23 00:00", "2026-10-30 00:00")
                == ["2026-10-23 09:00", "2026-10-23 21:00", "2026-10-24 09:00"].map(RT.d))
        // 从中间开始查，也只剩第 3 次
        #expect(dates(r, "2026-10-24 00:00", "2026-10-30 00:00") == [RT.d("2026-10-24 09:00")])
        #expect(ReminderPlanner.shouldFinish(r, now: RT.d("2026-10-24 10:00"), calendar: cal))
    }

    @Test func 暂停的不响() {
        var r = RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []))
        r.state = .paused
        #expect(dates(r, "2026-10-23 00:00", "2026-10-30 00:00").isEmpty)
        #expect(!ReminderPlanner.shouldFinish(r, now: RT.d("2027-10-23 00:00"), calendar: cal))
    }

    @Test func 接下来几次() {
        let r = RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []))
        let next = ReminderPlanner.next(r, after: RT.d("2026-10-23 09:00"), count: 2, calendar: cal)
        #expect(next.map(\.scheduledAt) == ["2026-10-24 09:00", "2026-10-25 09:00"].map(RT.d))
    }

    @Test func 换时区后按新时区的墙上时间响() {
        var tokyo = cal
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let r = RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []))
        let fire = ReminderPlanner.next(r, after: RT.d("2026-10-23 12:00"), count: 1, calendar: tokyo)[0]
        #expect(tokyo.component(.hour, from: fire.scheduledAt) == 9)
    }

    @Test func 文案按第几次轮换() {
        let r = RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []), messages: ["甲", "乙"])
        let fire = Fire(reminderID: "r1", date: RT.d("2026-10-24 09:00"))
        #expect(ReminderPlanner.message(r, fire: fire, ordinal: 0) == "甲")
        #expect(ReminderPlanner.message(r, fire: fire, ordinal: 1) == "乙")
        #expect(ReminderPlanner.message(r, fire: fire, ordinal: 2) == "甲")
        let lead = Fire(reminderID: "r1", date: RT.d("2026-10-24 09:00"), leadDays: 5)
        #expect(ReminderPlanner.message(r, fire: lead, ordinal: 0) == "还有 5 天：甲")
    }
}
```
- [ ] **Step 2:** 跑一次，确认编译失败。
- [ ] **Step 3: 实现 `Shared/ReminderPlanner.swift` 第一部分**
```swift
import Foundation

/// 某条提醒的一次响铃。scheduledAt 是按时间安排「本该响」的时刻（也是记录用的键），
/// ringAt 是实际要响的时刻：平时两者相同，「10 分钟后」再响时 ringAt 更晚
struct Fire: Equatable, Hashable, Sendable {
    var reminderID: String
    var scheduledAt: Date
    var ringAt: Date
    /// 提前几天的预告（只有每年的提醒有），0 = 当天
    var leadDays: Int

    init(reminderID: String, date: Date, leadDays: Int = 0) {
        self.init(reminderID: reminderID, scheduledAt: date, ringAt: date, leadDays: leadDays)
    }

    init(reminderID: String, scheduledAt: Date, ringAt: Date, leadDays: Int) {
        self.reminderID = reminderID
        self.scheduledAt = scheduledAt
        self.ringAt = ringAt
        self.leadDays = leadDays
    }
}

/// 提醒的排期规则（纯逻辑，方便测试）
enum ReminderPlanner {
    /// 最多往后看多少天
    static let horizonDays = 400

    /// 只按时间安排算 [start, end) 里的响铃，不看状态和次数上限；达到 limit 条就停
    static func rawFires(_ r: Reminder, from start: Date, to end: Date, calendar: Calendar,
                         limit: Int = .max) -> [Fire] {
        guard start < end, limit > 0 else { return [] }
        if case .once(let at) = r.schedule {
            return at >= start && at < end ? [Fire(reminderID: r.id, date: at)] : []
        }
        var result: [Fire] = []
        var day = calendar.startOfDay(for: start)
        var steps = 0
        while day < end && steps < horizonDays && result.count < limit {
            let today = times(on: day, schedule: r.schedule, calendar: calendar).compactMap { time, lead -> Fire? in
                guard let date = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day),
                      date >= start, date < end else { return nil }
                return Fire(reminderID: r.id, date: date, leadDays: lead)
            }
            result += today.sorted { $0.scheduledAt < $1.scheduledAt }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
            steps += 1
        }
        return Array(result.prefix(limit))
    }

    /// 某一天要响的时刻，以及每个时刻是提前几天的预告
    static func times(on day: Date, schedule: Schedule, calendar: Calendar) -> [(ClockTime, Int)] {
        switch schedule {
        case .once:
            return []
        case .daily(let times, let weekdays):
            guard matches(day, weekdays: weekdays, calendar: calendar) else { return [] }
            return times.map { ($0, 0) }
        case .interval(let every, let from, let to, let weekdays):
            guard every > 0, from <= to, matches(day, weekdays: weekdays, calendar: calendar) else { return [] }
            return stride(from: from.minutes, through: to.minutes, by: every).compactMap {
                ClockTime(hour: $0 / 60, minute: $0 % 60).map { ($0, 0) }
            }
        case .monthly(let days, let times):
            let dayOfMonth = calendar.component(.day, from: day)
            let lastDay = calendar.range(of: .day, in: .month, for: day)?.count ?? 31
            guard Set(days.map { min($0, lastDay) }).contains(dayOfMonth) else { return [] }
            return times.map { ($0, 0) }
        case .yearly(let month, let dayOfMonth, let times, let leadDays):
            var result: [(ClockTime, Int)] = []
            for lead in Set([0] + leadDays.filter { $0 > 0 }) {
                guard let target = calendar.date(byAdding: .day, value: lead, to: day),
                      isAnniversary(target, month: month, day: dayOfMonth, calendar: calendar) else { continue }
                result += times.map { ($0, lead) }
            }
            return result
        }
    }

    /// 1 = 周一 … 7 = 周日（系统的 weekday 是 1 = 周日）
    static func isoWeekday(_ date: Date, calendar: Calendar) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7 + 1
    }

    private static func matches(_ day: Date, weekdays: [Int], calendar: Calendar) -> Bool {
        weekdays.isEmpty || weekdays.contains(isoWeekday(day, calendar: calendar))
    }

    /// 是不是每年的那一天；2 月 29 日在平年算 2 月 28 日
    private static func isAnniversary(_ date: Date, month: Int, day: Int, calendar: Calendar) -> Bool {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        guard c.month == month else { return false }
        if month == 2 && day == 29, let year = c.year,
           !(year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) {
            return c.day == 28
        }
        return c.day == day
    }

    /// 考虑状态、开始 / 结束日期、次数上限之后，[start, end) 里真正要响的
    static func fires(_ r: Reminder, from start: Date, to end: Date, calendar: Calendar,
                      limit: Int = .max) -> [Fire] {
        guard r.state == .active else { return [] }
        // 从「开始日期」和「建立时间」里较晚的那个算起，建之前的时刻不响、也不计入次数
        let origin = max(r.startDate ?? r.createdAt, r.createdAt)
        let upper = r.endDate.map { min(end, $0.addingTimeInterval(1)) } ?? end
        guard let maxCount = r.maxOccurrences else {
            return rawFires(r, from: max(start, origin), to: upper, calendar: calendar, limit: limit)
        }
        let all = rawFires(r, from: origin, to: upper, calendar: calendar, limit: maxCount)
        return Array(all.filter { $0.scheduledAt >= start }.prefix(limit))
    }

    /// now 之后的 count 次
    static func next(_ r: Reminder, after now: Date, count: Int, calendar: Calendar) -> [Fire] {
        let horizon = calendar.date(byAdding: .day, value: horizonDays, to: now) ?? now
        return fires(r, from: now.addingTimeInterval(0.001), to: horizon, calendar: calendar, limit: count)
    }

    /// 以后再也不会响了（过了结束日期、响满次数、一次性的已经过了）
    static func shouldFinish(_ r: Reminder, now: Date, calendar: Calendar) -> Bool {
        r.state == .active && next(r, after: now, count: 1, calendar: calendar).isEmpty
    }

    /// 第 ordinal 次响铃用哪句文案；提前预告前面加「还有 N 天：」
    static func message(_ r: Reminder, fire: Fire, ordinal: Int) -> String {
        let base = r.messages.isEmpty ? r.title : r.messages[abs(ordinal) % r.messages.count]
        return fire.leadDays > 0 ? "还有 \(fire.leadDays) 天：\(base)" : base
    }
}
```
- [ ] **Step 4:** 跑 `ReminderPlannerTests`，全部通过。
- [ ] **Step 5: 提交**「0.5：提醒排期——响铃时间」

### Task 5: 排期第二部分：到期处理 `due` / `plan` / `process`（先写测试，含 30 天模拟）

**Files:** Modify `Shared/ReminderPlanner.swift`；Create `RestBreakTests/ReminderProcessTests.swift`、`RestBreakTests/ReminderSimulationTests.swift`

- [ ] **Step 1: 测试 `ReminderProcessTests.swift`**
```swift
import Foundation
import Testing
@testable import RestBreak

/// 主 App 每 30 秒一次的处理：到点、错过、强提醒再提醒、自动结束、通知 AI 新建的提醒
struct ReminderProcessTests {
    let cal = RT.calendar

    func data(_ reminders: [Reminder], checkedAt: String?) -> ReminderData {
        var d = ReminderData()
        d.reminders = reminders
        d.checkedAt = checkedAt.map(RT.d)
        return d
    }

    @Test func 第一次运行不补以前的() {
        var d = data([RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []))], checkedAt: nil)
        let report = ReminderPlanner.process(&d, now: RT.d("2026-10-23 10:00"), calendar: cal)
        #expect(d.occurrences.isEmpty && report.cards.isEmpty)
        #expect(d.checkedAt == RT.d("2026-10-23 10:00"))
    }

    @Test func 准时_普通提醒记为已提醒() {
        var d = data([RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []))], checkedAt: "2026-10-23 08:59")
        let report = ReminderPlanner.process(&d, now: RT.d("2026-10-23 09:00"), calendar: cal)
        #expect(d.occurrences.map(\.outcome) == [.notified])
        #expect(report.cards.isEmpty)
    }

    @Test func 准时_强提醒弹卡片() {
        var d = data([RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []), style: .firm)], checkedAt: "2026-10-23 08:59")
        let report = ReminderPlanner.process(&d, now: RT.d("2026-10-23 09:00"), calendar: cal)
        #expect(d.occurrences.map(\.outcome) == [.pending])
        #expect(report.cards.map(\.scheduledAt) == [RT.d("2026-10-23 09:00")])
    }

    @Test func 晚了两小时_记为错过并汇总() {
        var d = data([RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []))], checkedAt: "2026-10-23 08:00")
        let report = ReminderPlanner.process(&d, now: RT.d("2026-10-23 11:00"), calendar: cal)
        #expect(d.occurrences.map(\.outcome) == [.missed])
        #expect(report.lateTitles == ["吃药"])
    }

    @Test func 晚了超过12小时_只记录不汇总() {
        var d = data([RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []))], checkedAt: "2026-10-23 08:00")
        let report = ReminderPlanner.process(&d, now: RT.d("2026-10-23 21:30"), calendar: cal)
        #expect(d.occurrences.map(\.outcome) == [.missed])
        #expect(report.lateTitles.isEmpty)
    }

    @Test func 强提醒没处理_每10分钟再提醒_3次后记为错过() {
        var d = data([RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []), style: .firm)], checkedAt: "2026-10-23 08:59")
        _ = ReminderPlanner.process(&d, now: RT.d("2026-10-23 09:00"), calendar: cal)
        var nagTimes: [String] = []
        var expiredAt: String?
        for minute in 1...45 {
            let now = "2026-10-23 09:\(String(format: "%02d", minute))"
            let report = ReminderPlanner.process(&d, now: RT.d(now), calendar: cal)
            if !report.nags.isEmpty { nagTimes.append(now) }
            if !report.expired.isEmpty { expiredAt = now }
        }
        #expect(nagTimes == ["2026-10-23 09:10", "2026-10-23 09:20", "2026-10-23 09:30"])
        #expect(expiredAt == "2026-10-23 09:40")
        #expect(d.occurrences.map(\.outcome) == [.missed])
    }

    @Test func 推迟后到点再弹() {
        var d = data([RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []), style: .firm)], checkedAt: "2026-10-23 08:59")
        _ = ReminderPlanner.process(&d, now: RT.d("2026-10-23 09:00"), calendar: cal)
        d.setOutcome("r1", scheduledAt: RT.d("2026-10-23 09:00"), .snoozed, now: RT.d("2026-10-23 09:01"),
                     snoozedUntil: RT.d("2026-10-23 09:11"))
        #expect(ReminderPlanner.process(&d, now: RT.d("2026-10-23 09:10"), calendar: cal).cards.isEmpty)
        let report = ReminderPlanner.process(&d, now: RT.d("2026-10-23 09:11"), calendar: cal)
        #expect(report.cards.map(\.ringAt) == [RT.d("2026-10-23 09:11")])
        #expect(d.occurrences.map(\.outcome) == [.pending])
    }

    @Test func 一次性响过后结束() {
        var d = data([RT.reminder(.once(at: RT.d("2026-10-23 09:00")))], checkedAt: "2026-10-23 08:59")
        _ = ReminderPlanner.process(&d, now: RT.d("2026-10-23 09:00"), calendar: cal)
        #expect(d.reminders[0].state == .finished)
        #expect(d.occurrences.map(\.outcome) == [.notified])
    }

    @Test func AI新建的提醒只通知一次_手动建的不通知() {
        var ai = RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []), id: "a")
        ai.announced = false
        var manual = RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []), id: "m", createdBy: ReminderTools.manualClient)
        manual.announced = false
        var d = data([ai, manual], checkedAt: "2026-10-23 08:00")
        #expect(ReminderPlanner.process(&d, now: RT.d("2026-10-23 08:01"), calendar: cal).created.map(\.id) == ["a"])
        #expect(ReminderPlanner.process(&d, now: RT.d("2026-10-23 08:02"), calendar: cal).created.isEmpty)
        #expect(d.reminders.allSatisfy(\.announced))
    }

    @Test func 登记系统通知_跳过已处理_带上推迟的_最多limit条() {
        var d = data([RT.reminder(.interval(everyMinutes: 15, from: RT.t("00:00"), to: RT.t("23:45"), weekdays: []))],
                     checkedAt: "2026-10-23 08:00")
        d.setOutcome("r1", scheduledAt: RT.d("2026-10-23 08:15"), .done, now: RT.d("2026-10-23 08:01"))
        d.setOutcome("r1", scheduledAt: RT.d("2026-10-23 07:45"), .snoozed, now: RT.d("2026-10-23 07:50"),
                     snoozedUntil: RT.d("2026-10-23 08:20"))
        let plan = ReminderPlanner.plan(d, from: RT.d("2026-10-23 08:01"), days: 7, limit: 50, calendar: cal)
        #expect(plan.count == 50)
        #expect(!plan.contains { $0.scheduledAt == RT.d("2026-10-23 08:15") })
        #expect(plan.contains { $0.ringAt == RT.d("2026-10-23 08:20") && $0.scheduledAt == RT.d("2026-10-23 07:45") })
        #expect(plan == plan.sorted { $0.ringAt < $1.ringAt })
    }

    @Test func 清理90天前的记录() {
        var d = ReminderData()
        d.setOutcome("r1", scheduledAt: RT.d("2026-07-01 09:00"), .done, now: RT.d("2026-07-01 09:00"))
        d.setOutcome("r1", scheduledAt: RT.d("2026-10-01 09:00"), .done, now: RT.d("2026-10-01 09:00"))
        ReminderPlanner.prune(&d, now: RT.d("2026-10-23 09:00"))
        #expect(d.occurrences.map(\.scheduledAt) == [RT.d("2026-10-01 09:00")])
    }
}
```
- [ ] **Step 2: 测试 `ReminderSimulationTests.swift`**（参照 `DaySimulationTests`：用固定种子模拟 30 天）
```swift
import Foundation
import Testing
@testable import RestBreak

/// 固定种子模拟 30 天：每 5 分钟处理一次，随机合盖几小时，随机处理强提醒的卡片。
/// 检查规则不变量：不重复、不漏、结束后不再响、卡片不会一直挂着
struct ReminderSimulationTests {
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    @Test(arguments: [1, 7, 42])
    func 三十天不变量(seed: UInt64) {
        let cal = RT.calendar
        var rng = Seeded(state: seed)
        var d = ReminderData()
        d.reminders = [
            RT.reminder(.daily(times: [RT.t("09:00"), RT.t("21:00")], weekdays: []), id: "med", style: .firm, max: 21),
            RT.reminder(.interval(everyMinutes: 90, from: RT.t("09:00"), to: RT.t("18:00"), weekdays: [1, 2, 3, 4, 5]), id: "water"),
            RT.reminder(.monthly(days: [31], times: [RT.t("10:00")]), id: "rent"),
            RT.reminder(.once(at: RT.d("2026-10-30 18:30")), id: "milk", style: .firm),
            RT.reminder(.yearly(month: 11, day: 5, times: [RT.t("09:00")], leadDays: [5]), id: "mom"),
        ]
        let start = RT.d("2026-10-23 08:00")
        let end = RT.d("2026-11-22 08:00")
        d.checkedAt = start
        var now = start
        var finishedAt: [String: Date] = [:]
        while now < end {
            now += 5 * 60
            // 约 1% 的概率合盖 1～14 小时（期间不处理）
            if Int.random(in: 0..<100, using: &rng) == 0 { now += TimeInterval(Int.random(in: 1...14, using: &rng)) * 3600 }
            // 随机处理挂着的卡片
            for o in d.occurrences where o.outcome == .pending && Bool.random(using: &rng) {
                switch Int.random(in: 0..<3, using: &rng) {
                case 0: d.setOutcome(o.reminderID, scheduledAt: o.scheduledAt, .done, now: now)
                case 1: d.setOutcome(o.reminderID, scheduledAt: o.scheduledAt, .snoozed, now: now, snoozedUntil: now + 600)
                default: d.setOutcome(o.reminderID, scheduledAt: o.scheduledAt, .skipped, now: now)
                }
            }
            _ = ReminderPlanner.process(&d, now: now, calendar: cal)
            for r in d.reminders where r.state == .finished && finishedAt[r.id] == nil { finishedAt[r.id] = now }

            // 不变量 1：同一次响铃只有一条记录
            let keys = d.occurrences.map { "\($0.reminderID)|\($0.scheduledAt.timeIntervalSince1970)" }
            #expect(Set(keys).count == keys.count)
            // 不变量 2：卡片挂着不会超过 40 分钟（再提醒 3 次后记为错过）
            for o in d.occurrences where o.outcome == .pending {
                #expect(now.timeIntervalSince(o.snoozedUntil ?? o.scheduledAt) < 40 * 60 + 5 * 60)
            }
        }
        // 不变量 3：每条提醒在模拟期内该响的都有记录，一次不多一次不少
        for r in d.reminders {
            var original = r
            original.state = .active
            let expected = Set(ReminderPlanner.fires(original, from: start + 0.001, to: d.checkedAt! + 0.001, calendar: cal).map(\.scheduledAt))
            let recorded = Set(d.occurrences.filter { $0.reminderID == r.id }.map(\.scheduledAt))
            #expect(recorded == expected, "\(r.id)")
        }
        // 不变量 4：吃药一共响 21 次就结束；牛奶响一次就结束
        #expect(d.occurrences.filter { $0.reminderID == "med" }.count == 21)
        #expect(d.reminder("med")?.state == .finished && d.reminder("milk")?.state == .finished)
        // 不变量 5：结束之后没有新的记录
        for (id, at) in finishedAt {
            #expect(!d.occurrences.contains { $0.reminderID == id && $0.scheduledAt > at })
        }
    }
}
```
- [ ] **Step 3:** 跑一次，确认编译失败。
- [ ] **Step 4: 在 `ReminderPlanner.swift` 末尾加上**
```swift
/// 到点的一次响铃，以及晚了多久
struct DueFire: Equatable, Sendable {
    var fire: Fire
    var isSnooze: Bool
    var lateness: TimeInterval
}

/// 一次处理之后，主 App 要做的事
struct ProcessReport: Equatable, Sendable {
    /// 要弹卡片的强提醒
    var cards: [Fire] = []
    /// 要再提醒一次的强提醒（横幅）
    var nags: [Fire] = []
    /// 再提醒 3 次仍没处理、已记为错过：卡片收掉
    var expired: [Fire] = []
    /// 合盖、关机期间错过的（5 分钟～12 小时），合成一条汇总通知
    var lateTitles: [String] = []
    /// AI 新建、还没告诉用户的提醒
    var created: [Reminder] = []
}

extension ReminderPlanner {
    /// 晚了 5 分钟以内算准时
    static let onTimeWindow: TimeInterval = 5 * 60
    /// 晚了 12 小时以上只记录、不再告诉用户
    static let maxLateness: TimeInterval = 12 * 3600
    static let nagInterval: TimeInterval = 10 * 60
    static let maxNags = 3
    static let keepDays = 90

    /// (checkedAt, now] 里到点、还没有记录的响铃（含「10 分钟后」再响的）
    static func due(_ data: ReminderData, now: Date, calendar: Calendar) -> [DueFire] {
        guard let since = data.checkedAt, since < now else { return [] }
        let handled = Set(data.occurrences.map { Key($0.reminderID, $0.scheduledAt) })
        var result: [DueFire] = []
        for r in data.reminders {
            for fire in fires(r, from: since.addingTimeInterval(0.001), to: now.addingTimeInterval(0.001), calendar: calendar)
            where !handled.contains(Key(fire.reminderID, fire.scheduledAt)) {
                result.append(DueFire(fire: fire, isSnooze: false, lateness: now.timeIntervalSince(fire.ringAt)))
            }
        }
        for o in data.occurrences where o.outcome == .snoozed {
            guard let until = o.snoozedUntil, until > since, until <= now else { continue }
            let fire = Fire(reminderID: o.reminderID, scheduledAt: o.scheduledAt, ringAt: until, leadDays: o.leadDays)
            result.append(DueFire(fire: fire, isSnooze: true, lateness: now.timeIntervalSince(until)))
        }
        return result.sorted { $0.fire.ringAt < $1.fire.ringAt }
    }

    /// 接下来 days 天要登记成系统定时通知的响铃（跳过已处理的，带上推迟的），按时间排序最多 limit 条
    static func plan(_ data: ReminderData, from now: Date, days: Int, limit: Int, calendar: Calendar) -> [Fire] {
        let end = calendar.date(byAdding: .day, value: days, to: now) ?? now
        let handled = Set(data.occurrences.map { Key($0.reminderID, $0.scheduledAt) })
        var all = data.reminders.flatMap { fires($0, from: now, to: end, calendar: calendar, limit: limit) }
            .filter { !handled.contains(Key($0.reminderID, $0.scheduledAt)) }
        all += data.occurrences.compactMap { o in
            guard o.outcome == .snoozed, let until = o.snoozedUntil, until > now, until < end,
                  data.reminder(o.reminderID) != nil else { return nil }
            return Fire(reminderID: o.reminderID, scheduledAt: o.scheduledAt, ringAt: until, leadDays: o.leadDays)
        }
        return Array(all.sorted { $0.ringAt < $1.ringAt }.prefix(limit))
    }

    static func prune(_ data: inout ReminderData, now: Date) {
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86400)
        data.occurrences.removeAll { $0.scheduledAt < cutoff }
    }

    /// 主 App 每次处理都调用这一个函数（在文件锁里）。顺序：到点 → 再提醒 → 结束 → 通知新建 → 清理
    static func process(_ data: inout ReminderData, now: Date, calendar: Calendar) -> ProcessReport {
        var report = ProcessReport()
        if data.checkedAt == nil { data.checkedAt = now }   // 第一次运行：不补以前的

        for due in due(data, now: now, calendar: calendar) {
            let fire = due.fire
            guard let r = data.reminder(fire.reminderID) else { continue }
            let snoozedUntil = due.isSnooze ? fire.ringAt : nil
            if due.lateness > maxLateness {
                data.setOutcome(r.id, scheduledAt: fire.scheduledAt, leadDays: fire.leadDays, .missed, now: now)
            } else if due.lateness > onTimeWindow {
                data.setOutcome(r.id, scheduledAt: fire.scheduledAt, leadDays: fire.leadDays, .missed, now: now)
                report.lateTitles.append(r.title)
            } else if r.style == .firm {
                data.setOutcome(r.id, scheduledAt: fire.scheduledAt, leadDays: fire.leadDays, .pending,
                                now: now, snoozedUntil: snoozedUntil)
                if let i = data.occurrences.firstIndex(where: { $0.reminderID == r.id && $0.scheduledAt == fire.scheduledAt }) {
                    data.occurrences[i].nagCount = 0
                }
                report.cards.append(fire)
            } else {
                data.setOutcome(r.id, scheduledAt: fire.scheduledAt, leadDays: fire.leadDays, .notified, now: now)
            }
        }

        // 强提醒没处理：每 10 分钟再提醒一次，3 次之后（第 40 分钟）记为错过
        for i in data.occurrences.indices where data.occurrences[i].outcome == .pending {
            let o = data.occurrences[i]
            let base = o.snoozedUntil ?? o.scheduledAt
            let fire = Fire(reminderID: o.reminderID, scheduledAt: o.scheduledAt, ringAt: now, leadDays: o.leadDays)
            let elapsed = now.timeIntervalSince(base)
            if elapsed >= nagInterval * Double(maxNags + 1) {
                data.occurrences[i].outcome = .missed
                data.occurrences[i].actedAt = now
                report.expired.append(fire)
            } else if o.nagCount < maxNags, elapsed >= nagInterval * Double(o.nagCount + 1) {
                data.occurrences[i].nagCount += 1
                report.nags.append(fire)
            }
        }

        for i in data.reminders.indices where shouldFinish(data.reminders[i], now: now, calendar: calendar) {
            data.reminders[i].state = .finished
            data.reminders[i].updatedAt = now
        }
        for i in data.reminders.indices where !data.reminders[i].announced {
            data.reminders[i].announced = true
            if data.reminders[i].createdBy != ReminderTools.manualClient { report.created.append(data.reminders[i]) }
        }
        prune(&data, now: now)
        data.checkedAt = now
        return report
    }

    private struct Key: Hashable {
        let id: String
        let at: Date
        init(_ id: String, _ at: Date) { self.id = id; self.at = at }
    }
}
```
`ReminderTools.manualClient` 在 Task 6 定义。这一步先在 `Shared/ReminderTools.swift` 里放一个占位：`enum ReminderTools { static let manualClient = "手动" }`，Task 6 会整个替换掉这个文件。
- [ ] **Step 5:** 跑 `ReminderProcessTests`、`ReminderSimulationTests`、`ReminderPlannerTests`，全部通过。模拟测试失败时，先用 superpowers:systematic-debugging 找原因，**不要改测试去迁就实现**。
- [ ] **Step 6: 提交**「0.5：到期处理、再提醒、错过汇总、30 天模拟」

### Task 6: 中文描述 `ScheduleText` + 工具 `ReminderTools`（先写测试）

**Files:** Create `Shared/ScheduleText.swift`、`Shared/ReminderTools.swift`（替换占位）、`RestBreakTests/ScheduleTextTests.swift`、`RestBreakTests/ReminderToolsTests.swift`；Modify `RestBreakTests/ReminderTestSupport.swift`（恢复 `d` 和 `context`）

- [ ] **Step 1: 测试 `ScheduleTextTests.swift`**
```swift
import Foundation
import Testing
@testable import RestBreak

struct ScheduleTextTests {
    let cal = RT.calendar

    @Test func 描述时间安排() {
        #expect(ScheduleText.describe(.daily(times: [RT.t("21:00"), RT.t("09:00")], weekdays: []), calendar: cal) == "每天 09:00、21:00")
        #expect(ScheduleText.describe(.daily(times: [RT.t("10:00")], weekdays: [1, 2, 3, 4, 5]), calendar: cal) == "工作日 10:00")
        #expect(ScheduleText.describe(.daily(times: [RT.t("10:00")], weekdays: [6, 7]), calendar: cal) == "周末 10:00")
        #expect(ScheduleText.describe(.daily(times: [RT.t("10:00")], weekdays: [3, 1]), calendar: cal) == "每周一、三 10:00")
        #expect(ScheduleText.describe(.interval(everyMinutes: 90, from: RT.t("09:00"), to: RT.t("18:00"), weekdays: []), calendar: cal)
                == "每天 09:00–18:00 每 1 小时 30 分钟")
        #expect(ScheduleText.describe(.monthly(days: [10], times: [RT.t("09:00")]), calendar: cal) == "每月 10 号 09:00")
        #expect(ScheduleText.describe(.yearly(month: 11, day: 5, times: [RT.t("09:00")], leadDays: [5]), calendar: cal)
                == "每年 11 月 5 日 09:00（提前 5 天预告）")
        #expect(ScheduleText.describe(.once(at: RT.d("2026-10-24 18:30")), calendar: cal) == "10 月 24 日 周六 18:30")
    }

    @Test func 下次响铃的说法() {
        let now = RT.d("2026-10-23 15:00")
        #expect(ScheduleText.fireText(RT.d("2026-10-23 21:00"), now: now, calendar: cal) == "今天 21:00")
        #expect(ScheduleText.fireText(RT.d("2026-10-24 09:00"), now: now, calendar: cal) == "明天 09:00")
        #expect(ScheduleText.fireText(RT.d("2026-10-26 09:00"), now: now, calendar: cal) == "10 月 26 日 周一 09:00")
    }

    @Test func 状态说明() {
        let now = RT.d("2026-10-23 15:00")
        let times = RT.reminder(.daily(times: [RT.t("09:00"), RT.t("21:00")], weekdays: []), max: 21)
        #expect(ScheduleText.status(times, now: now, calendar: cal) == "还剩 20 次")
        let days = RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []), end: RT.d("2026-10-26 23:59"))
        #expect(ScheduleText.status(days, now: now, calendar: cal) == "还剩 4 天")
        var paused = days; paused.state = .paused
        #expect(ScheduleText.status(paused, now: now, calendar: cal) == "已暂停")
    }

    @Test func 客户端显示名() {
        #expect(ClientNames.display("claude-code") == "Claude Code")
        #expect(ClientNames.display("codex-mcp-client") == "Codex")
        #expect(ClientNames.display("cursor") == "cursor")
    }

    @Test func 多久以前() {
        let now = RT.d("2026-10-23 15:00")
        #expect(ScheduleText.ago(now - 20, now: now) == "刚刚")
        #expect(ScheduleText.ago(RT.d("2026-10-23 14:57"), now: now) == "3 分钟前")
        #expect(ScheduleText.ago(RT.d("2026-10-23 12:00"), now: now) == "3 小时前")
        #expect(ScheduleText.ago(RT.d("2026-10-21 12:00"), now: now) == "2 天前")
    }
}
```
- [ ] **Step 2: 测试 `ReminderToolsTests.swift`**
```swift
import Foundation
import Testing
@testable import RestBreak

/// 5 个 MCP 工具：正常和出错的输入输出
struct ReminderToolsTests {
    func call(_ name: String, _ args: [String: Any], at now: String = "2026-10-23 15:12",
              store: ReminderStore, client: String = "claude-code") -> ToolResult {
        ReminderTools.call(name, arguments: args, context: RT.context(now, store: store, client: client))
    }

    let daily: [String: Any] = ["title": "吃抗生素", "messages": ["饭后半小时，该吃药啦"],
                                "schedule": ["kind": "daily", "times": ["09:00", "21:00"]], "style": "firm",
                                "reason": "10/23 聊到医生开了 7 天抗生素", "endDate": "2026-10-29"]

    @Test func 新建每天提醒() throws {
        let store = RT.tempStore()
        let result = call("create_reminder", daily, store: store)
        #expect(!result.isError && result.changed)
        let object = RT.object(result.text)
        #expect(object["next"] as? [String] == ["今天 21:00", "明天 09:00", "明天 21:00"])
        #expect((object["now"] as? [String: Any])?["weekday"] as? String == "周五")
        let saved = try #require(try store.load().reminders.first)
        #expect(saved.createdBy == "claude-code" && saved.style == .firm && !saved.announced)
        #expect(saved.endDate == RT.calendar.date(bySettingHour: 23, minute: 59, second: 59, of: RT.d("2026-10-29 00:00")))
    }

    @Test func 过去的时间报错并给建议() {
        let result = call("create_reminder", ["title": "买牛奶", "messages": ["下班买牛奶"],
                                              "schedule": ["kind": "once", "at": "2026-10-23 08:00"]], store: RT.tempStore())
        #expect(result.isError)
        #expect(result.text.contains("已经过去了") && result.text.contains("2026-10-23 15:12 周五") && result.text.contains("明天"))
    }

    @Test func 带时区的时间也接受() throws {
        let store = RT.tempStore()
        let result = call("create_reminder", ["title": "开会", "messages": ["准备开会"],
                                              "schedule": ["kind": "once", "at": "2026-10-24T09:30+08:00"]], store: store)
        #expect(!result.isError)
        #expect(try store.load().reminders.first?.schedule == .once(at: RT.d("2026-10-24 09:30")))
    }

    @Test func 时刻格式不对() {
        let result = call("create_reminder", ["title": "喝水", "messages": ["喝水"],
                                              "schedule": ["kind": "daily", "times": ["9点"]]], store: RT.tempStore())
        #expect(result.isError && result.text.contains("HH:mm"))
    }

    @Test func 间隔太短() {
        let result = call("create_reminder", ["title": "喝水", "messages": ["喝水"],
                                              "schedule": ["kind": "interval", "everyMinutes": 10, "from": "09:00", "to": "18:00"]],
                          store: RT.tempStore())
        #expect(result.isError && result.text.contains("15"))
    }

    @Test func 以后不会再响时报错() {
        var args = daily
        args["endDate"] = "2026-10-23"
        args["schedule"] = ["kind": "daily", "times": ["09:00"]]
        let result = call("create_reminder", args, store: RT.tempStore())
        #expect(result.isError && result.text.contains("一次都不会响"))
    }

    @Test func 最多100条() throws {
        let store = RT.tempStore()
        try store.update { data in
            data.reminders = (0..<100).map { RT.reminder(.daily(times: [RT.t("09:00")], weekdays: []), id: "x\($0)", createdBy: "手动") }
        }
        #expect(call("create_reminder", daily, store: store).text.contains("100 条"))
    }

    @Test func 同一客户端每小时最多新建20条() {
        let store = RT.tempStore()
        for _ in 0..<20 { #expect(!call("create_reminder", daily, store: store).isError) }
        #expect(call("create_reminder", daily, store: store).isError)
        #expect(!call("create_reminder", daily, store: store, client: "codex-mcp-client").isError)
    }

    @Test func 列表带完成情况() throws {
        let store = RT.tempStore()
        _ = call("create_reminder", daily, store: store)
        let id = try #require(try store.load().reminders.first?.id)
        try store.update { $0.setOutcome(id, scheduledAt: RT.d("2026-10-23 21:00"), .done, now: RT.d("2026-10-23 21:05")) }
        let result = call("list_reminders", ["historyDays": 7], at: "2026-10-24 08:00", store: store)
        let reminders = try #require(RT.object(result.text)["reminders"] as? [[String: Any]])
        let history = try #require(reminders.first?["history"] as? [[String: Any]])
        #expect(history.first?["result"] as? String == "完成")
        #expect(reminders.first?["schedule"] as? String == "每天 09:00、21:00")
    }

    @Test func 修改和暂停() throws {
        let store = RT.tempStore()
        _ = call("create_reminder", daily, store: store)
        let id = try #require(try store.load().reminders.first?.id)
        let result = call("update_reminder", ["id": id, "title": "吃消炎药", "state": "paused"], store: store)
        #expect(!result.isError)
        let saved = try #require(try store.load().reminders.first)
        #expect(saved.title == "吃消炎药" && saved.state == .paused)
        #expect(call("update_reminder", ["id": "nope00"], store: store).text.contains("list_reminders"))
    }

    @Test func 删除连同记录() throws {
        let store = RT.tempStore()
        _ = call("create_reminder", daily, store: store)
        let id = try #require(try store.load().reminders.first?.id)
        try store.update { $0.setOutcome(id, scheduledAt: RT.d("2026-10-23 21:00"), .done, now: RT.d("2026-10-23 21:05")) }
        #expect(!call("delete_reminder", ["id": id], store: store).isError)
        let data = try store.load()
        #expect(data.reminders.isEmpty && data.occurrences.isEmpty)
    }

    @Test func 概览() throws {
        let store = RT.tempStore()
        _ = call("create_reminder", daily, store: store)
        let object = RT.object(call("get_overview", [:], store: store).text)
        let today = try #require(object["upcoming"] as? [[String: Any]])
        #expect(today.map { $0["time"] as? String } == ["今天 21:00", "明天 09:00"])
        #expect((object["now"] as? [String: Any])?["local"] as? String == "2026-10-23 15:12")
    }

    @Test func 工具定义合法() throws {
        #expect(Set(ReminderTools.specs.map(\.name)).count == 5)
        for spec in ReminderTools.specs {
            let schema = try #require(try JSONSerialization.jsonObject(with: Data(spec.schema.utf8)) as? [String: Any], "\(spec.name)")
            #expect(schema["type"] as? String == "object")
        }
        #expect(ReminderTools.specs.filter(\.readOnly).map(\.name).sorted() == ["get_overview", "list_reminders"])
        #expect(!ReminderTools.instructions.isEmpty)
    }

    @Test func 不认识的工具() {
        #expect(call("make_coffee", [:], store: RT.tempStore()).isError)
    }
}
```
- [ ] **Step 3:** 把 `ReminderTestSupport.swift` 恢复成 Task 2 Step 1 的写法（`d` 用 `ReminderTools.parseDateTime`，加回 `tempStore`、`context`），然后跑一次，确认编译失败。
- [ ] **Step 4: 实现 `Shared/ScheduleText.swift`**
```swift
import Foundation

/// 把时间安排和时刻转成中文说法（App 界面和给 AI 的结果共用）
enum ScheduleText {
    static let weekdayNames = ["一", "二", "三", "四", "五", "六", "日"]

    static func describe(_ schedule: Schedule, calendar: Calendar) -> String {
        switch schedule {
        case .once(let at):
            return dateTime(at, calendar: calendar)
        case .daily(let times, let weekdays):
            return "\(days(weekdays)) \(join(times))"
        case .interval(let every, let from, let to, let weekdays):
            return "\(days(weekdays)) \(from)–\(to) 每 \(minutes(every))"
        case .monthly(let ds, let times):
            return "每月 \(ds.sorted().map { "\($0) 号" }.joined(separator: "、")) \(join(times))"
        case .yearly(let month, let day, let times, let leadDays):
            let lead = leadDays.isEmpty ? "" : "（提前 \(leadDays.sorted(by: >).map(String.init).joined(separator: "、")) 天预告）"
            return "每年 \(month) 月 \(day) 日 \(join(times))\(lead)"
        }
    }

    static func days(_ weekdays: [Int]) -> String {
        let set = Set(weekdays)
        if set.isEmpty || set.count == 7 { return "每天" }
        if set == Set(1...5) { return "工作日" }
        if set == [6, 7] { return "周末" }
        return "每周" + set.sorted().map { weekdayNames[$0 - 1] }.joined(separator: "、")
    }

    static func minutes(_ m: Int) -> String {
        if m % 60 == 0 { return "\(m / 60) 小时" }
        return m > 60 ? "\(m / 60) 小时 \(m % 60) 分钟" : "\(m) 分钟"
    }

    static func join(_ times: [ClockTime]) -> String {
        times.sorted().map(\.description).joined(separator: "、")
    }

    /// "10 月 24 日 周六 18:30"
    static func dateTime(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        let weekday = weekdayNames[ReminderPlanner.isoWeekday(date, calendar: calendar) - 1]
        return "\(c.month!) 月 \(c.day!) 日 周\(weekday) " + String(format: "%02d:%02d", c.hour!, c.minute!)
    }

    /// "今天 21:00" / "明天 09:00" / "10 月 26 日 周一 09:00"
    static func fireText(_ date: Date, now: Date, calendar: Calendar) -> String {
        let time = String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date))
        if calendar.isDate(date, inSameDayAs: now) { return "今天 \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "明天 \(time)"
        }
        return dateTime(date, calendar: calendar)
    }

    /// 列表里的补充说明：「已暂停」「已结束」「还剩 N 次」「还剩 N 天」
    static func status(_ r: Reminder, now: Date, calendar: Calendar) -> String? {
        switch r.state {
        case .paused: return "已暂停"
        case .finished: return "已结束"
        case .active: break
        }
        if r.maxOccurrences != nil {
            let horizon = calendar.date(byAdding: .day, value: ReminderPlanner.horizonDays, to: now) ?? now
            return "还剩 \(ReminderPlanner.fires(r, from: now, to: horizon, calendar: calendar).count) 次"
        }
        if let end = r.endDate,
           let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: end)).day {
            return "还剩 \(days + 1) 天"
        }
        return nil
    }

    /// "刚刚" / "3 分钟前" / "3 小时前" / "2 天前"
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) 小时前" }
        return "\(Int(seconds / 86400)) 天前"
    }
}

/// MCP 客户端名 → 给人看的名字
enum ClientNames {
    static func display(_ name: String) -> String {
        switch name {
        case "claude-code": "Claude Code"
        case "codex-mcp-client": "Codex"
        case "claude-ai": "Claude"
        default: name
        }
    }
}
```
- [ ] **Step 5: 实现 `Shared/ReminderTools.swift`**
```swift
import Foundation

struct ToolError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

struct ToolResult: Equatable, Sendable {
    var text: String
    var isError: Bool
    /// 改了数据：小程序据此决定要不要拉起主 App
    var changed: Bool
}

struct ToolSpec: Sendable {
    let name: String
    let description: String
    /// JSON Schema 原文
    let schema: String
    let readOnly: Bool
    let destructive: Bool
}

struct ToolContext {
    var now: Date
    var calendar: Calendar
    /// 调用方的 MCP 客户端名
    var client: String
    var store: ReminderStore
}

/// 给 AI 用的 5 个工具。参数是 JSON 解出来的字典，结果是 JSON 文本；不依赖 MCP SDK，方便测试
enum ReminderTools {
    static let manualClient = "手动"
    static let maxActive = 100
    static let minIntervalMinutes = 15
    static let maxCreatesPerHour = 20

    static let instructions = """
    你连接的是「歇一会」：用户 Mac 菜单栏上的休息与提醒助手。你可以替用户建、改、查提醒，歇一会负责到点准时提醒（它本身不调用任何 AI）。
    - 用户提到将来要做的事（吃药、买东西、截止日期、给某人回电话、交房租、家人生日）时，主动问一句「要我在歇一会里提醒你吗？」，用户同意后再建。
    - 时间都按用户本地时间理解。不确定现在几点时先调用 get_overview，它会返回当前时间和星期几。
    - messages 写 1～5 句贴合用户情况的提醒文案：短一点、暖一点，可以带上原因或进度（如「还剩 4 天就吃完了」）。反复响的提醒写 2～5 句不同的话，歇一会会轮换使用。
    - 吃药、重要截止这类不能错过的用 style = "firm"，其他用默认的 "gentle"。
    - reason 用一句话写清这个提醒从哪来，比如「10/23 聊到医生开了 7 天抗生素」。
    - 用户聊到相关话题时，可以先用 get_overview，或带 historyDays 调用 list_reminders，看看完成情况再给出关心。
    - 不要删除或修改不是这次对话里建的提醒，除非用户明确要求。
    - 建好后，用工具返回的 next（接下来 3 次）向用户复述确认。
    """

    private static let scheduleSchema = #"""
    {"type":"object","required":["kind"],"description":"什么时候响。时刻写本地时间 HH:mm；日期时间写 yyyy-MM-dd HH:mm（也接受带时区的 ISO 8601）","properties":{
     "kind":{"type":"string","enum":["once","daily","interval","monthly","yearly"],"description":"once 一次 / daily 每天（可限星期几）/ interval 每隔一段时间 / monthly 每月 / yearly 每年"},
     "at":{"type":"string","description":"once：什么时候，如 2026-10-24 18:30"},
     "times":{"type":"array","items":{"type":"string"},"description":"daily / monthly / yearly：哪几个时刻，如 [\"09:00\",\"21:00\"]"},
     "weekdays":{"type":"array","items":{"type":"integer","minimum":1,"maximum":7},"description":"daily / interval：只在星期几响，1 = 周一 … 7 = 周日；不填 = 每天"},
     "everyMinutes":{"type":"integer","minimum":15,"description":"interval：每隔多少分钟（至少 15）"},
     "from":{"type":"string","description":"interval：从几点开始，如 09:00"},
     "to":{"type":"string","description":"interval：到几点结束，如 18:00"},
     "days":{"type":"array","items":{"type":"integer","minimum":1,"maximum":31},"description":"monthly：每月几号；31 号在小月自动改成当月最后一天"},
     "month":{"type":"integer","minimum":1,"maximum":12,"description":"yearly：几月"},
     "day":{"type":"integer","minimum":1,"maximum":31,"description":"yearly：几号"},
     "leadDays":{"type":"array","items":{"type":"integer","minimum":1,"maximum":30},"description":"yearly：提前几天也预告一次，如 [5]"}}}
    """#

    private static let fieldSchemas = """
     "title":{"type":"string","description":"提醒标题，40 字以内，如「吃抗生素」"},
     "messages":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":5,"description":"1～5 句提醒文案，每次响铃轮换使用"},
     "schedule":\(scheduleSchema),
     "style":{"type":"string","enum":["gentle","firm"],"description":"gentle：只弹横幅（默认）；firm：横幅加一张不处理就不消失的卡片，没处理会每 10 分钟再提醒，适合吃药"},
     "reason":{"type":"string","description":"一句话：为什么建这个提醒"},
     "startDate":{"type":"string","description":"从哪天开始，yyyy-MM-dd；不填 = 现在"},
     "endDate":{"type":"string","description":"到哪天结束（含这一天），yyyy-MM-dd"},
     "maxOccurrences":{"type":"integer","minimum":1,"description":"一共响几次后自动结束，比如吃 7 天、一天 3 次就是 21"}
    """

    static let specs: [ToolSpec] = [
        ToolSpec(name: "get_overview",
                 description: "看歇一会的概况：现在的本地时间和星期几、今天和接下来 24 小时要响的提醒及每条的状态、最近 3 天错过的提醒。不确定现在几点、或想关心用户今天的情况时先调用它。",
                 schema: #"{"type":"object","properties":{}}"#, readOnly: true, destructive: false),
        ToolSpec(name: "create_reminder",
                 description: "新建一条提醒。用户同意后再调用。返回提醒内容和接下来 3 次响的时间，用来向用户复述确认。",
                 schema: #"{"type":"object","required":["title","messages","schedule"],"properties":{"# + fieldSchemas + "}}",
                 readOnly: false, destructive: false),
        ToolSpec(name: "list_reminders",
                 description: "列出提醒。status 为 active（默认，含已暂停）或 all（含已结束）；historyDays 为 1～30 时附上最近几天每次的完成情况，用来回答「这周药都按时吃了吗」。",
                 schema: #"{"type":"object","properties":{"status":{"type":"string","enum":["active","all"]},"historyDays":{"type":"integer","minimum":0,"maximum":30}}}"#,
                 readOnly: true, destructive: false),
        ToolSpec(name: "update_reminder",
                 description: "按 id 修改提醒，只传要改的字段。state 传 paused 暂停、active 恢复（已结束的也能恢复）；endDate、maxOccurrences 传 null 表示去掉限制。",
                 schema: #"{"type":"object","required":["id"],"properties":{"id":{"type":"string"},"state":{"type":"string","enum":["active","paused"]},"# + fieldSchemas + "}}",
                 readOnly: false, destructive: false),
        ToolSpec(name: "delete_reminder",
                 description: "按 id 删除提醒及其完成记录。只删用户明确要删的。",
                 schema: #"{"type":"object","required":["id"],"properties":{"id":{"type":"string"}}}"#,
                 readOnly: false, destructive: true),
    ]

    static func call(_ name: String, arguments: [String: Any], context: ToolContext) -> ToolResult {
        do {
            switch name {
            case "get_overview": return try overview(context)
            case "create_reminder": return try create(arguments, context)
            case "list_reminders": return try list(arguments, context)
            case "update_reminder": return try update(arguments, context)
            case "delete_reminder": return try delete(arguments, context)
            default: throw ToolError("没有这个工具：\(name)")
            }
        } catch let error as ToolError {
            return ToolResult(text: error.message, isError: true, changed: false)
        } catch let error as StoreError {
            return ToolResult(text: error.description, isError: true, changed: false)
        } catch {
            return ToolResult(text: "歇一会出错了：\(error.localizedDescription)", isError: true, changed: false)
        }
    }

    // MARK: - 五个工具

    private static func overview(_ c: ToolContext) throws -> ToolResult {
        let data = try c.store.load()
        let start = c.calendar.startOfDay(for: c.now)
        let end = c.now.addingTimeInterval(86400)
        let upcoming = data.reminders
            .flatMap { ReminderPlanner.fires($0, from: start, to: end, calendar: c.calendar) }
            .sorted { $0.scheduledAt < $1.scheduledAt }
            .compactMap { fire -> [String: Any]? in
                guard let r = data.reminder(fire.reminderID) else { return nil }
                let state = data.occurrence(r.id, at: fire.scheduledAt).map { outcomeText($0.outcome) }
                    ?? (fire.scheduledAt > c.now ? "待响" : "已过（歇一会还没处理）")
                return ["id": r.id, "title": r.title, "time": ScheduleText.fireText(fire.scheduledAt, now: c.now, calendar: c.calendar), "state": state]
            }
        let missed = data.occurrences
            .filter { $0.outcome == .missed && $0.scheduledAt >= c.now.addingTimeInterval(-3 * 86400) }
            .compactMap { o -> [String: Any]? in
                guard let r = data.reminder(o.reminderID) else { return nil }
                return ["id": r.id, "title": r.title, "time": ScheduleText.dateTime(o.scheduledAt, calendar: c.calendar)]
            }
        return result(["now": nowInfo(c), "upcoming": upcoming, "missedRecently": missed,
                       "activeCount": data.reminders.filter { $0.state == .active }.count,
                       "pausedCount": data.reminders.filter { $0.state == .paused }.count], changed: false)
    }

    private static func create(_ args: [String: Any], _ c: ToolContext) throws -> ToolResult {
        let title = try requiredText(args, "title", max: 40)
        let messages = try messageList(args["messages"])
        let schedule = try parseSchedule(args["schedule"], context: c)
        let style = try parseStyle(args["style"]) ?? .gentle
        let reason = try optionalText(args, "reason", max: 200)
        let startDate = try optionalDay(args, "startDate", c)
        let endDate = try optionalDay(args, "endDate", c).map(endOfDay(c))
        let maxOccurrences = try optionalPositive(args, "maxOccurrences")
        if let startDate, let endDate, endDate < startDate { throw ToolError("endDate 早于 startDate") }

        return try c.store.update { data in
            guard data.reminders.filter({ $0.state != .finished }).count < maxActive else {
                throw ToolError("已经有 \(maxActive) 条提醒了，请先帮用户删掉一些不用的")
            }
            let recent = data.reminders.filter { $0.createdBy == c.client && c.now.timeIntervalSince($0.createdAt) < 3600 }
            guard recent.count < maxCreatesPerHour else {
                throw ToolError("一小时内最多新建 \(maxCreatesPerHour) 条提醒，请稍后再试")
            }
            let reminder = Reminder(id: ReminderData.newID(existing: Set(data.reminders.map(\.id))),
                                    title: title, messages: messages, schedule: schedule, style: style, reason: reason,
                                    createdBy: c.client, createdAt: c.now, updatedAt: c.now,
                                    startDate: startDate, endDate: endDate, maxOccurrences: maxOccurrences,
                                    state: .active, announced: false)
            let next = ReminderPlanner.next(reminder, after: c.now, count: 3, calendar: c.calendar)
            guard !next.isEmpty else {
                throw ToolError("按这个时间安排，以后一次都不会响。请检查 endDate、maxOccurrences、weekdays。现在是 \(nowText(c))")
            }
            data.reminders.append(reminder)
            return result(["now": nowInfo(c), "created": describe(reminder, c),
                           "next": next.map { ScheduleText.fireText($0.scheduledAt, now: c.now, calendar: c.calendar) }],
                          changed: true)
        }
    }

    private static func list(_ args: [String: Any], _ c: ToolContext) throws -> ToolResult {
        let status = args["status"] as? String ?? "active"
        let historyDays = min(max(args["historyDays"] as? Int ?? 0, 0), 30)
        let data = try c.store.load()
        let items = data.reminders.filter { status == "all" || $0.state != .finished }.map { r -> [String: Any] in
            var item = describe(r, c)
            if historyDays > 0 {
                let since = c.now.addingTimeInterval(-Double(historyDays) * 86400)
                item["history"] = data.occurrences
                    .filter { $0.reminderID == r.id && $0.scheduledAt >= since }
                    .sorted { $0.scheduledAt < $1.scheduledAt }
                    .map { ["time": ScheduleText.dateTime($0.scheduledAt, calendar: c.calendar), "result": outcomeText($0.outcome)] }
            }
            return item
        }
        return result(["now": nowInfo(c), "reminders": items], changed: false)
    }

    private static func update(_ args: [String: Any], _ c: ToolContext) throws -> ToolResult {
        let id = try requiredText(args, "id", max: 20)
        return try c.store.update { data in
            guard let i = data.reminders.firstIndex(where: { $0.id == id }) else {
                throw ToolError("没有 id 为 \(id) 的提醒，先用 list_reminders 查一下")
            }
            var r = data.reminders[i]
            if args["title"] != nil { r.title = try requiredText(args, "title", max: 40) }
            if args["messages"] != nil { r.messages = try messageList(args["messages"]) }
            if args["schedule"] != nil { r.schedule = try parseSchedule(args["schedule"], context: c) }
            if args["style"] != nil { r.style = try parseStyle(args["style"]) ?? r.style }
            if args["reason"] != nil { r.reason = try optionalText(args, "reason", max: 200) }
            if args["startDate"] != nil { r.startDate = try optionalDay(args, "startDate", c) }
            if args["endDate"] != nil { r.endDate = try optionalDay(args, "endDate", c).map(endOfDay(c)) }
            if args["maxOccurrences"] != nil { r.maxOccurrences = try optionalPositive(args, "maxOccurrences") }
            if let state = args["state"] {
                switch state as? String {
                case "active": r.state = .active
                case "paused": r.state = .paused
                default: throw ToolError("state 只能是 active 或 paused")
                }
            }
            r.updatedAt = c.now
            let next = ReminderPlanner.next(r, after: c.now, count: 3, calendar: c.calendar)
            if r.state == .active && next.isEmpty {
                throw ToolError("改完以后一次都不会响了。请检查 endDate、maxOccurrences、weekdays。现在是 \(nowText(c))")
            }
            data.reminders[i] = r
            return result(["now": nowInfo(c), "updated": describe(r, c),
                           "next": next.map { ScheduleText.fireText($0.scheduledAt, now: c.now, calendar: c.calendar) }],
                          changed: true)
        }
    }

    private static func delete(_ args: [String: Any], _ c: ToolContext) throws -> ToolResult {
        let id = try requiredText(args, "id", max: 20)
        return try c.store.update { data in
            guard let r = data.reminder(id) else { throw ToolError("没有 id 为 \(id) 的提醒，先用 list_reminders 查一下") }
            data.reminders.removeAll { $0.id == id }
            data.occurrences.removeAll { $0.reminderID == id }
            return result(["deleted": r.title], changed: true)
        }
    }

    // MARK: - 解析

    static func parseSchedule(_ value: Any?, context c: ToolContext) throws -> Schedule {
        guard let object = value as? [String: Any] else {
            throw ToolError(#"schedule 必须是对象，例如 {"kind":"daily","times":["09:00"]}"#)
        }
        switch object["kind"] as? String {
        case "once":
            guard let text = object["at"] as? String else { throw ToolError(#"once 需要 at，例如 "2026-10-24 18:30""#) }
            guard let at = parseDateTime(text, calendar: c.calendar) else {
                throw ToolError("at「\(text)」看不懂，请写成 yyyy-MM-dd HH:mm，例如 2026-10-24 18:30")
            }
            guard at > c.now else { throw ToolError(pastMessage(at, c)) }
            return .once(at: at)
        case "daily":
            return .daily(times: try clockList(object["times"]), weekdays: try weekdays(object["weekdays"]))
        case "interval":
            guard let every = object["everyMinutes"] as? Int else { throw ToolError("interval 需要 everyMinutes（整数分钟）") }
            guard every >= minIntervalMinutes else { throw ToolError("everyMinutes 至少 \(minIntervalMinutes) 分钟，太频繁会打扰用户") }
            let from = try clock(object["from"], name: "from")
            let to = try clock(object["to"], name: "to")
            guard from < to else { throw ToolError("from 要早于 to") }
            return .interval(everyMinutes: every, from: from, to: to, weekdays: try weekdays(object["weekdays"]))
        case "monthly":
            guard let days = object["days"] as? [Int], !days.isEmpty, days.allSatisfy((1...31).contains) else {
                throw ToolError("monthly 需要 days：1～31 的整数数组，例如 [10]")
            }
            return .monthly(days: Array(Set(days)).sorted(), times: try clockList(object["times"]))
        case "yearly":
            guard let month = object["month"] as? Int, (1...12).contains(month),
                  let day = object["day"] as? Int, (1...31).contains(day) else {
                throw ToolError("yearly 需要 month（1～12）和 day（1～31）")
            }
            let maxDay = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
            guard day <= maxDay else { throw ToolError("\(month) 月没有 \(day) 号") }
            let leadDays = object["leadDays"] as? [Int] ?? []
            guard leadDays.allSatisfy((1...30).contains) else { throw ToolError("leadDays 是 1～30 的整数数组") }
            return .yearly(month: month, day: day, times: try clockList(object["times"]), leadDays: Array(Set(leadDays)).sorted())
        default:
            throw ToolError("schedule.kind 必须是 once / daily / interval / monthly / yearly 之一")
        }
    }

    /// 接受 "yyyy-MM-dd HH:mm"、"yyyy-MM-ddTHH:mm"（本地时间），以及带时区的 ISO 8601。秒数一律舍去
    static func parseDateTime(_ text: String, calendar: Calendar) -> Date? {
        let s = text.trimmingCharacters(in: .whitespaces)
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            iso.formatOptions = options
            if let date = iso.date(from: s) { return truncateToMinute(date, calendar: calendar) }
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mmXXXXX"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: s) { return truncateToMinute(date, calendar: calendar) }
        }
        return nil
    }

    private static func truncateToMinute(_ date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .minute, for: date)?.start ?? date
    }

    private static func pastMessage(_ at: Date, _ c: ToolContext) -> String {
        var text = "at \(stamp(at, c)) 已经过去了，现在是 \(nowText(c))。"
        if let tomorrow = c.calendar.date(byAdding: .day, value: 1, to: at), tomorrow > c.now {
            text += "是不是想设成明天 \(stamp(tomorrow, c))？"
        }
        return text
    }

    private static func clock(_ value: Any?, name: String) throws -> ClockTime {
        guard let text = value as? String, let time = ClockTime(text) else {
            throw ToolError("\(name) 要写成 HH:mm，例如 09:00")
        }
        return time
    }

    private static func clockList(_ value: Any?) throws -> [ClockTime] {
        guard let list = value as? [String], !list.isEmpty else { throw ToolError(#"times 要写成 HH:mm 的数组，例如 ["09:00","21:00"]"#) }
        let times = try list.map { try clock($0, name: "times 里的「\($0)」") }
        return Array(Set(times)).sorted()
    }

    private static func weekdays(_ value: Any?) throws -> [Int] {
        guard let value, !(value is NSNull) else { return [] }
        guard let list = value as? [Int], list.allSatisfy((1...7).contains) else {
            throw ToolError("weekdays 是 1～7 的整数数组，1 = 周一 … 7 = 周日")
        }
        return Array(Set(list)).sorted()
    }

    private static func parseStyle(_ value: Any?) throws -> ReminderStyle? {
        guard let value, !(value is NSNull) else { return nil }
        guard let text = value as? String, let style = ReminderStyle(rawValue: text) else {
            throw ToolError("style 只能是 gentle 或 firm")
        }
        return style
    }

    private static func requiredText(_ args: [String: Any], _ key: String, max: Int) throws -> String {
        guard let text = (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw ToolError("缺少 \(key)")
        }
        guard text.count <= max else { throw ToolError("\(key) 最多 \(max) 个字") }
        return text
    }

    private static func optionalText(_ args: [String: Any], _ key: String, max: Int) throws -> String? {
        guard let value = args[key], !(value is NSNull) else { return nil }
        guard let text = value as? String else { throw ToolError("\(key) 必须是文字") }
        guard text.count <= max else { throw ToolError("\(key) 最多 \(max) 个字") }
        return text.isEmpty ? nil : text
    }

    private static func messageList(_ value: Any?) throws -> [String] {
        guard let list = value as? [String] else { throw ToolError("messages 是 1～5 句文字的数组") }
        let messages = list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard (1...5).contains(messages.count) else { throw ToolError("messages 要有 1～5 句") }
        guard messages.allSatisfy({ $0.count <= 200 }) else { throw ToolError("每句 messages 最多 200 个字") }
        return messages
    }

    private static func optionalDay(_ args: [String: Any], _ key: String, _ c: ToolContext) throws -> Date? {
        guard let value = args[key], !(value is NSNull) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = c.calendar
        formatter.timeZone = c.calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let text = value as? String, let date = formatter.date(from: text) else {
            throw ToolError("\(key) 要写成 yyyy-MM-dd，例如 2026-10-30")
        }
        return c.calendar.startOfDay(for: date)
    }

    private static func endOfDay(_ c: ToolContext) -> (Date) -> Date {
        { c.calendar.date(bySettingHour: 23, minute: 59, second: 59, of: $0) ?? $0 }
    }

    private static func optionalPositive(_ args: [String: Any], _ key: String) throws -> Int? {
        guard let value = args[key], !(value is NSNull) else { return nil }
        guard let number = value as? Int, number >= 1 else { throw ToolError("\(key) 是大于 0 的整数") }
        return number
    }

    // MARK: - 输出

    private static func describe(_ r: Reminder, _ c: ToolContext) -> [String: Any] {
        var item: [String: Any] = [
            "id": r.id, "title": r.title, "messages": r.messages, "style": r.style.rawValue, "state": r.state.rawValue,
            "schedule": ScheduleText.describe(r.schedule, calendar: c.calendar),
            "createdBy": ClientNames.display(r.createdBy),
            "next": ReminderPlanner.next(r, after: c.now, count: 3, calendar: c.calendar)
                .map { ScheduleText.fireText($0.scheduledAt, now: c.now, calendar: c.calendar) },
        ]
        if let reason = r.reason { item["reason"] = reason }
        if let status = ScheduleText.status(r, now: c.now, calendar: c.calendar) { item["status"] = status }
        return item
    }

    static func outcomeText(_ outcome: Outcome) -> String {
        switch outcome {
        case .pending: "等用户处理"
        case .notified: "已提醒"
        case .done: "完成"
        case .snoozed: "推迟了"
        case .skipped: "跳过"
        case .missed: "错过"
        }
    }

    private static func nowInfo(_ c: ToolContext) -> [String: Any] {
        ["local": stamp(c.now, c),
         "weekday": "周" + ScheduleText.weekdayNames[ReminderPlanner.isoWeekday(c.now, calendar: c.calendar) - 1],
         "timeZone": c.calendar.timeZone.identifier]
    }

    private static func nowText(_ c: ToolContext) -> String {
        "\(stamp(c.now, c)) 周\(ScheduleText.weekdayNames[ReminderPlanner.isoWeekday(c.now, calendar: c.calendar) - 1])（\(c.calendar.timeZone.identifier)）"
    }

    private static func stamp(_ date: Date, _ c: ToolContext) -> String {
        let formatter = DateFormatter()
        formatter.calendar = c.calendar
        formatter.timeZone = c.calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func result(_ object: [String: Any], changed: Bool) -> ToolResult {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return ToolResult(text: String(decoding: data, as: UTF8.self), isError: false, changed: changed)
    }
}
```
- [ ] **Step 6:** 跑 `ScheduleTextTests`、`ReminderToolsTests`，然后跑全部测试，都要通过。
- [ ] **Step 7: 提交**「0.5：中文描述、5 个 MCP 工具」

### Task 7: 小程序接入工具 + 端到端验证

**Files:** Modify `RestBreakMCP/MCPCommand.swift`

- [ ] **Step 1: `RestBreakMCP/MCPCommand.swift`**
```swift
import AppKit
import Foundation
import MCP

/// MCP 服务器：把 SDK 的 tools/list、tools/call 接到 ReminderTools
enum MCPCommand {
    static func run() async throws {
        let store = try ReminderStore.shared()
        let client = ClientName()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let server = Server(name: "xieyihui", version: version, title: "歇一会",
                            instructions: ReminderTools.instructions,
                            capabilities: .init(tools: .init(listChanged: false)))
        let tools = try ReminderTools.specs.map { spec in
            Tool(name: spec.name, description: spec.description,
                 inputSchema: try JSONDecoder().decode(Value.self, from: Data(spec.schema.utf8)),
                 annotations: .init(readOnlyHint: spec.readOnly, destructiveHint: spec.destructive))
        }
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
        await server.withMethodHandler(CallTool.self) { params in
            // SDK 的 Value → JSON → 字典，ReminderTools 不依赖 SDK
            let raw = try JSONEncoder().encode(params.arguments ?? [:])
            let arguments = (try JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:]
            let context = ToolContext(now: Date(), calendar: .current, client: client.value, store: store)
            let result = ReminderTools.call(params.name, arguments: arguments, context: context)
            if result.changed { await AppLauncher.launchIfNeeded() }
            return .init(content: [.text(result.text)], isError: result.isError)
        }
        try await server.start(transport: StdioTransport()) { info, _ in
            client.value = info.name
            try? store.update { $0.recordClient(info.name, now: Date()) }
        }
        await server.waitUntilCompleted()
    }
}

/// 握手时拿到的客户端名，工具调用时读（两边在不同的任务里，所以加锁）
final class ClientName: @unchecked Sendable {
    private let lock = NSLock()
    private var name = "unknown"
    var value: String {
        get { lock.withLock { name } }
        set { lock.withLock { name = newValue } }
    }
}

/// 提醒改了但歇一会没在运行：把它拉起来，否则到点不会弹强提醒卡片
enum AppLauncher {
    @MainActor
    static func launchIfNeeded() async {
        // 已经在运行就不再启动：新实例会把旧实例顶掉，Xcode 调试中的旧实例会留下两个
        guard NSRunningApplication.runningApplications(withBundleIdentifier: AppGroup.appBundleID).isEmpty else { return }
        // 小程序在 歇一会.app/Contents/MacOS/ 里，往上三层就是 App 本身
        let appURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard appURL.pathExtension == "app" else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }
}
```
注意：命令行程序的 `Bundle.main.bundleURL` 是它所在的文件夹（`Contents/MacOS`），所以往上三层才是 `.app`。如果 `appURL` 算错了，Step 3 的最后一项会发现。
- [ ] **Step 2:** `eval $BUILD` 得到 `BUILD SUCCEEDED`。
- [ ] **Step 3: 端到端**（沙盒外执行，用 `XIEYIHUI_STORE=test`，不碰真实数据）
```bash
call() { printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"e2e","version":"1"}}}' '{"jsonrpc":"2.0","method":"notifications/initialized"}' "$1"; sleep 1; }
call '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | XIEYIHUI_STORE=test "$MCP" | grep -o '"name":"[a-z_]*"' | sort -u
call '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"create_reminder","arguments":{"title":"端到端测试","messages":["测试"],"schedule":{"kind":"daily","times":["09:00"]}}}}' | XIEYIHUI_STORE=test "$MCP" | tail -1
cat "$HOME/Library/Group Containers/B45N72QF4V.com.lizhiming.RestBreak/Reminders-test/store.json" | grep -E '"title"|"createdBy"|"name"'
```
Expected：
- 5 个工具名，加上 `"name":"e2e"` 等字段；
- 第二条命令输出的 JSON 里有 `"next"`；
- `store.json` 里能看到 `端到端测试`、`e2e`。

然后用 `delete_reminder`（id 从 store.json 里看）删掉这条，确认 `reminders` 变成空数组。
- [ ] **Step 4: 验证拉起逻辑不会误启动**：你的歇一会正由 Xcode 运行，所以 Step 3 不应该启动第二个实例。检查 `pgrep -fl "RestBreak.app/Contents/MacOS/RestBreak"`，应该只有一个进程。
- [ ] **Step 5: 提交**「0.5：小程序接入 5 个提醒工具」

### Task 8: 统一通知代理 `NotificationRouter`，`BreakNotifier` 改为由它分发

**Files:** Create `RestBreak/Services/NotificationRouter.swift`；Modify `RestBreak/Services/BreakNotifier.swift`、`RestBreak/App/BreakCoordinator.swift`

- [ ] **Step 1: `RestBreak/Services/NotificationRouter.swift`**
```swift
import UserNotifications

/// 用户点了某条通知（已经从系统对象里取出要用的字符串，可以跨线程传）
struct NotificationReply: Sendable {
    var category: String
    var action: String
    var info: [String: String]
}

/// 系统只允许一个通知代理，也只有一份「通知分类（按钮组合）」列表。
/// 休息通知和提醒通知都经过这里：分类以 reminder. 开头的交给提醒，其余交给休息
@MainActor
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    var onBreakAction: ((String) -> Void)?
    var onReminderReply: ((NotificationReply) -> Void)?
    private var categories: [String: Set<UNNotificationCategory>] = [:]

    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// 各自登记自己的按钮组合，这里合并后一起交给系统（系统每次都整份替换）
    func setCategories(_ set: Set<UNNotificationCategory>, owner: String) {
        categories[owner] = set
        UNUserNotificationCenter.current().setNotificationCategories(categories.values.reduce(into: []) { $0.formUnion($1) })
    }

    /// 设置窗口开着（App 在前台）时也照常显示横幅
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        var info: [String: String] = [:]
        for (key, value) in content.userInfo {
            if let key = key as? String, let value = value as? String { info[key] = value }
        }
        await route(NotificationReply(category: content.categoryIdentifier, action: response.actionIdentifier, info: info))
    }

    private func route(_ reply: NotificationReply) {
        if reply.category.hasPrefix("reminder.") {
            onReminderReply?(reply)
        } else {
            onBreakAction?(reply.action)
        }
    }
}
```
- [ ] **Step 2: 改 `BreakNotifier.swift`**
  - 类声明改成 `final class BreakNotifier {`，不再继承 NSObject、也不再遵守代理协议；
  - 删掉 `onAction` 属性、`start` 里的 `center.delegate = self`、`// MARK: - UNUserNotificationCenterDelegate` 以下两个代理方法和 `handleAction`；
  - `registerCategories` 最后一行 `center.setNotificationCategories(categories)` 改成 `NotificationRouter.shared.setCategories(categories, owner: "break")`。

  `start` 改完是：
```swift
    func start(settings: AppSettings) {
        registerCategories(settings: settings)
        if settings.notifyBeforeBreak { requestAuthorization() }
    }
```
- [ ] **Step 3: 改 `BreakCoordinator.start()`**，把 `notifier.onAction = { ... }` 那一行换成：
```swift
        // 通知回调统一走 NotificationRouter：休息的按钮交给这里，提醒的交给 reminders
        NotificationRouter.shared.install()
        NotificationRouter.shared.onBreakAction = { [weak self] identifier in
            if let action = BreakNotifier.Action(rawValue: identifier) { self?.handleNotificationAction(action) }
        }
```
- [ ] **Step 4:** `eval $BUILD`、`eval $TEST` 全部通过（休息通知的引擎测试不受影响）。
- [ ] **Step 5: 提交**「0.5：统一通知代理 NotificationRouter」

### Task 9: 提醒通知 `ReminderNotifier`

**Files:** Create `RestBreak/Services/ReminderNotifier.swift`

- [ ] **Step 1: 实现**
```swift
import Foundation
import UserNotifications

/// 提醒的系统通知：到点横幅（提前登记成系统定时通知，App 没运行也会弹）、强提醒的再次提醒、
/// 错过汇总、「AI 帮你建了提醒」（带撤销）
@MainActor
final class ReminderNotifier {
    enum Action: String {
        case done = "reminder.done"
        case snooze = "reminder.snooze"
        case skip = "reminder.skip"
        case undo = "reminder.undo"
    }

    static let gentleCategory = "reminder.gentle"
    static let firmCategory = "reminder.firm"
    static let createdCategory = "reminder.created"
    static let summaryCategory = "reminder.summary"
    private static let firePrefix = "reminder.fire."
    /// 上次登记的定时通知 id。存起来是为了下次能精确撤掉，不用去查系统的待发列表
    private static let scheduledKey = "reminderScheduledIDs"

    private let center = UNUserNotificationCenter.current()

    func start() {
        let done = UNNotificationAction(identifier: Action.done.rawValue, title: "完成")
        let snooze = UNNotificationAction(identifier: Action.snooze.rawValue, title: "10 分钟后")
        let skip = UNNotificationAction(identifier: Action.skip.rawValue, title: "跳过这次")
        let undo = UNNotificationAction(identifier: Action.undo.rawValue, title: "撤销", options: [.destructive])
        NotificationRouter.shared.setCategories([
            UNNotificationCategory(identifier: Self.gentleCategory, actions: [done, snooze], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.firmCategory, actions: [done, snooze, skip], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.createdCategory, actions: [undo], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.summaryCategory, actions: [], intentIdentifiers: []),
        ], owner: "reminder")
    }

    func requestAuthorization() {
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    /// 重新登记接下来要响的（先撤掉上次登记的）
    func schedule(_ items: [(fire: Fire, reminder: Reminder, message: String)], calendar: Calendar) {
        let old = UserDefaults.standard.stringArray(forKey: Self.scheduledKey) ?? []
        center.removePendingNotificationRequests(withIdentifiers: old)
        var ids: [String] = []
        for item in items {
            let content = UNMutableNotificationContent()
            content.title = item.reminder.title
            content.body = item.message
            content.sound = .default
            content.categoryIdentifier = item.reminder.style == .firm ? Self.firmCategory : Self.gentleCategory
            content.userInfo = Self.info(item.fire)
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: item.fire.ringAt)
            let id = Self.fireID(item.fire)
            center.add(UNNotificationRequest(identifier: id, content: content,
                                             trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)),
                       withCompletionHandler: nil)
            ids.append(id)
        }
        UserDefaults.standard.set(ids, forKey: Self.scheduledKey)
    }

    /// 强提醒没处理：再弹一次（同一次响铃的再提醒用同一个 id，新的替换旧的）
    func postNag(_ fire: Fire, reminder: Reminder, message: String, count: Int) {
        let content = UNMutableNotificationContent()
        content.title = "\(reminder.title)（第 \(count + 1) 次提醒）"
        content.body = message
        content.sound = .default
        content.categoryIdentifier = Self.firmCategory
        content.userInfo = Self.info(fire)
        center.add(UNNotificationRequest(identifier: Self.nagID(fire), content: content, trigger: nil), withCompletionHandler: nil)
    }

    func postSummary(_ titles: [String]) {
        let content = UNMutableNotificationContent()
        content.title = "你不在的时候有 \(titles.count) 条提醒"
        content.body = Array(Set(titles)).sorted().joined(separator: "、")
        content.categoryIdentifier = Self.summaryCategory
        content.userInfo = ["id": "summary"]
        center.add(UNNotificationRequest(identifier: "reminder.summary", content: content, trigger: nil), withCompletionHandler: nil)
    }

    func postCreated(_ reminder: Reminder, scheduleText: String) {
        let content = UNMutableNotificationContent()
        content.title = "\(ClientNames.display(reminder.createdBy)) 帮你建了提醒"
        content.body = "\(reminder.title)：\(scheduleText)"
        content.categoryIdentifier = Self.createdCategory
        content.userInfo = ["id": reminder.id]
        center.add(UNNotificationRequest(identifier: "reminder.created.\(reminder.id)", content: content, trigger: nil),
                   withCompletionHandler: nil)
    }

    /// 用户处理过某次响铃后，把通知中心里相关的横幅收掉
    func removeDelivered(_ fire: Fire) {
        center.removeDeliveredNotifications(withIdentifiers: [Self.fireID(fire), Self.nagID(fire)])
    }

    func removeCreated(_ id: String) {
        center.removeDeliveredNotifications(withIdentifiers: ["reminder.created.\(id)"])
    }

    private static func info(_ fire: Fire) -> [String: String] {
        ["id": fire.reminderID, "at": String(fire.scheduledAt.timeIntervalSince1970), "lead": String(fire.leadDays)]
    }

    private static func fireID(_ fire: Fire) -> String {
        "\(firePrefix)\(fire.reminderID).\(Int(fire.scheduledAt.timeIntervalSince1970)).\(Int(fire.ringAt.timeIntervalSince1970))"
    }

    private static func nagID(_ fire: Fire) -> String {
        "reminder.nag.\(fire.reminderID).\(Int(fire.scheduledAt.timeIntervalSince1970))"
    }
}
```
`removeDelivered` 用的 `fireID` 里含 `ringAt`。处理推迟后再响的那次时，要传入那次的 ringAt（卡片和回调都带着完整的 Fire），否则收不掉横幅。原始那次的横幅交给系统自己收起来就行。
- [ ] **Step 2:** `eval $BUILD` 通过。
- [ ] **Step 3: 提交**「0.5：提醒的系统通知」

### Task 10: 强提醒卡片 + `ReminderCoordinator`

**Files:** Create `RestBreak/UI/ReminderCard.swift`、`RestBreak/App/ReminderCoordinator.swift`

- [ ] **Step 1: `RestBreak/UI/ReminderCard.swift`**
```swift
import AppKit
import SwiftUI

/// 强提醒卡片：主屏幕右上角的浮动卡片，点了「完成」「10 分钟后」「跳过这次」才消失。
/// 不抢焦点（nonactivatingPanel），全屏 App 上也看得到
@MainActor
final class ReminderCardPanel: NSPanel {
    init(title: String, message: String, reason: String?,
         onDone: @escaping () -> Void, onSnooze: @escaping () -> Void, onSkip: @escaping () -> Void) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 160),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        let hosting = NSHostingController(rootView: ReminderCardView(title: title, message: message, reason: reason,
                                                                     onDone: onDone, onSnooze: onSnooze, onSkip: onSkip))
        hosting.sizingOptions = .preferredContentSize
        contentViewController = hosting
    }

    override var canBecomeKey: Bool { true }

    /// 放在主屏幕右上角，第 index 张往下排
    func place(index: Int) {
        guard let screen = NSScreen.main else { return }
        layoutIfNeeded()
        let size = contentViewController?.view.fittingSize ?? frame.size
        let visible = screen.visibleFrame
        let y = visible.maxY - 12 - CGFloat(index + 1) * size.height - CGFloat(index) * 10
        setFrame(NSRect(x: visible.maxX - size.width - 12, y: y, width: size.width, height: size.height), display: true)
    }
}

struct ReminderCardView: View {
    let title: String
    let message: String
    let reason: String?
    let onDone: () -> Void
    let onSnooze: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "bell.badge.fill")
                    .foregroundStyle(SettingsTheme.accent)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SettingsTheme.textPrimary)
                Spacer()
            }
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(SettingsTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let reason {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("完成", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button("10 分钟后", action: onSnooze)
                Button("跳过这次", action: onSkip)
                Spacer()
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(.white, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(SettingsTheme.cardBorder))
        .environment(\.colorScheme, .light)
    }
}
```
- [ ] **Step 2: `RestBreak/App/ReminderCoordinator.swift`**
```swift
import AppKit
import Foundation

extension Notification.Name {
    /// 共享文件夹里的提醒数据变了（小程序发 Darwin 通知，转成进程内通知）
    static let reminderStoreChanged = Notification.Name("reminderStoreChanged")
}

/// 提醒的总指挥：每 30 秒处理一次到期提醒，监听小程序改数据，响应用户在通知、卡片、设置页上的操作
@MainActor
final class ReminderCoordinator: NSObject, ObservableObject {   // NSObject：系统通知用 selector 方式监听
    @Published private(set) var data = ReminderData()
    @Published private(set) var errorText: String?

    /// 休息中、开会、全屏时强提醒卡片先等一等（最多 30 分钟），由 BreakCoordinator 提供
    var isBusy: () -> Bool = { false }
    /// 点通知打开「提醒」页
    var onOpenPage: (() -> Void)?

    private let store: ReminderStore?
    private let notifier = ReminderNotifier()
    private var calendar: Calendar { Calendar.current }
    /// 正在显示的卡片，键是「提醒 id + 本该响的时刻」
    private var cards: [String: ReminderCardPanel] = [:]
    /// 因为忙而在等的卡片
    private var waiting: [(fire: Fire, since: Date)] = []
    private var lastPlan: [Fire] = []
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
        if !data.reminders.isEmpty { notifier.requestAuthorization() }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.check()
            }
        }
    }

    @objc private func storeChanged() {
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
            report = try store.update(notify: false) { ReminderPlanner.process(&$0, now: now, calendar: calendar) }
            errorText = nil
        } catch {
            errorText = "\(error)"
            return
        }
        reload()
        for fire in report.cards {
            if isBusy() { waiting.append((fire, now)) } else { showCard(fire) }
        }
        // 等着的卡片：不忙了就弹；等了 30 分钟还在忙就不等了（横幅已经弹过，没处理会照常再提醒）
        waiting = waiting.filter { item in
            guard data.occurrence(item.fire.reminderID, at: item.fire.scheduledAt)?.outcome == .pending else { return false }
            if !isBusy() { showCard(item.fire); return false }
            return now.timeIntervalSince(item.since) < Self.maxCardWait
        }
        for fire in report.nags {
            guard let r = data.reminder(fire.reminderID),
                  let o = data.occurrence(fire.reminderID, at: fire.scheduledAt) else { continue }
            notifier.postNag(fire, reminder: r, message: message(r, fire), count: o.nagCount)
        }
        for fire in report.expired { closeCard(fire) }
        if !report.lateTitles.isEmpty { notifier.postSummary(report.lateTitles) }
        for r in report.created {
            notifier.requestAuthorization()
            notifier.postCreated(r, scheduleText: ScheduleText.describe(r.schedule, calendar: calendar))
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

    // MARK: - 卡片

    private func key(_ fire: Fire) -> String { "\(fire.reminderID)|\(fire.scheduledAt.timeIntervalSince1970)" }

    private func showCard(_ fire: Fire) {
        guard cards[key(fire)] == nil, let r = data.reminder(fire.reminderID) else { return }
        let card = ReminderCardPanel(title: r.title, message: message(r, fire), reason: r.reason,
                                     onDone: { [weak self] in self?.act(fire, .done) },
                                     onSnooze: { [weak self] in self?.snooze(fire) },
                                     onSkip: { [weak self] in self?.act(fire, .skipped) })
        cards[key(fire)] = card
        card.place(index: cards.count - 1)
        card.orderFrontRegardless()
    }

    private func closeCard(_ fire: Fire) {
        cards.removeValue(forKey: key(fire))?.orderOut(nil)
        for (index, card) in cards.values.enumerated() { card.place(index: index) }
    }

    // MARK: - 用户操作

    func act(_ fire: Fire, _ outcome: Outcome, now: Date = Date()) {
        try? store?.update { $0.setOutcome(fire.reminderID, scheduledAt: fire.scheduledAt, leadDays: fire.leadDays, outcome, now: now) }
        closeCard(fire)
        notifier.removeDelivered(fire)
        reload()
    }

    func snooze(_ fire: Fire, now: Date = Date()) {
        try? store?.update {
            $0.setOutcome(fire.reminderID, scheduledAt: fire.scheduledAt, leadDays: fire.leadDays, .snoozed,
                          now: now, snoozedUntil: now.addingTimeInterval(ReminderPlanner.nagInterval))
        }
        closeCard(fire)
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
        for (key, card) in cards where key.hasPrefix("\(id)|") { card.orderOut(nil); cards.removeValue(forKey: key) }
        notifier.removeCreated(id)
        reload()
        reschedule(now: Date())
    }

    /// 通知上的按钮
    func handle(_ reply: NotificationReply) {
        guard let id = reply.info["id"] else { return }
        if reply.action == ReminderNotifier.Action.undo.rawValue { delete(id); return }
        guard let at = reply.info["at"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) else {
            onOpenPage?()
            return
        }
        let fire = Fire(reminderID: id, scheduledAt: at, ringAt: at, leadDays: Int(reply.info["lead"] ?? "") ?? 0)
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
```
- [ ] **Step 3:** `eval $BUILD` 通过。
- [ ] **Step 4: 提交**「0.5：提醒总指挥和强提醒卡片」

### Task 11: 连接 AI 的配置生成 `AIIntegration`（先写测试）

**Files:** Create `RestBreak/App/AIIntegration.swift`、`RestBreakTests/AIIntegrationTests.swift`

- [ ] **Step 1: 测试**
```swift
import Foundation
import Testing
@testable import RestBreak

/// 「连接 AI」页复制出去的配置
struct AIIntegrationTests {
    let helper = "/Applications/歇一会.app/Contents/MacOS/restbreak-mcp"

    @Test func Codex配置_只放行只读工具() {
        let text = AIIntegration.codexSnippet(helper: helper)
        #expect(text.contains("[mcp_servers.xieyihui]"))
        #expect(text.contains(#"command = "\#(helper)""#))
        #expect(text.contains("[mcp_servers.xieyihui.tools.get_overview]"))
        #expect(text.contains("[mcp_servers.xieyihui.tools.list_reminders]"))
        #expect(!text.contains("tools.create_reminder") && !text.contains("tools.delete_reminder"))
    }

    @Test func ClaudeDesktop配置是合法JSON() throws {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(AIIntegration.claudeDesktopSnippet(helper: helper).utf8)) as? [String: Any])
        let servers = try #require(object["mcpServers"] as? [String: Any])
        #expect((servers["xieyihui"] as? [String: Any])?["command"] as? String == helper)
    }

    @Test func ClaudeCode插件文件() throws {
        let files = AIIntegration.pluginFiles(helper: helper, version: "0.5.0")
        #expect(Set(files.keys) == [".claude-plugin/marketplace.json", "plugins/xieyihui/.claude-plugin/plugin.json", "plugins/xieyihui/.mcp.json"])
        for (path, text) in files {
            #expect((try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil, "\(path)")
        }
        #expect(files["plugins/xieyihui/.mcp.json"]!.contains(helper))
        #expect(AIIntegration.claudeCodeCommand(root: URL(fileURLWithPath: "/tmp/p"))
                == #"claude plugin marketplace add "/tmp/p" && claude plugin install xieyihui@xieyihui-app"#)
    }
}
```
- [ ] **Step 2:** 跑一次，确认编译失败。
- [ ] **Step 3: 实现 `RestBreak/App/AIIntegration.swift`**
```swift
import Foundation

/// 「连接 AI」页复制出去的配置。小程序的路径就是当前运行的歇一会里那一份
enum AIIntegration {
    static var helperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/restbreak-mcp").path
    }

    /// 从 Xcode 运行的开发版：路径在 DerivedData 里，换到正式安装位置后要重新复制
    static var isDevelopmentBuild: Bool { helperPath.contains("/DerivedData/") }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Codex：贴到 ~/.codex/config.toml 末尾。不推荐 codex mcp add：它会把整份 config.toml 重新排版（第 0 步实测）
    static func codexSnippet(helper: String) -> String {
        let escaped = helper.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """

        # 歇一会：让 Codex 能帮你建提醒
        [mcp_servers.xieyihui]
        command = "\(escaped)"

        # 只读工具不用每次批准；建、改、删提醒仍会先问你
        [mcp_servers.xieyihui.tools.get_overview]
        approval_mode = "approve"

        [mcp_servers.xieyihui.tools.list_reminders]
        approval_mode = "approve"

        """
    }

    /// Claude Desktop：合并进 claude_desktop_config.json 的 mcpServers
    static func claudeDesktopSnippet(helper: String) -> String {
        json(["mcpServers": ["xieyihui": ["command": helper]]])
    }

    /// Claude Code 插件（本地 marketplace）。同一个小程序如果还被手动加过，Claude Code 会把插件里的那份当重复去掉，
    /// 所以页面上提示先 claude mcp remove xieyihui
    static func pluginFiles(helper: String, version: String) -> [String: String] {
        [
            ".claude-plugin/marketplace.json": json([
                "name": "xieyihui-app", "owner": ["name": "歇一会"], "description": "歇一会的本地插件",
                "plugins": [["name": "xieyihui", "source": "./plugins/xieyihui", "description": "让 Claude 帮你在歇一会里建提醒"]],
            ]),
            "plugins/xieyihui/.claude-plugin/plugin.json": json([
                "name": "xieyihui", "displayName": "歇一会", "version": version,
                "description": "让 Claude 帮你在歇一会里建、改、查提醒", "author": ["name": "李志铭"],
            ]),
            "plugins/xieyihui/.mcp.json": json(["mcpServers": ["xieyihui": ["command": helper]]]),
        ]
    }

    static func claudeCodeCommand(root: URL) -> String {
        #"claude plugin marketplace add "\#(root.path)" && claude plugin install xieyihui@xieyihui-app"#
    }

    /// 把插件写到共享文件夹的 Integrations/claude-plugin（命令行的 claude 能读到），返回根目录
    static func writeClaudePlugin() throws -> URL {
        guard let base = AppGroup.containerURL else { throw StoreError.noContainer }
        let root = base.appendingPathComponent("Integrations/claude-plugin", isDirectory: true)
        for (path, text) in pluginFiles(helper: helperPath, version: version) {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        }
        return root
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
```
- [ ] **Step 4:** 跑 `AIIntegrationTests`，全部通过。
- [ ] **Step 5: 提交**「0.5：生成连接 AI 的配置」

### Task 12: 设置「提醒」页 + 菜单 + 把各部分接起来

**Files:** Create `RestBreak/UI/RemindersPage.swift`；Modify `UI/SettingsWindow.swift`、`UI/StatusBarController.swift`、`App/BreakCoordinator.swift`、`App/RestBreakApp.swift`

- [ ] **Step 1: `RestBreak/UI/RemindersPage.swift`**
```swift
import AppKit
import SwiftUI

/// 「提醒」页的两个分段
enum RemindersTab: String, CaseIterable, Identifiable {
    case list = "我的提醒"
    case connect = "连接 AI"

    var id: Self { self }
}

struct RemindersPage: View {
    @EnvironmentObject private var coordinator: BreakCoordinator
    @EnvironmentObject private var navigation: SettingsNavigation

    var body: some View {
        switch navigation.remindersTab {
        case .list: ReminderList(model: coordinator.reminders) { navigation.remindersTab = .connect }
        case .connect: AIConnectView(model: coordinator.reminders)
        }
    }
}

/// 「我的提醒」：只能看、暂停、删除。新建只走 AI（这正是要避开的传统写法），所以不做新建表单
private struct ReminderList: View {
    @ObservedObject var model: ReminderCoordinator
    let onConnect: () -> Void
    @State private var expanded: String?
    @State private var pendingDelete: Reminder?

    var body: some View {
        let reminders = model.data.reminders.sorted { a, b in
            a.state == b.state ? a.createdAt > b.createdAt : order(a.state) < order(b.state)
        }
        if reminders.isEmpty {
            Card {
                VStack(spacing: 10) {
                    Image(systemName: "bell.badge")
                        .font(.system(size: 28))
                        .foregroundStyle(SettingsTheme.accent)
                    Text("还没有提醒")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(SettingsTheme.textPrimary)
                    Text("在 Claude 或 Codex 里说「每天 9 点提醒我吃药」试试")
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsTheme.textSecondary)
                    Button("去连接 AI", action: onConnect).buttonStyle(PillButtonStyle())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            }
        } else {
            Card {
                ForEach(Array(reminders.enumerated()), id: \.element.id) { index, reminder in
                    if index > 0 { RowDivider() }
                    row(reminder)
                }
            }
            .alert("删除「\(pendingDelete?.title ?? "")」？", isPresented: Binding(get: { pendingDelete != nil },
                                                                          set: { if !$0 { pendingDelete = nil } })) {
                Button("删除", role: .destructive) { pendingDelete.map { model.delete($0.id) } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("完成记录也会一起删掉。")
            }
        }
        if let error = model.errorText {
            Text(error).font(.system(size: 11)).foregroundStyle(.red).padding(.horizontal, 14)
        }
    }

    private func order(_ state: ReminderState) -> Int {
        switch state {
        case .active: 0
        case .paused: 1
        case .finished: 2
        }
    }

    @ViewBuilder
    private func row(_ reminder: Reminder) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(title: reminder.title, subtitle: model.subtitle(for: reminder)) {
                HStack(spacing: 8) {
                    if reminder.style == .firm { Tag(text: "强提醒") }
                    Tag(text: ClientNames.display(reminder.createdBy))
                    if reminder.state != .finished {
                        Button(reminder.state == .paused ? "恢复" : "暂停") { model.togglePause(reminder.id) }
                            .buttonStyle(PillButtonStyle())
                    }
                    Button { pendingDelete = reminder } label: { Image(systemName: "trash") }
                        .buttonStyle(PillButtonStyle())
                        .accessibilityLabel("删除")
                }
            }
            .opacity(reminder.state == .finished ? 0.55 : 1)
            .contentShape(Rectangle())
            .onTapGesture { expanded = expanded == reminder.id ? nil : reminder.id }
            if expanded == reminder.id { details(reminder) }
        }
    }

    private func details(_ reminder: Reminder) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reason = reminder.reason { Text("来源：\(reason)") }
            Text("提醒文案：" + reminder.messages.joined(separator: " / "))
            let history = model.history(reminder.id, days: 7)
            Text(history.isEmpty ? "最近 7 天：还没响过" : "最近 7 天：\n" + history.prefix(10).joined(separator: "\n"))
        }
        .font(.system(size: 11))
        .foregroundStyle(SettingsTheme.textSecondary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SettingsTheme.cardPadding)
        .padding(.bottom, 14)
    }
}

private struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(SettingsTheme.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Color(red: 0.94, green: 0.94, blue: 0.95), in: Capsule())
    }
}

/// 「连接 AI」：三种客户端各一行「复制」，下面是连接状态。必须一屏放下
private struct AIConnectView: View {
    @ObservedObject var model: ReminderCoordinator
    @State private var copied: String?

    var body: some View {
        Card {
            CardHeader(title: "连接 AI 助手")
            SettingRow(title: "Claude Code", subtitle: "在终端运行复制的命令（装一个插件）；以前手动加过歇一会的，先运行 claude mcp remove xieyihui") {
                copyButton("claude") {
                    (try? AIIntegration.writeClaudePlugin()).map(AIIntegration.claudeCodeCommand) ?? StoreError.noContainer.description
                }
            }
            RowDivider()
            SettingRow(title: "Codex", subtitle: "粘贴到 ~/.codex/config.toml 末尾；命令行和 ChatGPT App 都能用，第一次调用时批准一次") {
                copyButton("codex") { AIIntegration.codexSnippet(helper: AIIntegration.helperPath) }
            }
            RowDivider()
            SettingRow(title: "Claude Desktop", subtitle: "合并到 claude_desktop_config.json 的 mcpServers 里，然后重启 Claude") {
                copyButton("desktop") { AIIntegration.claudeDesktopSnippet(helper: AIIntegration.helperPath) }
            }
        }
        Card {
            CardHeader(title: "连接状态")
            let clients = model.data.clients.sorted { $0.lastSeen > $1.lastSeen }.prefix(3)
            if clients.isEmpty {
                SettingRow(title: "还没有 AI 连上", subtitle: "配好以后，在 AI 里说一句「看看我歇一会里的提醒」") { EmptyView() }
            } else {
                ForEach(Array(clients.enumerated()), id: \.element.name) { index, client in
                    if index > 0 { RowDivider() }
                    SettingRow(title: "已连接：\(ClientNames.display(client.name))",
                               subtitle: "\(ScheduleText.ago(client.lastSeen, now: Date()))用过") { EmptyView() }
                }
            }
        }
        Text("歇一会不调用任何 AI；提醒只存在这台 Mac 上，只有你的 AI 来读时才会作为对话内容发送出去。"
             + (AIIntegration.isDevelopmentBuild ? "\n现在是开发版，换到正式安装位置后需要重新复制配置。" : ""))
            .font(.system(size: 11))
            .foregroundStyle(SettingsTheme.textSecondary)
            .padding(.horizontal, 14)
    }

    private func copyButton(_ key: String, _ text: @escaping () -> String) -> some View {
        Button(copied == key ? "已复制" : "复制") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text(), forType: .string)
            copied = key
        }
        .buttonStyle(PillButtonStyle())
    }
}
```
「已连接」的副标题：`ago` 返回「3 分钟前」，后面接「用过」，显示成「3 分钟前用过」；「刚刚」会显示成「刚刚用过」。
- [ ] **Step 2: 改 `UI/SettingsWindow.swift`**
  - `SettingsNavigation` 加 `@Published var remindersTab: RemindersTab = .list`。
  - `SettingsPage` 在 `rest` 后面加 `case reminders = "提醒"`，`symbol` 加 `case .reminders: "bell"`。
  - 标题行的 `else if page == .personal { ... }` 后面加 `else if page == .reminders { SegmentPicker(selection: $navigation.remindersTab) }`。
  - `switch page` 里加 `case .reminders: RemindersPage()`。
- [ ] **Step 3: 改 `App/BreakCoordinator.swift`**
  - 属性区 `let screenshots = ScreenshotController()` 下面加 `let reminders = ReminderCoordinator()`。
  - `start()` 里 Task 8 加的 `onBreakAction` 那几行下面加：
```swift
        NotificationRouter.shared.onReminderReply = { [weak self] reply in self?.reminders.handle(reply) }
        // 休息中、开会、全屏时，强提醒卡片先等一等
        reminders.isBusy = { [weak self] in
            guard let self else { return false }
            if case .onBreak = self.scheduler.state { return true }
            return self.scheduler.isInMeeting || self.scheduler.isFullscreen
        }
        reminders.start()
```
- [ ] **Step 4: 改 `App/RestBreakApp.swift`**：在 `coordinator.screenshots.onOpenSettings = ...` 下面加
```swift
        coordinator.reminders.onOpenPage = { settingsWindow.show(page: .reminders) }
```
- [ ] **Step 5: 改 `UI/StatusBarController.swift`**：在「1. 状态信息」那组循环后面的 `menu.addItem(.separator())` 之后插入
```swift
        // 1.5 接下来的提醒（有提醒时才显示）
        if !coordinator.reminders.data.reminders.isEmpty {
            let header = NSMenuItem(title: "接下来的提醒", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for item in coordinator.reminders.upcoming(now: now, limit: 3) {
                let line = NSMenuItem(title: "\(ScheduleText.fireText(item.date, now: now, calendar: .current))　\(item.title)",
                                      action: nil, keyEquivalent: "")
                line.isEnabled = false
                line.indentationLevel = 1
                menu.addItem(line)
            }
            addItem("全部提醒…", #selector(showReminders))
            menu.addItem(.separator())
        }
```
  并在菜单动作里加 `@objc private func showReminders() { openSettings(.reminders) }`。
- [ ] **Step - [ ] **Step 7: 「连接 AI」一屏放下**：把 `RemindersPage.swift` 里的 `private struct AIConnectView` 改成 `struct AIConnectView`（去掉 private），在 `RestBreakTests/SettingsWindowTests.swift` 里加：
```swift
    @Test func 提醒页连接AI一屏放下() {
        // 内容区宽 760 - 212（侧边栏）- 40（左右边距）= 508；标题行以下可用高度约 520
        let view = NSHostingView(rootView: VStack(spacing: SettingsTheme.cardSpacing) {
            AIConnectView(model: ReminderCoordinator(store: RT.tempStore()))
        }.frame(width: 508))
        #expect(view.fittingSize.height <= 520)
    }
```
  跑 `SettingsWindowTests`，通过。放不下的话，就缩短副标题文字。
.height <= 520`。如果 `AIConnectView` 是 private 不好测，就把它改成 internal。
- [ ] **Step 8: 提交**「0.5：设置『提醒』页、菜单『接下来的提醒』，接好提醒总指挥」

### Task 13: 版本号、文档、全面验证

**Files:** Modify `RestBreak.xcodeproj/project.pbxproj`、`CLAUDE.md`、`docs/superpowers/specs/2026-10-23-agent-reminders-design.md`

- [ ] **Step 1: 版本号**：`sed -i '' 's/MARKETING_VERSION = 0.4.3;/MARKETING_VERSION = 0.5.0;/' RestBreak.xcodeproj/project.pbxproj`，然后 `grep -c "MARKETING_VERSION = 0.5.0" RestBreak.xcodeproj/project.pbxproj` 应该等于 6。
- [ ] **Step 2: `CLAUDE.md` 加一节「第五阶段：AI 派提醒（0.5，2026-10-2x）」**，写下这些要点（照着已有章节的写法）：
  - 设计、管家场景、第 0 步验证记录、本计划这几份文档的路径；
  - 架构：Shared 三方共用；store.json 的位置、锁、原子写；Darwin 通知名；主 App 每 30 秒调用一次 `ReminderPlanner.process`；
  - 规则：准时窗口 5 分钟；12 小时；每 10 分钟再提醒，最多 3 次；未来 7 天最多登记 50 条系统通知；卡片忙时最多等 30 分钟；保留 90 天；
  - 限制：100 条；15 分钟；每个客户端每小时 20 条；
  - 安装方式：Claude Code 用插件；Codex 用 TOML 片段（**不推荐 `codex mcp add`**）；Claude Desktop 用 JSON 片段；
  - 坑：同一个 MCP 命令手动加过又装了插件，插件那份会被去掉；主 App 不能把小程序当子进程启动；`XIEYIHUI_STORE=test`；
  - 后续：0.6 AI 工作感知、0.7、0.8 见管家场景文档。
- [ ] **Step 3: 回写设计文档**：把本计划开头「和设计文档的差异」4 条写进设计文档对应位置（第 3、5、6 节和代码位置）。
- [ ] **Step 4: 全面验证**（用 superpowers:verification-before-completion）
```bash
eval $BUILD
eval $TEST
codesign -d --entitlements - "$MCP" 2>&1 | grep B45N72QF4V
codesign --verify --deep --strict "$APP" && echo 签名完整
```
Expected：`BUILD SUCCEEDED`；测试全过（原来 169 个，加上新增的）；签名正常。
- [ ] **Step 5: 代码审查**：用 superpowers:requesting-code-review 对 `main..HEAD` 做一次审查，重点看：
  - 并发：锁、MainActor、C 回调；
  - 时间边界；
  - 通知 id 是否一致；
  - 有没有把对话原文落盘。

  按 superpowers:receiving-code-review 处理审查意见。
- [ ] **Step 6: 提交**「版本 0.5.0：AI 派提醒」

### Task 14: 真机走查（需要你操作，写成清单）

在 Xcode 里运行歇一会（新版会替换掉旧实例），然后按顺序做：
1. 设置 → 提醒 → 连接 AI → Claude Code「复制」，在终端运行复制的命令。再打开一个 Claude Code 会话，说「医生开了 7 天抗生素，一天三次饭后吃，帮我在歇一会里提醒」。
   Expected：Claude 先问几点吃，再建一条 `firm` 提醒，`maxOccurrences` 21 或 `endDate` 7 天后；右上角弹「Claude Code 帮你建了提醒」；「我的提醒」里出现这条。
2. 让它建一条 2 分钟后的 `firm` 一次性提醒。到点后：横幅和卡片都出现；点「10 分钟后」卡片消失，10 分钟后再出现；不处理的话，每 10 分钟一条「第 N 次提醒」，第 40 分钟卡片消失、记为错过。
3. 在横幅上点「撤销」，提醒被删除。
4. 问「这周药都按时吃了吗」，回答和「我的提醒」里的记录一致。
5. Codex：把复制的 TOML 贴进 `config.toml`（**先删掉第 0 步留下的 5 行验证配置**），在 Codex 里说「每天 9 点提醒我吃药」，能建成；`list_reminders` 不用批准，`create_reminder` 要批准。
6. 退出歇一会（菜单「退出」），让 Claude 建一条提醒，歇一会会被拉起来。
7. 建一条 3 分钟后的提醒，合上屏幕 10 分钟再打开：收到「你不在的时候有 1 条提醒」。
8. Claude Desktop：把复制的 JSON 合并进配置、重启 Claude，在普通聊天里能调用工具。如果手动验证第 2 项（`.mcpb`）已经通过，再另开一个任务做「导出 .mcpb」按钮。

每一项结果记进 `docs/superpowers/specs/2026-10-23-agent-step0-findings.md` 末尾新增的「0.5 走查」一节。有问题先用 superpowers:systematic-debugging 查原因再修。
