import AppKit
import Network
import Security

/// 钉钉日历：用 OAuth 登录钉钉，通过钉钉官方「钉钉日历」MCP 服务读取日程（只读，只调用查询工具）。
/// - 登录：浏览器打开钉钉授权页 → 授权后跳回本机临时端口 → 用授权码换令牌
/// - 令牌存在 Mac 钥匙串里；过期自动用刷新令牌续期
/// - 每 5 分钟查询一次未来 12 小时的日程，供调度引擎使用
@MainActor
final class DingTalkCalendar: ObservableObject {
    enum Status: Equatable {
        case loggedOut
        case loggingIn
        case connected
        case failed(String)
    }

    @Published private(set) var status: Status = .loggedOut
    /// 最近一次成功同步的时间和日程数
    @Published private(set) var lastSync: (date: Date, count: Int)?

    /// 钉钉日历 MCP 服务地址（OAuth 版）
    static let serverURL = URL(string: "https://mcp-gw.dingtalk.com/oauth/server/calendar")!
    /// 登录回调用的本机端口（钉钉只允许 https 或本机 http 作为回调地址）
    static let callbackPort: UInt16 = 38127
    static var redirectURI: String { "http://127.0.0.1:\(callbackPort)/callback" }
    private static let refreshInterval: TimeInterval = 5 * 60

    private var credentials: DingTalkCredentials?
    private var cachedEvents: [CalendarEvent] = []
    private var fetchedAt: Date?
    private var isFetching = false
    private var loginTask: Task<Void, Never>?
    /// list_calendar_events 的参数说明，第一次查询时从 tools/list 读取
    private var querySchema: [String: Any]?

    init() {
        credentials = Keychain.load(DingTalkCredentials.self)
        if credentials?.accessToken != nil { status = .connected }
    }

    var isLoggedIn: Bool { credentials?.accessToken != nil }

    /// 调度器每秒调用：返回缓存的日程；缓存过期时在后台重新查询
    func events(now: Date) -> [CalendarEvent] {
        guard isLoggedIn else { return [] }
        let stale = fetchedAt.map { now.timeIntervalSince($0) >= Self.refreshInterval } ?? true
        if stale && !isFetching { Task { await refresh() } }
        return cachedEvents
    }

    // MARK: - 登录 / 退出

    func login() {
        loginTask?.cancel()
        status = .loggingIn
        loginTask = Task {
            do {
                try await performLogin()
                status = .connected
                await refresh()
            } catch is CancellationError {
                status = isLoggedIn ? .connected : .loggedOut
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    func cancelLogin() {
        loginTask?.cancel()
    }

    func logout() {
        loginTask?.cancel()
        Keychain.delete(DingTalkCredentials.self)
        credentials = nil
        cachedEvents = []
        fetchedAt = nil
        lastSync = nil
        querySchema = nil
        status = .loggedOut
    }

    private func performLogin() async throws {
        // 1. 读取钉钉公开的授权配置
        let endpoints = try await OAuthEndpoints.discover(resource: Self.serverURL)
        // 2. 先开好本机回调端口，再向钉钉登记「星期五」
        let server = try LoopbackServer(port: Self.callbackPort)
        defer { server.cancel() }
        let client = try await registerClient(endpoints: endpoints)
        // 3. 打开浏览器授权
        let verifier = PKCE.makeVerifier()
        let state = PKCE.makeVerifier()
        var authorize = URLComponents(url: endpoints.authorization, resolvingAgainstBaseURL: false)!
        authorize.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: "user"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "resource", value: Self.serverURL.absoluteString),
        ]
        NSWorkspace.shared.open(authorize.url!)
        // 4. 等浏览器跳回来（最多 5 分钟）
        let callback = try await withTimeout(seconds: 300, cancel: { server.cancel() }) {
            try await server.waitForCallback()
        }
        guard case .success(let code, let returnedState) = callback else {
            if case .failure(let reason) = callback {
                throw MCPError.server(reason == "access_denied" ? "你取消了授权" : reason)
            }
            return
        }
        guard returnedState == state else { throw MCPError.badResponse("授权状态不匹配，请重试") }
        // 5. 用授权码换令牌
        let token = try await requestToken(endpoint: endpoints.token, form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": client.id,
            "client_secret": client.secret,
            "code_verifier": verifier,
            "resource": Self.serverURL.absoluteString,
        ])
        let saved = DingTalkCredentials(tokenEndpoint: endpoints.token, clientID: client.id, clientSecret: client.secret,
                                        accessToken: token.accessToken, refreshToken: token.refreshToken,
                                        expiresAt: token.expiresAt)
        Keychain.save(saved)
        credentials = saved
    }

    private func registerClient(endpoints: OAuthEndpoints) async throws -> (id: String, secret: String) {
        guard let registration = endpoints.registration else { throw MCPError.badResponse("钉钉不支持自动登记应用") }
        let body: [String: Any] = [
            "client_name": "星期五 RestBreak",
            "redirect_uris": [Self.redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "client_secret_post",
            "scope": "user",
        ]
        var request = URLRequest(url: registration)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let id = json["client_id"] as? String, let secret = json["client_secret"] as? String else {
            throw MCPError.server(json["error_description"] as? String ?? "登记应用失败")
        }
        return (id, secret)
    }

    private struct TokenResponse {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
    }

    private func requestToken(endpoint: URL, form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "")
            .replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let access = json["access_token"] as? String else {
            if json["error"] as? String == "invalid_grant" { throw MCPError.unauthorized }
            throw MCPError.server(json["error_description"] as? String ?? json["error"] as? String ?? "获取令牌失败")
        }
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue
        return TokenResponse(accessToken: access, refreshToken: json["refresh_token"] as? String,
                             expiresAt: expiresIn.map { Date().addingTimeInterval($0) })
    }

    // MARK: - 查询日程

    func refresh() async {
        guard isLoggedIn, !isFetching else { return }
        isFetching = true
        defer { isFetching = false }
        let now = Date()
        do {
            let window = DingTalkQuery.window(now: now)
            let events = try await fetchEvents(from: window.start, to: window.end)
            cachedEvents = events
            lastSync = (now, CalendarEvent.upcomingCount(events, now: now))
            status = .connected
        } catch MCPError.unauthorized {
            logout()
            status = .failed(MCPError.unauthorized.localizedDescription)
        } catch {
            // 网络临时出错：保留上一次的日程，稍后重试
            status = .failed(error.localizedDescription)
        }
        fetchedAt = now
    }

    private func fetchEvents(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        try await refreshTokenIfNeeded()
        do {
            return try await queryEvents(from: start, to: end)
        } catch MCPError.unauthorized {
            // 令牌被提前作废：续期一次再试
            try await refreshTokenIfNeeded(force: true)
            return try await queryEvents(from: start, to: end)
        }
    }

    private func refreshTokenIfNeeded(force: Bool = false) async throws {
        guard var saved = credentials else { throw MCPError.unauthorized }
        let expiresSoon = saved.expiresAt.map { $0.timeIntervalSinceNow < 120 } ?? false
        guard force || expiresSoon else { return }
        guard let refreshToken = saved.refreshToken else { throw MCPError.unauthorized }
        let token = try await requestToken(endpoint: saved.tokenEndpoint, form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": saved.clientID,
            "client_secret": saved.clientSecret,
            "resource": Self.serverURL.absoluteString,
        ])
        saved.accessToken = token.accessToken
        saved.refreshToken = token.refreshToken ?? refreshToken
        saved.expiresAt = token.expiresAt
        Keychain.save(saved)
        credentials = saved
    }

    private func queryEvents(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        guard let token = credentials?.accessToken else { throw MCPError.unauthorized }
        let session = MCPSession(url: Self.serverURL, accessToken: token)
        try await session.initialize()
        if querySchema == nil {
            let tools = try await session.request("tools/list", params: [:])
            let tool = (tools["tools"] as? [[String: Any]])?.first { $0["name"] as? String == DingTalkQuery.toolName }
            querySchema = tool?["inputSchema"] as? [String: Any] ?? [:]
        }
        let arguments = DingTalkQuery.arguments(schema: querySchema ?? [:], start: start, end: end, timeZone: .current)
        let result = try await session.request("tools/call",
                                               params: ["name": DingTalkQuery.toolName, "arguments": arguments])
        return DingTalkEventParser.busyEvents(fromToolText: try MCPResponse.toolText(result))
    }
}

// MARK: - OAuth 配置发现

private struct OAuthEndpoints {
    let authorization: URL
    let token: URL
    let registration: URL?

    /// MCP 标准：未登录访问服务会返回 401，里面指明授权服务器；再读授权服务器的公开配置
    static func discover(resource: URL) async throws -> OAuthEndpoints {
        var probe = URLRequest(url: resource)
        probe.httpMethod = "POST"
        probe.setValue("application/json", forHTTPHeaderField: "Content-Type")
        probe.httpBody = Data(#"{"jsonrpc":"2.0","id":0,"method":"ping"}"#.utf8)
        let (_, response) = try await URLSession.shared.data(for: probe)
        let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "WWW-Authenticate") ?? ""
        guard let range = header.range(of: #"resource_metadata="([^"]+)""#, options: .regularExpression),
              let metadataURL = URL(string: String(header[range].dropFirst(19).dropLast())) else {
            throw MCPError.badResponse("找不到钉钉的授权配置")
        }
        let resourceMeta = try await fetchJSON(metadataURL)
        guard let server = (resourceMeta["authorization_servers"] as? [String])?.first,
              let serverURL = URL(string: server) else { throw MCPError.badResponse("找不到钉钉的授权服务器") }
        let meta = try await fetchJSON(serverURL.appendingPathComponent(".well-known/oauth-authorization-server"))
        guard let authorization = (meta["authorization_endpoint"] as? String).flatMap(URL.init(string:)),
              let token = (meta["token_endpoint"] as? String).flatMap(URL.init(string:)) else {
            throw MCPError.badResponse("钉钉授权配置不完整")
        }
        return OAuthEndpoints(authorization: authorization, token: token,
                              registration: (meta["registration_endpoint"] as? String).flatMap(URL.init(string:)))
    }

    private static func fetchJSON(_ url: URL) async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}

// MARK: - MCP 会话（Streamable HTTP）

private final class MCPSession {
    private let url: URL
    private let accessToken: String
    private var sessionID: String?
    private var nextID = 1

    init(url: URL, accessToken: String) {
        self.url = url
        self.accessToken = accessToken
    }

    func initialize() async throws {
        _ = try await request("initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "clientInfo": ["name": "RestBreak", "version": "0.2"],
        ])
        try await send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        let (data, response) = try await send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        return try MCPResponse.parse(data, contentType: response.value(forHTTPHeaderField: "Content-Type"), id: id)
    }

    @discardableResult
    private func send(_ body: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPError.badResponse("没有收到回应") }
        if http.statusCode == 401 { throw MCPError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw MCPError.server("HTTP \(http.statusCode) \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        if let id = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = id }
        return (data, http)
    }
}

// MARK: - 本机回调端口

/// 登录时在 127.0.0.1 上临时监听一个端口，接收浏览器跳回来的授权码；只接受本机连接，收到后立即关闭
private final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var continuation: CheckedContinuation<OAuthCallback, Error>?
    private var finished = false

    init(port: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw MCPError.server("本机端口 \(port) 被占用，请稍后再试")
        }
    }

    func waitForCallback() async throws -> OAuthCallback {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.finish(.failure(MCPError.server("无法打开本机登录端口"))) }
            }
            listener.start(queue: .global())
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            guard let callback = OAuthCallback.parse(request) else {
                Self.reply(connection, status: "404 Not Found", body: "")
                return
            }
            let succeeded = if case .success = callback { true } else { false }
            Self.reply(connection, status: "200 OK", body: Self.page(success: succeeded))
            self?.finish(.success(callback))
        }
    }

    private func finish(_ result: Result<OAuthCallback, Error>) {
        let pending: CheckedContinuation<OAuthCallback, Error>? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            defer { continuation = nil }
            return continuation
        }
        listener.cancel()
        pending?.resume(with: result)
    }

    private static func reply(_ connection: NWConnection, status: String, body: String) {
        let bytes = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func page(success: Bool) -> String {
        let title = success ? "已连接钉钉日历" : "没有完成授权"
        let detail = success ? "可以关闭这个页面，回到「星期五」了。" : "请回到「星期五」重新登录。"
        return """
        <!doctype html><html lang="zh"><meta charset="utf-8"><title>\(title)</title>
        <body style="font-family:-apple-system,sans-serif;display:flex;height:90vh;align-items:center;justify-content:center;background:#f7f7f8;color:#1c1c1e">
        <div style="text-align:center"><div style="font-size:44px">\(success ? "☕️" : "⚠️")</div>
        <h2 style="font-weight:600">\(title)</h2><p style="color:#8a8a8e">\(detail)</p></div></body></html>
        """
    }
}

/// 给异步操作加超时：超时后调用 cancel 并抛出错误
private func withTimeout<T: Sendable>(seconds: Double, cancel: @escaping @Sendable () -> Void,
                                      _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let timer = Task {
        try await Task.sleep(for: .seconds(seconds))
        cancel()
    }
    defer { timer.cancel() }
    return try await withTaskCancellationHandler {
        do {
            return try await operation()
        } catch is CancellationError where !Task.isCancelled {
            throw MCPError.server("等待授权超时，请重新登录")
        }
    } onCancel: {
        cancel()
    }
}

// MARK: - 钥匙串

/// 保存在钥匙串里的钉钉登录信息
struct DingTalkCredentials: Codable, KeychainItem {
    static let account = "dingtalk-calendar"
    var tokenEndpoint: URL
    var clientID: String
    var clientSecret: String
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: Date?
}

protocol KeychainItem: Codable {
    static var account: String { get }
}

/// 把一个 Codable 值以 JSON 形式存进 Mac 钥匙串（只有「星期五」自己能读）
enum Keychain {
    private static let service = "com.lizhiming.RestBreak"

    static func save<T: KeychainItem>(_ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        delete(T.self)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: T.account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load<T: KeychainItem>(_ type: T.Type) -> T? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: T.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func delete<T: KeychainItem>(_ type: T.Type) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: T.account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
