# 星期五鼠标组件（验证版）

基于 Mos 的平滑滚动核心，为普通离散滚轮提供平滑、上下/左右反向、速度、平滑程度、最小步长和应用排除。macOS 14+，独立非沙盒 App；星期五主程序仍为沙盒。许可 CC BY-NC 4.0，来源和修改见 [UPSTREAM.md](UPSTREAM.md)。

## 使用

1. 使用包含本组件的星期五包，打开「设置 › 鼠标」，打开「鼠标增强」。所有设置都在这一页，组件没有自己的窗口。
2. 第一次会提示缺少权限：点「去授权」，在「隐私与安全性 › 辅助功能」里打开「星期五鼠标」，授权后自动生效。
3. 分别设置上下/左右反转和平滑。速度、平滑程度、最小步长默认使用所选 Mos 源码版本的值。
4. 对不适合的应用添加排除项。关闭「鼠标增强」立即释放输入拦截，组件随即退出。

检测到正式或 Debug 版 Mos 运行时不接管滚轮，退出 Mos 后自动接管。其他鼠标驱动仍可能干预滚动；本版保守跳过已连续化的事件，Magic Mouse 和触控板保持原样。

组件没有窗口、Dock 图标和菜单栏图标，只为星期五服务：增强开着时随星期五启动，星期五退出或关闭增强时退出；直接双击组件会立即退出。设置由星期五写在 App Group 的 `MouseCompanion/config.json`，组件把运行状态写回 `status.json`，各发一个 Darwin 通知（`com.lizhiming.RestBreak.mouse.config|status`）。星期五用 `friday-mouse://launch|authorize` 拉起组件、请求授权。组件签名带同一 App Group 权限（`FridayMouse.entitlements`）。

## 构建

```sh
swift test --build-system native --package-path MouseCompanion
python3 MouseCompanion/scripts/build_app.py --build-friday
```

在仓库根目录运行，产物在 `MouseCompanion/dist/`。完整构建从 Xcode 主程序签名提取身份，用同一身份签组件及组合包；保留主 App 原有 entitlements。可显式指定 `--identity`。只有单独构建组件且未指定身份时默认 ad-hoc，供本地开发，不等于公证。

已有 CC 集成版主程序时，可使用 `--main-app /绝对路径/星期五.app`；主程序须已包含鼠标设置入口。脚本保留包内其他 Helpers，新增鼠标组件，再重新签名。不会安装或启动成品。

## 范围

合成帧以原事件目标 PID 投递；拿不到目标时原样放行。点击、修饰键变化、切换 App/桌面或换了接收进程时清掉惯性；挪动鼠标不打断滚动。锁屏、睡眠、退出或关闭时停表并销毁 event tap。系统偶尔因繁忙暂停监听时就地恢复（10 秒内最多 3 次）；辅助功能权限撤销时立即停止，重新授权后自动开启。

不监听鼠标移动、不定时检查：DisplayLink 只在滚动时运行，权限变化靠系统通知。高刷新率、Magic Mouse、Logi 驱动和真实应用手感需要设备验证。诊断和验证边界见 `../docs/mouse/2026-11-03-validation.md`。
