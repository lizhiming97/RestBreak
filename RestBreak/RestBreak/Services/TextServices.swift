import Foundation
import Vision

/// 识别图片里的文字（系统 Vision，离线，不需要下载）
enum TextRecognizer {
    /// 识别并按原图位置排版；在后台线程执行，不卡界面
    static func recognize(_ image: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: image).perform([request])

            let width = CGFloat(image.width), height = CGFloat(image.height)
            let lines = (request.results ?? []).compactMap { observation -> RecognizedLine? in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                // Vision 的位置是 0～1、左下角原点，换成像素、左上角原点
                let box = observation.boundingBox
                return RecognizedLine(text: text, frame: CGRect(x: box.minX * width, y: (1 - box.maxY) * height,
                                                                width: box.width * width, height: box.height * height))
            }
            return OCRLayout.text(from: lines)
        }.value
    }
}

/// 存在钥匙串里的腾讯云密钥
extension TencentTranslate.Credentials: KeychainItem {
    static let account = "tencent-translate"
}

/// 调腾讯云机器翻译
enum TencentTranslator {
    static var credentials: TencentTranslate.Credentials? {
        Keychain.load(TencentTranslate.Credentials.self).flatMap { $0.isComplete ? $0 : nil }
    }

    static func saveCredentials(_ credentials: TencentTranslate.Credentials) {
        if credentials.isComplete {
            Keychain.save(TencentTranslate.Credentials(
                secretId: credentials.secretId.trimmingCharacters(in: .whitespacesAndNewlines),
                secretKey: credentials.secretKey.trimmingCharacters(in: .whitespacesAndNewlines)))
        } else {
            Keychain.delete(TencentTranslate.Credentials.self)
        }
    }

    /// 翻译整段文字：长文本分段依次请求，再用换行拼起来
    static func translate(_ text: String, target: String,
                          credentials: TencentTranslate.Credentials? = nil) async throws(TranslateError) -> String {
        guard let credentials = credentials ?? self.credentials, credentials.isComplete else { throw .missingKey }
        var results: [String] = []
        for chunk in TencentTranslate.chunks(text) {
            // 空行原样保留，不浪费一次请求
            if chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                results.append(chunk)
                continue
            }
            let data: Data
            do {
                let request = try TencentTranslate.request(text: chunk, target: target, credentials: credentials)
                (data, _) = try await URLSession.shared.data(for: request)
            } catch {
                throw .network
            }
            switch TencentTranslate.parse(data) {
            case .success(let translated): results.append(translated)
            case .failure(let error): throw error
            }
        }
        return results.joined(separator: "\n")
    }
}
