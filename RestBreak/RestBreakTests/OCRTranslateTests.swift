import Foundation
import Testing
@testable import RestBreak

/// 第三期：OCR 排版、腾讯云翻译协议
struct OCRTranslateTests {
    // MARK: - OCR 排版

    private func line(_ text: String, x: CGFloat = 0, y: CGFloat, h: CGFloat = 20) -> RecognizedLine {
        RecognizedLine(text: text, frame: CGRect(x: x, y: y, width: 100, height: h))
    }

    @Test func 按从上到下排列_行距大时分段() {
        let lines = [line("第二段", y: 120), line("第一行", y: 0), line("第二行", y: 26)]
        #expect(OCRLayout.text(from: lines) == "第一行\n第二行\n\n第二段")
    }

    @Test func 同一行的几段用空格连起来() {
        let lines = [line("39s", x: 300, y: 2), line("Render all annotation kinds", x: 0, y: 0)]
        #expect(OCRLayout.text(from: lines) == "Render all annotation kinds  39s")
    }

    @Test func 统计行数和字数() {
        let stats = OCRLayout.stats("你好 world\n\n第二行")
        #expect(stats.lines == 2)
        #expect(stats.characters == 11)   // 不算换行
        #expect(OCRLayout.text(from: []) == "")
    }

    // MARK: - 翻译方向和分段

    @Test func 中文多就翻成英文_否则翻成中文() {
        #expect(TencentTranslate.defaultTarget(for: "想用这个页面 as 首屏") == "en")
        #expect(TencentTranslate.defaultTarget(for: "Background tasks 后台") == "zh")
        #expect(TencentTranslate.defaultTarget(for: "こんにちは") == "zh")
    }

    @Test func 长文本按行分段_单行太长硬切() {
        let text = String(repeating: "a", count: 1500) + "\n" + String(repeating: "b", count: 1500)
        #expect(TencentTranslate.chunks(text, limit: 2000).count == 2)
        #expect(TencentTranslate.chunks(text, limit: 2000).joined(separator: "\n") == text)
        let long = String(repeating: "c", count: 4500)
        let parts = TencentTranslate.chunks(long, limit: 2000)
        #expect(parts.map(\.count) == [2000, 2000, 500])
        #expect(TencentTranslate.chunks("短", limit: 2000) == ["短"])
    }

    // MARK: - 签名（对照腾讯云官方文档示例中不依赖密钥的部分）

    /// 官方示例：https://cloud.tencent.com/document/api/551/30636
    private let officialPayload =
        #"{"Limit": 1, "Filters": [{"Values": ["\u672a\u547d\u540d"], "Name": "instance-name"}]}"#

    @Test func 请求体哈希和官方示例一致() {
        #expect(TencentTranslate.sha256Hex(officialPayload)
                == "35e9c5b0e3ae67532d3c9f17ead6c90222632e5b1ff7f6e89887f1398934f064")
    }

    @Test func 规范请求哈希和官方示例一致() {
        let canonical = TencentTranslate.canonicalRequest(host: "cvm.tencentcloudapi.com",
                                                          action: "DescribeInstances", payload: officialPayload)
        #expect(TencentTranslate.sha256Hex(canonical)
                == "7019a55be8395899b900fb5564e4200d984910f34794a27cb3fb7d10ff6a1e84")
        let toSign = TencentTranslate.stringToSign(canonicalRequest: canonical, timestamp: 1551113065, service: "cvm")
        #expect(toSign.hasPrefix("TC3-HMAC-SHA256\n1551113065\n2019-02-25/cvm/tc3_request\n7019a55b"))
    }

    @Test func HMAC符合RFC4231() {
        // RFC 4231 Test Case 2
        let mac = TencentTranslate.hmac(key: Data("Jefe".utf8), "what do ya want for nothing?")
        #expect(mac.map { String(format: "%02x", $0) }.joined()
                == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    }

    @Test func Authorization格式() {
        let auth = TencentTranslate.authorization(
            credentials: .init(secretId: "AKIDtest", secretKey: "key"), timestamp: 1551113065,
            payload: "{}", action: "TextTranslate", host: TencentTranslate.host, service: TencentTranslate.service)
        #expect(auth.hasPrefix("TC3-HMAC-SHA256 Credential=AKIDtest/2019-02-25/tmt/tc3_request, SignedHeaders=content-type;host;x-tc-action, Signature="))
        #expect(auth.count == "TC3-HMAC-SHA256 Credential=AKIDtest/2019-02-25/tmt/tc3_request, SignedHeaders=content-type;host;x-tc-action, Signature=".count + 64)
    }

    @Test func 请求带齐腾讯云要求的头() throws {
        let request = try TencentTranslate.request(text: "你好", target: "en",
                                                   credentials: .init(secretId: "id", secretKey: "key"),
                                                   now: Date(timeIntervalSince1970: 1551113065))
        #expect(request.url?.absoluteString == "https://tmt.tencentcloudapi.com/")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "X-TC-Action") == "TextTranslate")
        #expect(request.value(forHTTPHeaderField: "X-TC-Version") == "2018-03-21")
        #expect(request.value(forHTTPHeaderField: "X-TC-Timestamp") == "1551113065")
        #expect(request.value(forHTTPHeaderField: "X-TC-Region") == "ap-guangzhou")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["SourceText"] as? String == "你好")
        #expect(json["Source"] as? String == "auto")
        #expect(json["Target"] as? String == "en")
        #expect(json["ProjectId"] as? Int == 0)
    }

    // MARK: - 响应解析

    @Test func 解析成功响应() {
        let data = Data(#"{"Response":{"TargetText":"Hello","Source":"zh","Target":"en","RequestId":"x"}}"#.utf8)
        #expect(TencentTranslate.parse(data) == .success("Hello"))
    }

    @Test func 错误码翻译成中文原因() {
        func error(_ code: String) -> TranslateError? {
            let data = Data(#"{"Response":{"Error":{"Code":"\#(code)","Message":"m"},"RequestId":"x"}}"#.utf8)
            if case .failure(let e) = TencentTranslate.parse(data) { return e }
            return nil
        }
        #expect(error("AuthFailure.SecretIdNotFound") == .invalidKey)
        #expect(error("AuthFailure.SignatureFailure") == .invalidKey)
        #expect(error("AuthFailure.SignatureExpire") == .clockSkew)
        #expect(error("FailedOperation.NoFreeAmount") == .quotaExhausted)
        #expect(error("FailedOperation.ServiceIsolate") == .quotaExhausted)
        #expect(error("FailedOperation.UserNotRegistered") == .notActivated)
        #expect(error("RequestLimitExceeded") == .rateLimited)
        #expect(error("InternalError") == .server("m"))
        #expect(TencentTranslate.parse(Data("oops".utf8)) == .failure(.server("返回内容无法识别")))
        #expect(TranslateError.missingKey.message.contains("密钥"))
    }
}
