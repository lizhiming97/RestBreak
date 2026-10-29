import Foundation

// 星期五的命令行小程序，放在 星期五.app/Contents/MacOS/restbreak-mcp。
// 用户的 AI（Claude、Codex……）启动它，通过标准输入输出说 MCP 协议：看现状、推送、建到点提醒。
// 0.7 起新接入走主 App 的本机地址（Services/LocalMCPServer）；这个小程序只为以前按路径配置过的 AI 保留。
try await MCPCommand.run()
