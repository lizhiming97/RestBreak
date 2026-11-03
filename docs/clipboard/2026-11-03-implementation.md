# 星期五剪贴板验证版

## 范围与操作

从「设置 → 剪贴板」或菜单「剪贴板历史…」进入。首次默认关闭，用户启用后采集文字与图片；设置页可录制全局快捷键。搜索支持文字正文与来源应用标识，固定内容优先显示。回车或双击复制选中项，返回原应用按 `⌘V` 粘贴；也可复制纯文本、固定、删除、清空普通历史或清空全部。

右键「复制并粘贴（实验）」要求已授权辅助功能，且呼出前有目标应用。权限不足仍会复制，并提示使用 `⌘V`；延迟恢复焦点后会核对前台进程再发送按键。该路径尚需在使用者实际签名、权限与目标应用中验证，不能仅凭单元测试声明支持所有应用或输入法。

本轮交付是调研中的第一阶段。文件历史、多项顺序粘贴、图片 OCR 搜索和历史条目直接贴图/翻译不在本版范围；现有截图、识字和翻译的复制结果可以进入历史。

## 实现决策

- 新增代码集中在 `RestBreak/RestBreak/Clipboard/`，不引入第三方包，不修改 Xcode 工程文件或现有休息设置 JSON。
- 参考 Maccy 的类型排除和多表示回放；使用自身的存储、生命周期、设置与界面。上游版本及许可见 `2026-11-03-research.md` 和 App 随附的 `ThirdParty/Maccy-LICENSE.txt`。
- 剪贴板偏好单独保存在 `friday.clipboard.settings.v1`。历史目录是沙盒内 Application Support 下的 `FridayClipboard/`。
- 每个条目独立二进制 plist，索引为 JSON；修改采用原子写，索引提交后删除不再引用的条目。磁盘操作在独立 actor 上执行。重复内容更新原条目的复制时间并保留固定状态。
- 默认 200 条、64 MB 内容容量，单次最多 8 MB；容量包括固定内容。自动清理只删除最旧普通项，固定内容占满时拒绝新项。降低上限不自动删除固定项，会显示超限提示。容量指保存的内容字节，磁盘文件另有少量编码和索引开销。
- 0.5 秒检查 `changeCount`，0.1 秒 timer tolerance；未变化不读取内容、不触发写盘。此处是剪贴板专用的有界轮询，不加入休息调度 tick。
- 关闭、暂停、锁屏、显示器休眠、睡眠或用户会话切走时停表；恢复后重置基线，不追溯暂停期间的内容。采样间隔中被其他内容覆盖的复制可能漏记。
- 暂停是当前会话状态；关闭功能是持久化设置。已存历史可在关闭采集后继续查阅，清空历史不更改系统剪贴板。
- 密码/临时类型标记、指定应用、文件 URL、多个 pasteboard item 和空文本会跳过。应用归属是检测时的前台应用，无法保证准确归属所有后台写入。不能将类型标记过滤描述为识别所有密码。
- 星期五的「复制接入指令」等配置复制加 concealed 标记，避免本机 MCP 密钥持久化到历史。
- 启动读取失败不覆盖原存储；保存失败保留内存状态并显示重试。退出时等待当前历史保存；持久化失败仍允许退出，未保存内容可能丢失。
- 图片列表按可见行生成小尺寸缩略图，关闭面板释放界面与缩略图。原始内容在历史加载后受总容量限制保留在内存中；此验证版尚不是磁盘按需读取的超大历史方案。

## 协作与合并边界

开发分支 `codex/friday-clipboard`，基于 GitHub `origin/main` 的 `20e48f5`，使用独立 worktree。未带入 CC 的 `feature/menu-bar-shelf`、本地 0.7.1 或其他未发布提交。

用户要求本分支通过 PR 交给 CC review，由 CC 决定并执行合并；Codex 不自行合并、发布或改写 main。

仓库当前有两套没有共同祖先的历史：本地开发 `main` 与 GitHub 发布快照 `origin/main`。本 PR 面向 GitHub `main`；CC 如需同步本地开发 `main`，应在自己的集成 worktree 挑拣本 PR 的功能提交并做回归，而不是合并无关历史。不得因该同步把本地完整开发历史推到 GitHub。

为接入功能，少量修改这些公共文件，CC 合并时应保留双方入口：

| 文件 | 本分支修改 |
| --- | --- |
| `App/BreakCoordinator.swift` | 独立 clipboard 实例、启动调用、快捷键分支 |
| `App/RestBreakApp.swift` | 剪贴板设置跳转、退出前等待保存 |
| `Engine/KeyShortcut.swift` | 在枚举末尾追加 clipboardHistory |
| `UI/SettingsWindow.swift` | 新增剪贴板设置页的枚举、图标和 switch |
| `UI/StatusBarController.swift` | 菜单入口、菜单展开时的快捷键处理 |
| `UI/ReminderOverviewPage.swift` | 配置复制增加 concealed 标记 |
| `RestBreakTests/ShortcutTests.swift` | 新动作的分类预期 |

这些文件可能和其他功能同时改动；worktree 隔离不会消除语义冲突。review 时需特别检查设置枚举覆盖、菜单项并存、各模块启动/退出流程和快捷键注册。

## 验证方法

```sh
xcodebuild test -scheme RestBreak -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/friday-clipboard-derived -allowProvisioningUpdates
```

在 `RestBreak/` 下执行。新增测试使用独立命名剪贴板、临时历史目录和独立偏好域，不读取用户的系统剪贴板或真实历史。

新增测试涵盖富文本/纯文本回放、图片回放、排除规则、大小限制、多 item 处理、去重和固定、容量淘汰、重启恢复、暂停恢复、无变化不写盘、损坏存储保护、写盘失败重试和面板布局。验证结果另见 `2026-11-03-validation.md`。

实际使用还应检查：Safari/Chrome、飞书、TextEdit 间连续复制；截图和 OCR 复制；全屏/多屏唤出；辅助功能拒绝和授权后的直接粘贴；Release 版开关功能的实际能耗。自动化通过不等同于这些真机使用场景已全部完成。
