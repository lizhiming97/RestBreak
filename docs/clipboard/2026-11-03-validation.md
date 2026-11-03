# 剪贴板验证记录

日期：2026-11-03。环境：MacBook Air arm64，macOS 26.6.2（25G83），本机 Xcode。

## 已完成

- 基线 `origin/main@20e48f5`：259 个测试通过，参数化共 303 次执行。
- 最终全量回归：273 个测试通过，参数化共 317 次执行，0 失败、0 跳过。
- 新增剪贴板测试 14 项，均通过；覆盖文本/图片回放、类型与应用排除、单项限制、多 item 跳过、去重与固定、容量限制、磁盘恢复、暂停基线、无变化不写盘、损坏数据保护、写盘失败重试、偏好隔离、锁屏与睡眠叠加、指纹边界与布局。
- 原有调度、提醒、截图、OCR、快捷键等测试随全套执行通过。
- 历史面板、图片缩略图和设置页通过 NSHostingView 实际渲染，并人工查看导出的图片。素材均为测试合成内容，不使用真实剪贴板。截图保存在本 worktree 的 `发布/剪贴板验证/`。
- Release 构建通过；成品 `codesign --verify --deep --strict` 通过；App 资源中包含 Maccy MIT 许可文件。
- `git diff --check` 通过。

最后一次全量结果：`/tmp/friday-clipboard-debug-final/Logs/Test/Test-RestBreak-2026.11.03_11-52-25-+0800.xcresult`。测试摘要的 273 是逻辑测试数，317 是含参数化的执行次数。

过程中曾发现测试截图写入沙盒外目录被拒，已改为测试应用自己的临时目录；还发现生成的测试图片 alpha 为 0，改用 CGContext 生成不透明图片并新增 alpha 断言。上述问题已在最终结果中通过验证。

## 与 CC 分支的静态合并检查

对 `feature/menu-bar-shelf@4e3769f9ae5968752ae6fc761fc81f8a8832f0c6` 的已提交内容，以 GitHub main 文件快照作为共同内容基线，使用临时文件运行 `git merge-file -p`，未修改 CC 的 checkout、索引或分支。

双方均修改的四个文件 `BreakCoordinator.swift`、`RestBreakApp.swift`、`SettingsWindow.swift`、`StatusBarController.swift` 均能自动进行文本合并。设置页最初的三个相邻新增点产生冲突，已通过调整本分支新增项的位置消除。

这不是最终集成测试：不覆盖 CC 未提交的修改或后续新提交，也不证明合并后的运行行为正确。CC review 后仍需在集成 worktree 构建并跑测试。两套 main 历史的关系及挑拣建议见实施文档。

## 尚未实测，不作为完成结论

- Safari/Chrome、飞书、TextEdit 的真实输入框自动粘贴，以及不同输入法和键盘布局。
- 真机锁屏/睡眠、全屏、多屏切换的完整交互链路；已测试的是生命周期处理逻辑。
- Release 版开启采集前后的长期 CPU、内存、唤醒和能耗对比。已确认关闭/暂停时计时器停止，未变化时不写盘；不能据此宣称零耗电。
- macOS 14/15 真机覆盖；本次机器仅为 macOS 26.6.2。

本次没有启动或替换用户正在使用的星期五，也没有更改辅助功能授权或系统剪贴板。Release 验证包与截图在忽略目录中提供，未发布 GitHub Release。PR 保持 draft，供 CC review 后决定后续验证和合并。
