# Time Out vs Stretchly：功能对比与自研 Mac 休息提醒应用方案

> 调研日期：2026-10-19
> 资料来源：Dejal 官网 Time Out 介绍页（v3.1）、Mac App Store 截图、Stretchly GitHub README 与 LICENSE

---

## 一、一句话概括

**Stretchly** 是一个"够用、免费、跨平台"的开源休息提醒器：两种固定休息类型（Mini / Long），按间隔轮转，界面是一块纯色窗口加一句休息建议，高级功能大多要手改 JSON 配置文件。

**Time Out** 是一个"深度为 Mac 打磨"的商业休息提醒器：休息类型可以无限添加、带优先级，支持定点/日历排程，有一套"规则引擎"智能避开会议和全屏，休息画面可以是视频/网页/照片主题，还有休息前后的自动化动作和活动统计。

简单说：**Stretchly 解决"提醒我休息"，Time Out 解决"让休息融入我的工作日"。**

---

## 二、基础信息对比

| 维度 | Stretchly | Time Out |
|---|---|---|
| 开发者 | Jan Hovancik（个人 + 社区） | Dejal Systems, LLC（David Sinclair） |
| 技术栈 | Electron（JS/HTML/CSS） | 原生 macOS（Swift/AppKit） |
| 平台 | macOS 13+、Windows、Linux | 仅 macOS（3.1 版要求 macOS 26，旧版 2.9.7 支持 10.15） |
| 开源 | 是，BSD 2-Clause 许可证 | 否，闭源 |
| 收费模式 | 免费；赞助者解锁"Contributor Preferences"和偏好同步 | 核心功能免费；Supporter（$4.99–$59.99 买断）或 App Store 订阅解锁高级功能；也在 Setapp 上架 |
| 签名/分发 | 仅 ad-hoc 签名，首次打开需绕过 Gatekeeper；Homebrew tap 安装 | App Store / 官网 / Setapp，正规签名公证 |
| 多语言 | 通过 Weblate 社区翻译，语言多（含中文） | App Store 显示仅英文 |
| 资源占用 | Electron 自带 Chromium，内存占用相对大 | 原生，轻量 |

---

## 三、核心功能逐项对比

### 1. 休息类型模型

| | Stretchly | Time Out |
|---|---|---|
| 休息种类 | 固定两种：**Mini break**（默认每 10 分钟休 20 秒）、**Long break**（每 2 次 Mini 后来一次，休 5 分钟） | 内置 **Normal** 和 **Micro** 两种，**可无限添加自定义休息**（如"午餐"、"拉伸"），也可禁用任意一种 |
| 休息之间的关系 | Long 是 Mini 的"第 N 次"，耦合死 | 每个休息独立计时，**按优先级排序**（拖动排序），有冲突处理规则 |
| 冲突处理 | 无需处理（只有一条时间线） | "完成更高优先级休息后重置本休息"、"若更高优先级休息在 N 分钟内到期则跳过本次" |

这是两者**最本质的差别**。Time Out 的"多休息 + 优先级"模型更灵活，也是自研时最值得借鉴的数据模型设计。

### 2. 排程方式

| | Stretchly | Time Out |
|---|---|---|
| 按间隔 | ✅ | ✅（如"每 1 小时"） |
| 固定时间点 | ❌ | ✅（如"每小时第 30 分钟"） |
| 围绕日历事件 | ❌ | ✅（读系统日历） |
| 可用时段 | ❌（只有"暂停到明早/日出"） | ✅ 每个休息可设"08:00–17:00，周一至周五"等 |
| 到期行为 | 直接开始（提前 10s/30s 通知） | 可选"直接开始" / "询问何时开始，N 分钟后自动开始" |

### 3. 自然休息（Natural Break / 闲置检测）

| | Stretchly | Time Out |
|---|---|---|
| 检测闲置 | ✅ 闲置 5 分钟则暂停休息计时，回来后重置 | ✅ |
| 可配置程度 | 闲置阈值需改配置文件（赞助者功能） | 每个休息单独配置：闲置时"继续倒计时"还是"闲置超过 X 分钟就重置" |
| 睡眠/锁屏 | ✅ 唤醒后重置（标注为不稳定） | ✅ |

### 4. 智能避让（会议、全屏、专注模式）

| | Stretchly | Time Out |
|---|---|---|
| 勿扰/专注模式 | ✅ 检测 DND 时暂停 | ✅ Focus 模式规则 |
| 全屏应用 | ❌ | ✅ |
| 指定 App 运行时 | ✅ `appExclusions`，但**只能改 JSON**，按进程名匹配 | ✅ 图形化 **Rules** 规则，按"正在使用某 App"匹配 |
| 日历事件期间 | ❌ | ✅ |
| 会议检测 | ❌ | ✅ 脚本识别 FaceTime / Teams / Zoom 通话 |
| 规则动作 | 只有暂停/恢复 | 推迟或跳过，并可选择"这段时间算作自然休息" |

Time Out 在这块明显领先，而且这是用户体验差异最大的地方——开会时弹出全屏休息是最让人想卸载提醒软件的场景。

### 5. 休息画面

| | Stretchly | Time Out |
|---|---|---|
| 样式 | 纯色窗口（可设颜色），可全屏或窗口，可透明/模糊背景 | 屏幕渐隐进入**主题**场景 |
| 内容 | 一句"休息建议"文字（可自定义，支持简单 HTML 和本地图片） | 主题可以是**图片、文字、YouTube 视频、网页、本地 HTML/CSS/JS** |
| 主题管理 | 无 | 内置主题浏览器，点击 Get 下载；单个/顺序轮换/随机 |
| 多显示器 | 全屏显示或只在一个屏显示内容 | **每个显示器可设不同主题** |
| 背景 | 固定颜色 | 固定色 / 随机色相 / 模糊效果 |

### 6. 休息控制与"强制力度"

| | Stretchly | Time Out |
|---|---|---|
| 推迟 | 默认可推迟 1 次（Mini 2 分钟 / Long 5 分钟），次数和时长可配 | 可推迟，可设推迟次数上限 |
| 跳过 | 经过一段时间后才能跳过 | 可跳过，可设跳过次数上限 |
| 提前结束 | 快捷键 Cmd+X | ✅ End Break |
| 严格模式 | ✅ Strict Mode（不能跳过） | 休息开始时短暂禁用按钮；可隐藏容易绕过的命令 |
| 手动结束 | ✅ 倒计时结束后需手动点 Finish | ✅ 保持在屏幕直到点 End Break |
| 控制面板 | 窗口底部链接 | 浮动控制面板，可淡出、鼠标靠近再出现 |
| 趣味设计 | **Break Health Mode**：跳过/推迟越多，屏幕边缘"游戏残血"红晕越重 | — |

### 7. 休息动作（自动化）

| | Stretchly | Time Out |
|---|---|---|
| 提前通知 | ✅ 系统通知（10s / 30s 前） | ✅ |
| 声音 | 开始/结束提示音，可换 WAV | ✅ 播放声音、**语音播报** |
| 系统控制 | ❌ | 调节系统音量、闪屏 |
| 脚本 | ❌ | **AppleScript、Shell、Python、Automator**，可在休息前/中/后执行，或绑定到自定义按钮 |
| 典型用法 | — | 休息开始暂停 Music → 播放白噪音 → 结束后淡出并恢复 Music |

### 8. 统计

| | Stretchly | Time Out |
|---|---|---|
| 活动记录 | ❌ | ✅ **Activity**：时间轴展示休息、App 使用、离开时间，可缩放 |
| 统计报表 | ❌ | ✅ **Statistics**：长期休息习惯回顾 |

### 9. 交互入口与其他

| | Stretchly | Time Out |
|---|---|---|
| 菜单栏 | ✅ 托盘图标，可显示"距下次休息时间"或进度 | ✅ 菜单栏手动开始休息、暂停、修改下次时间 |
| 全局快捷键 | ✅ 多个（暂停 30 分钟/1 小时/到明早、跳到下次等），但需改 JSON | ✅ 图形化设置 |
| 命令行 | ✅ `stretchly` CLI | ❌ |
| 第三方集成 | Alfred / Raycast 扩展 | 社区脚本（Extras 页面） |
| 偏好同步 | ✅（赞助者） | — |
| 企业部署 | ✅ 可隐藏更新、隐藏严格模式设置、自定义提示文本 | — |

---

## 四、差异总结

**Stretchly 的优势**：开源可参考、跨平台、免费、多语言（含中文）、CLI 和企业部署友好、Break Health Mode 这种小巧思。

**Stretchly 的短板**：很多实用配置藏在 JSON 文件里、休息模型简单僵硬、不会识别会议/全屏、休息画面单调、没有统计、Electron 体积大、macOS 上没有正式签名。

**Time Out 的优势**：灵活的多休息优先级模型、强大的规则引擎、精美主题、自动化动作、活动统计、原生体验。

**Time Out 的短板**：闭源、仅英文、新版只支持 macOS 26、设置项非常多（新手门槛高）、高级功能付费。

---

## 五、自研方向建议

### 差异化机会

如果你要做自己的版本，以下几点是两者都没做好、或你有天然优势的地方：

1. **中文本地化 + 本土化内容**：Time Out 只有英文。可以内置眼保健操、八段锦片段、颈椎操、20-20-20 护眼法则等中文休息建议，这是很容易出彩的点。
2. **"零配置也好用"**：Time Out 功能强但设置复杂，Stretchly 高级功能要改 JSON。做一个默认就聪明（自动识别会议和全屏）、需要时才展开高级设置的产品。
3. **免脚本的会议检测**：Time Out 用脚本识别 Zoom/Teams。macOS 上可以直接检测"麦克风/摄像头是否正被占用"，对所有会议软件（包括腾讯会议、飞书、钉钉）通用。
4. **借鉴 Stretchly 的 Break Health Mode**：用游戏化方式反馈"你最近跳过太多次了"。
5. **轻量原生**：用 Swift 写，体积和内存远小于 Electron。

### 推荐技术栈：Swift + SwiftUI（必要处用 AppKit）

理由：只做 Mac 的话，原生方案在菜单栏、全屏覆盖窗口、多显示器、系统事件监听上都比 Electron/Tauri 更可控，也更省资源。

### 关键功能对应的 macOS API

| 功能 | 实现方式 |
|---|---|
| 菜单栏常驻 | SwiftUI `MenuBarExtra`，或 AppKit `NSStatusItem`；`Info.plist` 设 `LSUIElement = YES` 隐藏 Dock 图标 |
| 全屏休息遮罩 | 为每个 `NSScreen` 创建无边框 `NSWindow`/`NSPanel`，`level` 设为 `.screenSaver`，`collectionBehavior` 含 `.canJoinAllSpaces`、`.fullScreenAuxiliary`，以覆盖其他 App 的全屏空间 |
| 闲置检测 | `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)`（即 kCGAnyInputEventType），无需额外权限 |
| 睡眠/锁屏 | `NSWorkspace` 的 `willSleepNotification` / `didWakeNotification`；`DistributedNotificationCenter` 监听 `com.apple.screenIsLocked` / `screenIsUnlocked` |
| 前台 App 识别 | `NSWorkspace.shared.frontmostApplication` 和 `didActivateApplicationNotification` |
| 全屏 App 检测 | `CGWindowListCopyWindowInfo` 比对前台窗口尺寸与屏幕尺寸（读取窗口边界不需要屏幕录制权限） |
| 会议检测 | CoreAudio 查询输入设备的 `kAudioDevicePropertyDeviceIsRunningSomewhere`，判断麦克风是否被占用 |
| 日历排程 | `EventKit`（需日历权限） |
| 提前通知 | `UserNotifications` |
| 语音播报 | `AVSpeechSynthesizer`（支持中文语音） |
| 视频/网页主题 | `AVPlayerLayer` / `WKWebView` |
| 全局快捷键 | 开源库 `KeyboardShortcuts`（sindresorhus），或 Carbon `RegisterEventHotKey` |
| 开机启动 | `SMAppService.mainApp.register()`（macOS 13+） |
| 数据存储 | 设置用 `UserDefaults`/`@AppStorage`；休息记录用 `SwiftData` |
| 统计图表 | `Swift Charts` |
| 执行脚本 | `NSUserAppleScriptTask`（沙盒内）或 `Process`（非沙盒） |

> 注意：专注模式（Focus）状态的读取在公开 API 中比较受限（`INFocusStatusCenter` 需要特定能力且只返回是否专注），这块需要实际验证可行性。若计划上架 App Store，沙盒会限制执行任意脚本，需要权衡。

### 核心数据模型（借鉴 Time Out）

```swift
struct BreakDefinition: Identifiable, Codable {
    var id: UUID
    var name: String               // "微休息" / "长休息" / "午餐"
    var isEnabled: Bool
    var priority: Int              // 数字越小优先级越高
    var duration: TimeInterval     // 休息时长
    var schedule: Schedule         // .interval(3600) / .fixedTime(minute: 30) / .calendar
    var availability: Availability // 时间段 + 星期
    var naturalBreakPolicy: NaturalBreakPolicy // 闲置时继续计时 / 超过 N 分钟重置
    var postponeLimit: Int
    var skipLimit: Int
    var strictMode: Bool
    var theme: ThemeRef
}
```

调度器本质是一个每秒 tick 的状态机：对每个启用的休息计算"下次到期时间"，结合闲置状态、规则引擎（会议/全屏/指定 App）和优先级冲突，决定是否触发、推迟或跳过。

### 分阶段路线

**阶段 1（MVP，约 1–2 周）**：菜单栏图标 + 倒计时；两种休息（微休息、长休息）按间隔触发；多显示器全屏遮罩 + 倒计时 + 中文休息建议；推迟 / 跳过 / 提前结束；闲置自动重置；开机启动；基础设置界面。

**阶段 2（智能化）**：会议检测（麦克风占用）和全屏检测时自动推迟；指定 App 规则；提前通知；提示音和语音播报；全局快捷键；自定义休息类型与优先级。

**阶段 3（体验与数据）**：图片/视频主题、每屏不同主题、模糊背景；休息记录与统计图表；Break Health Mode 类游戏化反馈；日历排程与可用时段。

**阶段 4（可选进阶）**：休息动作（暂停/恢复音乐、执行脚本）；主题市场；iCloud 同步设置。

---

## 六、关于参考 Stretchly 源码

Stretchly 采用 **BSD 2-Clause** 许可证，允许你阅读、借鉴甚至复用其代码，只需在源码和二进制分发中保留原版权声明和免责声明。不过它是 Electron/JS 写的，如果你用 Swift 原生开发，主要参考价值在于：休息调度逻辑（`app/breaksPlanner.js`）、默认参数、休息建议文案库、各种边界情况的处理（睡眠唤醒、多显示器等）。

Time Out 是闭源商业软件，只能参考公开的功能设计，不要复制其主题素材、图标、文案等受版权保护的内容。
