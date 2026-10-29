import CryptoKit
import Foundation

// 钉钉日历接入里不涉及网络的部分：PKCE、回调解析、MCP 返回解析、日程提取、查询参数。
// 只依赖 Foundation / CryptoKit，方便单元测试。

/// OAuth PKCE：登录时先生成一个随机「验证码」，只把它的哈希发给钉钉，换令牌时再出示原文，防止授权码被截获后冒用
enum PKCE {
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// 钉钉授权完成后浏览器会访问 http://127.0.0.1:端口/callback?code=…，这里解析这个请求
enum OAuthCallback: Equatable {
    case success(code: String, state: String)
    case failure(String)

    /// 不是 /callback 请求（比如浏览器顺带请求的 favicon）时返回 nil
    static func parse(_ request: String) -> OAuthCallback? {
        guard let line = request.split(separator: "\r\n", omittingEmptySubsequences: false).first,
              line.hasPrefix("GET "),
              let target = line.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://127.0.0.1" + target),
              components.path == "/callback" else { return nil }
        let items = Dictionary(components.queryItems?.map { ($0.name, $0.value ?? "") } ?? [],
                               uniquingKeysWith: { first, _ in first })
        if let error = items["error"] { return .failure(error) }
        guard let code = items["code"] else { return .failure("没有收到授权码") }
        return .success(code: code, state: items["state"] ?? "")
    }
}

enum MCPError: Error, LocalizedError {
    case server(String)
    case unauthorized
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .server(let message): "钉钉返回错误：\(message)"
        case .unauthorized: "钉钉登录已失效，请重新登录"
        case .badResponse(let detail): "钉钉返回的数据看不懂：\(detail)"
        }
    }
}

/// MCP 的 HTTP 返回可能是普通 JSON，也可能是 SSE 流（多条 data: 消息），这里统一取出对应请求的 result
enum MCPResponse {
    static func parse(_ data: Data, contentType: String?, id: Int) throws -> [String: Any] {
        let messages: [Any]
        if contentType?.contains("text/event-stream") == true {
            let text = String(decoding: data, as: UTF8.self)
            messages = text.split(whereSeparator: \.isNewline)
                .filter { $0.hasPrefix("data:") }
                .compactMap { try? JSONSerialization.jsonObject(with: Data($0.dropFirst(5).utf8)) }
        } else {
            guard let object = try? JSONSerialization.jsonObject(with: data) else {
                throw MCPError.badResponse(String(decoding: data.prefix(200), as: UTF8.self))
            }
            messages = (object as? [Any]) ?? [object]
        }
        for case let message as [String: Any] in messages where (message["id"] as? Int) == id {
            if let error = message["error"] as? [String: Any] {
                throw MCPError.server(error["message"] as? String ?? "未知错误")
            }
            if let result = message["result"] as? [String: Any] { return result }
        }
        throw MCPError.badResponse("没有找到第 \(id) 号请求的结果")
    }

    /// tools/call 的结果：把 content 里所有文字拼起来（钉钉把日程 JSON 放在文字里）
    static func toolText(_ result: [String: Any]) throws -> String {
        if result["isError"] as? Bool == true {
            let text = (result["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
            throw MCPError.server(text.isEmpty ? "工具调用失败" : text)
        }
        if let structured = result["structuredContent"],
           let data = try? JSONSerialization.data(withJSONObject: structured) {
            return String(decoding: data, as: UTF8.self)
        }
        return (result["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
    }
}

/// 从钉钉返回的日程数据里提取「忙碌的时间段」。
/// 不依赖固定字段结构：递归找带开始/结束时间的对象，兼容 ISO 时间、毫秒时间戳、{dateTime: …} 嵌套。
enum DingTalkEventParser {
    static func events(fromToolText text: String) -> [CalendarEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return [] }
        var found: [CalendarEvent] = []
        collect(object, into: &found)
        return found.sorted { $0.interval.start < $1.interval.start }
    }

    private static func collect(_ object: Any, into found: inout [CalendarEvent]) {
        if let array = object as? [Any] {
            array.forEach { collect($0, into: &found) }
            return
        }
        guard let dict = object as? [String: Any] else { return }
        if let event = event(from: dict) {
            found.append(event)
            return
        }
        dict.values.forEach { collect($0, into: &found) }
    }

    private static func event(from dict: [String: Any]) -> CalendarEvent? {
        guard let startValue = dict["start"] ?? dict["startTime"],
              let endValue = dict["end"] ?? dict["endTime"] else { return nil }
        // 全天日程（只有 date 没有 dateTime）、标为「空闲」的日程不算
        if dict["isAllDay"] as? Bool == true { return CalendarEvent.skipped }
        if (dict["freeBusy"] as? String)?.uppercased() == "FREE" { return CalendarEvent.skipped }
        guard let start = date(startValue), let end = date(endValue), end > start else {
            return isAllDayValue(startValue) ? CalendarEvent.skipped : nil
        }
        let status = (dict["status"] as? String)?.lowercased()
        if status == "cancelled" || status == "canceled" { return CalendarEvent.skipped }
        // 自己已拒绝的不算
        if let attendees = dict["attendees"] as? [[String: Any]],
           let me = attendees.first(where: { $0["self"] as? Bool == true }),
           (me["responseStatus"] as? String)?.lowercased() == "declined" { return CalendarEvent.skipped }
        let title = (dict["summary"] ?? dict["title"] ?? dict["subject"]) as? String ?? "钉钉日程"
        return CalendarEvent(title: title, interval: DateInterval(start: start, end: end))
    }

    private static func isAllDayValue(_ value: Any) -> Bool {
        guard let dict = value as? [String: Any] else { return false }
        return present(dict["date"]) != nil && present(dict["dateTime"]) == nil
    }

    /// JSON 里的 null 会变成 NSNull，当成「没有这个字段」
    private static func present(_ value: Any?) -> Any? {
        value is NSNull ? nil : value
    }

    /// 解析 ISO 时间，带不带毫秒都行（日程最多几十条，每次新建格式器的开销可以忽略）
    private static var isoFormatters: [ISO8601DateFormatter] {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [plain, fractional]
    }

    private static func date(_ value: Any) -> Date? {
        if let dict = value as? [String: Any] {
            return (present(dict["dateTime"]) ?? present(dict["timestamp"])).flatMap(date)
        }
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 1e11 ? raw / 1000 : raw)   // 毫秒或秒
        }
        if let string = value as? String {
            if let number = Double(string) { return date(NSNumber(value: number)) }
            return isoFormatters.lazy.compactMap { $0.date(from: string) }.first
        }
        return nil
    }
}

private extension CalendarEvent {
    /// 识别出是日程、但不该算忙碌（全天、取消、已拒绝）：用一个空时间段占位，之后过滤掉
    static let skipped = CalendarEvent(title: "", interval: DateInterval(start: .distantPast, duration: 0))
}

extension DingTalkEventParser {
    /// 过滤掉占位用的「跳过」日程
    static func busyEvents(fromToolText text: String) -> [CalendarEvent] {
        events(fromToolText: text).filter { $0.interval.duration > 0 }
    }
}

/// 根据 list_calendar_events 工具的参数说明生成查询参数（参数名和时间格式以钉钉实际说明为准）
enum DingTalkQuery {
    static let toolName = "list_calendar_events"

    /// 查询范围。钉钉只返回「开始时间晚于查询起点」的日程，所以起点往前推 8 小时，避免漏掉正在开的长会
    static func window(now: Date) -> (start: Date, end: Date) {
        (now - 8 * 3600, now + 12 * 3600)
    }

    static func arguments(schema: [String: Any], start: Date, end: Date, timeZone: TimeZone) -> [String: Any] {
        let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
        var args: [String: Any] = [:]
        for (name, spec) in properties {
            let key = name.lowercased()
            let type = spec["type"] as? String
            if key.contains("calendar") && key.hasSuffix("id") {
                args[name] = "primary"
            } else if key == "timemin" || key == "starttime" || key == "start" || key == "mintime" {
                args[name] = timeValue(start, type: type, timeZone: timeZone)
            } else if key == "timemax" || key == "endtime" || key == "end" || key == "maxtime" {
                args[name] = timeValue(end, type: type, timeZone: timeZone)
            } else if key == "maxresults" || key == "pagesize" || key == "limit" {
                args[name] = 100
            }
        }
        return args
    }

    private static func timeValue(_ date: Date, type: String?, timeZone: TimeZone) -> Any {
        if type == "integer" || type == "number" {
            return Int64((date.timeIntervalSince1970 * 1000).rounded())
        }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
}
