# AI 接入第 0 步：打通验证 Implementation Plan

> **状态：已完成（2026-10-23，结论见 specs/2026-10-23-agent-step0-findings.md；末尾待用户手动验证的清单仍未做完）。** 下面的勾选框没有逐条打勾，以本行为准；实际实现以代码和 docs/项目细节.md 为准。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** 用最小的代码证明设计文档里每一条「待验证」的路都走得通（或走不通），把结论写进验证记录，再据此修订设计文档。

**Architecture:** 新增命令行 target `RestBreakMCP`（产物 `restbreak-mcp`，放进 `歇一会.app/Contents/MacOS/`），开沙盒和 App Group。它有三种用法：不带参数时是 MCP 服务器（只有一个 `ping` 工具），`hook claude|codex` 记录 AI 工作状态，`statusline` 记录 Claude 额度。主 App 和小程序共用 `Shared/` 文件夹里的代码；主 App 收到 Darwin 通知后写回执文件。所有验证产物都写在 `~/Library/Group Containers/B45N72QF4V.com.lizhiming.RestBreak/spike/`。

**设计文档:** `docs/superpowers/specs/2026-10-23-agent-reminders-design.md`

**Tech Stack:** Swift 6、`modelcontextprotocol/swift-sdk` 0.12.x（产品名 `MCP`）、CoreFoundation Darwin 通知、AppKit `NSWorkspace`。

**变量**（每个终端会话先执行一次）：
```bash
cd "/Users/lizhiming/Desktop/lizhiming/个人项目验证/桌面闹钟/有趣的项目--桌面提醒工具/RestBreak"
TEST='xcodebuild test -scheme RestBreak -destination platform=macOS -derivedDataPath "$DD" -allowProvisioningUpdates 2>&1 | grep -E "error:|✘|Test run with"'
DD="$HOME/Library/Developer/Xcode/DerivedData/RestBreak-xieyihui-spike"   # 单独的编译目录，不覆盖你正在 Xcode 里运行的那份
APP="$DD/Build/Products/Debug/RestBreak.app"
BUILD='xcodebuild -scheme RestBreak -configuration Debug -derivedDataPath "$DD" build -allowProvisioningUpdates 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"'
BK=/tmp/xieyihui-backup
MCP="$APP/Contents/MacOS/restbreak-mcp"
SPIKE="$HOME/Library/Group Containers/B45N72QF4V.com.lizhiming.RestBreak/spike"
SCRATCH="$HOME/Desktop/Project_Hub/scratch/xieyihui-spike"
```

## 开工前的通盘分析（2026-10-23）

**对现有版本的影响和对策**
| 风险 | 对策 |
|---|---|
| 你的歇一会正由 Xcode 调试运行（DerivedData 里的 Debug 版）。命令行编译会原地覆盖它的文件，可能让运行中的 App 崩溃 | 所有编译和测试都用单独的 `-derivedDataPath`（`$DD`），不碰你在用的那份 |
| 启动第二个歇一会会触发 `SingleInstance`，Xcode 调试中的旧实例关不掉，会留下两个实例 | 验证期间**不启动**新版主 App。「小程序 → App」的 Darwin 通知改成用小程序的 `listen` 子命令验证：它和主 App 一样是独立沙盒进程，结论等价。拉起 App 的能力用 `open-test`（打开计算器）验证沙盒是否允许，真正拉起歇一会放进最后的手动清单 |
| 主 App 加 App Group 权限后签名要重新生成（个人免费团队） | 用团队 ID 前缀的 App Group，macOS 上不需要描述文件。编译失败就回退权限并改走备选方案（写进验证记录）。录屏、日历授权和钥匙串都按 Bundle ID 和团队绑定，不受影响 |
| 改 `project.pbxproj` 可能把工程弄坏；Xcode 正开着这个工程 | 先备份；改完先用 `plutil -lint` 检查再编译。Xcode 会自动重新载入工程 |
| 主 App 的代码改动 | 只加权限和 `Shared/` 文件夹，**不改任何现有代码**（原计划的 `SpikeProbe` 删掉了） |
| 修改你的全局配置（`~/.claude.json`、`~/.codex/config.toml`、`~/.claude/settings.json`、Claude Desktop 配置） | 改之前全部备份到 `$BK`，Task 8 原样恢复。`config.toml` 里有你的中转设置，用备份文件恢复，不靠 `codex mcp remove` |
| 我执行命令的 shell 本身可能带沙盒：沙盒里再启动沙盒程序会直接崩，造成误判 | 运行小程序的命令都放在沙盒外执行 |

**设计上的新发现（写进验证记录和设计文档）**
- 主 App **不能**把小程序当子进程启动：已经在沙盒里的进程再启动一个带自己沙盒权限的程序会崩。小程序只由 AI 客户端启动；主 App 要用它的功能时，直接调用 `Shared/` 里的代码。
- Codex 的 hooks 要「信任」才运行（按内容哈希记录，改了要重新信任）。`codex exec --dangerously-bypass-hook-trust` 可以在验证时跳过这一步。插件里的 hooks 同样要信任，而且带 hooks 的插件**进不了公开插件目录**。所以 Codex 的正式安装方式是 `codex mcp add` 加 `~/.codex/hooks.json`，由设置页生成，第一次使用时在 `/hooks` 里信任一次。
- Claude Code 插件可以同时带 `.mcp.json` 和 `hooks/hooks.json`，校验用 `claude plugin validate`。插件名不能以 `claude-` 开头，所以用 `xieyihui`。
- 上架风险（现在没法验证）：App 里带一个给其他软件调用的命令行程序，审核时需要说明用途。在验证记录里列为待办。

**做不了自动化、留给你手动验证的**：
1. Claude Desktop 普通聊天（要重启 Claude Desktop，而这个对话就跑在它里面）；
2. `.mcpb` 安装；
3. ChatGPT App 里的 Codex；
4. Claude Code 状态栏额度；
5. Codex 在 `/hooks` 里的真实信任流程；
6. 真正拉起歇一会。

这些会写成清单放在验证记录末尾，每项一两条命令或一句话。

**已经确认的（不用再验证）**：本机 Codex 走第三方中转 `club`，最新会话记录里 `rate_limits` 的 `primary` / `secondary` 全是 null。所以 Codex 额度功能对本机不可用，只做解析代码和测试，真机验证跳过。

---

### Task 0: 开分支、提交设计文档

- [ ] **Step 1**
```bash
cd .. && git switch -c feature/agent-reminders
git add docs/superpowers/specs/2026-10-23-agent-reminders-design.md docs/superpowers/specs/2026-10-23-butler-scenarios.md docs/superpowers/plans/2026-10-23-agent-step0-spike.md
git commit -m "AI 接入：设计文档、管家场景、第 0 步计划

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
cd RestBreak
```

### Task 1: 共享代码 `Shared/`（纯逻辑先写测试）

**Files:**
- Create: `RestBreak/Shared/AppGroup.swift`、`RestBreak/Shared/HookEvent.swift`、`RestBreak/Shared/UsageParser.swift`（`Shared/` 和 `RestBreak/RestBreak/` 同级，主 App 和小程序都编译它）
- Test: `RestBreakTests/AgentSpikeTests.swift`

> `Shared/` 要等 Task 2 加进工程后才会被编译。所以这个任务先写好文件，Task 2 结束时再统一跑测试。

- [ ] **Step 1: 写测试** `RestBreakTests/AgentSpikeTests.swift`
```swift
import Foundation
import Testing
@testable import RestBreak

/// 第 0 步：hook 输入解析、额度解析
struct AgentSpikeTests {
    let now = Date(timeIntervalSince1970: 1_792_000_000)

    @Test func hook事件只取需要的字段() throws {
        let json = """
        {"session_id":"abc","cwd":"/Users/x/桌面闹钟","hook_event_name":"UserPromptSubmit",
         "prompt":"帮我改一下密码 123456","transcript_path":"/tmp/t.jsonl"}
        """
        let event = try #require(HookEvent.parse(client: "claude", json: Data(json.utf8), now: now))
        #expect(event == HookEvent(client: "claude", event: "UserPromptSubmit", sessionID: "abc", project: "桌面闹钟", at: now))
        // 落盘内容里不能出现提问原文
        let encoded = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        #expect(!encoded.contains("123456"))
    }

    @Test func hook缺字段或不是JSON时返回nil() {
        #expect(HookEvent.parse(client: "codex", json: Data("不是 json".utf8), now: now) == nil)
        #expect(HookEvent.parse(client: "codex", json: Data(#"{"session_id":"a"}"#.utf8), now: now) == nil)
    }

    @Test func hook没有cwd时项目名为空() throws {
        let json = #"{"session_id":"a","hook_event_name":"Stop"}"#
        let event = try #require(HookEvent.parse(client: "codex", json: Data(json.utf8), now: now))
        #expect(event.project == "")
    }

    @Test func Claude状态栏额度() {
        let json = """
        {"model":{"display_name":"Opus"},"rate_limits":{
          "five_hour":{"used_percentage":23.5,"resets_at":1738425600},
          "seven_day":{"used_percentage":41.2,"resets_at":1738857600}}}
        """
        let windows = UsageParser.claudeStatusline(Data(json.utf8))
        #expect(windows == [
            UsageWindow(windowMinutes: 300, usedPercent: 23.5, resetsAt: Date(timeIntervalSince1970: 1738425600)),
            UsageWindow(windowMinutes: 10080, usedPercent: 41.2, resetsAt: Date(timeIntervalSince1970: 1738857600)),
        ])
    }

    @Test func Claude状态栏没有额度时为空() {
        #expect(UsageParser.claudeStatusline(Data(#"{"model":{}}"#.utf8)).isEmpty)
    }

    @Test func Codex额度按窗口长度区分不按位置() {
        // 新版：primary 是一周窗口
        let line = """
        {"type":"event_msg","payload":{"type":"token_count","rate_limits":{
          "primary":{"used_percent":12.0,"window_minutes":10080,"resets_at":1792600000},
          "secondary":{"used_percent":41.0,"window_minutes":300,"resets_at":1792171200}}}}
        """
        let windows = UsageParser.codexTokenCount(Data(line.utf8))
        #expect(windows.map(\.windowMinutes) == [300, 10080])
        #expect(windows.first?.usedPercent == 41)
    }

    @Test func Codex中转服务额度全为null时为空() {
        // 本机真实数据（第三方中转）
        let line = """
        {"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex",
          "primary":null,"secondary":null,"credits":null}}}
        """
        #expect(UsageParser.codexTokenCount(Data(line.utf8)).isEmpty)
    }
}
```

- [ ] **Step 2: 写 `Shared/AppGroup.swift`**
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

    /// 第 0 步验证用的子文件夹，第 1 步换成正式的数据文件后删掉
    static var spikeURL: URL? {
        guard let base = containerURL else { return nil }
        let url = base.appendingPathComponent("spike", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// 第 0 步验证日志：往共享文件夹里的文件追加一行「时间 内容」
enum SpikeLog {
    @discardableResult
    static func append(_ line: String, to file: String) -> Bool {
        guard let url = AppGroup.spikeURL?.appendingPathComponent(file) else { return false }
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            return (try? handle.write(contentsOf: Data(text.utf8))) != nil
        }
        return (try? Data(text.utf8).write(to: url)) != nil
    }
}

/// Darwin 通知：跨进程的「有东西变了」信号，只有名字，不能带内容
enum DarwinNotice {
    static let spikePing = "com.lizhiming.RestBreak.spike.ping"
    static let agentsChanged = "com.lizhiming.RestBreak.agents.changed"

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name as CFString), nil, nil, true)
    }
}
```

- [ ] **Step 3: 写 `Shared/HookEvent.swift`**
```swift
import Foundation

/// Claude Code / Codex 的 hook 事件里我们只留这几个字段。
/// 提问原文（prompt）、回答原文（last_assistant_message）、工具参数一律不取、不落盘。
struct HookEvent: Codable, Equatable {
    var client: String     // "claude" / "codex"
    var event: String      // hook_event_name，如 UserPromptSubmit / Stop / PermissionRequest
    var sessionID: String
    var project: String    // cwd 的最后一段（项目文件夹名），没有 cwd 时为空
    var at: Date

    static func parse(client: String, json: Data, now: Date) -> HookEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let event = object["hook_event_name"] as? String,
              let session = object["session_id"] as? String else { return nil }
        let cwd = object["cwd"] as? String ?? ""
        let project = cwd.isEmpty ? "" : URL(fileURLWithPath: cwd).lastPathComponent
        return HookEvent(client: client, event: event, sessionID: session, project: project, at: now)
    }
}
```

- [ ] **Step 4: 写 `Shared/UsageParser.swift`**
```swift
import Foundation

/// 一个额度窗口：5 小时（300 分钟）或一周（10080 分钟）
struct UsageWindow: Codable, Equatable {
    var windowMinutes: Int
    var usedPercent: Double
    var resetsAt: Date
}

/// 从 Claude Code 状态栏输入、Codex 会话记录里取额度。按窗口长度从短到长排序。
enum UsageParser {
    /// Claude Code 状态栏命令的标准输入：rate_limits.five_hour / seven_day（Pro / Max 才有）
    static func claudeStatusline(_ data: Data) -> [UsageWindow] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = object["rate_limits"] as? [String: Any] else { return [] }
        let names = [("five_hour", 300), ("seven_day", 10080)]
        return names.compactMap { key, minutes in
            guard let window = limits[key] as? [String: Any],
                  let used = window["used_percentage"] as? Double,
                  let resets = window["resets_at"] as? Double else { return nil }
            return UsageWindow(windowMinutes: minutes, usedPercent: used, resetsAt: Date(timeIntervalSince1970: resets))
        }
    }

    /// Codex 会话记录里的一行 token_count 事件。
    /// 新旧版本 primary / secondary 代表的窗口不同，只能看 window_minutes。
    static func codexTokenCount(_ line: Data) -> [UsageWindow] {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let limits = payload["rate_limits"] as? [String: Any] else { return [] }
        return ["primary", "secondary"].compactMap { key -> UsageWindow? in
            guard let window = limits[key] as? [String: Any],
                  let used = window["used_percent"] as? Double,
                  let minutes = window["window_minutes"] as? Int,
                  let resets = window["resets_at"] as? Double else { return nil }
            return UsageWindow(windowMinutes: minutes, usedPercent: used, resetsAt: Date(timeIntervalSince1970: resets))
        }
        .sorted { $0.windowMinutes < $1.windowMinutes }
    }
}
```

### Task 2: 工程里加 `RestBreakMCP` target、App Group、MCP 依赖

**Files:**
- Create: `RestBreakMCP.entitlements`、`RestBreakMCP/main.swift`（先放一行占位，Task 3 写完整）
- Modify: `RestBreak.entitlements`（加 App Group）、`RestBreak.xcodeproj/project.pbxproj`

- [ ] **Step 1: 两个权限文件**

`RestBreakMCP.entitlements`：
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>B45N72QF4V.com.lizhiming.RestBreak</string>
	</array>
</dict>
</plist>
```
`RestBreak.entitlements`：在 `</dict>` 前加
```xml
	<key>com.apple.security.application-groups</key>
	<array>
		<string>B45N72QF4V.com.lizhiming.RestBreak</string>
	</array>
```
`RestBreakMCP/main.swift` 占位：`print("restbreak-mcp")`

- [ ] **Step 2: 用脚本改 project.pbxproj**（先备份：`cp RestBreak.xcodeproj/project.pbxproj /tmp/project.pbxproj.bak`）

把下面的脚本存为 `/tmp/add_mcp_target.py`，然后运行 `python3 /tmp/add_mcp_target.py`：
```python
import pathlib
p = pathlib.Path("RestBreak.xcodeproj/project.pbxproj")
s = p.read_text()
assert "RestBreakMCP" not in s, "已经加过了"
T = "\t"

def before(marker, text):
    global s
    assert marker in s, marker
    s = s.replace(marker, text + marker, 1)

def after(marker, text):
    global s
    assert marker in s, marker
    s = s.replace(marker, marker + text, 1)

def replace(old, new):
    global s
    assert s.count(old) == 1, old
    s = s.replace(old, new)

before("/* Begin PBXContainerItemProxy section */", """/* Begin PBXBuildFile section */
\t\tA10000000000000000000107 /* MCP in Frameworks */ = {isa = PBXBuildFile; productRef = A10000000000000000000108 /* MCP */; };
\t\tA1000000000000000000010B /* restbreak-mcp in 嵌入命令行小程序 */ = {isa = PBXBuildFile; fileRef = A10000000000000000000101 /* restbreak-mcp */; };
/* End PBXBuildFile section */

""")
before("/* End PBXContainerItemProxy section */", """\t\tA1000000000000000000010C /* PBXContainerItemProxy */ = {
\t\t\tisa = PBXContainerItemProxy;
\t\t\tcontainerPortal = A10000000000000000000001 /* Project object */;
\t\t\tproxyType = 1;
\t\t\tremoteGlobalIDString = A10000000000000000000100;
\t\t\tremoteInfo = RestBreakMCP;
\t\t};
""")
after("/* End PBXContainerItemProxy section */\n", """
/* Begin PBXCopyFilesBuildPhase section */
\t\tA1000000000000000000010A /* 嵌入命令行小程序 */ = {
\t\t\tisa = PBXCopyFilesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tdstPath = "";
\t\t\tdstSubfolderSpec = 6;
\t\t\tfiles = (
\t\t\t\tA1000000000000000000010B /* restbreak-mcp in 嵌入命令行小程序 */,
\t\t\t);
\t\t\tname = "嵌入命令行小程序";
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t};
/* End PBXCopyFilesBuildPhase section */
""")
before("/* End PBXFileReference section */", """\t\tA10000000000000000000101 /* restbreak-mcp */ = {isa = PBXFileReference; explicitFileType = "compiled.mach-o.executable"; includeInIndex = 0; path = "restbreak-mcp"; sourceTree = BUILT_PRODUCTS_DIR; };
\t\tA10000000000000000000102 /* RestBreakMCP.entitlements */ = {isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = RestBreakMCP.entitlements; sourceTree = "<group>"; };
""")
before("/* End PBXFileSystemSynchronizedRootGroup section */", """\t\tA10000000000000000000103 /* RestBreakMCP */ = {
\t\t\tisa = PBXFileSystemSynchronizedRootGroup;
\t\t\tpath = RestBreakMCP;
\t\t\tsourceTree = "<group>";
\t\t};
\t\tA10000000000000000000104 /* Shared */ = {
\t\t\tisa = PBXFileSystemSynchronizedRootGroup;
\t\t\tpath = Shared;
\t\t\tsourceTree = "<group>";
\t\t};
""")
before("/* End PBXFrameworksBuildPhase section */", """\t\tA10000000000000000000106 /* Frameworks */ = {
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\tA10000000000000000000107 /* MCP in Frameworks */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t};
""")
# 左侧文件列表
replace("\t\t\t\tA10000000000000000000041 /* RestBreakTests */,\n\t\t\t\tA10000000000000000000003 /* Products */,",
        "\t\t\t\tA10000000000000000000041 /* RestBreakTests */,\n\t\t\t\tA10000000000000000000102 /* RestBreakMCP.entitlements */,\n\t\t\t\tA10000000000000000000103 /* RestBreakMCP */,\n\t\t\t\tA10000000000000000000104 /* Shared */,\n\t\t\t\tA10000000000000000000003 /* Products */,")
replace("\t\t\t\tA10000000000000000000031 /* RestBreakTests.xctest */,\n",
        "\t\t\t\tA10000000000000000000031 /* RestBreakTests.xctest */,\n\t\t\t\tA10000000000000000000101 /* restbreak-mcp */,\n")
# 主 App：加复制阶段、依赖、Shared 文件夹
replace("\t\t\t\tA10000000000000000000072 /* Resources */,\n\t\t\t);",
        "\t\t\t\tA10000000000000000000072 /* Resources */,\n\t\t\t\tA1000000000000000000010A /* 嵌入命令行小程序 */,\n\t\t\t);")
replace("\t\t\tdependencies = (\n\t\t\t);\n\t\t\tfileSystemSynchronizedGroups = (\n\t\t\t\tA10000000000000000000040 /* RestBreak */,\n",
        "\t\t\tdependencies = (\n\t\t\t\tA1000000000000000000010D /* PBXTargetDependency */,\n\t\t\t);\n\t\t\tfileSystemSynchronizedGroups = (\n\t\t\t\tA10000000000000000000040 /* RestBreak */,\n\t\t\t\tA10000000000000000000104 /* Shared */,\n")
before("/* End PBXNativeTarget section */", """\t\tA10000000000000000000100 /* RestBreakMCP */ = {
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = A1000000000000000000010E /* Build configuration list for PBXNativeTarget "RestBreakMCP" */;
\t\t\tbuildPhases = (
\t\t\t\tA10000000000000000000105 /* Sources */,
\t\t\t\tA10000000000000000000106 /* Frameworks */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tfileSystemSynchronizedGroups = (
\t\t\t\tA10000000000000000000103 /* RestBreakMCP */,
\t\t\t\tA10000000000000000000104 /* Shared */,
\t\t\t);
\t\t\tname = RestBreakMCP;
\t\t\tpackageProductDependencies = (
\t\t\t\tA10000000000000000000108 /* MCP */,
\t\t\t);
\t\t\tproductName = RestBreakMCP;
\t\t\tproductReference = A10000000000000000000101 /* restbreak-mcp */;
\t\t\tproductType = "com.apple.product-type.tool";
\t\t};
""")
after("\t\t\t\tTargetAttributes = {\n", "\t\t\t\t\tA10000000000000000000100 = {\n\t\t\t\t\t\tCreatedOnToolsVersion = 27.1;\n\t\t\t\t\t};\n")
after("\t\t\tminimizedProjectReferenceProxies = 1;\n",
      "\t\t\tpackageReferences = (\n\t\t\t\tA10000000000000000000109 /* XCRemoteSwiftPackageReference \"swift-sdk\" */,\n\t\t\t);\n")
replace("\t\t\t\tA10000000000000000000011 /* RestBreakTests */,\n\t\t\t);\n\t\t};\n/* End PBXProject section */",
        "\t\t\t\tA10000000000000000000011 /* RestBreakTests */,\n\t\t\t\tA10000000000000000000100 /* RestBreakMCP */,\n\t\t\t);\n\t\t};\n/* End PBXProject section */")
before("/* End PBXSourcesBuildPhase section */", """\t\tA10000000000000000000105 /* Sources */ = {
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t};
""")
before("/* End PBXTargetDependency section */", """\t\tA1000000000000000000010D /* PBXTargetDependency */ = {
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = A10000000000000000000100 /* RestBreakMCP */;
\t\t\ttargetProxy = A1000000000000000000010C /* PBXContainerItemProxy */;
\t\t};
""")
def config(id, name):
    return f"""\t\t{id} /* {name} */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tCODE_SIGN_ENTITLEMENTS = RestBreakMCP.entitlements;
\t\t\t\tCODE_SIGN_IDENTITY = "Apple Development";
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCREATE_INFOPLIST_SECTION_IN_BINARY = YES;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tDEVELOPMENT_TEAM = B45N72QF4V;
\t\t\t\tENABLE_HARDENED_RUNTIME = YES;
\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tMARKETING_VERSION = 0.4.3;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.lizhiming.RestBreak.mcp;
\t\t\t\tPRODUCT_NAME = "restbreak-mcp";
\t\t\t\tSKIP_INSTALL = YES;
\t\t\t\tSWIFT_VERSION = 6.0;
\t\t\t}};
\t\t\tname = {name};
\t\t}};
"""
before("/* End XCBuildConfiguration section */",
       config("A1000000000000000000010F", "Debug") + config("A10000000000000000000110", "Release"))
before("/* End XCConfigurationList section */", """\t\tA1000000000000000000010E /* Build configuration list for PBXNativeTarget "RestBreakMCP" */ = {
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\tA1000000000000000000010F /* Debug */,
\t\t\t\tA10000000000000000000110 /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t};
""")
after("/* End XCConfigurationList section */\n", """
/* Begin XCRemoteSwiftPackageReference section */
\t\tA10000000000000000000109 /* XCRemoteSwiftPackageReference "swift-sdk" */ = {
\t\t\tisa = XCRemoteSwiftPackageReference;
\t\t\trepositoryURL = "https://github.com/modelcontextprotocol/swift-sdk";
\t\t\trequirement = {
\t\t\t\tkind = upToNextMinorVersion;
\t\t\t\tminimumVersion = 0.12.1;
\t\t\t};
\t\t};
/* End XCRemoteSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
\t\tA10000000000000000000108 /* MCP */ = {
\t\t\tisa = XCSwiftPackageProductDependency;
\t\t\tpackage = A10000000000000000000109 /* XCRemoteSwiftPackageReference "swift-sdk" */;
\t\t\tproductName = MCP;
\t\t};
/* End XCSwiftPackageProductDependency section */
""")
p.write_text(s)
print("ok")
```
SDK 还是 0.x 版本，接口可能变动，所以只允许自动升级小版本（`upToNextMinorVersion`）。没加 `CodeSignOnCopy`，因为复制时重签名会冲掉小程序自己的权限。

- [ ] **Step 3: 解析依赖并编译**
```bash
plutil -lint RestBreak.xcodeproj/project.pbxproj
xcodebuild -resolvePackageDependencies -scheme RestBreak -derivedDataPath "$DD"
eval $BUILD
```
Expected: `BUILD SUCCEEDED`。如果报 pbxproj 解析错误，用 `/tmp/project.pbxproj.bak` 恢复后检查脚本。

- [ ] **Step 4: 检查产物和权限**
```bash
ls -l "$MCP"
codesign -d --entitlements - "$MCP" 2>&1 | grep -E "app-sandbox|application-groups|B45N72QF4V"
codesign -d --entitlements - "$APP" 2>&1 | grep -E "application-groups|B45N72QF4V"
codesign --verify --deep --strict "$APP" && echo 签名完整
"$MCP" hook x </dev/null; echo "退出码 $?"
```
Expected: 小程序存在；两个程序都带 `B45N72QF4V.com.lizhiming.RestBreak`；`签名完整`。

- [ ] **Step 5: 跑测试**：`eval $TEST`。Expected：`AgentSpikeTests` 7 个测试全过，原有测试不受影响。
- [ ] **Step 6: 提交**「AI 接入第 0 步：RestBreakMCP 命令行 target、App Group、共享解析代码」（`git add -A RestBreak`）

### Task 3: 小程序三种用法

**Files:** Modify `RestBreakMCP/main.swift`；Create `RestBreakMCP/MCPCommand.swift`、`RestBreakMCP/HookCommand.swift`

- [ ] **Step 1: `RestBreakMCP/main.swift`**
```swift
import Foundation

// 歇一会的命令行小程序，放在 歇一会.app/Contents/MacOS/restbreak-mcp。
// - 不带参数：MCP 服务器。Claude / Codex 启动它，通过标准输入输出通信
// - hook claude|codex：被 AI 工具的 hooks 调用，记录 AI 在干活 / 干完 / 等你
// - statusline：被 Claude Code 状态栏调用，记录额度
let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "hook":
    HookCommand.run(client: arguments.dropFirst().first ?? "unknown")
case "statusline":
    StatuslineCommand.run()
case "listen":   // 第 0 步：代替主 App 接收 Darwin 通知，验证沙盒进程之间能否收到
    ListenCommand.run(seconds: Double(arguments.dropFirst().first ?? "") ?? 5)
case "open-test": // 第 0 步：验证沙盒里能否用 NSWorkspace 打开别的 App
    await OpenTestCommand.run()
default:
    try await MCPCommand.run()
}
```

- [ ] **Step 2: `RestBreakMCP/HookCommand.swift`**
```swift
import Foundation

/// hooks 调用：必须很快结束、永远成功退出、不往标准输出写东西，绝不能拖慢或拦住 AI
enum HookCommand {
    static func run(client: String) {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let event = HookEvent.parse(client: client, json: input, now: Date()),
              let data = try? JSONEncoder().encode(event) else {
            SpikeLog.append("hook \(client) 解析失败（\(input.count) 字节）", to: "hooks.log")
            exit(0)
        }
        SpikeLog.append(String(decoding: data, as: UTF8.self), to: "hooks.log")
        DarwinNotice.post(DarwinNotice.agentsChanged)
        exit(0)
    }
}

/// Claude Code 状态栏：记下额度，再输出一行状态栏文字
enum StatuslineCommand {
    static func run() {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let windows = UsageParser.claudeStatusline(input)
        if let data = try? JSONEncoder().encode(windows), let dir = AppGroup.spikeURL {
            try? data.write(to: dir.appendingPathComponent("usage-claude.json"))
        }
        print(windows.isEmpty ? "歇一会：没有额度数据" : "歇一会：5 小时额度 \(Int(windows[0].usedPercent))%")
    }
}
```

- [ ] **Step 2b: `RestBreakMCP/SpikeCommands.swift`**（第 1 步删除）
```swift
import AppKit

/// 在指定秒数内监听 Darwin 通知，收到就写一行回执
enum ListenCommand {
    static func run(seconds: Double) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for name in [DarwinNotice.spikePing, DarwinNotice.agentsChanged] {
            CFNotificationCenterAddObserver(center, nil, { _, _, name, _, _ in
                SpikeLog.append("收到 \(name.map { $0.rawValue as String } ?? "?")", to: "listen.log")
            }, name as CFString, nil, .deliverImmediately)
        }
        SpikeLog.append("开始监听 \(seconds) 秒", to: "listen.log")
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}

/// 用 NSWorkspace 打开计算器（不抢焦点），再退出它
enum OpenTestCommand {
    @MainActor
    static func run() async {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        do {
            let app = try await NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: "/System/Applications/Calculator.app"), configuration: configuration)
            print("打开成功")
            app.terminate()
        } catch {
            print("打开失败：\(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 3: `RestBreakMCP/MCPCommand.swift`**
```swift
import AppKit
import MCP

/// MCP 服务器。第 0 步只有一个 ping 工具，用来验证各条路是否通
enum MCPCommand {
    static func run() async throws {
        let server = Server(name: "xieyihui", version: "0.0.1", title: "歇一会",
                            instructions: "歇一会第 0 步验证版本，只有 ping 工具。",
                            capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in
            let schema: Value = .object([
                "type": .string("object"),
                "properties": .object(["launch": .object(["type": .string("boolean"),
                                                         "description": .string("歇一会没在运行时是否把它打开")])]),
            ])
            return .init(tools: [Tool(name: "ping", description: "测试歇一会是否连通，返回每一项检查的结果。", inputSchema: schema)])
        }
        await server.withMethodHandler(CallTool.self) { params in
            guard params.name == "ping" else {
                return .init(content: [.text("没有这个工具：\(params.name)")], isError: true)
            }
            let report = await Ping.run(launch: params.arguments?["launch"]?.boolValue ?? false)
            return .init(content: [.text(report)], isError: false)
        }
        try await server.start(transport: StdioTransport()) { client, _ in
            SpikeLog.append("initialize \(client.name) \(client.version)", to: "mcp.log")
        }
        await server.waitUntilCompleted()
    }
}

enum Ping {
    @MainActor
    static func run(launch: Bool) async -> String {
        guard let dir = AppGroup.spikeURL else { return "拿不到 App Group 文件夹（权限没配好）" }
        var lines = [SpikeLog.append("ping launch=\(launch)", to: "mcp.log")
                     ? "写入共享文件夹：成功（\(dir.path)）" : "写入共享文件夹：失败"]
        DarwinNotice.post(DarwinNotice.spikePing)
        lines.append("已发送 Darwin 通知")
        // 已在运行就不再启动：新实例会把旧实例顶掉，Xcode 调试中的旧实例会留下两个
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: AppGroup.appBundleID).isEmpty
        lines.append("歇一会\(running ? "正在运行" : "没在运行")")
        if launch && !running {
            // 小程序在 歇一会.app/Contents/MacOS/ 里，往上三层就是 App 本身
            let appURL = Bundle.main.executableURL!.deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            do {
                _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
                lines.append("已启动歇一会：\(appURL.path)")
            } catch {
                lines.append("启动歇一会失败：\(error.localizedDescription)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
```

- [ ] **Step 4: 编译**（`eval $BUILD`）。Expected: `BUILD SUCCEEDED`。
- [ ] **Step 5: 用标准输入测 MCP**
```bash
(printf '%s\n' \
 '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"manual-test","version":"1"}}}' \
 '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
 '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
 '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ping","arguments":{}}}'; sleep 2) | "$MCP"
cat "$SPIKE/mcp.log"
```
Expected：输出 3 条 JSON 响应。id 3 的回复包含「写入共享文件夹：成功」；`mcp.log` 里有 `initialize manual-test 1`。
- [ ] **Step 6: 测 hook 和状态栏**
```bash
echo '{"session_id":"s1","cwd":"/tmp/项目A","hook_event_name":"Stop","last_assistant_message":"秘密"}' | "$MCP" hook codex; echo "退出码 $?"
tail -1 "$SPIKE/hooks.log"
echo '{"rate_limits":{"five_hour":{"used_percentage":50,"resets_at":1792171200}}}' | "$MCP" statusline
cat "$SPIKE/usage-claude.json"
```
Expected：退出码 0、hooks.log 里没有「秘密」；状态栏输出「歇一会：5 小时额度 50%」。
- [ ] **Step 7: 提交**「AI 接入第 0 步：小程序 ping / hook / statusline」

### Task 4: 沙盒进程之间的 Darwin 通知、沙盒里打开 App（不启动主 App）

- [ ] **Step 1: 通知**
```bash
"$MCP" listen 4 & sleep 1
echo '{"session_id":"s2","hook_event_name":"Stop"}' | "$MCP" hook claude
wait; cat "$SPIKE/listen.log"
```
Expected：出现「收到 com.lizhiming.RestBreak.agents.changed」。
- [ ] **Step 2: 打开 App**：`"$MCP" open-test`。Expected：输出「打开成功」，计算器闪一下就退出。
- [ ] **Step 3:** 没有新增提交（代码已在 Task 3 提交）。

### Task 5: Claude Code 和 Codex 的 MCP + hooks 真机验证

- [ ] **Step 0: 备份全局配置**
```bash
mkdir -p "$BK"
cp ~/.claude.json "$BK/claude.json"; cp ~/.claude/settings.json "$BK/claude-settings.json"
cp ~/.codex/config.toml "$BK/codex-config.toml"; [ -f ~/.codex/hooks.json ] && cp ~/.codex/hooks.json "$BK/codex-hooks.json"
```
- [ ] **Step 1: 准备临时目录**（全局配置只注册 MCP；hooks 只写在临时目录里，不碰全局 `~/.claude/settings.json`）
```bash
mkdir -p "$SCRATCH/.claude" "$SCRATCH/.codex"
python3 - "$MCP" "$SCRATCH" <<'EOF'
import json, sys, pathlib
mcp, scratch = sys.argv[1], pathlib.Path(sys.argv[2])
def hooks(client, events):
    return {"hooks": {e: [{"hooks": [{"type": "command", "command": f'"{mcp}" hook {client}'}]}] for e in events}}
claude = hooks("claude", ["UserPromptSubmit", "Stop", "Notification", "PermissionRequest", "SessionEnd"])
claude["statusLine"] = {"type": "command", "command": f'"{mcp}" statusline'}
(scratch / ".claude/settings.local.json").write_text(json.dumps(claude, ensure_ascii=False, indent=2))
(scratch / ".codex/hooks.json").write_text(json.dumps(hooks("codex", ["UserPromptSubmit", "Stop", "PermissionRequest", "Interrupt", "SessionEnd"]), ensure_ascii=False, indent=2))
EOF
claude mcp add --scope user xieyihui-spike -- "$MCP"
codex mcp add xieyihui-spike -- "$MCP"
```
- [ ] **Step 2: Claude Code 非交互**
```bash
cd "$SCRATCH" && claude -p "调用 xieyihui-spike 的 ping 工具（launch=false），把结果原样告诉我" --allowedTools "mcp__xieyihui-spike__ping"; cd -
grep claude "$SPIKE/hooks.log" | tail -3; tail -2 "$SPIKE/mcp.log"
```
Expected：回答里有「写入共享文件夹：成功」；hooks.log 有 `UserPromptSubmit` 和 `Stop`；mcp.log 有 `initialize claude-code ...`（记下客户端的真实名字）。
- [ ] **Step 3: Claude Code 权限请求**：`cd "$SCRATCH" && claude -p "在当前目录建一个文件 a.txt"`（不给权限），看 hooks.log 里有没有 `PermissionRequest` 或 `Notification`。下面的交互部分放进手动清单：在 `$SCRATCH` 里运行 `claude`，说「在当前目录建一个文件 a.txt」。等它请求权限时先别批准，检查 `tail -2 "$SPIKE/hooks.log"` 里有没有 `PermissionRequest`；然后批准，看状态栏是否显示「歇一会：…」，`usage-claude.json` 是否写入（没有 Pro / Max 订阅就是空数组）。最后 `/exit`，确认有 `SessionEnd`。
- [ ] **Step 4: Codex 命令行**：`cd "$SCRATCH" && codex exec --dangerously-bypass-hook-trust "调用 xieyihui-spike 的 ping 工具，把结果原样告诉我"`（项目目录要先被 Codex 信任；不信任时就把 hooks 临时放进 `~/.codex/hooks.json` 再试，结束后用备份恢复）。检查回复、hooks.log 里 `codex` 的 `UserPromptSubmit` / `Stop`、mcp.log 里的客户端名。`PermissionRequest`、`Interrupt` 需要交互，放进手动清单。**重点记录：hook 写共享文件夹是否失败**（失败说明 Codex 把 hook 放进了它自己的沙盒）。
- [ ] **Step 5（手动清单）: ChatGPT App 里的 Codex**：重启 ChatGPT App，在 Codex 里说「调用 xieyihui-spike 的 ping 工具」。记录能否调用、客户端名，以及这个项目的 hooks 会不会触发。
- [ ] **Step 6（手动清单，现在只写好配置脚本）: Claude Desktop（stdio 配置）**
```bash
CFG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
cp "$CFG" /tmp/claude_desktop_config.bak 2>/dev/null || echo '{}' > /tmp/claude_desktop_config.bak
python3 - "$CFG" "$MCP" <<'EOF'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1]); d = json.loads(p.read_text()) if p.exists() else {}
d.setdefault("mcpServers", {})["xieyihui-spike"] = {"command": sys.argv[2]}
p.write_text(json.dumps(d, ensure_ascii=False, indent=2))
EOF
```
退出并重新打开 Claude Desktop，在普通聊天里说「调用 xieyihui-spike 的 ping 工具」。记录结果和客户端名。

### Task 6: `.mcpb` 扩展包能否用绝对路径

- [ ] **Step 1: 两个版本**
```bash
for v in abs copy; do mkdir -p "/tmp/mcpb-$v/server"; done
cp "$MCP" /tmp/mcpb-copy/server/restbreak-mcp
printf '#!/bin/sh\nexit 0\n' > /tmp/mcpb-abs/server/placeholder && chmod +x /tmp/mcpb-abs/server/placeholder
python3 - "$MCP" <<'EOF'
import json, sys
for v, entry, cmd in [("abs", "server/placeholder", sys.argv[1]), ("copy", "server/restbreak-mcp", "${__dirname}/server/restbreak-mcp")]:
    m = {"manifest_version": "0.3", "name": f"xieyihui-{v}", "display_name": f"歇一会验证（{v}）",
         "version": "0.0.1", "description": "第 0 步验证", "author": {"name": "李志铭"},
         "server": {"type": "binary", "entry_point": entry, "mcp_config": {"command": cmd, "args": []}},
         "compatibility": {"platforms": ["darwin"]}}
    open(f"/tmp/mcpb-{v}/manifest.json", "w").write(json.dumps(m, ensure_ascii=False, indent=2))
EOF
for v in abs copy; do npx -y @anthropic-ai/mcpb pack "/tmp/mcpb-$v" "/tmp/xieyihui-$v.mcpb"; done
```
- [ ] **Step 1b:** 先自动检查：`npx -y @anthropic-ai/mcpb validate /tmp/mcpb-abs/manifest.json`，以及 copy 版的同样检查。
- [ ] **Step 2（手动清单）:** 双击两个 `.mcpb`，分别在 Claude Desktop 里安装，然后各调用一次 ping。记录：abs 版能否安装和调用；copy 版复制出来的小程序 App Group 写入是否仍然成功（签名会随文件一起复制）。验证完在 Claude Desktop 扩展设置里卸载这两个扩展。

### Task 7: 插件能否同时带 MCP 和 hooks

> 文件格式先对照官方文档：Claude Code `https://code.claude.com/docs/en/plugins-reference`；Codex `https://learn.chatgpt.com/docs/hooks`（插件部分）和插件文档。格式和下面不一样时，以文档为准，并把差异记进验证记录。

- [ ] **Step 1: Claude Code 插件**（本地 marketplace）
```bash
P=/tmp/xieyihui-claude-plugin; mkdir -p "$P/.claude-plugin" "$P/plugins/xieyihui/.claude-plugin" "$P/plugins/xieyihui/hooks"
cat > "$P/.claude-plugin/marketplace.json" <<EOF
{"name":"xieyihui-local","owner":{"name":"李志铭"},"plugins":[{"name":"xieyihui","source":"./plugins/xieyihui","description":"歇一会验证"}]}
EOF
cat > "$P/plugins/xieyihui/.claude-plugin/plugin.json" <<EOF
{"name":"xieyihui","version":"0.0.1","description":"歇一会验证"}
EOF
cat > "$P/plugins/xieyihui/.mcp.json" <<EOF
{"mcpServers":{"xieyihui":{"command":"$MCP"}}}
EOF
cat > "$P/plugins/xieyihui/hooks/hooks.json" <<EOF
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\"$MCP\" hook claude-plugin"}]}]}}
EOF
claude plugin validate "$P/plugins/xieyihui"
claude plugin marketplace add "$P" && claude plugin install xieyihui@xieyihui-local
claude -p "调用 xieyihui 插件的 ping 工具" --allowedTools "mcp__plugin_xieyihui_xieyihui__ping"
grep claude-plugin "$SPIKE/hooks.log" | tail -1
```
Expected：ping 成功，并有 `claude-plugin` 的 `Stop`。
- [ ] **Step 2: Codex 插件**：不做真机验证。带 hooks 的插件进不了公开目录，只能在桌面 App 里手动安装，而且 hooks 同样要信任，所以正式方案不走插件。把这个结论写进验证记录。

### Task 8: 写验证记录、修订设计、清理

**Files:** Create `docs/superpowers/specs/2026-10-23-agent-step0-findings.md`；Modify `docs/superpowers/specs/2026-10-23-agent-reminders-design.md`

- [ ] **Step 1: 验证记录**：每一项写「通 / 不通 / 部分通 + 证据（命令输出或日志行）+ 对设计的影响」。项目如下：
  1. App Group 写入（命令行直接运行 / Claude Code / Codex / ChatGPT App / Claude Desktop 启动）；
  2. Darwin 通知（小程序 → 主 App）；
  3. 拉起主 App；
  4. 各客户端的 `clientInfo.name`；
  5. 两家 hooks 各事件是否触发、是否被 Codex 的沙盒拦住；
  6. `.mcpb` 绝对路径版和复制版；
  7. 两家插件能否同时带 MCP 和 hooks，以及实际文件格式；
  8. Claude 状态栏额度（有没有数据）；
  9. Codex 额度：本机走中转，为空（已确认）；
  10. 签名和权限检查结果。
- [ ] **Step 2: 修订设计文档**：第 3 节安装方式按 6、7 的结果定下来；第 8 节额度部分写明「走第三方中转时 Codex 没有额度数据，设置页显示『你的 Codex 用的服务不提供额度信息』」；有走不通的路，就把替代做法写进去。
- [ ] **Step 3: 清理**
```bash
claude plugin uninstall xieyihui@xieyihui-local; claude plugin marketplace remove xieyihui-local
claude mcp remove --scope user xieyihui-spike
cp "$BK/codex-config.toml" ~/.codex/config.toml
[ -f "$BK/codex-hooks.json" ] && cp "$BK/codex-hooks.json" ~/.codex/hooks.json || rm -f ~/.codex/hooks.json
diff <(python3 -c 'import json;d=json.load(open("'"$BK"'/claude-settings.json"));print(sorted(d))') <(python3 -c 'import json,os;d=json.load(open(os.path.expanduser("~/.claude/settings.json")));print(sorted(d))') && echo settings 一致
```
Claude Desktop 的配置等你手动验证完再恢复（清单里写好了命令）。`$SCRATCH` 保留到第 1 步，方便复测。
- [ ] **Step 4: 提交**「AI 接入第 0 步：验证记录与设计修订」

## 保留到第 1 步的东西
`RestBreakMCP` target、`Shared/AppGroup.swift`、`HookEvent`、`UsageParser` 和测试都留着继续用。第 1 步开始时删掉：`SpikeCommands.swift`、`SpikeLog`、`AppGroup.spikeURL`、`ping` 工具和 `spike/` 文件夹。
