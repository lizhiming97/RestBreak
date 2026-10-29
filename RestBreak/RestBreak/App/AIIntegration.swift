import Foundation

/// 「连接 AI」页复制出去的文字。接法和瑞幸 MCP 一样：给一个地址 + 密钥，用户的 AI 自己加进配置。
/// 地址是星期五在本机开的（只有这台 Mac 能连），不随重新编译、换安装位置变化
enum AIIntegration {
    /// 不用每次批准的工具（`ToolSpec.autoApprove`）
    static var autoApprovedTools: [String] { AllTools.specs.filter(\.autoApprove).map(\.name) }

    /// 大多数 AI 应用通用的 mcpServers 写法（Streamable HTTP）
    static func genericJSON(url: String, token: String) -> String {
        json(["mcpServers": ["friday": ["type": "http", "url": url, "headers": ["Authorization": "Bearer \(token)"]]]])
    }

    /// 复制接入方式：发给用户的 AI，让它自己加好 MCP、装好技能
    static func setupText(url: String, token: String) -> String {
        """
        请帮我接入「星期五」——我这台 Mac 上的提醒 App，它在本机提供一个 MCP 服务（Streamable HTTP）。

        1. 把下面这个 MCP 服务器加到你的 MCP 配置里（用户级，所有项目都能用）。你的配置不是这种 JSON 格式的话，按你自己的格式写同样的内容：地址、请求头 Authorization。
        \(genericJSON(url: url, token: token))
        \(autoApprovedTools.joined(separator: "、")) 可以设为不用每次批准（它们只读，或有每天的打扰上限）；建、改、删提醒保持每次询问。

        2. 如果你支持 Skills（技能），把文末的 SKILL.md 保存为名为 friday 的技能；不支持就跳过。

        3. 告诉我加在了哪里。新加的 MCP 要在新对话里（或重启你之后）才能用，不要在这个对话里试着调用。新对话里我会说「看看我星期五里的提醒」来验证。

        注意：这个地址只在这台 Mac 上能连，而且星期五 App 要开着。

        ===== SKILL.md =====
        \(skill)
        """
    }

    /// Codex：贴到 ~/.codex/config.toml 末尾。不推荐 codex mcp add：它会把整份 config.toml 重新排版（第 0 步实测）
    static func codexSnippet(url: String, token: String) -> String {
        let approvals = autoApprovedTools.map { "[mcp_servers.friday.tools.\($0)]\napproval_mode = \"approve\"\n" }
        return """

        # 星期五：让 Codex 能看你的状况、给你推送、建到点提醒
        [mcp_servers.friday]
        url = "\(url)"
        http_headers = { "Authorization" = "Bearer \(token)" }

        # 这几个不用每次批准；建、改、删提醒仍会先问你
        \(approvals.joined(separator: "\n"))
        """
    }

    /// 技能：什么时候用哪个工具、怎么巡视。支持 Agent Skills（SKILL.md）的 AI 会按需加载
    static let skill = """
    ---
    name: friday
    description: 用「星期五」（用户 Mac 上的提醒 App，MCP 服务器 friday）提醒用户。用户说「几点提醒我…」、问自己的提醒、或要你做一次管家巡视时使用。
    ---

    # 星期五

    星期五只负责把话递到用户眼前（屏幕顶部刘海处的灵动岛），自己不调用任何 AI。说什么、什么时候说，由你判断。

    ## 两种开口方式
    - 用户说了明确时间的事（「每天 21:00 提醒我吃药」）：用 `create_reminder`，到点由星期五准时提醒，你不在线也会响。吃药、重要截止用 `style: "firm"`。建好后用返回的 next 向用户复述。
    - 你自己判断出来、现在就值得说的事：用 `push`。不要为了「过一会再说」去建提醒。

    ## 巡视（定时任务里运行）
    \(patrolPrompt)
    """

    /// 巡视任务说明：用户在自己 AI 应用的定时任务里新建任务，贴进「说明」。重复和时间由用户自己设。
    /// 留意什么由用户自己写在最后一条（2026-10-29 用户要求：只在 Agent 的任务里配置，App 不重复）
    static let patrolPrompt = """
    你是我的贴身管家，现在做一次例行巡视。
    1. 调用星期五（friday）的 get_context，看看我现在的状况、今天的日程和提醒、还剩几条推送预算。
    2. 按第 5 条我写的要求，结合你对我的了解（记忆、最近的对话），判断现在有没有值得主动跟我说的事：快来不及的事、我可能忘了的事、我该停一停的时候、值得知道的事。
    3. 有就调用 push（每次最多 1～2 条），title 说什么事，why 说清为什么是现在；没有就什么都不做。说不清为什么是现在的，不要推。
    4. 不要给我发消息、不要问我问题，巡视完直接结束。
    5. 我特别希望你留意：（在这里写，比如「快开会了还没准备」「连续工作超过 90 分钟」「AI 任务跑完我还没看」）
    """

    private static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
