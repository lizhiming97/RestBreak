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
- 用专用 `--render-preview` 路径渲染组件设置并查看图片。此路径不启动监听、不启用增强、不修改配置。开关采用蓝/灰和开/关文字，避免非激活窗口中状态不明显。
- 对 CC 本地 `main@d38430c34069d853791380e68a8a1c78973d5378` 做内容三方合并预检，README、RestBreakApp、SettingsWindow 均能自动文本合并。未实际合并，不覆盖后续改动或运行语义。

修复了测试发现的两处真实数据问题：CoreGraphics 写一个 delta 字段会联动改变其他字段，因此反转必须先快照再写回；point delta 保存为整数，因此平滑输出跨帧保留小数余量，避免每帧丢失细小位移。

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
- 长时间 CPU/唤醒/能耗。DisplayLink 仅在滚动期间运行，但开启后有每 5 秒一次健康检查，不能声称零耗电。

试用顺序：退出 Mos → 星期五设置「鼠标」打开组件 → 授权并启用 → 测试短滚、连续长滚、立刻反向、停手和横向 → 在排除应用测试原生行为 → 关闭增强确认原生滚动恢复。遇到异常可直接关闭或退出组件。真实试用前 PR 保持 Draft，由 CC review 后决定合并。
