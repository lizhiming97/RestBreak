# 调研：怎样让「任何本机 AI」都接得上歇一会

日期：2026-10-28　起因：0.7 的「复制接入方式」发给 AI 后，AI 都说接不上（一个跑在云端；另一个能操作电脑，也只把配置还给了用户）。用户要求：不支持纯云端的 AI，但本机能操作电脑的 AI 要真的通用。

## 结论
1. **MCP 本身是通用的，「安装 MCP」不通用。** 协议各家都一样，但每家把配置放在不同的文件、用不同的格式，AI 自己往往也不知道自己的配置在哪。
2. **刚加的 MCP 在当前对话里用不了。** Claude Code、Codex、Claude Desktop 都只在会话开始时读一次配置，必须新开对话或重启；Cursor 要在设置里开关一次。0.7 说明里「加好后调用一次 get_context 确认」在同一个对话里**注定失败**，AI 只好说做不到。
3. **「让 AI 直接运行歇一会的命令」这条路走不通（实测）。** 用 `codex sandbox` 在 Codex 的沙箱里运行 `restbreak-mcp`：进程立即崩溃（退出码 134），系统日志 `deny mach-lookup com.apple.secinitd`：AI 的沙箱里不能再启动一个带 App 沙盒的程序。而走 MCP 时，小程序由 AI 应用本身在沙箱外启动，所以能用。**MCP 是唯一能穿过各家 AI 沙箱的方式**，方向不用换。
4. **写本机文件、开本机端口也不通用**：AI 沙箱通常只能写自己的工作目录，很多默认断网（含本机回环），App 沙盒也读不到 AI 写的地方。

## 这台 Mac 上各家的 MCP 配置（2026-10-28 实查）
| AI 应用 | 配置文件 | 格式 | 现状 |
|---|---|---|---|
| Claude Code | `~/.claude.json`（用 `claude mcp add --scope user` 写） | JSON `mcpServers` | 已有 1 个 |
| Codex（命令行 / ChatGPT App / IDE 共用） | `~/.codex/config.toml` | TOML `[mcp_servers.x]` | 只有第 0 步的 `xieyihui-spike`，没有正式的 |
| Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` | JSON `mcpServers` | 无 |
| WorkBuddy | `~/.workbuddy/mcp.json` | JSON `mcpServers`（支持 stdio `command`） | 无 xieyihui |
| Cursor | `~/.cursor/mcp.json` | JSON `mcpServers` | 文件不存在 |
| TRAE SOLO | 在应用的 MCP 设置里加（磁盘上没找到固定文件） | — | — |
| Gemini CLI | `~/.gemini/settings.json` | JSON `mcpServers` | 无 |

共同点：除 Codex 外，内容几乎都是同一段 `{"mcpServers":{"xieyihui":{"command":"…"}}}`；**不同的只是放在哪个文件。**

## 其他发现
- 路径会变：现在复制出去的是 Xcode 开发版路径（`DerivedData/RestBreak-<随机>/…`），换个编译目录或正式安装就失效。
- 设置页「已连接：Codex」是第 0 步验证留下的记录，不代表现在接上了。
- Agent Skills（`SKILL.md`）在本机多家都支持（`~/.agents/skills`、WorkBuddy、Trae、Codex、Claude Code），适合放「巡视说明」「什么时候用 push」这类说明，但它不能代替 MCP 的安装。

## 最初的建议（被用户否决：不要扫描用户的 App）
**由歇一会自己把配置写进各家的配置文件，而不是让 AI 去写。**
- 「连接 AI」页自动列出这台 Mac 上装了的 AI 应用（按上表检测），每个一个「添加」按钮。
- 点「添加」：弹出系统的文件选择框，已经定位到那个配置文件，用户点「允许」后，歇一会把 xieyihui 合并进去（不动其他内容，先备份）。这是沙盒 App 修改别的文件的标准做法，上架也允许。
- 加完提示：「请在 WorkBuddy 里新开一个对话（或重启它）」，再说「看看我歇一会里的提醒」验证。
- 列表里没有的 AI：保留「复制通用配置」，说明「贴进它的 MCP 设置，然后新开对话」。
- 巡视说明照旧复制，贴进定时任务；去掉「加好后立刻验证」这一句。
- 小程序路径改为指向正式安装的 App；开发版时页面提示。

## 参考
- Claude Code 新加 MCP 需重启：anthropics/claude-code issue #46426、#40059
- Agent Skills 开放标准：agentskills.io

## 最终方案（2026-10-28 用户确认并实现）
参考瑞幸 MCP、flyai Skill：歇一会在本机开 `http://127.0.0.1:38128/mcp`（Streamable HTTP + Bearer 密钥），「复制接入方式」给出通用 JSON 配置、技能 SKILL.md 和「新开对话后再用」的提醒，由用户自己的 AI 完成接入。实测 Codex、Claude Code 都能连上。实现细节见 `docs/项目细节.md` 第七阶段。如果这个方式仍解决不了，用户要求换别的方式。
