# 上游来源与许可

- 项目：Ice，Jordan Baird and contributors
- 仓库：https://github.com/jordanbaird/Ice
- 固定提交：`11edd39115f3f43a83ae114b5348df6a0e1741cf`
- macOS 26 兼容参考：`macos-26` 分支固定提交 `6d74d25c33a9ab04307c1f222fbe68ad71847234`；取用目标坐标补偿、来源进程路由、点击进程屏障和双抬起序列。
- 取用日期：2026-11-01
- 许可证：GPL-3.0；完整原文见本目录 `LICENSE`。
- 本目录中的派生代码、新增控制器、演示应用及测试均按 GPL-3.0 提供。
- 根目录星期五主程序的 MIT 许可不授予本目录代码 MIT 使用权；分发组件时必须保留本说明、GPL 和对应源代码。

## 提取和调整

| 本地文件 | Ice 原文件 | 改动 |
|---|---|---|
| `IceCore/ItemEventDriver.swift` | `MenuBar/MenuBarItems/MenuBarItemManager.swift` 的移动/点击及事件辅助段 | 移除 AppState、主程序事件管理器、设置和后台缓存依赖；等待输入最多 2 秒；几何轮询每 10ms 让出线程；增加事件超时时间；点击屏障处理 tap 被系统停用并加无条件 500ms 超时（对应 Ice macos-26 的外层 `Task(timeout:)`） |
| `IceCore/EventTap.swift` | `Events/EventTap.swift` | 增加超时任务取消；tap 创建失败立即完成调用，避免 continuation 永久挂起；修正缺少 refcon 的事件引用计数；超时以任务取消判断，tap 被系统停用后仍会触发 |
| `IceCore/MouseCursor.swift` | `Utilities/MouseCursor.swift` | 保留光标隐藏、恢复和位置操作，日志命名空间改为组件 |
| `IceCore/TaskTimeout.swift` | `Utilities/TaskTimeout.swift` | 保留有界异步操作工具 |
| `SystemBridge.swift` | `Bridging/Bridging.swift`、`Bridging/Shims/Private.swift`、`WindowInfo.swift`、`ScreenCapture.swift` | 按需窗口枚举、私有 CGS 桥接、窗口图像捕获；直接用系统 AX API，去掉 AXSwift 依赖；补齐内存释放及计数边界检查 |
| `Models.swift` | `MenuBarItem.swift`、`MenuBarItemInfo.swift` | 精简模型和固定系统项排除规则，增加纯几何函数 |
| `ShelfController.swift` | `ControlItem.swift`、`tempShowItem` / rehide 机制 | 10000pt 占位隐藏；全新生命周期控制；串行操作、归位上下文、最多 120 秒等待、失败退避重试、手动强制归位、退出清理（最多等待 10 秒）；多屏按每屏分隔符锚定图标链（新增 `DisplayChain.swift`） |
| `ShelfPanel.swift` | `UI/IceBar/IceBar.swift` | 保留图像代理、横向滚动、左右键转发机制；使用系统材质；释放即销毁图像 |

没有带入上游图标/品牌资产、外观编辑器、搜索、快捷键系统、Sparkle、LaunchAtLogin、AXSwift、CompactSlider 或 Ifrit。

## 与星期五的边界

主 App 不 import 或链接此模块；独立的 `.app` 使用自己的 bundle ID、设置和系统授权。主程序通过 LaunchServices 启动，并发送 `friday-menubar://settings` / `friday-menubar://toggle` 两个 URL。二者不共享内存、模型或私有协议文件。采用独立程序分发的边界，不能解释成“将 GPL 改成 MIT”。若未来改为主程序直接链接模块，需要重新处理组合程序的 GPL 分发要求。
