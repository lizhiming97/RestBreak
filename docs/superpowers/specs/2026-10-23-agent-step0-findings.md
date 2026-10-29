# AI 接入第 0 步：验证记录

日期：2026-10-23　分支：`feature/agent-reminders`　计划：`docs/superpowers/plans/2026-10-23-agent-step0-spike.md`

环境：macOS（Darwin 24.2）、Xcode 27.1、Claude Code 2.1.278（命令行）/ 2.1.308（桌面 App 里的 Code）、Codex CLI 0.145.0（走第三方中转 `club`）、MCP Swift SDK 0.12.1。

## 结论一览
| # | 验证项 | 结果 | 证据 | 对设计的影响 |
|---|---|---|---|---|
| 1 | 沙盒命令行小程序 + App Group：工程能编出来、能签名、能写入共享文件夹 | ✅ 通 | `restbreak-mcp`（7 MB）位于 `RestBreak.app/Contents/MacOS/`；两个程序都带 `B45N72QF4V.com.lizhiming.RestBreak`；`codesign --verify --deep --strict` 通过；169 个测试全过（新增 7 个） | 按设计做。个人免费团队 + 团队 ID 前缀的 App Group 不需要描述文件 |
| 2 | 由 Claude Code（桌面 App 的 Code 会话）启动并调用 | ✅ 通 | `mcp.log`：`initialize claude-code 2.1.308`，接着 `ping launch=false`；会话原样返回「写入共享文件夹：成功」 | — |
| 3 | 由 Codex 启动并调用 | ✅ 通（有条件） | `initialize codex-mcp-client 0.145.0`；`codex exec` 里返回了 ping 的结果 | **Codex 调用 MCP 工具默认要批准**，`exec` 模式下会自动取消。已验证：在 `config.toml` 里给工具写 `approval_mode = "approve"` 后，不用加任何命令行参数就能直接调用。正式版只对只读工具这样配置，会改数据的工具保持每次询问 |
| 4 | Claude Code hooks | ✅ 通 | `UserPromptSubmit`、`Stop`、`SessionEnd` 都写进了共享文件夹，项目名正确；单次 hook 耗时 31 ms | 按设计做 |
| 5 | Codex hooks（会不会被 Codex 的沙盒挡住） | ✅ 通 | 在 `sandbox: read-only` 下，`UserPromptSubmit`、`Stop`、`SessionEnd` 仍然写进了 App Group | Codex 的沙盒不影响 hook。**项目级 `.codex/hooks.json` 在项目没被信任时不加载**，用户级 `~/.codex/hooks.json` 可以；hooks 本身还要在 `/hooks` 里信任一次 |
| 6 | 沙盒进程之间的 Darwin 通知 | ✅ 通 | `listen.log`：「收到 com.lizhiming.RestBreak.agents.changed」 | 按设计做 |
| 7 | 沙盒里用 NSWorkspace 打开 App | ✅ 通 | `open-test`：「打开成功」（计算器）。真正拉起歇一会留给手动清单 | 按设计做 |
| 8 | 并发写 | ✅ 通（改了写法） | 第一版日志用「打开文件 → 跳到末尾 → 写」，两个进程同时写时互相覆盖；改用 `O_APPEND` 后，20 个进程同时写得到 20 行 | 正式的 `store.json` 照设计用 `flock` 加锁，再原子替换 |
| 9 | hook 不落盘原文 | ✅ 通 | 输入里带「秘密」，日志里搜不到；坏输入也返回 0 | — |
| 10 | `.mcpb` 扩展包 | ⏳ 两种都通过了格式校验，安装要手动 | `mcpb validate` 都通过；**复制版解包后签名仍有效、仍能写 App Group** | 复制版作为保底已确认可行；绝对路径版能不能装，等手动结果 |
| 11 | Claude Code 插件（MCP + hooks） | ✅ 通 | `claude plugin validate` 通过；本地 marketplace 安装后，插件的 hooks 记下了 `claude-plugin` 的 `UserPromptSubmit` / `Stop`；插件的 MCP 工具 `mcp__plugin_xieyihui_xieyihui__ping` 调用成功 | **注意**：如果用户同时手动加过一个 `command` 完全相同的 MCP 服务器，Claude Code 会把插件里的那个当重复去掉（第一次测试就因此看不到插件的 ping）。设置页安装插件时，要检测并提示删除旧的手动配置。Claude Code 的正式安装方式定为插件 |
| 12 | Codex 插件 | ❌ 不走 | Codex 0.145 `codex features list`：`plugin_hooks removed`；官方文档说带 hooks 的插件进不了公开目录 | 正式方案用 `~/.codex/hooks.json` + MCP 配置，不用插件 |
| 13 | Claude Code 状态栏额度 | ⏳ 手动 | 解析和输出已用样例验证：「歇一会：5 小时额度 50%」 | — |
| 14 | Codex 额度 | ❌ 本机不可用 | 中转服务的 `rate_limits` 全为 null | 设置页要显示「你的 Codex 用的服务不提供额度信息」 |
| 15 | MCP 进程退出 | ✅ 通 | 标准输入关闭后 1～2 秒内退出 | — |

## 新发现（要改进设计）
1. **`codex mcp add` 会重写整个 `~/.codex/config.toml`**：调整顺序、删掉 `type = "stdio"`、`args = []`，`120` 变成 `120.0`。意思没变，但文件不再是用户原来那份。设置页**不要**推荐 `codex mcp add`，改成给一段 TOML 让用户自己贴到文件末尾。
2. **主 App 不能把小程序当子进程启动**：已经在沙盒里的进程再启动一个带自己沙盒权限的程序会崩。主 App 要用这些功能时，直接调用 `Shared/` 里的代码。
3. 命令行版 `claude` 没登录也能完成 MCP 握手和 hooks，但模型不会回复。你的 Claude Code 登录由桌面 App 管理，所以以桌面 App 里的 Code 会话为准。
4. 客户端名字（用于设置页「已连接」）：`claude-code`、`codex-mcp-client`。Claude Desktop、ChatGPT App 里的 Codex 的名字等手动验证后补上。

## 对现有版本的影响
- 主 App 只多了 App Group 权限和 `Shared/` 文件夹，现有代码一行没改；169 个原有和新增测试全过。
- 验证全程用单独的编译目录 `~/Library/Developer/Xcode/DerivedData/RestBreak-xieyihui-spike`，你在 Xcode 里调试运行的那份没有被覆盖或重启。
- 回到 `main` 分支就完全是原来的版本。

## 手动清单（需要你操作，每项几分钟）
1. **真正拉起歇一会**：在 Xcode 里停止运行歇一会，然后在终端执行下面这条命令。预期看到「已启动歇一会」，菜单栏图标出现。
   ```bash
   (printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ping","arguments":{"launch":true}}}'; sleep 3) | ~/Library/Developer/Xcode/DerivedData/RestBreak-xieyihui-spike/Build/Products/Debug/RestBreak.app/Contents/MacOS/restbreak-mcp
   ```
2. **Claude Desktop 普通聊天**：双击 `/tmp/xieyihui-copy.mcpb` 和 `/tmp/xieyihui-abs.mcpb`，分别安装，在普通聊天里说「调用歇一会验证的 ping 工具」。记下哪个能用。用完在 Claude Desktop 的扩展设置里卸载。
3. **ChatGPT App 里的 Codex**：在 `~/Desktop/Project_Hub/scratch/xieyihui-spike` 打开一个 Codex 任务，说「调用 xieyihui-spike 的 ping 工具」，批准一次。
4. **Codex 交互**：在上面那个目录的终端里运行 `codex`，用 `/hooks` 信任 hooks，让它执行一条需要批准的命令（会触发 `PermissionRequest`），再按 Esc 打断（会触发 `Interrupt`）。
5. **Claude Code 状态栏额度**：在终端里运行 `claude`（需要先登录），在上面那个目录里随便问一句，看底部状态栏是否显示「歇一会：…」。
6. 做完 1～5 后告诉我，我来查看日志、补全这份记录，并清理配置。

## 现在还留着的验证配置（手动清单用，做完再删）
- `~/.codex/config.toml` 末尾有 5 行「歇一会第 0 步验证」，删掉这 5 行就恢复原样（备份：`/tmp/xieyihui-backup/codex-config.toml`）。
- 第 4 项要用到 Codex hooks，到时候运行 `cp ~/Desktop/Project_Hub/scratch/xieyihui-spike/.codex/hooks.json ~/.codex/hooks.json`，用完删掉 `~/.codex/hooks.json`（原来没有这个文件）。
- 已清理：Claude Code 的测试 MCP、测试插件和测试 marketplace（`~/.claude/settings.json` 已从备份恢复）。Claude Desktop 的配置没有动过。
