import Foundation

// 本机 MCP 地址（2026-10-28）：星期五在 http://127.0.0.1:<端口>/mcp 上提供 MCP（Streamable HTTP），
// 用户把「地址 + 密钥」交给自己的 AI，AI 自己加进配置（和瑞幸 MCP 一样的接法）。
// 这里是协议部分：纯逻辑，不碰网络，方便测试；网络监听在主 App 的 LocalMCPServer。
// 只回 JSON，不开 SSE：星期五不会主动给 AI 发消息，所以 GET 一律 405。

/// 一个 HTTP 请求（头的名字都转成小写）
struct HTTPMessage: Equatable, Sendable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
}

struct HTTPReply: Equatable, Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()

    static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> HTTPReply {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
        return HTTPReply(status: status, headers: headers.merging(["Content-Type": "application/json"]) { a, _ in a }, body: data)
    }

    /// 按 HTTP/1.1 写出来（每次回复后关闭连接）
    var serialized: Data {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// 从收到的字节里切出一个完整的 HTTP 请求（支持 Content-Length 和 chunked）
enum HTTPParser {
    enum Result: Equatable {
        case incomplete
        case invalid
        case tooLarge
        case complete(HTTPMessage)
    }

    static let maxBody = 1_000_000

    static func parse(_ data: Data) -> Result {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 64_000 ? .tooLarge : .incomplete
        }
        let lines = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ")
        guard start.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let rest = data[end.upperBound...]
        let body: Data
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            switch dechunk(Data(rest)) {
            case .none: return rest.count > maxBody ? .tooLarge : .incomplete
            case .some(let decoded): body = decoded
            }
        } else {
            let length = Int(headers["content-length"] ?? "0") ?? -1
            guard length >= 0 else { return .invalid }
            guard length <= maxBody else { return .tooLarge }
            guard rest.count >= length else { return .incomplete }
            body = Data(rest.prefix(length))
        }
        let target = String(start[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        return .complete(HTTPMessage(method: String(start[0]).uppercased(), path: path, headers: headers, body: body))
    }

    /// chunked 解码；还没收完返回 nil
    private static func dechunk(_ data: Data) -> Data? {
        var out = Data()
        var index = data.startIndex
        while true {
            guard let lineEnd = data[index...].firstRange(of: Data("\r\n".utf8)) else { return nil }
            let sizeText = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
            index = lineEnd.upperBound
            if size == 0 { return out }
            guard data.distance(from: index, to: data.endIndex) >= size + 2 else { return nil }
            let chunkEnd = data.index(index, offsetBy: size)
            out += data[index..<chunkEnd]
            index = data.index(chunkEnd, offsetBy: 2)
        }
    }
}

/// MCP 的 JSON-RPC 处理：鉴权、initialize、tools/list、tools/call、ping
final class LocalMCPProtocol {
    static let path = "/mcp"
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    /// 设置页「换密钥」时直接改，已有的会话记录保留
    var token: String
    let version: String
    /// 调用一个工具（工具名、参数、客户端名）
    let callTool: (String, [String: Any], String) -> ToolResult
    /// 有 AI 连上来了（客户端名）
    let onClient: (String) -> Void

    /// Mcp-Session-Id → 客户端名。只用来知道是谁在调用，丢了也不影响使用
    private var sessions: [String: String] = [:]

    init(token: String, version: String, callTool: @escaping (String, [String: Any], String) -> ToolResult,
         onClient: @escaping (String) -> Void) {
        self.token = token
        self.version = version
        self.callTool = callTool
        self.onClient = onClient
    }

    func handle(_ request: HTTPMessage) -> HTTPReply {
        guard request.path == Self.path else { return HTTPReply(status: 404) }
        // 防 DNS 重绑定：带 Origin 的只接受本机网页
        if let origin = request.headers["origin"], let host = URL(string: origin)?.host,
           !["127.0.0.1", "localhost", "::1"].contains(host) {
            return HTTPReply(status: 403)
        }
        guard request.headers["authorization"] == "Bearer \(token)" else {
            return HTTPReply.json(["error": "密钥不对：请在星期五「设置 › 提醒 › 连接 AI」重新复制接入方式"], status: 401,
                                  headers: ["WWW-Authenticate": "Bearer"])
        }
        guard request.method == "POST" else { return HTTPReply(status: 405, headers: ["Allow": "POST"]) }
        guard let parsed = try? JSONSerialization.jsonObject(with: request.body) else {
            return .json(error(id: NSNull(), code: -32700, message: "不是合法的 JSON"), status: 400)
        }
        let session = request.headers["mcp-session-id"]
        var extraHeaders: [String: String] = [:]
        let messages = (parsed as? [Any]) ?? [parsed]
        var replies: [[String: Any]] = []
        for case let message as [String: Any] in messages {
            guard let method = message["method"] as? String else { continue }   // AI 回给我们的响应：不需要
            guard let id = message["id"], !(id is NSNull) else { continue }      // 通知：不用回
            let params = message["params"] as? [String: Any] ?? [:]
            if method == "initialize" {
                let (reply, newSession) = initialize(id: id, params: params)
                extraHeaders["Mcp-Session-Id"] = newSession
                replies.append(reply)
            } else {
                replies.append(respond(id: id, method: method, params: params, client: client(for: session)))
            }
        }
        if replies.isEmpty { return HTTPReply(status: 202) }
        return .json(parsed is [Any] ? replies : replies[0], headers: extraHeaders)
    }

    private func initialize(id: Any, params: [String: Any]) -> ([String: Any], String) {
        let name = (params["clientInfo"] as? [String: Any])?["name"] as? String ?? "unknown"
        let session = UUID().uuidString
        if sessions.count >= 50 { sessions.removeAll() }
        sessions[session] = name
        onClient(name)
        let asked = params["protocolVersion"] as? String ?? ""
        let result: [String: Any] = [
            "protocolVersion": Self.supportedVersions.contains(asked) ? asked : Self.supportedVersions[0],
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "friday", "title": "星期五", "version": version],
            "instructions": ReminderTools.instructions,
        ]
        return (success(id: id, result), session)
    }

    private func respond(id: Any, method: String, params: [String: Any], client: String) -> [String: Any] {
        switch method {
        case "ping":
            return success(id: id, [String: Any]())
        case "tools/list":
            return success(id: id, ["tools": Self.toolList])
        case "tools/call":
            guard let name = params["name"] as? String else { return error(id: id, code: -32602, message: "缺少工具名 name") }
            let result = callTool(name, params["arguments"] as? [String: Any] ?? [:], client)
            return success(id: id, ["content": [["type": "text", "text": result.text]], "isError": result.isError])
        default:
            return error(id: id, code: -32601, message: "不支持的方法：\(method)")
        }
    }

    private func client(for session: String?) -> String {
        session.flatMap { sessions[$0] } ?? "unknown"
    }

    private func success(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    static var toolList: [[String: Any]] {
        AllTools.specs.map { spec in
        [
            "name": spec.name,
            "description": spec.description,
            "inputSchema": (try? JSONSerialization.jsonObject(with: Data(spec.schema.utf8))) ?? [:],
            "annotations": ["readOnlyHint": spec.readOnly, "destructiveHint": spec.destructive],
        ]
        }
    }
}
