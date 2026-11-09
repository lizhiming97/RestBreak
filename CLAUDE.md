# 项目：星期五（原名「歇一会」，工程名 RestBreak）——Mac 菜单栏的休息提醒 + 贴身管家

> 这份文件只放**当前状态、规则、偏好、坑和文档索引**。各功能的实现细节在 `docs/项目细节.md`（按阶段分节），设计和计划在 `docs/superpowers/`，每次改了什么看 `git log`。改完功能要同步更新对应的地方，这里只留结论。

## 当前状态（2026-11-03）
- **当前正式版 0.7.7**（2026-11-09 发布到 GitHub：标签 `v0.7.7`，Release 附 `Friday-0.7.7.dmg`，叠在 0.7.6 之上）：0.7.6 + 长截图（第二版：参考 Snow Shot 的设计，画面流 + 每帧和上一帧比、累计位置 + 分格投票；自动滚动由鼠标组件直接发给选区中间的窗口，不挪光标；细节见 `docs/项目细节.md`「长截图」）+ 识别结果面板高度封顶 + 长图窗口工具栏独立顶栏。用户试用认可效果。
- **0.7.6**（2026-11-05 发布，已被 0.7.7 取代：标签 `v0.7.6`，Release 附 `Friday-0.7.6.dmg`，叠在 0.7.5 之上；用户试用确认没问题）：`发布/星期五-0.7.6.dmg` = 0.7.5 + 修复「点开收起的图标后所有图标跑出来、开关变灰」（换桌面时放开了分隔符并禁用开关）+ 收起图标左键调到前台、右键开菜单 + 修复鼠标顺滑开了反转时 Ctrl/Command 缩放方向反了（11-05 重打包含这些）。
- 收纳的坑：点开收起图标时对方应用常会切桌面，`environmentChanged` 不能放开分隔符；打开统一在主屏副本上移动（外接屏副本临时移动会连续失败）。
- **0.7.5**（2026-11-04 发布，已被 0.7.6 取代：标签 `v0.7.5`，Release 附 `Friday-0.7.5.dmg`，叠在 0.7.4 之上）：0.7.4 + 修复每天零点闪退（用户反馈「每天早上星期五进程没了」，崩溃报告 `RestBreak-2026-11-04-000006.ips`）。本地 DMG `发布/星期五-0.7.5.dmg`。待用户过一夜确认不再闪退。
- **坑：系统从后台线程发 `NSCalendarDayChanged` / `NSSystemClockDidChange` / `NSSystemTimeZoneDidChange`**。不能用 `addObserver(self, selector:)` 指向 `@MainActor` 方法（Swift 线程检查直接崩溃），一律用 `MainThreadObserver.observe`（`queue: .main`）。测试 `MidnightNotificationTests`。
- **0.7.4**（2026-11-03 发布，已被 0.7.5 取代：标签 `v0.7.4`，Release 附 `Friday-0.7.4.dmg`，叠在 0.7.2 之上；用户同时在长期试用这个包，问题攒着下一版改）：`发布/星期五-0.7.4.dmg` = 0.7.3 + 鼠标组件（`Contents/Helpers/` 里同时有收纳和鼠标两个组件）+ 设置侧栏改名 + `get_context` 补了今天推迟/最后休息/开会时长/下次休息等数据和新的巡视任务说明（用户要重新复制给 Codex），用户装来真机试。两个组件的源码就在公开仓库里，包内也带源码归档。打包：`scripts/build-menu-bar-experiment.py --output <目录>` → `MouseCompanion/scripts/build_app.py --main-app <目录>/星期五.app`（产物在 `MouseCompanion/dist/星期五.app`）→ 按「发版」做 DMG。
- 0.7.3 本地测试包（2026-11-03，没单独发）：0.7.2 + 菜单栏收纳，内容都在 0.7.4 里。
- 0.7.2（2026-11-03 发布，已被 0.7.4 取代）= 0.7.1 的休息合并 + 剪贴板历史。下面 0.7.0 / 0.7.1 两条是历史记录。
- 版本 **0.7.0**（改名「星期五」后的第一个正式包），已合进 main；GitHub（`lizhiming97/RestBreak`，**2026-10-29 起公开开源，MIT**）上只有一个「星期五 0.7.0」提交，标签 `v0.7.0`，DMG 挂在 GitHub Releases。DMG `发布/星期五-0.7.0.dmg`，用户装到「应用程序」开始深度体验，问题攒着统一调整。0.6.2 没有单独发，两个修复（菜单开着时截图快捷键、首次点设置不弹窗）都在 0.7.0 里。
- 0.7 内容：App 只做「嘴」（灵动岛 + 到点提醒 + 推送关卡），说什么由用户主要用的 Agent 巡视后 `push`；接入是**本机 MCP 地址 + 密钥**（`http://127.0.0.1:38128/mcp`，服务名 `friday`，像瑞幸 MCP 一样交给用户的 AI 自己加，**不扫描用户的 App**），另给巡视任务说明（**定时间隔由用户在自己的 AI 应用里设**）；设置「Agent主动关怀」页（原「提醒」）只有「功能接入 / 记录」两个分段，**留意什么写在 Agent 的定时任务里，App 不重复配置**（用户要求，不要再加回关注方向）。细节见 `docs/项目细节.md` 第七阶段。
- 用户在体验中提过、先不改的：站会结束后马上弹休息（开会/离开判定有偏差，原因和两种改法见 2026-10-29 的对话：麦克风开着但人没看屏幕、短暂离开不满 5 分钟；用户说再用一段时间再定）。
- **0.7.1 本地测试包**（2026-10-30）：`发布/星期五-0.7.1.dmg`，只给用户自己装来体验，**没推 GitHub、没打标签、没发 Release**。内容：微休息和长休息挨得太近时合并成长休息（临近合并 + 会前合并），设计 `docs/superpowers/specs/2026-10-29-break-merge-design.md`，规则见 `docs/项目细节.md`「调度引擎设计」。用户体验没问题后，再和攒着的其他问题一起正式发版（到时按「发版」一节补标签、推 GitHub）。

- **剪贴板历史**（2026-11-03，Codex 做的 PR 1，挑进本地 main 后随 0.7.2 发布，PR 1 已关闭）：默认关闭，开启后记录文字和图片，搜索 / 固定 / 纯文本复制 / 排除应用，普通历史超过 7 天自动清理（固定的保留），菜单「剪贴板历史…」、设置「剪贴板」页、全局快捷键三个入口；数据在 `~/Library/Application Support/FridayClipboard`（沙盒容器内）。审查时修了：面板里「清空全部」确认框会把面板一起关掉、快捷键在「快捷键」页重复出现。**待用户真机试**：面板里的「清空全部历史…」、超过 7 天的历史是否被清掉、锁屏/睡眠后是否停止记录。以后别的 AI 交来的 PR 也**不要在 GitHub 上直接合并**：挑进本地 main，随发版推上去后关 PR。**自动粘贴（实验）用户说用不到，已去掉，不要再加回来。**实现与验证细节见 `docs/clipboard/`。

- **鼠标组件**（2026-11-03，Codex 做的 PR 2，CC review 修改后挑进本地 main，随 0.7.4 发布，PR 2 已关闭、远端分支已删；2026-11-03 用户装上 0.7.4 后反馈功能使用正常。Codex 的 PR 工作目录和 `codex/*` 本地分支已清理）：见下面「鼠标组件」一节。

- **设置侧栏名字**（2026-11-03 用户定的）：休息统计、休息间隔、Agent主动关怀、会议避让、外观与快捷键、历史剪贴板、截图、菜单栏收纳、鼠标顺滑。名字就是 `SettingsPage` 的 rawValue，界面文字里提到页面时用这些名字。
- **休息判断用不上剪贴板、鼠标数据**（2026-11-03 评估）：在不在电脑前靠系统的「距上次键鼠输入」，滚轮、复制早已包含在内；要更细只能常驻监听输入，违背性能规则。真正可改的是用户 10-29 提的「站会后马上弹休息」（开会时长时间没碰键鼠可算眼睛休息过），用户还没决定。

- 待用户手动验证的旧项：`docs/superpowers/specs/2026-10-23-agent-step0-findings.md` 末尾的清单（Claude Desktop `.mcpb`、ChatGPT App 里的 Codex 等）。

## 菜单栏收纳（2026-11-03 合并进 main，随 0.7.4 发布）
- 来自 `feature/menu-bar-shelf`（已合并）。主程序仍为 MIT＋沙盒；`MenuBarCompanion/` 是独立 GPL 组件，打包时放进 `星期五.app/Contents/Helpers/`，用户只装一个 App。
- 用户路径：星期五菜单顶部显示已收起图标（点开原菜单），「菜单栏图标 ▸」子菜单逐项开关，关菜单后一起生效。菜单栏只有星期五一个图标；组件随星期五启动/退出，启动时自动恢复收起选择。首次需在组件设置里授权并启用。
- 数据流：组件写 App Group `MenuBarShelf/snapshot.json`＋图标 PNG，星期五只读显示；星期五用 `friday-menubar://hide|show|open?key=<bundleID>#<序号>` 发命令。不要改用窗口编号（macOS 26 会在屏幕间互换）。
- 坑：macOS 26 收纳项被放到收纳区最左端，收纳/显示只验证分隔符哪一侧；分隔符位置系统不保存，组件自存偏移与收起列表；不能在 Swift Task/主队列块里直接 `NSApp.terminate`（卡死），先 `stop()` 再退出；KVO 观察 `NSRunningApplication` 要持有对象。
- 测试：组件 25 项、主程序 276 项、签名 5 项。设计与验证：`docs/menu-bar/2026-11-01-design.md`、`2026-11-03-multi-display-design.md`、`2026-11-03-menu-panel-design.md`、`2026-11-01-validation.md`。
- 下一步：用户长期试用 0.7.4；未测范围（「单独空间」开启、三屏、macOS 14/15、超宽滚动）见验证记录。
- 构建：`python3 scripts/build-menu-bar-experiment.py`；组件测试：`swift test --build-system native --package-path MenuBarCompanion`。

## 鼠标组件（2026-11-03 合并进本地 main，随 0.7.4 发布）
- `MouseCompanion/` 是独立非沙盒 App `星期五鼠标.app`（Bundle ID `com.lizhiming.FridayMouse`），复用 Caldis/Mos 的平滑滚动核心，**许可 CC BY-NC 4.0（非商业）**，不适用主程序 MIT。**上架 App Store 或商业化前必须整个剥离**（Mos 作者也明确不许上 App Store），剥离方法见 `MouseCompanion/UPSTREAM.md`。
- 用户路径：设置「鼠标」页里直接开「鼠标增强」→ 点「去授权」给「星期五鼠标」辅助功能 → 调方向、手感、排除 App。**所有设置都在星期五这一页，组件不要再有自己的窗口或菜单栏图标**（用户要求）。默认关闭；只处理普通滚轮，触控板/Magic Mouse/连续事件原样放行；检测到 Mos 运行时不接管。
- 数据流：星期五写 App Group `MouseCompanion/config.json`，组件写回 `status.json`，各发 Darwin 通知 `com.lizhiming.RestBreak.mouse.config|status`；星期五用 `friday-mouse://launch|authorize` 拉起组件。`MouseSettings`（主程序）和 `ScrollConfiguration`（组件）字段名要一起改。组件只在增强开着且星期五运行时留下（例外：长截图自动滚动用 `friday-mouse://scroll` 拉起时，没开增强也留下，60 秒没命令就退出），打包放 `Contents/Helpers/`，签名带 App Group 权限。
- 规则：方向反转对所有普通滚轮生效，**按住 Ctrl/Command 只跳过平滑、不跳过反转**（用户肌肉记忆是 Ctrl+上滚放大，Mos 也这样；`ScrollEngine.applyDirection`）。不监听 `mouseMoved`、不定时检查（权限变化靠 `com.apple.accessibility.api` 通知）；系统暂停监听时就地恢复，10 秒内最多 3 次。别把这些改回去（理由见 `docs/mouse/2026-11-03-validation.md`）。
- 构建：先 `python3 scripts/build-menu-bar-experiment.py` 出含收纳的 App，再 `python3 MouseCompanion/scripts/build_app.py --main-app <该 App 绝对路径>` 加入鼠标组件。组件测试：`swift test --build-system native --package-path MouseCompanion`（14 项）。
- 下一步：用户真机试 0.7.4（验证清单见 validation 文档末尾）；合成事件只填像素位移，Excel/Java 类 App 是否响应待试。

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
  2026-11-03 共 299 个测试。改了调度规则，`DaySimulationTests`（逐秒模拟 20 个工作日）和 `AdaptiveTickTests`（逐秒和按需两种跑法，结果必须一致）必须跑通。
- 不要用 `open` 命令替用户启动 App：Xcode 调试器挂着的旧实例关不掉，会留下两个实例（`SingleInstance` 的规则是新启动的留下）。
- 直接运行小程序、访问 App Group、跑 `codesign` / `hdiutil` 这类命令，要在 shell 沙盒外执行。

## 开源（2026-10-29）
- 仓库公开，MIT 许可证，根目录 `README.md` 面向外部用户。
- **GitHub 上只放「当前版本」**（用户要求）：远端只有 `main` 一个分支、每个版本一个提交、只有最新版本的标签和 Release；**完整开发历史只在本地 `main`**。本地分支 `public` 跟踪 `origin/main`，本地 `main` 不跟踪远端，**绝不能 `git push origin main`**（会把全部历史推上去）。发布新版本：
  ```
  S=$(git commit-tree "main^{tree}" -p public -m "星期五 X.Y.Z …")   # 用本地 main 的内容在 public 上叠一个提交
  git branch -f public $S && git push origin public:main && git push origin "${S}:refs/tags/vX.Y.Z"   # zsh 里要写 ${S}，$S:r 会被当成修饰符
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
  - 例外：剪贴板历史开启时每 0.5 秒看一次剪贴板 `changeCount`（macOS 没有剪贴板变化通知，只能这样；没变化时不读内容、不写盘），关闭、暂停、锁屏、睡眠时停。
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
- `docs/mouse/`：鼠标组件的设计和验证记录（含 CC review 修改）。
- `docs/clipboard/`：剪贴板历史的调研、实现边界和验证记录（参考了 Maccy，MIT 声明在 `RestBreak/RestBreak/ThirdParty/`）。
- `docs/superpowers/specs/`：各功能的设计文档。管家方向以 `2026-10-28-agent-driven-redesign.md` 为准（App 只做「嘴」）；`2026-10-24-butler-v2-design.md` 的五种来意、推送关卡仍有效，内置规则和 0.7 / 0.8 规划已被取代。
- `docs/superpowers/plans/`：各次的实现计划。开头一行「状态」写明是否完成；以后新的计划做完一步就打勾，当作进度表。
- `对外文档/`：项目介绍和开发复盘（给别人看的）。
- `设计/`：图标、提醒样式效果图、灵动岛参考截图。
