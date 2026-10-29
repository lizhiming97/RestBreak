# AI 助手派提醒（MCP 接入）设计

日期：2026-10-23　状态：待确认　版本目标：0.5.0（提醒）、0.6.0（AI 工作感知）

## 一句话
歇一会自己**不调用任何大模型**。它提供一个本地 MCP 工具，让你本来就在用、也已经了解你的 AI（Claude Desktop、Claude Code、Codex、Cursor 等）在聊天时直接帮你建提醒、改提醒、查提醒是否完成。同时通过 Claude Code 和 Codex 的 hooks 感知 AI 正在干活、干完了还是在等你，以及额度还剩多少，用来安排休息和提醒（第 8 节）。**AI 负责理解和配置，歇一会负责准时、可靠、有温度地提醒。**

## 为什么这样分工
- **了解你的是 AI，不是歇一会**：歇一会读不到你和 AI 的聊天，也不该去读。让 AI 把它理解到的东西写成提醒，就不用在 App 里再造一个「了解你的 Agent」。
- **到点触发不能交给大模型**：吃药这类提醒必须在断网、接口超时、模型判断出错时也照样准时响。所以只有 App 里写死的代码会触发提醒，模型永远碰不到「什么时候响」这一环。
- **App 里没有 API Key、没有模型费用、数据不出本机**：提醒只存在本机。只有你的 AI 来读时，提醒内容才会作为对话的一部分发给 AI 服务商。这对隐私说明和上架审核都最省事。

## 全链路

```
你 ──聊天──▶ Claude Desktop / Claude Code（已有记忆、了解你）
                 │ 本机 stdio，MCP JSON-RPC
                 ▼
        restbreak-mcp（App 包内的命令行小程序，沙盒 + App Group）
                 │ 读写同一个文件 + 系统通知「提醒变了」
                 ▼
   App Group 共享目录 / Reminders/store.json
                 ▲
                 │ 监听变化，重新排期
        歇一会主程序（菜单栏 App）
          ├─ ReminderPlanner：算出接下来每次该响的时间（纯逻辑）
          ├─ 系统定时通知：App 没运行也照样弹横幅
          └─ 强提醒卡片 / 再次提醒 / 完成记录 ──▶ 写回 store.json ──▶ AI 下次能查到
```

### 1. 传输方式：stdio 小程序（已查证）
- Claude Desktop 在设置里添加的「自定义连接器」是从 Anthropic 云端去连的，**连不上本机 localhost**；`claude_desktop_config.json` 里也只能填 stdio 服务器，填 URL 会被忽略。所以不能用「App 里开一个本地 HTTP 服务」的做法。
- 方案：在 App 包里放一个命令行程序 `歇一会.app/Contents/MacOS/restbreak-mcp`，由 AI 客户端负责启动它，两边通过标准输入输出交换 MCP 消息。Claude Desktop、Claude Code、Codex、Cursor 都支持这种方式。Codex 的命令行、桌面 App 和 IDE 插件共用 `~/.codex/config.toml`，配一次三处都能用。
- 用官方 Swift SDK `modelcontextprotocol/swift-sdk`（需 macOS 13+ 和 Swift 6，本机是 Xcode 27，满足；SDK 跟进的是 2025-11-25 版协议）。不自己写协议层，因为版本协商、ping、错误码这些细节交给官方维护更稳。这是本项目第一个第三方依赖，只给小程序这个 target 用，主 App 不链接。

### 2. 小程序和主 App 怎么通信：共享文件，不做进程间调用
- 两个程序都开同一个 App Group：`B45N72QF4V.com.lizhiming.RestBreak`（用团队 ID 当前缀，macOS 15 上不会弹「访问其他 App 数据」的提示）。
- 数据存在 `<共享目录>/Reminders/store.json`。读、改、写这一整套操作都放在 `flock` 文件锁里完成，写入用临时文件加原子替换。因为可能有多个写入方同时在（Claude Desktop 和 Claude Code 各启动一个小程序，再加上主 App），所以必须加锁。
- 写完后用 Darwin 通知（`notify_post`）发 `com.lizhiming.RestBreak.reminders.changed`，主 App 收到后重新排期。主 App 启动、从睡眠醒来时也会重新读一遍，防止错过通知。
- **主 App 没在运行也能建提醒**：小程序照样写文件，然后用 `NSWorkspace.openApplication`（按 Bundle ID 找到 App）把主 App 拉起来。拉起之前，先用 `NSRunningApplication` 检查主 App 是不是已经在运行，在运行就不再启动。原因：`SingleInstance` 的规则是新启动的实例会把旧实例顶掉，如果 Xcode 正在调试旧实例，这样会留下两个实例。
- 为什么不用 XPC：菜单栏 App 没法注册 launchd 的 mach 服务，绕过去要多写一个中转程序，太复杂。为什么不用本地 HTTP：要求主 App 一直开着，还要处理端口冲突和鉴权。共享文件这条路最简单，而且两边谁先启动都不影响。（第 0 步已验证：App Group 读写、沙盒进程之间的 Darwin 通知都通。）
- **主 App 绝不把小程序当子进程启动**：已经在沙盒里的进程再启动一个带自己沙盒权限的程序会崩。主 App 要用这些功能时，直接调用 `Shared/` 里的代码。

### 3. 安装：一键加到 AI 客户端
设置里新增「AI 助手」页，提供：
- **Claude Desktop**：点「安装到 Claude Desktop」，App 生成一个 `.mcpb` 扩展包，用 Claude 打开，用户在 Claude 里点一下「安装」就完成。
  - 第 0 步结论：把小程序复制进扩展包的做法已确认可行（解包后签名有效、能写 App Group）；写绝对路径的版本等手动安装验证。原来的待验证说明：`.mcpb` 的 `mcp_config.command` 能不能直接写 App 包里小程序的绝对路径。官方示例都是包内相对路径。能写的话，扩展包里只放清单文件，App 升级后自动用上新的小程序；不能写的话，就把小程序复制进扩展包，App 升级后在这页提示「扩展需要更新」并能重新生成。
  - 兜底：「复制配置」，复制 `claude_desktop_config.json` 片段，附上打开该文件的说明。沙盒 App 不能直接改别的 App 的配置文件，这是上架要求。
- **Claude Code**：优先用「歇一会」Claude Code 插件，一个插件里同时带 MCP 服务器（提醒）和 hooks（第 8 节的工作感知），装一次两样都有。只想要提醒的话，也可以复制 `claude mcp add --scope user xieyihui -- "<小程序路径>"`。
- **Codex**（第 0 步后修订：不做插件。Codex 0.145 已移除插件 hooks，带 hooks 的插件也进不了公开目录）：
  - 设置页生成两段内容，旁边各有「复制」和「打开文件」：
    - 一段 TOML，让你贴到 `~/.codex/config.toml` 末尾：`[mcp_servers.xieyihui]` 加 `command`，以及只读工具的 `[mcp_servers.xieyihui.tools.<工具>] approval_mode = "approve"`；会改数据的工具保持每次询问；
    - 一段 `~/.codex/hooks.json`。
  - **不推荐 `codex mcp add`**：实测它会重写整个 `config.toml`（调整顺序、删掉默认项）。
  - Codex 第一次运行这些 hooks 前，要在 `/hooks` 里信任一次，设置页写明这一步。
  - hooks 要放在用户级的 `~/.codex/hooks.json`：项目级的在项目没被信任时不会加载。
  - 这份配置 Codex 命令行、ChatGPT App、IDE 插件共用。
- **其他客户端（Cursor 等）**：复制通用 JSON 配置。
- **连接状态**：小程序每次被启动、握手成功时，会把客户端名字（MCP `clientInfo`）和时间记进 store。设置页据此显示「已连接：Claude Desktop · 3 分钟前用过」，没连过就显示「还没有 AI 连上」。

### 4. 给 AI 的工具（MCP tools）
共 5 个工具，名字用英文，说明用中文。每个返回结果里都带 `now`（本地时间、时区、星期几），因为模型经常不知道现在几点。

| 工具 | 作用 |
|---|---|
| `get_overview` | 现在的时间；今天和接下来 24 小时的提醒及每条的状态；最近 3 天错过的提醒；第二步加上今天的休息情况 |
| `create_reminder` | 新建提醒；返回提醒内容和接下来 3 次响的时间（中文描述），方便 AI 向你复述确认 |
| `list_reminders` | 列出提醒（`active` / `all`），可选 `historyDays` 带上最近 N 天每次的完成情况（「这周药都按时吃了吗」） |
| `update_reminder` | 按 id 修改部分字段，包括暂停和恢复 |
| `delete_reminder` | 按 id 删除 |

`create_reminder` 的参数：
- `title`：提醒标题，必填，比如「吃抗生素」。
- `messages`：1～5 句提醒文案，由 AI 用你习惯的语气写，比如「饭后半小时，该吃药啦，还剩 4 天就吃完了 💊」。每次响的时候轮换着用，**不用在 App 里调模型，也不会每次都一样冷冰冰**。
- `schedule`：什么时候响，五种之一（见下表）。
- `style`：`gentle`（只弹横幅，默认）或 `firm`（弹横幅，再加一张不处理就不消失的卡片，过一会儿再提醒，适合吃药）。
- `reason`：为什么建这个提醒，一句话，比如「10/23 聊到医生开了 7 天抗生素」。会显示在 App 里，让你知道它从哪来。
- 可选：`startDate`、`endDate`、`maxOccurrences`（比如吃 7 天就自动结束）。

`schedule` 的写法（时间都按本地时间理解；带时区的 ISO 8601 也接受）：

| kind | 字段 | 例子 |
|---|---|---|
| `once` | `at` | 今天 18:30 提醒去买牛奶 |
| `daily` | `times[]`，可选 `weekdays[]`（1=周一） | 每天 9:00、21:00 吃药；工作日 10:00 站会前看日报 |
| `interval` | `everyMinutes`、`from`、`to`，可选 `weekdays[]` | 工作时间每 90 分钟喝水 |
| `monthly` | `days[]`、`times[]`（31 号在小月自动改成当月最后一天） | 每月 10 号交房租 |
| `yearly` | `month`、`day`、`times[]`（2 月 29 日在平年改成 2 月 28 日），可选 `leadDays[]` 提前几天 | 妈妈生日 11/5，提前 5 天准备礼物 |

- 不用 RRULE 这种通用写法：字段越少，模型越不容易写错。
- **参数校验错误都写成 AI 看得懂、能自己改正的话**。例如「`at` 2026-10-23T08:00 已经过去了，现在是 2026-10-23 15:12 周五，是不是想设成明天？」
- **防失控上限**：最多 100 条有效提醒；`interval` 至少 15 分钟；同一个客户端每小时最多新建 20 条。

**服务器说明（MCP `instructions`）**：这是让 AI「主动」的关键，大意如下：
- 用户提到将来要做的事（吃药、买东西、截止日期、给某人回电话）时，主动问一句「要我在歇一会里提醒你吗？」，用户同意了再建。
- 提醒文案要贴合用户的情况，短一点、暖一点；对反复的提醒写 2～5 句不同的话。
- 用户聊到相关话题时，可以先用 `get_overview` 看看今天的提醒和完成情况，再给出关心。
- 不要替用户删掉不是这次对话里建的提醒，除非用户明确要求。

### 5. 主 App：排期与触发
- **`ReminderPlanner`（纯逻辑，只依赖 Foundation，按现有引擎的写法）**：给它提醒列表、完成记录和当前时间，它算出接下来每次该响的时间、哪些到点了、哪些错过了。用 `Calendar` 计算日期，跨月、闰年、改时区都能正确处理。
- **系统定时通知是第一道保障**：每次提醒有变、App 启动、醒来、过零点、系统时间或时区改变时，把未来 7 天内最多 50 次响铃登记成 `UNCalendarNotificationTrigger` 定时通知（系统上限 64 条，留出 14 条给休息通知）。这样即使 App 崩溃或被退出，横幅也照样会弹。
- **通知按钮**：「完成」「10 分钟后」。点按钮会唤起 App，写入完成记录。「10 分钟后」会生成一次单独的再提醒。
- **强提醒（`firm`）**：App 在运行时，到点额外弹一张浮动卡片，复用截图文字面板那套浅色浮窗样式，有「完成」「10 分钟后」「跳过这次」三个按钮，处理了才消失。没处理的话，每 10 分钟再弹一次横幅，最多 3 次，之后记为「错过」。
- **和休息、开会、全屏的关系**：
  - 横幅不额外拦截，勿扰和专注模式交给系统处理。
  - 强提醒卡片在休息遮罩显示时等休息结束再弹；开会或全屏时最多等 30 分钟（复用 `maxDeferral` 的思路），等不到就降成只弹横幅。
- **错过的提醒**：Mac 合盖或关机期间到点的提醒，开机后发一条汇总通知「你不在的时候有 2 条提醒」，并记为「错过」。超过 12 小时的不再补发，只记录。
- **AI 新建提醒时告诉你**：store 里出现 AI 新建的提醒，App 会弹一条横幅「Claude 帮你建了提醒：每天 9:00、21:00 吃药」，带「撤销」按钮。客户端调用工具前本来就会征求你同意，这一层是兜底：万一 AI 理解错了，你能马上撤掉。
- **通知代理要统一**：系统只允许一个通知代理，现在被 `BreakNotifier` 占着。改成一个 `NotificationRouter` 统一接收，再按通知分类前缀（`break.` / `reminder.`）分发给各自处理。这是本次必须顺带做的小重构。

### 6. 数据结构（store.json，带 `schemaVersion`）
- `Reminder`：`id`、`title`、`messages[]`、`schedule`、`style`、`reason`、`createdBy`（客户端名，或「手动」）、`createdAt`、`updatedAt`、`startDate`、`endDate`、`maxOccurrences`、`state`（`active` / `paused` / `finished`）。
- `Occurrence`（每一次响铃的记录）：`reminderId`、`scheduledAt`、`outcome`（`done` / `snoozed` / `skipped` / `missed`）、`actedAt`。保留 90 天。
- `clients[]`：客户端名、最近一次连接时间。
- 版本号不认识（比如旧版小程序遇到新格式）时只读、不写，并返回错误「请更新歇一会」，防止旧版程序把新数据写坏。

### 7. 界面
- **菜单**：在「下次休息」下面加「接下来的提醒」，列最近 3 条（「21:00 吃抗生素」），再加一项「全部提醒…」。
- **设置侧边栏新增第 6 组「提醒」**，标题右侧用分段切换（和「休息」页同样的写法）：
  - 「我的提醒」：提醒列表，每条显示标题、用中文说的时间（「每天 9:00、21:00 · 还剩 4 天」）、来源标签（「来自 Claude」），以及暂停 / 删除按钮；点开看 `reason`、文案和最近完成记录。条数多时列表可以滚动；没有提醒时显示引导：「在 Claude 里说『每天 9 点提醒我吃药』试试」，附「去连接」按钮。
  - 「连接 AI」：第 3 节的安装按钮和连接状态，另有一行说明：「歇一会不调用任何 AI；提醒只存在这台 Mac 上，只有你的 AI 来读时才会作为对话内容发送出去。」这一段必须一屏放下。
- **不做手动新建的表单**：这正是你想避开的传统写法。新建只走 AI；App 里只能看、暂停、删除。

## 8. AI 工作感知（Claude Code + Codex）

### 数据从哪来（已查证）
| | Claude Code | Codex（命令行、桌面 App、IDE 插件） |
|---|---|---|
| 开始干活 | hook `UserPromptSubmit` | hook `UserPromptSubmit` |
| 在等你批准 | hook `PermissionRequest`、`Notification` | hook `PermissionRequest` |
| 干完了 | hook `Stop`（出错是 `StopFailure`） | hook `Stop` |
| 被打断 / 会话结束 | `SessionEnd` | `Interrupt`、`SessionEnd` |
| 额度 | 状态栏命令的输入里有 `rate_limits.five_hour` / `seven_day`（已用百分比、重置时间，Pro / Max 才有） | 本地会话记录 `~/.codex/sessions/年/月/日/rollout-*.jsonl` 里每轮的 `token_count` 事件带 `rate_limits`；**要按 `window_minutes` 区分**（300 = 5 小时、10080 = 一周），不能假定 primary 就是 5 小时窗口 |

- 两边 hook 的输入都带 `session_id`、`cwd`、`hook_event_name`，所以可以按会话区分，显示「项目名 · 状态」。
- hook 的命令就是同一个小程序：`restbreak-mcp hook claude` / `restbreak-mcp hook codex`。它从标准输入读事件，**只取会话 id、项目文件夹名、事件名和时间**，写进共享目录的 `agents.json`，然后发 Darwin 通知 `com.lizhiming.RestBreak.agents.changed`。`UserPromptSubmit` 带的提问原文、`Stop` 带的回答原文一律丢掉，不落盘。
- hook 必须几毫秒内结束、永远返回成功且不输出内容，绝不能拖慢或拦住 AI。
- 子代理（`SubagentStart/Stop`）不单独显示，只算在主会话里。
- 会话状态超过 30 分钟没有新事件就当作已结束（防止 AI 崩溃后一直显示「在干活」）。

### 额度怎么拿
- **Codex**（第 0 步：走第三方中转时 `rate_limits` 全为 null，这时设置页显示「你的 Codex 用的服务不提供额度信息」，额度相关功能自动隐藏）：在「连接 AI」页点「允许读取 Codex 用量」，用 `NSOpenPanel` 选 `~/.codex` 文件夹，存安全书签（复用照片文件夹那套写法）。每次收到 Codex 的 `Stop` 事件时，读最新会话文件的最后一条 `token_count`。只读这一条，不读对话内容。
- **Claude Code**：hooks 拿不到额度，只有状态栏命令有。做法是在设置页给出一段状态栏配置：`restbreak-mcp statusline` 读到输入后存下额度，再把输入原样转给你原来的状态栏命令（如果有），所以不会弄丢你现在的状态栏。这一项可选，不配也不影响其他功能。
- 不调用任何非官方的额度接口，也不读钥匙串里的登录令牌。

### 歇一会用它做什么
1. **趁 AI 干活时休息**：有会话进入「在干活」且已经持续 1 分钟以上，并且下一次休息在 10 分钟内到期 → 把这次休息提前到现在，遮罩上写「Claude 在跑任务，正好起来走走」。提前规则和「日程前提前」共用一套：不在开会、不在全屏推迟、不在暂停时才提前。
2. **休息遮罩上显示 AI 状态**：底部一行小字，例如「Codex · 桌面闹钟 已完成」「Claude · RestBreak 在等你批准」。有会话在等你批准时显示「回去处理」按钮（等同于跳过这次休息，计入跳过次数）；严格模式下不显示这个按钮。
3. **AI 在等你时不弹休息**：有会话在等你批准时，到期的休息最多推迟 3 分钟，和全屏推迟共用 `maxDeferral` 的累计上限。
4. **额度提醒**：任何一个 5 小时窗口用到 90% 时弹一次横幅：「Claude 额度用了 90%，15:00 重置，可以安排去吃个饭」。用完后直到重置，菜单里显示「Claude 额度 15:00 恢复」。每个窗口每次重置前只提醒一次。
5. **任务完成提醒**：
   - 你对 AI 说「跑完提醒我」时，AI 调用新工具 `remind_when_done`，参数是当前会话、文案和强度。歇一会收到这个会话的 `Stop` 时按提醒的规则响铃。
   - 另有一个总开关「AI 干完后通知我」（默认关）：只在你离开电脑或者不在那个终端、App 里时才发通知。
6. **菜单和统计**：菜单栏加一行「AI：2 个在干活 · 1 个等你」，点开列出各会话。统计页加「和 AI 协作」：今天 AI 干活总时长、等你批准的平均时间、额度用到多少。

### 引擎改动
`tick(...)` 新增参数 `agents: AgentActivity`，内容是有没有会话在干活（以及干了多久）、有没有会话在等你。规则放进现有引擎，并扩展 `DaySimulationTests` 加入随机的 AI 会话事件。

## 分步交付
- **第 0 步：打通验证（约 1 天，先做，结果决定第 3、8 节走哪条路）**
  1. 沙盒 + App Group 的小程序，在 Claude Desktop、Claude Code、Codex（命令行和桌面 App）里都能调用一个 `ping` 工具；
  2. `.mcpb` 能否用绝对路径；
  3. 沙盒里的 `notify_post` 和 `NSWorkspace.openApplication` 能不能用；
  4. 小程序作为 Claude Code 和 Codex 的 hook 命令被调用时能写进 App Group 目录（Codex 会不会把 hook 也放进它自己的沙盒里运行）；Claude Code 插件、Codex 插件能否同时带 MCP 服务器和 hooks；
  5. Codex 会话记录里 `rate_limits` 的实际格式（本机真实文件）；Claude Code 状态栏输入里有没有 `rate_limits`（取决于你的订阅）；
  6. Archive 后用 `codesign -d --entitlements` 确认两个程序的权限都对。
- **第 1 步（0.5.0）：AI 派提醒**：数据存储 + 排期引擎 + 5 个工具 + 横幅与强提醒卡片 + 提醒页 + 连接页（Claude Desktop / Claude Code / Codex）+ 新建提醒的通知（带撤销）+ 通知代理重构。
- **第 2 步（0.6.0）：AI 工作感知**（第 8 节）：hooks 接入两家、`agents.json`、菜单 AI 状态、休息遮罩上的 AI 状态、趁 AI 干活时提前休息、等你批准时推迟休息、额度提醒、`remind_when_done`、统计「和 AI 协作」；两家的插件打包。
- **0.7 管家·情境、0.8 管家·记忆与简报**：见 `2026-10-23-butler-scenarios.md`。内容包括条件提醒（下班、回到电脑前、散会、空闲时）、内置关怀规则、打扰预算、关注事项（`remember`）、承诺追踪、晨间简报和下班收尾、节假日和调休、AI 巡检（借用 Claude / Codex 的定时任务）。0.5 的时间安排里加上 `yearly`（生日、纪念日）。
- **不做（写明原因）**：
  - claude.ai 网页、手机 App、ChatGPT 网页接入：它们只连得上公网上的 MCP 服务，需要我们自己架服务器、做账号和中转，和「数据不出本机」的原则冲突。（Codex 桌面 App 读本机配置，不受此限。）
  - Claude Desktop 普通聊天、VS Code 里的 Claude 侧边栏的工作感知：它们不触发 hooks。提醒工具照常能用。
  - 读对话内容、调用非官方额度接口、读登录令牌。
  - App 自己调用大模型：需要「想一想」的主动关怀交给 AI 巡检（见管家场景文档），App 仍然不接模型。

## 代码位置
- `Shared/`（主 App、小程序、测试三个 target 都编译）：`Reminder.swift`（模型、编解码、校验）、`ReminderStore.swift`（文件锁、原子写、版本号、Darwin 通知）、`ReminderTools.swift`（5 个工具的参数解析和逻辑，不依赖 MCP SDK，方便测试）。
- `Engine/ReminderPlanner.swift`、`Engine/ScheduleText.swift`（把时间安排转成中文描述）。
- 新 target `RestBreakMCP`（命令行程序）：`main.swift` 只负责把 SDK 的工具调用接到 `ReminderTools`。主 App 用 Copy Files 阶段把它放进 `Contents/MacOS`，单独配置权限文件（沙盒 + App Group）。
- `Shared/AgentActivity.swift`（hook 事件解析、`agents.json` 读写、会话超时）、`Shared/UsageParsers.swift`（Claude 状态栏输入、Codex `token_count` 解析）；小程序加 `hook claude|codex`、`statusline` 两个子命令；`Services/AgentMonitor.swift`（监听 `agents.json`、读 Codex 用量）；插件模板 `Plugins/claude/`、`Plugins/codex/`。
- `App/ReminderCoordinator.swift`、`Services/NotificationRouter.swift`、`Services/ReminderNotifier.swift`、`UI/ReminderCard.swift`、`UI/RemindersPage.swift`（「我的提醒」「连接 AI」两个分段）。
- 主 App 权限文件加上 App Group。

## 测试
- **Planner**：
  - 五种 `schedule` 的下次时间：跨零点、跨月、31 号遇上小月、闰年 2 月 29 日（含 `yearly` 平年）、`weekdays`、`endDate` / `maxOccurrences` 到了自动结束；
  - 10 分钟后再提醒、错过的判定（12 小时内补发、超过不补）；
  - 改时区后重新排期；
  - 未来 7 天最多登记 50 条；
  - 仿照 `DaySimulationTests`，用固定种子模拟 30 天随机操作，检查不变量：不重复响、不漏响、已结束的提醒不再响。
- **Store**：
  - 读写往返、版本号不认识时拒绝写入；
  - 用两个进程（测试里启动小程序）同时写 200 次，不丢数据。
- **Tools**：每个工具正常和出错的输入输出（尤其是过去时间、非法时间格式、超出上限）、返回里带 `now`、`createdBy` 记的是客户端名。
- **工作感知**：两家各事件的样例输入 → 正确状态，且落盘内容里没有提问和回答原文；30 分钟超时；Codex `rate_limits` 按 `window_minutes` 区分新旧两种格式；Claude 状态栏输入缺字段时不报错；状态栏转发后原状态栏输出不变；引擎「趁 AI 干活提前休息」「等你批准时推迟」在 `DaySimulationTests` 里加随机 AI 会话后不变量仍成立。
- **小程序端到端**：脚本把 `initialize`、`tools/list`、`tools/call` 写进小程序的标准输入，检查输出；再用 MCP Inspector 手动过一遍。
- **真机走查**（Claude Desktop，写成清单逐条打勾）：
  1. 「医生开了 7 天抗生素，一天三次饭后吃」→ 建成 `firm` 提醒，7 天后自动结束；
  2. 「下班提醒我买牛奶」→ AI 先问几点下班，再建 `once` 提醒（0.7 改成 `workEnd`）；
  3. 「这周药都按时吃了吗」→ 能正确回答；
  4. App 退出状态下建提醒 → App 被拉起，到点照常响；
  5. 合盖跨过响铃时间 → 开机后收到错过汇总；
  6. AI 新建提醒的横幅上点「撤销」→ 提醒被删除；
  7. 在 Codex 桌面 App 里说「每天 9 点提醒我吃药」→ 同样能建成；
  8. Claude Code 和 Codex 各开一个长任务 → 菜单显示「2 个在干活」，下次休息被提前，遮罩上能看到哪个干完了；
  9. Codex 弹出批准请求时休息到期 → 推迟不超过 3 分钟。

## 实现时的调整（0.5，2026-10-24）
1. `ReminderPlanner`、`ScheduleText` 放在 `Shared/` 而不是 `Engine/`：小程序返回「接下来 3 次」也要用。
2. 休息通知的分类保留原名 `upcoming.*`；`NotificationRouter` 按「以 `reminder.` 开头」分给提醒，其余给休息。
3. Claude Desktop 在 0.5 只提供「复制配置」（JSON）；`.mcpb` 导出等手动验证结果。Claude Code 用本地插件（插件里只带 MCP，hooks 到 0.6 再加）。
4. 第 0 步的 `hook` / `statusline` 子命令已删除，0.6 按第 8 节正式实现。
5. 小程序找 App 路径从 `Bundle.main.executableURL` 往上三层（计划里写的 `bundleURL` 对命令行程序不对）。
6. 「提醒」页放在侧边栏第 3 组（休息之后），两个分段：「我的提醒」「连接 AI」。
