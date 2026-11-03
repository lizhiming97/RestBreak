请复查星期五新增的菜单栏收纳功能。不要仅根据编译和单测通过判断真实图标操作可用。

仓库原位置：/Users/lizhiming/Desktop/lizhiming/个人项目验证/桌面闹钟/有趣的项目--桌面提醒工具
本次工作树：/Users/lizhiming/Desktop/lizhiming/个人项目验证/开源项目研究/friday-menu-bar
分支：feature/menu-bar-shelf
基线：35e507c（本地 0.7.1）
建议对比：git diff 35e507c..feature/menu-bar-shelf

用户已选择独立 GPL 菜单栏组件。星期五主程序保持 MIT＋沙盒，通过 LaunchServices 启动单独的非沙盒组件；没有把 GPL 库链接进主 App。不要自行改成主进程非沙盒，也不要推送本地 main 或发版。

先读：
1. CLAUDE.md 中菜单栏收纳分支说明。
2. docs/menu-bar/2026-11-01-design.md。
3. docs/menu-bar/2026-11-01-validation.md（以此判断真实验证完成到哪一步）。
4. MenuBarCompanion/UPSTREAM.md 和 README.md。

重点检查：
- 从 Ice 提取的窗口枚举、离屏捕获、事件 tap / session 转发、Command 移动是否保持正确；尤其现代 macOS 对私有 API 和录屏的实际行为。
- 点击前保存原位置，点击失败、菜单持续打开、应用退出、窗口 ID 复用、切换 Space、退出时的恢复是否正确。
- 权限拒绝/撤回和监听创建失败是否会挂起、错误点击或残留宽占位。
- 收起/展开、左右键、超宽滚动、单屏限制是否与界面和文档一致。
- 无操作时是否有轮询、图像缓存泄漏、事件监听或任务未释放。
- 星期五入口、应用识别、独立权限、成对打包、GPL 及对应源代码分发边界。
- 原有休息提醒、截图、MCP 和沙盒是否有回归。

验证命令：
- cd 工作树/RestBreak 后执行 xcodebuild test -scheme RestBreak -destination platform=macOS -derivedDataPath /tmp/FridayMenuBarClaudeReview -allowProvisioningUpdates。
- 在工作树执行 swift test --build-system native --package-path MenuBarCompanion。
- python3 scripts/build-menu-bar-experiment.py 构建两 App，不自动启动或替换安装版。

先输出按严重程度排序的问题，附具体文件/行号、可复现触发条件及建议；没有证据不要把风险猜测写成已确认 bug。把编译/自动测试与真实桌面验证分开报告。用户目前只要求一次检查，不需要自行推送或正式发版。

本轮真机已经跑通 CC Switch 左右键真实托盘面板、保持打开不提前归位、Escape 后自动归位，以及星期五移入移出收纳区；最新组件12项测试、签名5项，主程序275项。macOS 26 适配参考 Ice macos-26 固定提交。请重点补看主设置页到组件的完整真人操作路径：电脑控制工具无法取得星期五纯 NSMenu，当前只完成客户端自动测试。不要将该未验证项误报为已知失败，也不要把其它未覆盖系统组合当作已通过。
