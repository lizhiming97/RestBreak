# 星期五（Friday）

一个住在 Mac 菜单栏里的工作日管家：按时叫你休息、开会时不打扰你、需要时帮你截图识字，还能替你的 AI Agent 开口提醒你。

原名「歇一会」，工程名 RestBreak。macOS 14+，Swift / SwiftUI。主程序开源（MIT）；包内两个可选组件单独授权：菜单栏收纳（GPL-3.0）、鼠标顺滑（CC BY-NC 4.0，非商业）。

![功能接入页：灵动岛示意](设计/提醒样式/F-提醒页介绍.png)

## 能做什么

- **休息提醒**：微休息（20-20-20 护眼）和长休息各自计时；到点屏幕蒙上毛玻璃，配中文休息建议；可推迟、跳过，也有严格模式。
- **聪明地不打扰**：开会（麦克风在用）、全屏、指定 App、日历日程中先不弹；快开会时把休息提前到会前；离开电脑、睡眠、锁屏算自然休息。日历支持 Mac 日历和钉钉日历。
- **休息统计**：每天完成、跳过、累计休息、最长连续工作，7 / 30 天趋势图。
- **截图工具**：定格后框选、自动识别窗口、放大镜取色、8 种标注、贴图置顶、长截图（自动滚动拼接）、提取文字（系统 Vision，本机）、翻译（腾讯云，需自填密钥）。
- **剪贴板历史**（默认关闭）：记录复制过的文字和图片，可搜索、固定、纯文本复制、排除指定应用；超过 7 天的普通历史自动清理，固定内容保留；数据只存在本机。从菜单「剪贴板历史…」、设置「历史剪贴板」页或全局快捷键打开。
- **菜单栏收纳**（默认关闭）：把不常用的菜单栏图标收进星期五的菜单，点一下就能打开它原来的菜单；支持多块屏幕。需要给组件单独授予辅助功能和屏幕录制权限。
- **鼠标顺滑**（默认关闭）：让普通鼠标滚轮平滑滚动，可分别反转上下、左右方向，调速度和平滑程度，指定 App 保持原生滚动；触控板和 Magic Mouse 不受影响。需要给组件单独授予辅助功能权限。
- **AI 当管家**：星期五在本机提供一个 MCP 服务。你的 Agent（如 Codex、Claude Code）定时来看看你的状况，挑一件此刻最值得说的事，从刘海的「灵动岛」弹出来；你说了明确时间的事（「每晚 9 点提醒我吃药」），星期五到点准时提醒。**星期五自己不调用任何大模型，没有 API Key，数据只在本机。**

## 安装

到 [Releases](https://github.com/lizhiming97/RestBreak/releases) 下载 DMG，把「星期五」拖进「应用程序」。

目前没有经过苹果公证：第一次打开会被拦，到「系统设置 › 隐私与安全性」点「仍要打开」即可（DMG 里有详细说明）。

## 接入你的 Agent

打开 菜单栏图标 › 设置… › Agent主动关怀 › 功能接入：

1. **复制接入指令**，发给支持 MCP 的 Agent（Codex、Claude Code、Cursor 等），它会把 `http://127.0.0.1:38128/mcp`（带密钥）加进自己的配置。新开一个对话后生效。
2. **复制任务说明**，在 Agent 里新建定时任务（建议每 30～60 分钟），贴进说明，最后一条写上你希望它留意的事。Agent 每次巡视能看到：你在不在电脑前、连续工作多久、今天休息/推迟/跳过几次、最后一次休息的时刻、今天开会多久、下一次休息几点、今天的日程。

只支持在这台 Mac 上运行、能自定义 MCP 的 Agent；纯网页聊天的 AI 接不上。

## 从源码编译

需要 Xcode（支持 Swift 6）和 macOS 14+。

```bash
git clone https://github.com/lizhiming97/RestBreak.git
cd RestBreak/RestBreak
open RestBreak.xcodeproj
```

在 Xcode 的 Signing & Capabilities 里把 Team 换成你自己的（工程里是作者的个人团队 `B45N72QF4V`）。App Group 用了团队 ID 作前缀，换团队后要同步改 `RestBreak.entitlements`、`RestBreakMCP.entitlements` 和 `Shared/AppGroup.swift` 里的 `B45N72QF4V.com.lizhiming.RestBreak`。

命令行编译和测试：

```bash
xcodebuild -scheme RestBreak -configuration Debug build -allowProvisioningUpdates
xcodebuild test -scheme RestBreak -destination platform=macOS -allowProvisioningUpdates
```

主程序原有的第三方包依赖是官方 [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk)，只有命令行小程序 `restbreak-mcp` 用到。

## 包内的两个可选组件

菜单栏收纳和鼠标顺滑要拦截或读取系统输入、读别的 App 的菜单栏图标，沙盒里的主程序做不到，所以各是一个独立的小 App，放在 `星期五.app/Contents/Helpers/` 里，随星期五启动和退出，用户只装一个 App。设置都在星期五的设置窗口里。

- `MenuBarCompanion/`：从 [Ice](https://github.com/jordanbaird/Ice) 派生，GPL-3.0。见 [组件说明](MenuBarCompanion/README.md)、[来源](MenuBarCompanion/UPSTREAM.md)。
- `MouseCompanion/`：平滑滚动核心来自 [Mos](https://github.com/Caldis/Mos)，CC BY-NC 4.0（非商业）。见 [组件说明](MouseCompanion/README.md)、[来源与剥离方式](MouseCompanion/UPSTREAM.md)。

打包含两个组件的 App：

```sh
python3 scripts/build-menu-bar-experiment.py --output 发布/build
python3 MouseCompanion/scripts/build_app.py --main-app "$PWD/发布/build/星期五.app"
```

成品在 `MouseCompanion/dist/星期五.app`。组件测试：`swift test --build-system native --package-path MenuBarCompanion`、`swift test --build-system native --package-path MouseCompanion`。

## 文档

- [对外文档](对外文档/README.md)：项目介绍、开发复盘、踩过的坑、通俗版架构
- [docs/项目细节.md](docs/项目细节.md)：各功能的实现细节和规则
- [docs/superpowers/](docs/superpowers/)：设计文档和实现计划
- [CLAUDE.md](CLAUDE.md)：和 AI 编程助手协作时的项目记忆（当前状态、规则、踩过的坑）

这个项目是作者和 AI 编程助手（Claude Code）一起从零做出来的，过程见开发复盘。

## 许可证

[主程序 MIT](LICENSE)。两个组件不适用根目录 MIT 授权：`MenuBarCompanion/` 从 Ice 派生，适用 [GPL-3.0](MenuBarCompanion/LICENSE)；`MouseCompanion/` 复用 Mos 代码，适用 [CC BY-NC 4.0](MouseCompanion/LICENSE)，**不得用于商业用途**。
