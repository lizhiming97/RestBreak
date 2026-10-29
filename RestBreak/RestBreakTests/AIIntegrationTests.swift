import Foundation
import Testing
@testable import RestBreak

/// 「连接 AI」页复制出去的文字
struct AIIntegrationTests {
    let url = "http://127.0.0.1:38128/mcp"
    let token = "xyh_test"

    @Test func 接入方式_带地址密钥_技能_提醒新开对话() throws {
        let text = AIIntegration.setupText(url: url, token: token)
        #expect(text.contains(AIIntegration.autoApprovedTools.joined(separator: "、")))
        #expect(text.contains("新对话"))
        #expect(text.contains("name: friday"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(AIIntegration.genericJSON(url: url, token: token).utf8)) as? [String: Any])
        let server = try #require((object["mcpServers"] as? [String: Any])?["friday"] as? [String: Any])
        #expect(server["type"] as? String == "http" && server["url"] as? String == url)
        #expect((server["headers"] as? [String: String])?["Authorization"] == "Bearer \(token)")
    }

    @Test func Codex配置_用地址和请求头_只放行只读工具和push() {
        let text = AIIntegration.codexSnippet(url: url, token: token)
        #expect(text.contains(#"url = "\#(url)""#))
        #expect(text.contains(#"http_headers = { "Authorization" = "Bearer \#(token)" }"#))
        for tool in AIIntegration.autoApprovedTools {
            #expect(text.contains("[mcp_servers.friday.tools.\(tool)]\napproval_mode = \"approve\""))
        }
        #expect(!text.contains("tools.create_reminder") && !text.contains("tools.delete_reminder"))
    }

    @Test func 免批准的工具_只读的加上push() {
        #expect(AIIntegration.autoApprovedTools == ["get_context", "push", "list_reminders"])
        #expect(AllTools.specs.filter(\.autoApprove).allSatisfy { !$0.destructive })
    }

    @Test func 巡视说明_只用现有工具_不定间隔() {
        let prompt = AIIntegration.patrolPrompt
        #expect(prompt.contains("get_context") && prompt.contains("push") && prompt.contains("我特别希望你留意"))
        #expect(!prompt.contains("remember") && !prompt.contains("forget") && !prompt.contains("45 分钟"))
    }

    @Test func 技能有合法的头() {
        let lines = AIIntegration.skill.components(separatedBy: "\n")
        #expect(lines.first == "---" && lines[1] == "name: friday" && lines[2].hasPrefix("description: "))
    }
}
