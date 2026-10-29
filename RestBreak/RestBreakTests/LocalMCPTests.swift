import Foundation
import Testing
@testable import RestBreak

/// 本机 MCP 地址：HTTP 解析和 JSON-RPC 处理
struct LocalMCPTests {
    func request(_ body: String, method: String = "POST", path: String = "/mcp", token: String? = "t",
                 headers: [String: String] = [:]) -> HTTPMessage {
        var h = headers
        if let token { h["authorization"] = "Bearer \(token)" }
        return HTTPMessage(method: method, path: path, headers: h, body: Data(body.utf8))
    }

    func handler(calls: Box<[String]> = Box([]), clients: Box<[String]> = Box([])) -> LocalMCPProtocol {
        LocalMCPProtocol(token: "t", version: "0.7.0", callTool: { name, args, client in
            calls.value.append("\(client):\(name):\(args["x"] as? Int ?? 0)")
            return ToolResult(text: "ok", isError: false, changed: false)
        }, onClient: { clients.value.append($0) })
    }

    func json(_ reply: HTTPReply) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any] ?? [:]
    }

    @Test func 解析Content_Length请求_分段到达() {
        let raw = "POST /mcp?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 4\r\nAuthorization: Bearer t\r\n\r\nabcd"
        let data = Data(raw.utf8)
        #expect(HTTPParser.parse(data.prefix(data.count - 2)) == .incomplete)
        #expect(HTTPParser.parse(data) == .complete(HTTPMessage(method: "POST", path: "/mcp",
            headers: ["host": "127.0.0.1", "content-length": "4", "authorization": "Bearer t"], body: Data("abcd".utf8))))
    }

    @Test func 解析chunked请求() {
        let raw = "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n"
        guard case .complete(let m) = HTTPParser.parse(Data(raw.utf8)) else { Issue.record("没解析出来"); return }
        #expect(m.body == Data("abcde".utf8))
        #expect(HTTPParser.parse(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nab".utf8)) == .incomplete)
    }

    @Test func 太大的请求() {
        #expect(HTTPParser.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 2000000\r\n\r\n".utf8)) == .tooLarge)
    }

    @Test func 鉴权_路径_方法_来源() {
        let h = handler()
        #expect(h.handle(request("{}", token: nil)).status == 401)
        #expect(h.handle(request("{}", token: "wrong")).status == 401)
        #expect(h.handle(request("{}", path: "/other")).status == 404)
        #expect(h.handle(request("", method: "GET")).status == 405)
        #expect(h.handle(request("{}", headers: ["origin": "https://evil.example"])).status == 403)
        #expect(h.handle(request("not json")).status == 400)
    }

    @Test func 握手_记下客户端_后续调用带上客户端名() throws {
        let calls = Box<[String]>([]), clients = Box<[String]>([])
        let h = handler(calls: calls, clients: clients)
        let reply = h.handle(request(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"codex-mcp-client","version":"1"}}}"#))
        #expect(reply.status == 200)
        let result = try #require(json(reply)["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "friday")
        #expect(clients.value == ["codex-mcp-client"])
        let session = try #require(reply.headers["Mcp-Session-Id"])

        #expect(h.handle(request(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)).status == 202)
        let call = h.handle(request(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"push","arguments":{"x":3}}}"#,
                                    headers: ["mcp-session-id": session]))
        let content = try #require((json(call)["result"] as? [String: Any])?["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "ok")
        #expect(calls.value == ["codex-mcp-client:push:3"])
    }

    @Test func 不认识的协议版本回最新的() throws {
        let reply = handler().handle(request(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#))
        #expect((json(reply)["result"] as? [String: Any])?["protocolVersion"] as? String == LocalMCPProtocol.supportedVersions[0])
    }

    @Test func 工具列表_ping_未知方法_批量() throws {
        let h = handler()
        let list = json(h.handle(request(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)))
        let tools = try #require((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == AllTools.specs.map(\.name))
        #expect(tools.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" })
        #expect(json(h.handle(request(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)))["result"] != nil)
        #expect((json(h.handle(request(#"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#)))["error"] as? [String: Any])?["code"] as? Int == -32601)
        let batch = h.handle(request(#"[{"jsonrpc":"2.0","id":4,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/x"}]"#))
        #expect(((try JSONSerialization.jsonObject(with: batch.body)) as? [Any])?.count == 1)
    }

    @Test func 回复的HTTP格式() {
        let text = String(decoding: HTTPReply(status: 202).serialized, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 202 Accepted\r\n") && text.contains("Content-Length: 0\r\n") && text.hasSuffix("\r\n\r\n"))
    }
}

/// 真的开一个本机端口，用 URLSession 走一遍握手和工具列表
@MainActor
struct LocalMCPServerTests {
    @Test func 本机端口真的能连上() async throws {
        let defaults = try #require(UserDefaults(suiteName: "LocalMCPServerTests"))
        defaults.set(39_517, forKey: "localMCPPort")
        let server = LocalMCPServer(defaults: defaults)
        server.start()
        for _ in 0..<50 where server.url == nil { try await Task.sleep(for: .milliseconds(50)) }
        let url = try #require(server.url.flatMap(URL.init(string:)))

        func post(_ body: String, token: String) async throws -> (Int, [String: Any]) {
            var r = URLRequest(url: url)
            r.httpMethod = "POST"
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            r.httpBody = Data(body.utf8)
            let (data, response) = try await URLSession.shared.data(for: r)
            return ((response as! HTTPURLResponse).statusCode, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
        }
        #expect(try await post("{}", token: "wrong").0 == 401)
        let (status, object) = try await post(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#, token: server.token)
        #expect(status == 200)
        #expect(((object["result"] as? [String: Any])?["tools"] as? [Any])?.count == AllTools.specs.count)
        defaults.removePersistentDomain(forName: "LocalMCPServerTests")
    }
}

/// 测试里收集闭包调用结果
final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
