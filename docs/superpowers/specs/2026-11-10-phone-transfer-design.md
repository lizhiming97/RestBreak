# 手机互传（LocalSend 协议）设计

日期：2026-11-10。用户确认：手机是鸿蒙，通过卓易通装官方 LocalSend（安卓版）；星期五用 Swift **自己实现 LocalSend 协议 v2**（照协议文档写，不复制 LocalSend 代码，LocalSend 为 Apache-2.0），手机端用官方 LocalSend 即可和星期五互传。做法 A：**星期五收文件走 HTTP，发文件对接手机的 HTTPS**，不引入新依赖；以后可升级成全 HTTPS。

协议参考：<https://github.com/localsend/protocol>（v2，路由前缀 `/api/localsend/v2/`）。

## 用户路径

### 开关与设置
- 设置侧栏新增「手机互传」页（`SettingsPage` rawValue「手机互传」，放在「历史剪贴板」之后，图标 `iphone.and.arrow.forward`），**默认关闭**；打开才监听，关掉立刻停。
- 页面两个分段：「设置 / 记录」（样式同「Agent主动关怀」页）。「设置」分段要在 760×600 窗口里一屏放下（信任设备多了在列表框内滚动）；「记录」分段可以滚动。
- 设置分段：总开关；本机在手机上显示的名字（默认「星期五 · <Mac 名>」）；保存位置（默认「下载/星期五」，可改）；信任的设备列表（每台可取消信任）。
- 第一次打开总开关时请用户选一次保存位置（沙盒不能直接写「下载」），预选「下载/星期五」（不存在就建），存安全书签，做法同 `PhotoFolderService`。

### 手机 → 电脑
1. 手机 LocalSend 选文件 → 选「星期五」。
2. 陌生设备：灵动岛弹出「<设备名> 想发来 N 个文件（总大小）」，按钮「收」「拒」，另有「以后自动收」勾选。30 秒没人点按拒绝处理。
3. 信任设备：直接收，岛收起态显示进度百分比。
4. 收完：岛上「收到 N 个文件」，点一下在访达里显示（单个文件选中它，多个打开所在文件夹），15 秒自动收起。
5. 一次可多个文件；手机发来的文件夹按原目录结构存（LocalSend 的 `fileName` 可带相对路径）。
6. 手机发来的是一段文字（LocalSend「文本」，`fileType` 为 `text/plain` 且带 `preview`）：岛上显示内容，同时放进剪贴板，不存成文件，记录里记一条。
7. 文件重名：自动加序号「名字 (1).ext」，不覆盖。

### 电脑 → 手机
- 菜单「发送到手机…」：选文件（可多选、可选文件夹）→ 选设备；附近只有一台时直接发。
- 把文件 / 文件夹拖到菜单栏星期五图标上松手，效果相同。
- 文件夹展开成其中的文件，`fileName` 带相对路径发送。
- 手机是否要确认由手机端决定；电脑这边岛上显示进度和结果，被拒、失败也告诉用户。

### 传输记录
- 每次传输一条：时间、设备、方向（收 / 发）、文件名和大小（多文件可展开）、结果（成功 / 失败 / 被拒 / 取消）。
- 收到的文件点一下在访达里显示，文件不在了显示「文件已不在」；发出的显示电脑上的原文件。
- 超过 30 天的记录自动清掉（只清记录，不删文件）。

### 与休息、其他功能的关系
- 休息遮罩期间：信任设备照常后台收，不弹岛，休息结束后再提示；陌生设备直接拒（回 403）。
- 灵动岛排队规则沿用现有 `NotchIsland`（开会、全屏时的处理一致）。

## 架构

新文件夹 `RestBreak/RestBreak/Transfer/`：

| 文件 | 职责 |
|---|---|
| `LocalSendProtocol.swift` | 纯数据：设备信息（`alias`、`version`、`deviceModel`、`deviceType`、`fingerprint`、`port`、`protocol`、`download`、`announce`）、文件清单 / 会话的 JSON 结构、路由路径。不碰网络 |
| `LocalSendServer.swift` | 监听 TCP 53317（被占用往后找，最多 10 个），处理 `register` / `prepare-upload` / `upload` / `cancel`（以及调试用的 `info`）。`upload` 流式读取请求体，边收边写文件，不整个进内存。请求头解析可复用 `HTTPParser` 的思路，但需要流式版本 |
| `LocalSendDiscovery.swift` | Network.framework `NWConnectionGroup` 加入组播 `224.0.0.167:53317`：打开时发一次 `announce: true`；收到别人的 `announce: true` 就 HTTP `register` 回去（失败再组播 `announce: false`）。维护附近设备表（收到消息即更新，3 分钟没消息视为离开）。等事件，不轮询 |
| `LocalSendClient.swift` | 发送：`URLSession` 调对方 `register`、`prepare-upload`、`upload`、`cancel`。对方是 HTTPS 时接受自签名证书，并核对证书 SHA-256 与对方声明的指纹（第一次见到即记住，即 TOFU） |
| `TransferCoordinator.swift` | `@MainActor`，串起以上：是否询问、保存路径与重名、文本进剪贴板、灵动岛提示与进度、写记录、休息期间的处理 |
| `TransferStore.swift` | 信任设备（按指纹）+ 传输记录，存一个 JSON 文件到沙盒 Application Support（`FridayTransfer/store.json`）。只在真有变化时写；30 天清理在启动和写记录时顺手做 |
| `TransferSettingsPage.swift` | 设置「手机互传」页 |

本机身份：`fingerprint` 在 HTTP 模式下是随机字符串，生成一次存进 `UserDefaults`，不随重启变化（手机端靠它认出「同一台星期五」）。`protocol` 字段报 `http`，`version` 报 `2.1`，`deviceType` 报 `desktop`，`download` 报 `false`。

## 关键规则

- **默认关闭，关闭时不加载**：服务器、组播、记录文件都不碰。
- **性能**：打开后只有一个监听端口和一个组播接收在等事件，空闲 0 唤醒；不在 `BreakCoordinator` 的 tick 里做任何事；进度更新灵动岛最多每秒一次。
- **安全**：
  - 只接受局域网 / 链路本地地址的连接。
  - 同一时间只一个接收会话，其他 `prepare-upload` 回 409。
  - 每个文件一个随机令牌，`upload` 校验 `sessionId` + `fileId` + `token` + 来源 IP，不对回 403。
  - 文件名清洗：去掉 `..`、绝对路径、控制字符，保证最终路径在保存目录内。
  - 只接收 `prepare-upload` 里声明过、且用户同意的文件；写入字节数超过声明大小即中断。
  - 带 `sha256` 时校验，不符回 422 并删文件。
- **系统权限**：entitlements 已有 `network.server` / `network.client`。新增 `INFOPLIST_KEY_NSLocalNetworkUsageDescription`；组播在 macOS 15+ 可能需要 `com.apple.developer.networking.multicast`（受限权限，免费团队可能拿不到）——**实现第一步先实测**，拿不到就退回：只靠手机端组播被我们收到后 `register` 回去 + 手动按 IP 发送（见下）。

## 出错处理

- 传到一半断开 / 对方 `cancel`：删除没写完的文件，记录标「失败」或「取消」，岛上提示。
- 保存位置书签失效（移动硬盘拔了等）：拒收（回 500），岛上提示去设置里重新选。
- 端口全部被占：设置页显示原因，功能状态为「没开起来」。
- 发送时对方离线 / 超时：岛上提示「<设备名> 连不上」，记录标失败。
- 组播完全不通（路由器隔离等）：设置页提供「按 IP 添加设备」作为兜底（输入手机 LocalSend 显示的 IP）。

## 测试

单元测试（`RestBreakTests`）：
- 协议 JSON 编解码（含未知字段、`deviceType` 未知值）。
- 文件名清洗与相对路径（`../`、绝对路径、文件夹结构）。
- 重名加序号。
- 记录读写、30 天清理、信任设备增删。
- 接收流程：本机起 `LocalSendServer`（随机端口），用 `URLSession` 模拟手机走 `prepare-upload` → `upload`，验证文件内容、令牌错误 403、重复会话 409、超出声明大小中断、`cancel` 后清理。

真机清单（用户用鸿蒙 + 卓易通 LocalSend）：发现、收单个 / 多个 / 文件夹 / 文字、陌生设备询问与「以后自动收」、拒收、电脑发多个文件和文件夹、拖到菜单栏图标、休息期间收、传输中断、记录点开文件。

## 不做（本次）

- 星期五自己的 HTTPS 服务器（以后再加）、PIN、浏览器下载模式（`prepare-download`）。
- 访达右键共享扩展、剪贴板文字 / 截图一键发到手机。
- 记录的搜索、筛选、统计。
