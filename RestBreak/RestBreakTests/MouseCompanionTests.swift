import AppKit
import Testing
@testable import RestBreak

@MainActor
struct MouseCompanionTests {
    @Test func 组件使用固定网址和独立包路径() {
        #expect(MouseCompanionClient.commandURL(.settings).absoluteString == "friday-mouse://settings")
        #expect(MouseCompanionClient.commandURL(.launch).absoluteString == "friday-mouse://launch")
        let host = URL(fileURLWithPath: "/Applications/星期五.app")
        #expect(MouseCompanionClient.embeddedURL(mainApp: host).path == "/Applications/星期五.app/Contents/Helpers/星期五鼠标.app")
        #expect(MouseCompanionClient.siblingURL(mainApp: host).path == "/Applications/星期五鼠标.app")
        #expect(!MouseCompanionClient.isCompanion(host))
    }
}
