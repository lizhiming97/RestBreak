# 鼠标组件验证记录

日期：2026-11-03。环境：Apple Silicon / macOS 26.6.2，Xcode 27.1。所有工作在 `codex/friday-mos` 独立 worktree；未改写 CC 的开发目录、main 或现有 PR。

## 已完成

- 基线主 App：259 个逻辑测试通过。
- 接入后主 App：260 个逻辑测试通过，含参数化共 304 次执行，0 失败。包括原有调度、提醒、截图和新组件固定入口/路径测试。
- 鼠标模块：10 个 XCTest 通过，覆盖 Mos 默认参数、收敛与停止、快速反向无旧方向尾巴、横向输入不清掉纵向惯性、取消清空、连续/手势/自身事件透传、两轴反转、目标元数据保留、细小位移累计和关闭时不安装 tap。
- 组件 Swift Release 与星期五 Release 构建完成。
- 独立组件和内嵌组件、组合主 App 的严格代码签名校验通过；主 App 保留 `com.apple.security.app-sandbox = true`，组件独立非沙盒，Bundle ID 分别为原有 `com.lizhiming.RestBreak` 与新增 `com.lizhiming.FridayMouse`。
- 从主程序实际证书提取 SHA-1，并使用 `security verify-cert -p codeSign -R ocsp -R require` 验证；解决本机两张同名 Apple Development 证书导致的选择歧义。未修改证书或钥匙串。
- 组件资源包含 LICENSE、UPSTREAM.md、README.md 和可独立构建的源代码归档；归档排除 `.build`、`dist` 和缓存。
- 对 CC 本地 `main@d38430c34069d853791380e68a8a1c78973d5378` 做内容三方合并预检，README、RestBreakApp、SettingsWindow 均能自动文本合并。未实际合并，不覆盖后续改动或运行语义。

修复了测试发现的两处真实数据问题：CoreGraphics 写一个 delta 字段会联动改变其他字段，因此反转必须先快照再写回；point delta 保存为整数，因此平滑输出跨帧保留小数余量，避免每帧丢失细小位移。

## CC 集成 review 修改（2026-11-03）

挑进本地 main 时对照 Mos 固定提交改了三处，组件测试增至 12 个：

- 事件监听去掉 `mouseMoved`：原版边滚边挪鼠标会清空剩余惯性（原始滚动已被吞掉，页面停在半路），且开启后每次挪鼠标都唤醒组件。Mos 不监听鼠标移动。
- 只在接收进程变化时重新起步：去掉「位置变化」「停顿 0.45 秒」两个重置条件，滑行中续滚不再断一下。
- 系统暂停监听（超时/用户输入）时就地重新启用，10 秒内最多 3 次（`TapRestartBudget`），Mos 同样自动恢复；去掉每 5 秒的健康检查，改为监听 `com.apple.accessibility.api` 通知，撤销权限立即停、刚授权自动开启。
- 主程序设置侧栏「鼠标」移到「菜单栏收纳」之后，和其他组件页放在一起。
- 用户要求设置不另开窗口：全部设置搬进星期五「设置 › 鼠标」页（复用原有开关、滑条和「添加 App」菜单），组件去掉窗口、菜单栏图标和 `--render-preview`，改读 App Group 设置；组件签名加 App Group 权限。主程序 294 个测试、组件 13 个测试通过；设置页用 `TEST_RUNNER_FRIDAY_MOUSE_PREVIEW=1 xcodebuild test -only-testing:RestBreakTests/MouseCompanionPagePreviewTests` 渲染检查过。

待真机确认：撤销辅助功能时系统是否总会发该通知（若不发，tap 会被系统禁用、走上面的恢复失败分支停下）。

## 用户反馈修复（2026-11-05）

用户开着「反转上下滚动」，按住 Ctrl 滚动缩放时方向和平时相反（肌肉记忆是 Ctrl+上滚放大）。原因：带 Ctrl/Command 的滚动在反转之前就原样放行了。改为先按设置反转、再决定是否平滑：修饰键和认不出接收进程时只反转不平滑，与 Mos 一致（Mos 的 blockSmooth 只挡平滑）。测试 `testCtrlAndCommandScrollKeepReversedDirectionButSkipSmoothing`。随 0.7.6 本地测试包。

## 状态（2026-11-03 晚）

已随 0.7.4 合进本地 main 并发布；下面「成品」「仍需真实鼠标试用」是 Codex 交 PR 时的记录，真机试用结果待补。

## 成品

- `MouseCompanion/dist/星期五.app`：包含鼠标组件的独立验证包，未安装、未替换当前运行实例。
- `MouseCompanion/dist/星期五鼠标.app`：独立组件。
- `MouseCompanion/dist/鼠标设置预览.png`：设置页渲染图片。
- 测试结果目录：`/tmp/friday-mos-main-derived/Logs/Test/`。

本分支基于 GitHub `origin/main@20e48f5`，因此组合包不包含 CC 本地 0.7.3、菜单栏收纳和剪贴板的后续改动。实际集成时应由 CC review 并挑拣功能提交到本地开发 main，重新构建带最新全部功能的包；不要用本验证包覆盖日用版本来判断其他功能是否保留。

## 仍需真实鼠标试用

没有开启系统输入接管，没有代替用户授予辅助功能，也没有通过脚本移动或滚动用户窗口。因此以下均未声称已验证：

- 普通鼠标在 Safari/Chrome、飞书、编辑器、Excel 的真实事件目标 PID 和最终手感。
- 辅助功能授权、撤销、重新启用后的完整 UI/输入链路。
- 真机锁屏/睡眠、显示器插拔、不同刷新率和快速应用切换。
- Logitech 驱动、远程桌面、Magic Mouse 的设备兼容性；本版对连续事件保守透传。
- 长时间 CPU/唤醒/能耗。DisplayLink 仅在滚动期间运行，已去掉定时检查和鼠标移动监听，仍需实测。

试用顺序：退出 Mos → 星期五设置「鼠标」打开组件 → 授权并启用 → 测试短滚、连续长滚、立刻反向、停手和横向 → 在排除应用测试原生行为 → 关闭增强确认原生滚动恢复。遇到异常可直接关闭或退出组件。真实试用前 PR 保持 Draft，由 CC review 后决定合并。
