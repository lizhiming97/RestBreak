import AppKit
import Testing
@testable import RestBreak

@MainActor
struct MouseCompanionTests {
    @Test func 组件使用固定网址和独立包路径() {
        #expect(MouseCompanionClient.commandURL(.launch).absoluteString == "friday-mouse://launch")
        #expect(MouseCompanionClient.commandURL(.authorize).absoluteString == "friday-mouse://authorize")
        let host = URL(fileURLWithPath: "/Applications/星期五.app")
        #expect(MouseCompanionClient.embeddedURL(mainApp: host).path == "/Applications/星期五.app/Contents/Helpers/星期五鼠标.app")
        #expect(MouseCompanionClient.siblingURL(mainApp: host).path == "/Applications/星期五鼠标.app")
        #expect(!MouseCompanionClient.isCompanion(host))
    }

    /// config.json 是和鼠标组件的约定：字段名、默认值必须和组件的 ScrollConfiguration 一致
    /// （组件那边的 testDecodesConfigWrittenByFriday 用同一份字段解码）。
    @Test func 设置文件字段与组件约定一致() throws {
        let data = try JSONEncoder().encode(MouseSettings())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["enabled", "smoothVertical", "smoothHorizontal", "reverseVertical",
                                     "reverseHorizontal", "step", "speed", "duration", "excludedApps"])
        #expect(object["enabled"] as? Bool == false)
        #expect(object["step"] as? Double == 33.6)
        #expect(object["speed"] as? Double == 2.7)
        #expect(object["duration"] as? Double == 4.35)
    }

    @Test func 鼠标页数值格式() {
        #expect(TimeUnit.tenths.label(27) == "2.7")
        #expect(TimeUnit.points.label(34) == "34 点")
    }
}

/// 鼠标设置页的布局截图：只在设了 FRIDAY_MOUSE_PREVIEW 时输出，供本地视觉检查。
@MainActor
struct MouseCompanionPagePreviewTests {
    @Test func 设置页截图() async throws {
        guard ProcessInfo.processInfo.environment["FRIDAY_MOUSE_PREVIEW"] != nil else { return }
        let window = SettingsWindowController.makeWindow(SettingsView(page: .mouse).environmentObject(BreakCoordinator()))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))
        let view = try #require(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("friday-mouse-settings.png")
        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        print("MOUSE_PREVIEW \(url.path)")
    }
}
