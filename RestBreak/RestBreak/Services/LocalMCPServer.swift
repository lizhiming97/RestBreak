import Foundation
import Network

/// 本机 MCP 地址的密钥，存在钥匙串里；没有就生成一个
struct LocalMCPToken: Codable, KeychainItem {
    static let account = "local-mcp"
    var token: String

    static func loadOrCreate() -> String {
        if let saved = Keychain.load(Self.self) { return saved.token }
        return reset()
    }

    /// 换一个新密钥：旧的立刻失效，AI 要重新接入
    @discardableResult
    static func reset() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = "xyh_" + bytes.map { String(format: "%02x", $0) }.joined()
        Keychain.save(LocalMCPToken(token: token))
        return token
    }
}

/// 在 127.0.0.1 上提供 MCP（只接受本机连接），用户的 AI 通过「地址 + 密钥」接入。
/// 端口固定（默认 38128），被占用时往后找一个并记住，地址不随重新编译、换安装位置变化
@MainActor
final class LocalMCPServer: ObservableObject {
    static let defaultPort: UInt16 = 38128
    private static let portKey = "localMCPPort"

    /// 正在监听的端口；nil = 还没开好或开不了
    @Published private(set) var port: UInt16?
    @Published private(set) var failure: String?
    @Published private(set) var token: String

    /// 由 BreakCoordinator 提供：给 get_context 的现状
    var situation: () -> ButlerContext? = { nil }

    private var listener: NWListener?
    /// 只开一次；工具调用、记客户端都用它
    private let store = try? ReminderStore.shared()
    /// 记端口用；测试里换成单独的，不改动 App 记住的端口
    private let defaults: UserDefaults
    private lazy var protocolHandler = LocalMCPProtocol(
        token: token,
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
        callTool: { [weak self] name, arguments, client in
            guard let self, let store = self.store else {
                return ToolResult(text: StoreError.noContainer.description, isError: true, changed: false)
            }
            let context = ToolContext(now: Date(), calendar: .current, client: client, store: store)
            return AllTools.call(name, arguments: arguments, context: context, situation: self.situation)
        },
        onClient: { [weak self] name in try? self?.store?.update { $0.recordClient(name, now: Date()) } })

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        token = LocalMCPToken.loadOrCreate()
    }

    var url: String? { port.map { "http://127.0.0.1:\($0)\(LocalMCPProtocol.path)" } }

    func start() {
        let saved = UInt16(exactly: defaults.integer(forKey: Self.portKey)) ?? 0
        listen(on: saved > 0 ? saved : Self.defaultPort, attemptsLeft: 10)
    }

    func resetToken() {
        token = LocalMCPToken.reset()
        protocolHandler.token = token
    }

    private func listen(on port: UInt16, attemptsLeft: Int) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        guard let listener = try? NWListener(using: parameters) else {
            retry(after: port, attemptsLeft: attemptsLeft)
            return
        }
        self.listener = listener
        // 监听和连接都在主队列上回调，直接按主线程处理
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.listener === listener else { return }
                switch state {
                case .ready:
                    self.port = port
                    self.failure = nil
                    self.defaults.set(Int(port), forKey: Self.portKey)
                case .failed:
                    listener.cancel()
                    self.listener = nil
                    self.port = nil
                    self.retry(after: port, attemptsLeft: attemptsLeft)
                default: break
                }
            }
        }
        listener.start(queue: .main)
    }

    /// 端口被占用：换下一个
    private func retry(after port: UInt16, attemptsLeft: Int) {
        guard attemptsLeft > 1 else {
            failure = "本机端口都被占用，AI 暂时连不上星期五"
            return
        }
        listen(on: port + 1, attemptsLeft: attemptsLeft - 1)
    }

    // MARK: - 一次连接：收齐一个请求 → 处理 → 回复 → 关闭

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                let buffer = buffer + (data ?? Data())
                switch HTTPParser.parse(buffer) {
                case .complete(let request):
                    self.send(self.protocolHandler.handle(request), on: connection)
                case .invalid:
                    self.send(HTTPReply(status: 400), on: connection)
                case .tooLarge:
                    self.send(HTTPReply(status: 413), on: connection)
                case .incomplete:
                    if isComplete || error != nil { connection.cancel() } else { self.receive(connection, buffer: buffer) }
                }
            }
        }
    }

    private func send(_ reply: HTTPReply, on connection: NWConnection) {
        connection.send(content: reply.serialized, completion: .contentProcessed { _ in connection.cancel() })
    }
}
