# 星期五菜单栏收纳组件（实验版）

从 Ice 提取菜单栏图标整理的核心机制，做成独立 macOS App 和可复用 Swift 模块。部署目标 macOS 14+，本次真机验证为 macOS 26.6.2。支持多块屏幕。组件 GPL-3.0，来源与修改见 [UPSTREAM.md](UPSTREAM.md)。

## 使用

1. 发行包里组件已在 `星期五.app/Contents/Helpers/` 内。从星期五菜单选择「菜单栏图标…」，首次会打开组件设置。
2. 给**组件**（星期五菜单栏）单独允许辅助功能和屏幕录制，按系统提示重启组件。星期五已有的授权不替代组件授权。
3. 点击「启用收纳」。首次启用不收起任何图标。
4. 再次选择「菜单栏图标…」，面板在星期五图标下方弹出：打开开关即收起该图标，关闭即显示；「全部显示」一次放出全部。
5. 收起的图标在面板顶部，左键/右键打开原应用菜单；关闭菜单后图标归位。

星期五运行时组件不显示自己的图标，随星期五退出（所有图标回到菜单栏）；之后星期五启动时会在后台拉起组件并自动启用。单独运行组件时，它显示自己的入口图标。

## 构建与检查

需要 Xcode 和 Swift 6 编译器。模块使用 Swift 5 语言模式以保留上游兼容性，主 App 仍使用 Swift 6。

```sh
swift test --build-system native --package-path MenuBarCompanion
python3 -m unittest discover -s MenuBarCompanion/scripts -p 'test_*.py'
python3 MenuBarCompanion/scripts/build_app.py --configuration release
```

默认输出 `MenuBarCompanion/dist/星期五菜单栏.app`。构建脚本逐张校验 Apple Development / Developer ID 证书的在线吊销状态，选择可信身份，并再次验证成品证书。无身份时可使用本地 ad-hoc；若已有证书全部失效则明确失败，不静默降级。`FRIDAY_COMPANION_SIGN_IDENTITY` 可指定证书 SHA-1（或明确指定 `-` 做本地 ad-hoc）。开发证书签名不等于公证。

完整源代码归档随 App 放入 Resources，并另存到 dist；可独立重建，不依赖 Ice checkout 或网络第三方包。

## 可复用边界

`MenuBarShelf` 是独立 Swift Package library。非沙盒 GPL 宿主可持有 `ShelfController`，用户明确启用时调用 `start(anchor:)`，用 `showShelf()` 展开，用 `await stop()` 退出。MIT 星期五使用独立 App 入口，不直接链接此 library。

## 已知范围

- 多屏：在哪块屏点托盘，就在哪块屏的菜单栏下方展开，并在那块屏上临时移动、点击和归位。以每块屏上的分隔符为锚点识别本屏图标，不混用其他屏的副本。
- 收起靠分隔符占位宽度，系统对所有屏统一生效：**所有屏幕一起收起、一起展开**。
- 插拔屏幕、切换桌面或唤醒保持收起；只有临时图标待归位时才展开。目标屏被拔出时放弃自动归位，图标留在可见区域。
- 外接屏取不到应用菜单位置时，临时图标只放在该屏右半边。
- 需要关闭系统“自动隐藏菜单栏”。
- 依赖私有 CGS API、事件 tap 和旧窗口捕获 API；不同 macOS 版本、不同应用应逐一验证，不声明 App Store 可用。
- 系统固定项和星期五自己的图标标为「固定」，不允许收纳。即使展开栏能容纳图标，真实菜单栏仍需放得下一个临时图标才能点击。
- 拒绝权限、捕获失败、菜单未关闭、归位失败会显示具体状态。应用面板开着时最多等待 120 秒；自动归位失败按 2/4/8/16/30 秒退避重试 5 次。“恢复临时图标”随时强制归位，不再等待面板关闭。
- 不包含 Ice 外观美化、搜索、全局快捷键、始终隐藏第三分区和登录项管理。

具体自动测试、真实左右键与归位证据及尚未覆盖的入口/系统组合见 `../docs/menu-bar/2026-11-01-validation.md`。
