import AppKit
import Foundation
import MCP

/// MCP 服务器：把 SDK 的 tools/list、tools/call 接到 ReminderTools
enum MCPCommand {
    static func run() async throws {
        let store = try ReminderStore.shared()
        let client = ClientName()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let server = Server(name: "friday", version: version, title: "星期五",
                            instructions: ReminderTools.instructions,
                            capabilities: .init(tools: .init(listChanged: false)))
        let tools = try AllTools.specs.map { spec in
            Tool(name: spec.name, description: spec.description,
                 inputSchema: try JSONDecoder().decode(Value.self, from: Data(spec.schema.utf8)),
                 annotations: .init(readOnlyHint: spec.readOnly, destructiveHint: spec.destructive))
        }
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
        await server.withMethodHandler(CallTool.self) { params in
            // SDK 的 Value → JSON → 字典，ReminderTools 不依赖 SDK
            let raw = try JSONEncoder().encode(params.arguments ?? [:])
            let arguments = (try JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:]
            let context = ToolContext(now: Date(), calendar: .current, client: client.value, store: store)
            let result = AllTools.call(params.name, arguments: arguments, context: context, situation: { ContextRequest.fetch() })
            if result.changed { await AppLauncher.launchIfNeeded() }
            return .init(content: [.text(result.text)], isError: result.isError)
        }
        try await server.start(transport: QuietStdioTransport()) { info, _ in
            client.value = info.name
            try? store.update { $0.recordClient(info.name, now: Date()) }
        }
        await server.waitUntilCompleted()
    }
}

/// 握手时拿到的客户端名，工具调用时读（两边在不同的任务里，所以加锁）
final class ClientName: @unchecked Sendable {
    private let lock = NSLock()
    private var name = "unknown"
    var value: String {
        get { lock.withLock { name } }
        set { lock.withLock { name = newValue } }
    }
}

/// 提醒改了但星期五没在运行：把它拉起来，否则到点不会弹强提醒卡片
enum AppLauncher {
    @MainActor
    static func launchIfNeeded() async {
        // 已经在运行就不再启动：新实例会把旧实例顶掉，Xcode 调试中的旧实例会留下两个
        guard NSRunningApplication.runningApplications(withBundleIdentifier: AppGroup.appBundleID).isEmpty else { return }
        // 小程序是 星期五.app/Contents/MacOS/restbreak-mcp：从可执行文件往上三层就是 App 本身
        // （命令行程序的 Bundle.main.bundleURL 是 Contents/MacOS，不能拿它往上数）
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return }
        let appURL = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard appURL.pathExtension == "app" else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }
}

/// 向主 App 要现状：发 Darwin 通知，等主 App 写 context.json（最多 1.5 秒）。
/// 只在 AI 调 get_context 时发生，平时主 App 不写这个文件
enum ContextRequest {
    static func fetch() -> ButlerContext? {
        guard let url = AppGroup.contextURL else { return nil }
        let asked = Date()
        DarwinNotice.post(DarwinNotice.contextRequest)
        while Date().timeIntervalSince(asked) < 1.5 {
            if let raw = try? Data(contentsOf: url),
               let context = try? ButlerContext.fileDecoder.decode(ButlerContext.self, from: raw),
               context.generatedAt >= asked.addingTimeInterval(-0.05) {
                return context
            }
            usleep(50_000)
        }
        return nil
    }
}
