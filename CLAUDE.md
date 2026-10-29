# 项目：星期五（原名「歇一会」，工程名 RestBreak）——Mac 菜单栏的休息提醒 + 贴身管家

> 这份文件只放**当前状态、规则、偏好、坑和文档索引**。各功能的实现细节在 `docs/项目细节.md`（按阶段分节），设计和计划在 `docs/superpowers/`，每次改了什么看 `git log`。改完功能要同步更新对应的地方，这里只留结论。

## 当前状态（2026-10-29）
- 版本 **0.7.0**（改名「星期五」后的第一个正式包），已合进 main；GitHub（`lizhiming97/RestBreak`，**2026-10-29 起公开开源，MIT**）上只有一个「星期五 0.7.0」提交，标签 `v0.7.0`，DMG 挂在 GitHub Releases。DMG `发布/星期五-0.7.0.dmg`，用户装到「应用程序」开始深度体验，问题攒着统一调整。0.6.2 没有单独发，两个修复（菜单开着时截图快捷键、首次点设置不弹窗）都在 0.7.0 里。
- 0.7 内容：App 只做「嘴」（灵动岛 + 到点提醒 + 推送关卡），说什么由用户主要用的 Agent 巡视后 `push`；接入是**本机 MCP 地址 + 密钥**（`http://127.0.0.1:38128/mcp`，服务名 `friday`，像瑞幸 MCP 一样交给用户的 AI 自己加，**不扫描用户的 App**），另给巡视任务说明（**定时间隔由用户在自己的 AI 应用里设**）；设置「提醒」页只有「功能接入 / 记录」两个分段，**留意什么写在 Agent 的定时任务里，App 不重复配置**（用户要求，不要再加回关注方向）。细节见 `docs/项目细节.md` 第七阶段。
- 用户在体验中提过、先不改的：站会结束后马上弹休息（开会/离开判定有偏差，原因和两种改法见 2026-10-29 的对话：麦克风开着但人没看屏幕、短暂离开不满 5 分钟；用户说再用一段时间再定）。

- 待用户手动验证的旧项：`docs/superpowers/specs/2026-10-23-agent-step0-findings.md` 末尾的清单（Claude Desktop `.mcpb`、ChatGPT App 里的 Codex 等）。

## 背景与工作方式
- 目标：macOS 菜单栏休息提醒 App（类似 Time Out / Stretchly），逐步扩展成「电脑上的贴身管家」：主动、准时、有温度地提醒，不只管健康。主要自用，以后想上架 Mac App Store。竞品调研见 `TimeOut与Stretchly功能对比及自研方案.md`。
- 用户不熟悉 Swift：代码里写清楚的中文注释；每完成一步，用通俗中文说明改了什么、怎么在 Xcode 里验证。用户在 Xcode 里用方块停止、三角运行，不做别的操作。
- 用户授权「全部做完再报告」时就一次做完，中途不问；有真机才能验证的，做完列清单让用户试。

## 已确定的技术决策
- Swift 6 + SwiftUI，必要处用 AppKit。部署目标 macOS 14.0。工程 `RestBreak`，显示名「星期五」（2026-10-29 由「歇一会」改名），Bundle ID `com.lizhiming.RestBreak`。**改名只改显示名和界面文字；Bundle ID、App Group、钥匙串、通知名、`XIEYIHUI_STORE` 等内部标识一律不改**（改了会丢数据和权限）。MCP 服务名 `friday`（原 `xieyihui`）。
- 菜单栏 App：`LSUIElement = YES`，`NSStatusItem` + `NSMenu`。
- App Sandbox + Hardened Runtime。签名用免费个人团队（`DEVELOPMENT_TEAM = B45N72QF4V`，`Apple Development`）；命令行编译、测试要加 `-allowProvisioningUpdates`。
- `GENERATE_INFOPLIST_FILE = YES` + `INFOPLIST_KEY_*`，不单独放 Info.plist。
- 三个 target：主 App `RestBreak`、AI 用的命令行小程序 `RestBreakMCP`（产物 `restbreak-mcp`，放进 `Contents/MacOS`）、测试 `RestBreakTests`。`Shared/` 文件夹三方共用。唯一的第三方依赖是 MCP Swift SDK（0.12.x），只有小程序链接。
- **歇一会自己不调用任何大模型**。AI 通过 MCP 建提醒、推送、看现状；到点触发只由 App 里写死的代码负责。
- **编译和测试**（用单独的编译目录，不覆盖用户在 Xcode 里运行的那份）：
  ```
  cd RestBreak
  DD="$HOME/Library/Developer/Xcode/DerivedData/RestBreak-xieyihui-spike"
  xcodebuild -scheme RestBreak -configuration Debug -derivedDataPath "$DD" build -allowProvisioningUpdates
  xcodebuild test -scheme RestBreak -destination platform=macOS -derivedDataPath "$DD" -allowProvisioningUpdates
  ```
  2026-10-26 共 261 个测试。改了调度规则，`DaySimulationTests`（逐秒模拟 20 个工作日）和 `AdaptiveTickTests`（逐秒和按需两种跑法，结果必须一致）必须跑通。
- 不要用 `open` 命令替用户启动 App：Xcode 调试器挂着的旧实例关不掉，会留下两个实例（`SingleInstance` 的规则是新启动的留下）。
- 直接运行小程序、访问 App Group、跑 `codesign` / `hdiutil` 这类命令，要在 shell 沙盒外执行。

## 开源（2026-10-29）
- 仓库公开，MIT 许可证，根目录 `README.md` 面向外部用户。
- **GitHub 上只放「当前版本」**（用户要求）：远端只有 `main` 一个分支、每个版本一个提交、只有最新版本的标签和 Release；**完整开发历史只在本地 `main`**。本地分支 `public` 跟踪 `origin/main`，本地 `main` 不跟踪远端，**绝不能 `git push origin main`**（会把全部历史推上去）。发布新版本：
  ```
  S=$(git commit-tree "main^{tree}" -p public -m "星期五 X.Y.Z …")   # 用本地 main 的内容在 public 上叠一个提交
  git branch -f public $S && git push origin public:main && git push origin $S:refs/tags/vX.Y.Z
  ```
  然后 `gh release create vX.Y.Z` 上传英文名 DMG，删掉上一个版本的 Release 和标签（`gh release delete vA.B.C --cleanup-tag`）。只改文档也按这个流程推。**公开仓库里不能放别人的东西和任何密钥**：`设计/灵动岛参考/`（别人项目的截图）已从全部历史中清除并加进 `.gitignore`（清除前的完整备份在 `~/Desktop/Project_Hub/scratch/RestBreak-backup-before-filter-*.git`）。提交前照旧检查日志、临时测试、密钥。

## 发版
- 版本号改 `MARKETING_VERSION`，共 6 处，用 `sed` 统一替换 → 跑全部测试 → 提交 → `git tag -a vX.Y.Z`（本地）→ 按「开源」一节推到 GitHub（不要 `git push --tags`，也不要 push 本地 main） → `gh release create vX.Y.Z`，上传的 DMG 要用英文文件名（如 `Friday-X.Y.Z.dmg`，GitHub 会吞掉中文文件名）；README 的下载链接指向 Releases。
- 给别人试用的 DMG：`xcodebuild archive`（Release）→ 把 App 拷成 `星期五.app` → 加上「应用程序」快捷方式和 `先看我-安装说明.txt` → `hdiutil create -format UDZO`，输出到 `发布/`（已在 `.gitignore` 里）→ `hdiutil verify`，挂载后检查签名和版本。没有付费开发者账号，没法公证：对方第一次打开要在「隐私与安全性」点「仍要打开」，说明里写了。公开发布要等付费账号（Developer ID + 公证）。
- 推送前检查有没有误提交：日志、临时测试（`ZZ*Tmp*`）、密钥。腾讯云翻译密钥存在钥匙串里，绝不能打进包。

## 用户明确的偏好与禁忌（不要违反，不要再提）
- **性能要做到极致**：「像没有这个程序一样，丝毫不占资源」（见下一节）。
- 不要：休息结束提示音、休息前提前通知、自定义休息类型、语音播报、视频背景、手动新建提醒的表单（新建只走 AI）。
- 「休息」等分段设置页必须在 760×600 窗口里一屏放下、不滚动（「截图」「提醒」页可以滚动）。
- 设置窗口不能出现在别的 App 的全屏界面里（打开时切回桌面）。
- 灵动岛：纯黑底、深色平分按钮，**不要亮色实心按钮**，强提醒用细描边 + 光晕，**不压暗屏幕**；用户嫌第一版难看，不要退回去。
- 菜单要信息密度高、窄：「立即开始」合在倒计时行右侧，「接下来的提醒」只在 24 小时内有提醒时显示。
- 休息期间不能切走（锁住 ⌘Tab 和切桌面空间）。
- 搁置、未经用户同意不要开始做：Break Health Mode（屏幕残血红晕、健康值等）。

## 性能规则
- **不轮询，等事件**：
  - 麦克风用 `MicrophoneWatcher`（CoreAudio 属性监听）；
  - 全屏用 `FullscreenWatcher`（切 App、切桌面空间、屏幕变化时重算）；
  - 离开时才装全局鼠标监听，回来就拆；
  - 这些事件都调 `BreakCoordinator.kickTick()`，立刻 tick 一次。
  - **不要在 tick 里加跨进程调用**（CoreAudio、CGWindowList、EventKit 等）。
- **tick 只在状态可能变化时醒**：间隔由 `BreakScheduler.nextTick(now:)` 决定。
  - 准时醒的时刻：休息开始 / 结束、暂停到点、会后 60 秒缓冲结束，唤醒误差 0.1 秒；
  - 菜单栏倒计时换数字时也醒，最长 60 秒一次，误差 2 秒；
  - 推迟中逐秒。
  - 平均每天约 2700 次（逐秒是 28800 次）。
- **少写盘**：
  - 统计：有变化时最多 15 分钟写一次，有休息事件、睡眠、退出时立即写；
  - 提醒数据：`checkedAt` 放在内存里，只有提醒或记录真的变了才写 `store.json`；
  - 管家现状：`context.json` 只在 AI 来要时才写。
- **不用的东西不加载**：
  - 不开日历功能就不连 EventKit；
  - 不预热 ScreenCaptureKit；
  - 设置窗口、灵动岛用完就释放；
  - 截图窗口截图时才建，3 分钟不用就释放。
- **AI 小程序**：用自己写的 `QuietStdioTransport`（阻塞读），空闲时 0% CPU、0 次唤醒。**升级 SDK 时不要换回 SDK 自带的 `StdioTransport`**：它每 10 毫秒轮询一次，空闲也占约 1.1% CPU。
- 测真实耗电：用 Release 版 + 活动监视器「能耗」页。Xcode 的 Energy Impact 是 Debug 版加调试器的数字，进程被调试器暂停时还会显示异常值。2026-10-26 实测运行中：CPU 约 0.06%，每分钟唤醒约 2 次，内存约 21 MB，不写盘。

## 并发写法约定
- UI 类和调度器标 `@MainActor`。计时器用 `Task` + `Task.sleep(for:tolerance:)`；要在菜单跟踪时也跑的用 `Timer` 加到 `.common` 模式。
- 系统通知用 selector 方式的 `addObserver(self, selector:...)`，避免闭包的 Sendable 报错。
- Darwin 通知（跨进程）的 C 回调不能捕获变量：用 `DispatchQueue.main.async` 转发成进程内通知。

## 常见的坑（细节见 docs/项目细节.md 对应一节）
- 菜单栏 App 切换 activation policy 是异步生效的：**先切 policy，下一轮 runloop 再建窗口、激活**（设置窗口、休息遮罩都踩过）。但 `NSApp.activate()` 要在用户点击的处理函数里**同步**调用：macOS 14 起延后的激活请求会被拒（重试也没用），窗口会压在当前 App 后面（2026-10-28 用日志查实）。
- 歇一会自己的菜单开着时，Carbon 全局快捷键要等菜单关掉才送到。现在菜单开着时用计时器看键盘状态，自己处理截图和贴图快捷键。
- 设置窗口：SwiftUI 视图要外包一层普通 NSView，否则窗口会被撑到 632、底部出现白边。测试必须 `orderFrontRegardless` 后再检查。
- 灵动岛布局：黑色形状按当前阶段的大小画，内容用 overlay 叠上去，收起态内容固定宽度，否则展开的内容会把收起态撑宽。
- 小程序找 App 路径：要从 `Bundle.main.executableURL` 往上数三层。主 App 不能把小程序当子进程启动（沙盒里套沙盒会崩）。
- 新加的 MCP 只在新对话（或重启 AI 应用）后生效，同一个对话里调不到；接入说明里要提醒。AI 的沙箱里不能直接运行 `restbreak-mcp`（套沙盒会崩），所以接入只能走 MCP。
- 同一个 MCP 命令既手动加过、又装了插件时，Claude Code 会把插件里那份当重复去掉（0.7 起不再生成插件）。不推荐用 `codex mcp add`，它会重写整个 `config.toml`。
- `context.json` 的时间要用带小数的秒（`ButlerContext.fileEncoder`）：ISO 8601 只到整秒，会把刚写的现状误判成旧的。
- 录屏授权绑定代码签名，签名一变旧授权就失效。排查时用 `tccutil reset ScreenCapture com.lizhiming.RestBreak`。
- 中文系统下 SF Symbols 的 `textformat` 会显示成「格式」两个字：给图标加 `.environment(\.locale, en_US)`。

## 文档索引
- `docs/项目细节.md`：各阶段的实现细节和规则。包括：
  - MVP、调度引擎、只运行一个实例；
  - 会议、全屏、指定 App、快捷键；
  - 日历（Mac / 钉钉）、统计、背景主题；
  - 设置窗口样式；
  - 截图、标注、OCR 翻译；
  - AI 派提醒（0.5）、管家骨架（0.6）、App 只做「嘴」（0.7）。
- `docs/superpowers/specs/`：各功能的设计文档。管家方向以 `2026-10-28-agent-driven-redesign.md` 为准（App 只做「嘴」）；`2026-10-24-butler-v2-design.md` 的五种来意、推送关卡仍有效，内置规则和 0.7 / 0.8 规划已被取代。
- `docs/superpowers/plans/`：各次的实现计划。开头一行「状态」写明是否完成；以后新的计划做完一步就打勾，当作进度表。
- `对外文档/`：项目介绍和开发复盘（给别人看的）。
- `设计/`：图标、提醒样式效果图、灵动岛参考截图。
