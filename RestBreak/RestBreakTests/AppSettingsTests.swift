import Foundation
import Testing
@testable import RestBreak

/// 设置的读写测试。重点：以后给设置加新字段时，用户已保存的旧设置不能丢。
struct AppSettingsTests {
    /// 模拟「老版本存的设置」：先改掉几个值，再从 JSON 里删掉几个字段（假装那是新版本才加的）
    @Test func 缺少字段时保留已有设置_缺的用默认值() throws {
        var saved = AppSettings.default
        saved.maxPostpones = 4
        saved.strictMode = true
        saved[.micro].interval = 30 * 60

        var json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        json.removeValue(forKey: "showCountdownInMenuBar")
        var micro = try #require(json["microBreak"] as? [String: Any])
        micro.removeValue(forKey: "postponeDuration")
        json["microBreak"] = micro

        let data = try JSONSerialization.data(withJSONObject: json)
        let loaded = try JSONDecoder().decode(AppSettings.self, from: data)

        // 用户改过的值还在
        #expect(loaded.maxPostpones == 4)
        #expect(loaded.strictMode)
        #expect(loaded[.micro].interval == 30 * 60)
        // 缺的字段用默认值
        #expect(loaded.showCountdownInMenuBar == AppSettings.default.showCountdownInMenuBar)
        #expect(loaded[.micro].postponeDuration == AppSettings.default[.micro].postponeDuration)
    }

    @Test func 编码再解码结果不变() throws {
        var settings = AppSettings.default
        settings[.long].duration = 10 * 60
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data) == settings)
    }

    @Test func 旧设置没有截图字段时用默认值() throws {
        var json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings.default)) as? [String: Any])
        json.removeValue(forKey: "showMagnifier")
        json.removeValue(forKey: "pinOpacity")
        let loaded = try JSONDecoder().decode(AppSettings.self,
                                              from: JSONSerialization.data(withJSONObject: json))
        #expect(loaded.showMagnifier)
        #expect(loaded.pinOpacity == 1.0)
    }
}
