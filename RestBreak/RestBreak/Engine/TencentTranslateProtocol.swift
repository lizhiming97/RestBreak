import CryptoKit
import Foundation

/// 翻译失败的原因（面板上显示 message）
enum TranslateError: Error, Equatable, Sendable {
    case missingKey        // 还没在设置里填密钥
    case network           // 没联网 / 连不上
    case invalidKey        // 密钥不对
    case clockSkew         // 电脑时间不准，签名过期
    case quotaExhausted    // 免费额度用完（或欠费停用）
    case notActivated      // 腾讯云账号还没开通机器翻译
    case rateLimited       // 请求太频繁
    case server(String)    // 其他错误，附腾讯云的说明

    var message: String {
        switch self {
        case .missingKey: "还没有设置翻译密钥"
        case .network: "翻译失败，请检查网络"
        case .invalidKey: "翻译密钥不正确，请检查 SecretId 和 SecretKey"
        case .clockSkew: "电脑时间不准，请在系统设置里开启自动设置时间"
        case .quotaExhausted: "本月免费翻译额度已用完"
        case .notActivated: "腾讯云账号还没开通「机器翻译」服务"
        case .rateLimited: "请求太频繁，请稍后再试"
        case .server(let detail): "翻译失败：\(detail)"
        }
    }
}

/// 腾讯云机器翻译 TextTranslate 的协议细节（纯逻辑，方便测试）。
/// 签名方法 TC3-HMAC-SHA256：https://cloud.tencent.com/document/api/551/30636
enum TencentTranslate {
    static let host = "tmt.tencentcloudapi.com"
    static let service = "tmt"
    static let action = "TextTranslate"
    static let version = "2018-03-21"
    static let region = "ap-guangzhou"
    /// 腾讯云单次最多 6000 字符，留点余量
    static let chunkLimit = 2000

    struct Credentials: Codable, Equatable, Sendable {
        var secretId: String
        var secretKey: String

        var isComplete: Bool {
            !secretId.trimmingCharacters(in: .whitespaces).isEmpty
                && !secretKey.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    // MARK: - 方向和分段

    /// 汉字占文字类字符一半以上 → 翻成英文，否则翻成中文
    static func defaultTarget(for text: String) -> String {
        var han = 0, letters = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            if (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value) { han += 1 }
        }
        return han * 2 > letters ? "en" : "zh"
    }

    /// 按行把长文本切成不超过 limit 的几段（单行太长就硬切），依次翻译后用换行拼回去
    static func chunks(_ text: String, limit: Int = chunkLimit) -> [String] {
        // 先把每行切成不超过 limit 的小段
        var pieces: [String] = []
        for line in text.components(separatedBy: "\n") {
            var rest = Substring(line)
            while rest.count > limit {
                pieces.append(String(rest.prefix(limit)))
                rest = rest.dropFirst(limit)
            }
            pieces.append(String(rest))
        }
        // 再把相邻的小段用换行拼起来，再拼就超过 limit 时开始新的一段
        var result: [String] = []
        var current: String?
        for piece in pieces {
            if let joined = current, joined.count + 1 + piece.count <= limit {
                current = joined + "\n" + piece
            } else {
                if let current { result.append(current) }
                current = piece
            }
        }
        if let current { result.append(current) }
        return result
    }

    // MARK: - 签名

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func hmac(key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    /// 规范请求：签名的 header 固定为 content-type、host、x-tc-action
    static func canonicalRequest(host: String, action: String, payload: String) -> String {
        let headers = "content-type:application/json; charset=utf-8\nhost:\(host)\nx-tc-action:\(action.lowercased())\n"
        return ["POST", "/", "", headers, "content-type;host;x-tc-action", sha256Hex(payload)].joined(separator: "\n")
    }

    /// 签名用的日期（UTC）
    static func utcDate(_ timestamp: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    static func stringToSign(canonicalRequest: String, timestamp: Int, service: String) -> String {
        let scope = "\(utcDate(timestamp))/\(service)/tc3_request"
        return ["TC3-HMAC-SHA256", String(timestamp), scope, sha256Hex(canonicalRequest)].joined(separator: "\n")
    }

    static func authorization(credentials: Credentials, timestamp: Int, payload: String,
                              action: String, host: String, service: String) -> String {
        let date = utcDate(timestamp)
        let toSign = stringToSign(canonicalRequest: canonicalRequest(host: host, action: action, payload: payload),
                                  timestamp: timestamp, service: service)
        let secretDate = hmac(key: Data("TC3\(credentials.secretKey)".utf8), date)
        let secretService = hmac(key: secretDate, service)
        let secretSigning = hmac(key: secretService, "tc3_request")
        let signature = hmac(key: secretSigning, toSign).map { String(format: "%02x", $0) }.joined()
        return "TC3-HMAC-SHA256 Credential=\(credentials.secretId)/\(date)/\(service)/tc3_request, "
            + "SignedHeaders=content-type;host;x-tc-action, Signature=\(signature)"
    }

    // MARK: - 请求和响应

    /// 翻译一段文字的请求；源语言自动识别
    static func request(text: String, target: String, credentials: Credentials, now: Date = Date()) throws -> URLRequest {
        let body: [String: Any] = ["SourceText": text, "Source": "auto", "Target": target, "ProjectId": 0]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let payload = String(decoding: data, as: UTF8.self)
        let timestamp = Int(now.timeIntervalSince1970)

        var request = URLRequest(url: URL(string: "https://\(host)/")!, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(action, forHTTPHeaderField: "X-TC-Action")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-TC-Timestamp")
        request.setValue(version, forHTTPHeaderField: "X-TC-Version")
        request.setValue(region, forHTTPHeaderField: "X-TC-Region")
        request.setValue(authorization(credentials: credentials, timestamp: timestamp, payload: payload,
                                       action: action, host: host, service: service),
                         forHTTPHeaderField: "Authorization")
        return request
    }

    /// 解析腾讯云返回：成功拿到译文，失败把错误码翻译成中文原因
    static func parse(_ data: Data) -> Result<String, TranslateError> {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = json["Response"] as? [String: Any]
        else { return .failure(.server("返回内容无法识别")) }
        if let error = response["Error"] as? [String: Any] {
            let code = error["Code"] as? String ?? ""
            let message = error["Message"] as? String ?? code
            return .failure(Self.error(code: code, message: message))
        }
        guard let text = response["TargetText"] as? String else { return .failure(.server("返回内容无法识别")) }
        return .success(text)
    }

    private static func error(code: String, message: String) -> TranslateError {
        switch code {
        case "AuthFailure.SignatureExpire": .clockSkew
        case _ where code.hasPrefix("AuthFailure"): .invalidKey
        case "FailedOperation.NoFreeAmount", "FailedOperation.ServiceIsolate", "FailedOperation.StopUsing": .quotaExhausted
        case "FailedOperation.UserNotRegistered", "UnauthorizedOperation.ActionNotFound": .notActivated
        case "RequestLimitExceeded", "LimitExceeded": .rateLimited
        default: .server(message)
        }
    }
}
