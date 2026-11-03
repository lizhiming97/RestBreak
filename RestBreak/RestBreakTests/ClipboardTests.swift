import AppKit
import SwiftUI
import Testing
@testable import RestBreak

@Suite(.serialized)
@MainActor
struct ClipboardTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("friday-clipboard-test-" + UUID().uuidString)
    }
    private func text(_ value: String, at: TimeInterval = 0) -> ClipboardItem {
        ClipboardItem(contents: [.init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(value.utf8))],
                      sourceApp: "test.editor", at: Date(timeIntervalSince1970: at))
    }
    private func board() -> NSPasteboard { NSPasteboard(name: .init("friday-test-" + UUID().uuidString)) }
    private func copy(_ value: String, to board: NSPasteboard) {
        board.clearContents()
        board.setString(value, forType: .string)
    }
    private func imageData() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                                             bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.15, green: 0.62, blue: 0.58, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let image = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        #expect((image.colorAt(x: 0, y: 0)?.alphaComponent ?? 0) > 0.9)
        return try #require(image.representation(using: .png, properties: [:]))
    }

    @Test func 富文本回放和纯文本回放保留正确表示() throws {
        let board = board()
        defer { board.releaseGlobally() }
        copy("你好 Friday", to: board)
        board.setString("<b>你好 Friday</b>", forType: .html)
        guard case .item(let item) = ClipboardCapture.read(board, sourceApp: "editor", excluding: []) else {
            Issue.record("未采集到文本"); return
        }
        #expect(item.text == "你好 Friday")
        #expect(item.contents.count == 2)
        #expect(ClipboardCapture.write(item, to: board))
        #expect(board.string(forType: .html) == "<b>你好 Friday</b>")
        #expect(ClipboardCapture.write(item, to: board, plainText: true))
        #expect(board.string(forType: .string) == "你好 Friday")
        #expect(board.data(forType: .html) == nil)
        if case .item = ClipboardCapture.read(board, sourceApp: "editor", excluding: []) {
            Issue.record("历史自己写回的内容不应再次采集")
        }
    }

    @Test func 图片可采集和回放但不冒充纯文本() throws {
        let board = board()
        defer { board.releaseGlobally() }
        let png = try imageData()
        board.setData(png, forType: .png)
        guard case .item(let item) = ClipboardCapture.read(board, sourceApp: nil, excluding: []) else {
            Issue.record("未采集到图片"); return
        }
        #expect(item.imageData == png)
        #expect(ClipboardCapture.write(item, to: board))
        #expect(board.data(forType: .png) == png)
        #expect(!ClipboardCapture.write(item, to: board, plainText: true))
        #expect(board.data(forType: .png) == png)
    }

    @Test func 敏感标记应用排除文件和空文本不进入历史() {
        let board = board()
        defer { board.releaseGlobally() }
        for marker in ClipboardCapture.ignoredTypes {
            copy("fixture-secret", to: board)
            board.setString("1", forType: .init(marker))
            if case .item = ClipboardCapture.read(board, sourceApp: nil, excluding: []) {
                Issue.record("没有排除类型 \(marker)")
            }
        }
        copy("excluded", to: board)
        if case .item = ClipboardCapture.read(board, sourceApp: "private.app", excluding: ["private.app"]) {
            Issue.record("没有排除应用")
        }
        board.setString("file:///tmp/example", forType: .fileURL)
        if case .item = ClipboardCapture.read(board, sourceApp: nil, excluding: []) {
            Issue.record("文件引用不属于本版范围")
        }
        copy(" \n\t", to: board)
        if case .item = ClipboardCapture.read(board, sourceApp: nil, excluding: []) { Issue.record("空文本入库") }
    }

    @Test func 超大内容跳过且多条剪贴板不错误合并() {
        let board = board()
        defer { board.releaseGlobally() }
        board.setData(Data(repeating: 65, count: ClipboardCapture.maxItemBytes + 1), forType: .string)
        guard case .tooLarge = ClipboardCapture.read(board, sourceApp: nil, excluding: []) else {
            Issue.record("超大内容没有被拒绝"); return
        }
        board.clearContents()
        let first = NSPasteboardItem(), second = NSPasteboardItem()
        first.setString("one", forType: .string)
        second.setString("two", forType: .string)
        board.writeObjects([first, second])
        if case .item = ClipboardCapture.read(board, sourceApp: nil, excluding: []) { Issue.record("多条内容被错误合并") }
    }

    @Test func 去重更新顺序并保留固定及重启后的历史() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir)
        await store.load()
        let a = text("常用地址", at: 1), b = text("会议记录", at: 2)
        #expect(store.add(a)); #expect(store.add(b))
        store.togglePin(a.id)
        #expect(store.add(text("常用地址", at: 3)))
        #expect(store.items.count == 2)
        #expect(store.ordered.first?.id == a.id)
        #expect(store.ordered.first?.isPinned == true)
        await store.flush()
        let reopened = ClipboardStore(directory: dir)
        await reopened.load()
        #expect(reopened.items == store.items)
        reopened.clear()
        #expect(reopened.items.map(\.id) == [a.id])
        await reopened.flush()
        reopened.clear(includingPinned: true)
        await reopened.flush()
        let empty = ClipboardStore(directory: dir)
        await empty.load()
        #expect(empty.items.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".clip") }.isEmpty)
    }

    @Test func 容量清理最旧普通项并拒绝挤掉固定内容() async {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir)
        await store.load()
        store.maxItems = 2
        let a = text("aaa", at: 1), b = text("bbb", at: 2), c = text("ccc", at: 3)
        store.add(a); store.togglePin(a.id); store.add(b); store.add(c)
        #expect(Set(store.items.map(\.id)) == [a.id, c.id])
        store.togglePin(c.id)
        #expect(!store.add(text("ddd", at: 4)))
        #expect(Set(store.items.map(\.id)) == [a.id, c.id])
        store.togglePin(c.id)
        store.maxBytes = 3
        store.enforceLimits()
        #expect(store.items.map(\.id) == [a.id])
        await store.flush()
    }

    @Test func 超过7天的普通历史自动清理且固定内容保留() async {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir)
        await store.load()
        let day: TimeInterval = 24 * 60 * 60
        let now = Date(timeIntervalSince1970: 100 * day)
        let old = text("八天前", at: 92 * day), oldPinned = text("八天前固定", at: 92 * day)
        let edge = text("刚好七天", at: 93 * day), fresh = text("昨天", at: 99 * day)
        store.add(old); store.add(oldPinned); store.togglePin(oldPinned.id); store.add(edge); store.add(fresh)
        store.removeExpired(now: now)
        #expect(Set(store.items.map(\.id)) == [oldPinned.id, edge.id, fresh.id])
        await store.flush()
        let reloaded = ClipboardStore(directory: dir)
        await reloaded.load()
        #expect(Set(reloaded.items.map(\.id)) == [oldPinned.id, edge.id, fresh.id])
    }

    @Test func 采集暂停恢复不补录_轮询无变化不写盘() async throws {
        let dir = directory(), board = board()
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir)
        await store.load()
        let monitor = ClipboardMonitor(pasteboard: board)
        monitor.sourceApp = { "test.editor" }
        monitor.onCapture = { if case .item(let item) = $0 { store.add(item) } }
        monitor.setRunning(true)
        defer { monitor.setRunning(false) }
        copy("first", to: board); monitor.poll()
        await store.flush()
        let index = dir.appendingPathComponent("index.json")
        let modified = try index.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        for _ in 0..<100 { monitor.poll() }
        await store.flush()
        #expect(try index.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
        monitor.setRunning(false)
        copy("paused", to: board); monitor.poll()
        monitor.setRunning(true); monitor.poll()
        #expect(store.items.count == 1)
        copy("after resume", to: board); monitor.poll()
        #expect(store.items.count == 2)
        await store.flush()
    }

    @Test func 损坏的历史保留原文件且不被新采集覆盖() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let index = dir.appendingPathComponent("index.json"), invalid = Data("broken".utf8)
        try invalid.write(to: index)
        let store = ClipboardStore(directory: dir)
        await store.load()
        #expect(!store.isLoaded)
        #expect(store.error != nil)
        #expect(!store.add(text("new")))
        await store.flush()
        #expect(try Data(contentsOf: index) == invalid)
    }

    @Test func 写盘失败不丢内存并可以重试() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir)
        await store.load()
        try Data("block directory".utf8).write(to: dir)
        store.add(text("待保存"))
        await store.flush()
        #expect(store.items.count == 1)
        #expect(store.error != nil)
        try FileManager.default.removeItem(at: dir)
        await store.flush()
        #expect(store.error == nil)
        let reopened = ClipboardStore(directory: dir)
        await reopened.load()
        #expect(reopened.items.first?.text == "待保存")
    }

    @Test func 新用户默认不采集且独立设置不影响旧设置() throws {
        let name = "friday-clipboard-settings-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let coordinator = ClipboardCoordinator(defaults: defaults)
        coordinator.start()
        defer { coordinator.stop() }
        #expect(!coordinator.preferences.enabled)
        #expect(!coordinator.monitor.isRunning)
        coordinator.preferences.maxItems = 100
        let reopened = ClipboardCoordinator(defaults: defaults)
        #expect(reopened.preferences.maxItems == 100)
        #expect(AppSettings.default.shortcuts.isEmpty)
    }

    @Test func 搜索匹配中文和来源并限制列表摘要() {
        let item = text("今天讨论剪贴板历史\n下周验证")
        #expect(item.matches("剪贴板"))
        #expect(item.matches("EDITOR"))
        #expect(!item.matches("不存在"))
        #expect(!item.title.contains("\n"))
        #expect(text(String(repeating: "字", count: 1000)).title.count == 240)
    }

    @Test func 锁屏和睡眠同时发生时必须全部恢复才继续记录() async throws {
        let dir = directory(), board = board(), suite = "friday-clipboard-lifecycle-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { board.releaseGlobally(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir)
        await store.load()
        let coordinator = ClipboardCoordinator(store: store, monitor: ClipboardMonitor(pasteboard: board), defaults: defaults)
        coordinator.start()
        defer { coordinator.stop() }
        coordinator.preferences.enabled = true
        #expect(coordinator.monitor.isRunning)
        coordinator.suspend(Notification(name: NSWorkspace.willSleepNotification))
        coordinator.suspend(Notification(name: .init("com.apple.screenIsLocked")))
        #expect(!coordinator.monitor.isRunning)
        copy("while locked", to: board)
        coordinator.resume(Notification(name: NSWorkspace.didWakeNotification))
        #expect(!coordinator.monitor.isRunning)
        coordinator.resume(Notification(name: .init("com.apple.screenIsUnlocked")))
        #expect(coordinator.monitor.isRunning)
        coordinator.monitor.poll()
        #expect(store.items.isEmpty)
        coordinator.preferences.enabled = false
        #expect(!coordinator.monitor.isRunning)
        await store.flush()
    }

    @Test func 不同格式组合不能产生相同去重指纹() {
        let html = NSPasteboard.PasteboardType.html.rawValue, string = NSPasteboard.PasteboardType.string.rawValue
        let single = ClipboardItem(contents: [.init(type: html, data: Data(("a" + string + "\0b").utf8))], sourceApp: nil)
        let multiple = ClipboardItem(contents: [.init(type: html, data: Data("a".utf8)),
                                               .init(type: string, data: Data("b".utf8))], sourceApp: nil)
        #expect(single.fingerprint != multiple.fingerprint)
    }

    @Test func 历史面板布局及图片列表可渲染() async throws {
        let dir = directory(), board = board(), suite = "friday-clipboard-preview-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { board.releaseGlobally(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir)
        await store.load()
        let pinned = text("常用回复：收到，我整理后发你。", at: 3)
        store.add(pinned); store.togglePin(pinned.id)
        store.add(text("产品调研：剪贴板历史、快捷搜索、图片预览", at: 2))
        store.add(ClipboardItem(contents: [.init(type: NSPasteboard.PasteboardType.png.rawValue, data: try imageData())], sourceApp: "com.apple.Safari"))
        let coordinator = ClipboardCoordinator(store: store, monitor: ClipboardMonitor(pasteboard: board), defaults: defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
        let view = NSHostingView(rootView: ClipboardHistoryView(coordinator: coordinator, store: store))
        view.sizingOptions = []
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(250))
        view.layoutSubtreeIfNeeded()
        #expect(view.bounds.size == NSSize(width: 480, height: 520))
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // 供本地视觉检查使用，测试不依赖屏幕录制权限，也不接触系统剪贴板。
        if ProcessInfo.processInfo.environment["FRIDAY_CLIPBOARD_PREVIEW"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("friday-clipboard-panel.png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: url)
            print("CLIPBOARD_PREVIEW \(url.path)")
            let settings = SettingsWindowController.makeWindow(
                SettingsView(page: .clipboard).environmentObject(BreakCoordinator(clipboard: coordinator)))
            settings.orderFrontRegardless()
            defer { settings.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(250))
            let settingsView = try #require(settings.contentView)
            settingsView.layoutSubtreeIfNeeded()
            let settingsBitmap = try #require(settingsView.bitmapImageRepForCachingDisplay(in: settingsView.bounds))
            settingsView.cacheDisplay(in: settingsView.bounds, to: settingsBitmap)
            try settingsBitmap.representation(using: .png, properties: [:])?.write(
                to: url.deletingLastPathComponent().appendingPathComponent("friday-clipboard-settings.png"))
        }
        await store.flush()
    }
}
