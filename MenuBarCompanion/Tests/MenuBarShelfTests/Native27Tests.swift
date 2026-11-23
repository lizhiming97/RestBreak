// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import MenuBarShelf

/// macOS 27 系统开关列表（trackedApplications）的读写规则：只改指定应用的 isAllowed，其他内容原样保留。
struct Native27Tests {
    static func key(_ id: String) -> [String: Any] { ["bundle": ["_0": id]] }
    static func value(_ id: String, _ allowed: Bool) -> [String: Any] {
        ["isAllowed": allowed, "location": key(id), "menuItemLocations": [key(id)]]
    }
    static let adhocKey: [String: Any] = ["adhocBinary": ["_0": ["relative": "file:///tmp/x"]]]
    let list: [Any] = [key("a.app"), value("a.app", true), adhocKey, ["isAllowed": true],
                       key("b.app"), value("b.app", false), key("c.app"), value("c.app", true)]

    @Test func readsAllowedStatesOfBundleKeysOnly() {
        #expect(Native27.Switches.states(in: list) == ["a.app": true, "b.app": false, "c.app": true])
    }

    @Test func settingChangesOnlyRequestedAppsAndKeepsEverythingElse() throws {
        let result = Native27.Switches.setting(false, for: ["a.app", "b.app", "missing.app"], in: list)
        #expect(result.changed == ["a.app"])   // b 已经是关的，missing 不在列表里
        #expect(Native27.Switches.states(in: result.array) == ["a.app": false, "b.app": false, "c.app": true])
        #expect(result.array.count == list.count)
        let changed = try #require(result.array[1] as? [String: Any])
        #expect(changed["menuItemLocations"] != nil && changed["location"] != nil)
        #expect(NSDictionary(dictionary: result.array[2] as! [String: Any]).isEqual(to: Self.adhocKey))
    }

    /// 图标来自某个 .app 包内部的辅助程序时（WPS 的 WPS Office Service、Docker 的 helper），
    /// 要往上找到最外层的 .app，系统的开关记在它名下。
    @Test func findsOutermostApplicationOnThePath() {
        #expect(Native27.enclosingApp(ofBundlePath: "/Applications/wpsoffice.app/Contents/SharedSupport/wpscloudsvr.app")?.id
                == "com.kingsoft.wpsoffice.mac")
        // 自己就是最外层的：没有外层应用
        #expect(Native27.enclosingApp(ofBundlePath: "/Applications/wpsoffice.app") == nil)
        #expect(Native27.enclosingApp(ofBundlePath: "/usr/libexec/somebinary") == nil)
    }

    @Test func stableIDIsDeterministicAndOutsideRealWindowRange() {
        let id = Native27.stableID(for: "com.example.app", index: 0)
        #expect(id == Native27.stableID(for: "com.example.app", index: 0))
        #expect(id >= 0x8000_0000)
        #expect(id != Native27.stableID(for: "com.example.other", index: 0))
    }
}
