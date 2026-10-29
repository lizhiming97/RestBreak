import Foundation
import Testing
@testable import RestBreak

/// 休息背景主题：设置保存、随机不连续重复、照片文件夹读取
struct ThemeTests {
    @Test func 默认是毛玻璃_主题设置能保存和读取() throws {
        #expect(AppSettings.default.overlayStyle == .frosted)
        var s = AppSettings.default
        s.overlayStyle = .photos
        s.photoFolder = PhotoFolderRef(name: "壁纸", bookmark: Data([1, 2, 3]))
        let loaded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(loaded.overlayStyle == .photos)
        #expect(loaded.photoFolder == s.photoFolder)
    }

    @Test func 内置风景至少6套_名字不重复() {
        #expect(Scenery.all.count >= 6)
        #expect(Set(Scenery.all.map(\.name)).count == Scenery.all.count)
        #expect(Scenery.all.allSatisfy { $0.colors.count >= 3 })
    }

    @Test func 随机挑选不会连续重复() {
        var picker = NoRepeatPicker<Int>()
        var last: Int?
        for _ in 0..<200 {
            let pick = picker.next(from: [1, 2, 3])
            #expect(pick != nil)
            #expect(pick != last)
            last = pick
        }
        // 只有一个可选项时照样返回它
        var single = NoRepeatPicker<Int>()
        #expect(single.next(from: [7]) == 7)
        #expect(single.next(from: [7]) == 7)
        #expect(single.next(from: []) == nil)
    }

    @Test func 照片文件夹只列出图片_包含子文件夹_忽略隐藏文件() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("theme-test-\(UUID().uuidString)")
        let sub = dir.appendingPathComponent("旅行")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["a.jpg", "b.PNG", "c.heic", "notes.txt", ".hidden.jpg"] {
            try Data([0]).write(to: dir.appendingPathComponent(name))
        }
        try Data([0]).write(to: sub.appendingPathComponent("d.jpeg"))

        let names = PhotoLibrary.imageFiles(in: dir).map(\.lastPathComponent).sorted()
        #expect(names == ["a.jpg", "b.PNG", "c.heic", "d.jpeg"])
    }
}
