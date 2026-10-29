import Foundation
import Testing
@testable import RestBreak

/// 钉钉日历接入里可以离线测试的部分：PKCE、回调解析、MCP 返回解析、日程提取、查询参数
struct DingTalkTests {
    @Test func PKCE_S256_符合RFC7636示例() {
        // 预期值用 Python 独立计算：base64url(sha256(verifier)) 去掉末尾 =
        let verifier = "dBjftJeZ4CVP-mJ92ZNJu4R9n0fFNGqZWo6W5lQlbM0"
        #expect(PKCE.challenge(for: verifier) == "o4ysMGguqymrnzdFVmoPOIAnlIahJulRZfSHMj8Oz8o")
        let generated = PKCE.makeVerifier()
        #expect(generated.count >= 43 && generated.count <= 128)
        #expect(generated.allSatisfy { $0.isLetter || $0.isNumber || "-._~".contains($0) })
    }

    @Test func 解析浏览器回调请求() {
        let ok = "GET /callback?code=abc%2F123&state=xyz HTTP/1.1\r\nHost: 127.0.0.1:38127\r\n\r\n"
        #expect(OAuthCallback.parse(ok) == .success(code: "abc/123", state: "xyz"))
        let denied = "GET /callback?error=access_denied&state=xyz HTTP/1.1\r\n\r\n"
        #expect(OAuthCallback.parse(denied) == .failure("access_denied"))
        #expect(OAuthCallback.parse("GET /favicon.ico HTTP/1.1\r\n\r\n") == nil)
    }

    @Test func 解析MCP返回_普通JSON和SSE两种格式() throws {
        let json = #"{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"hi"}]}}"#
        let a = try MCPResponse.parse(Data(json.utf8), contentType: "application/json", id: 3)
        #expect(a["content"] != nil)

        let sse = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\nevent: message\ndata: \(json)\n\n"
        let b = try MCPResponse.parse(Data(sse.utf8), contentType: "text/event-stream", id: 3)
        #expect(b["content"] != nil)

        let err = #"{"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"bad params"}}"#
        #expect(throws: MCPError.self) { try MCPResponse.parse(Data(err.utf8), contentType: "application/json", id: 3) }
    }

    @Test func 从日程列表里提取时间段_排除全天取消和已拒绝() throws {
        let text = """
        {"events":[
          {"summary":"周会","start":{"dateTime":"2026-10-21T10:00:00+08:00"},"end":{"dateTime":"2026-10-21T11:00:00+08:00"}},
          {"summary":"全天","start":{"date":"2026-10-21"},"end":{"date":"2026-10-22"},"isAllDay":true},
          {"summary":"取消了","status":"cancelled","start":{"dateTime":"2026-10-21T12:00:00+08:00"},"end":{"dateTime":"2026-10-21T13:00:00+08:00"}},
          {"summary":"拒绝了","start":{"dateTime":"2026-10-21T14:00:00+08:00"},"end":{"dateTime":"2026-10-21T15:00:00+08:00"},
           "attendees":[{"self":true,"responseStatus":"declined"}]},
          {"summary":"毫秒时间戳","startTime":1792560600000,"endTime":1792564200000}
        ]}
        """
        let events = DingTalkEventParser.busyEvents(fromToolText: text)
        #expect(events.map(\.title) == ["周会", "毫秒时间戳"])
        let iso = ISO8601DateFormatter()
        #expect(events.first?.interval.start == iso.date(from: "2026-10-21T02:00:00Z"))
        #expect(events.last?.interval.duration == 3600)
    }

    /// 字段结构照抄钉钉真实返回（内容是编的）：start/end 里 date 和 dateTime 一个有值一个为 null
    @Test func 钉钉真实格式_空值字段和空闲日程() {
        let text = """
        {"result":{"hasMore":false,"events":[
          {"summary":"评审会","freeBusy":"BUSY","isAllDay":false,"status":"confirmed",
           "start":{"date":null,"dateTime":"2026-10-21T10:00:00+08:00","timeZone":"Asia/Shanghai"},
           "end":{"date":null,"dateTime":"2026-10-21T11:00:00+08:00","timeZone":"Asia/Shanghai"},
           "attendees":[{"displayName":"甲","self":false,"responseStatus":"accepted"},
                        {"displayName":"我","self":true,"responseStatus":"needsAction"}],
           "organizer":{"displayName":"甲","self":false}},
          {"summary":"标记空闲","freeBusy":"FREE","isAllDay":false,"status":"confirmed",
           "start":{"date":null,"dateTime":"2026-10-21T12:00:00+08:00"},"end":{"date":null,"dateTime":"2026-10-21T13:00:00+08:00"}},
          {"summary":"全天","freeBusy":"BUSY","isAllDay":true,"status":"confirmed",
           "start":{"date":"2026-10-21","dateTime":null},"end":{"date":"2026-10-22","dateTime":null}},
          {"summary":"全天没标记","start":{"date":"2026-10-21","dateTime":null},"end":{"date":"2026-10-22","dateTime":null}}
        ]}}
        """
        let events = DingTalkEventParser.busyEvents(fromToolText: text)
        #expect(events.map(\.title) == ["评审会"])
        #expect(events.first?.interval.duration == 3600)
    }

    @Test func 查询从8小时前开始_不漏掉进行中的长会() {
        let now = Date(timeIntervalSince1970: 1_792_560_000)
        #expect(DingTalkQuery.window(now: now).start == now - 8 * 3600)
        #expect(DingTalkQuery.window(now: now).end == now + 12 * 3600)
    }

    @Test func 按工具说明生成查询参数() {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "calendarId": ["type": "string"],
                "timeMin": ["type": "string"],
                "timeMax": ["type": "string"],
                "maxResults": ["type": "integer"],
            ],
        ]
        let start = Date(timeIntervalSince1970: 1_792_560_000)
        let args = DingTalkQuery.arguments(schema: schema, start: start, end: start + 3600,
                                           timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        #expect(args["calendarId"] as? String == "primary")
        #expect(args["timeMin"] as? String == "2026-10-21T13:20:00+08:00")
        #expect(args["timeMax"] as? String == "2026-10-21T14:20:00+08:00")
        #expect(args["maxResults"] as? Int == 100)

        let numeric: [String: Any] = ["properties": ["startTime": ["type": "integer"], "endTime": ["type": "number"]]]
        let args2 = DingTalkQuery.arguments(schema: numeric, start: start, end: start + 60, timeZone: .current)
        #expect(args2["startTime"] as? Int64 == 1_792_560_000_000)
        #expect(args2["endTime"] as? Int64 == 1_792_560_060_000)
    }

    @Test func 日程数只算还没结束的_已结束和12小时以后的不算() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func event(_ startHours: Double, _ hours: Double) -> CalendarEvent {
            CalendarEvent(title: "x", interval: DateInterval(start: now + startHours * 3600, duration: hours * 3600))
        }
        let events = [
            event(-6, 1),     // 今天下午已经开完的会（这次的问题）
            event(-0.5, 1),   // 正在开
            event(3, 1),      // 3 小时后
            event(13, 1),     // 12 小时以后
        ]
        #expect(CalendarEvent.upcomingCount(events, now: now) == 2)
    }
}
