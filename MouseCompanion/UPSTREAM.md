# Mos 来源与许可边界

- 项目：[Caldis/Mos](https://github.com/Caldis/Mos)
- 作者：Caldis 及 Mos contributors，Copyright 2017–2026。
- 固定提交：`8a2fd112e2af444c37ca5f65f42e9bd19c08a5c2`（master，2026-08-20）。正式发行版查询结果为 4.2.1；本组件来源固定于上述提交，不声明与 4.2.1 二进制行为完全一致。
- 许可：[CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/)，[完整条款](https://creativecommons.org/licenses/by-nc/4.0/legalcode)。`LICENSE` 原样保留上游文件。
- 上游明确要求不要将 Mos 上传到 App Store。本组件为用户授权的个人非商业用途制作；不暗示原作者背书。

## 复用与修改（2026-11-03）

`Sources/MosScrollCore/Upstream/Interpolator.swift` 与 `ScrollFilter.swift` 从该提交复制，仅去除行尾空白，逻辑和原版权头保留。

`MosSmoother.swift` 改编 `ScrollPoster.swift` 的 `update` 和 `processing` 核心：同向滚动累积、反向重新起步、lerp 插值、ScrollFilter 峰值滤波。集成时移除上游全局单例、热键与 Logi/HID 依赖；反向时清空旧方向滤波缓存，零输入不重置另一轴，停止条件调整为剩余量和输出都收敛。

`ScrollConfiguration.swift` 的步长 33.6、速度 2.70、持续参数 4.35，以及 duration 到 transition 的变换来自 `Mos/Utils/Constants.swift`。

`ScrollEventAdapter.swift` 改编 `ScrollEvent.swift` 的三种 delta 表示读取、反转与清零。输入分类改为保守透传连续/手势事件，不包含 Mos 的 Logitech 来源特判。

`ScrollEngine.swift`、组件设置 UI、宿主生命周期与打包脚本为本次集成新增：主线程 event tap + CVDisplayLink 调度、最多一个待处理帧、取消代次、目标 PID 与位置保护、权限失效恢复原生输入、锁屏/睡眠停止、独立偏好与运行进程。

本组件未包含 Mos 完整 ScrollPhase 状态机、Logi/HID、按钮映射、脚本执行、模拟触控板模式、按应用独立参数及自动更新。这是复用 Mos 滚动核心的星期五组件，不是完整 Mos 的替代发行版，不承诺所有设备上手感一致。

## 隔离和剥离

整个 `MouseCompanion/` 按 CC BY-NC 4.0 提供，不适用仓库根目录的 MIT 授权。主程序通过固定 URL 与独立 App 交互，不直接链接 Mos 代码。源代码、许可和本说明随组件打包。

移除该目录、主程序的 `MouseCompanionPage.swift`、设置页三个入口与启动调用，并从发行包中移除 `Contents/Helpers/星期五鼠标.app`，即可停止随星期五分发此组件。剥离不会改变用户已经获得的许可或历史分发事实。商业化或上架前应核对最终发行内容。
