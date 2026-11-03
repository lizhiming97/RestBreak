import Foundation

/// 磁盘工作在独立 actor 上执行。每个条目独立写入，新增文本不会重写已有图片。
actor ClipboardDisk {
    struct Index: Codable {
        var version = 1
        let ids: [UUID]
    }
    let directory: URL
    private var saved: [UUID: ClipboardItem] = [:]
    private var latestRevision: UInt64 = 0

    init(directory: URL) { self.directory = directory }

    func load() throws -> [ClipboardItem] {
        let indexURL = directory.appendingPathComponent("index.json")
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }
        let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: indexURL))
        guard index.version == 1, index.ids.count <= 500, Set(index.ids).count == index.ids.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var result: [ClipboardItem] = []
        var bytes = 0
        for id in index.ids {
            let url = file(id)
            let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard fileSize <= 9 * 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
            let item = try PropertyListDecoder().decode(ClipboardItem.self, from: Data(contentsOf: url))
            bytes += item.byteCount
            guard item.id == id, item.byteCount <= 8 * 1024 * 1024, bytes <= 128 * 1024 * 1024 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            result.append(item)
        }
        saved = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
        return result
    }

    func save(_ items: [ClipboardItem], revision: UInt64) throws {
        guard revision > latestRevision else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        for item in items where saved[item.id] != item {
            try encoder.encode(item).write(to: file(item.id), options: .atomic)
        }
        try JSONEncoder().encode(Index(ids: items.map(\.id)))
            .write(to: directory.appendingPathComponent("index.json"), options: .atomic)
        // 先提交索引再删旧数据；中途失败不让原索引引用不存在的文件。
        let keep = Set(items.map { $0.id.uuidString + ".clip" })
        for url in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.pathExtension == "clip" && !keep.contains(url.lastPathComponent) {
            try fm.removeItem(at: url)
        }
        saved = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        latestRevision = revision
    }

    private func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".clip") }
}

@MainActor
final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []
    @Published private(set) var isLoaded = false
    @Published private(set) var error: String?
    private let disk: ClipboardDisk
    private var revision: UInt64 = 0
    private var loading = false
    var maxItems = 200
    var maxBytes = 64 * 1024 * 1024

    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("FridayClipboard")) {
        disk = ClipboardDisk(directory: directory)
    }

    var ordered: [ClipboardItem] {
        items.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.copiedAt > $1.copiedAt
        }
    }
    var byteCount: Int { items.reduce(0) { $0 + $1.byteCount } }

    func load() async {
        guard !isLoaded, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            items = try await disk.load()
            isLoaded = true
            error = nil
            enforceLimits()
        } catch {
            self.error = "历史记录未能读取，原文件已保留。请检查磁盘空间或重试。"
        }
    }

    @discardableResult
    func add(_ item: ClipboardItem) -> Bool {
        guard isLoaded, item.byteCount <= ClipboardCapture.maxItemBytes else { return false }
        let previous = items
        if let index = items.firstIndex(where: { $0.fingerprint == item.fingerprint }) {
            items[index].copiedAt = item.copiedAt
            items[index].sourceApp = item.sourceApp
        } else {
            items.append(item)
        }
        trim()
        guard items.contains(where: { $0.fingerprint == item.fingerprint }) else {
            items = previous
            return false
        }
        changed()
        return true
    }

    func togglePin(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isPinned.toggle()
        trim()
        changed()
    }

    func delete(_ id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        changed()
    }

    func clear(includingPinned: Bool = false) {
        guard isLoaded else { return }
        let previous = items
        items.removeAll { includingPinned || !$0.isPinned }
        if items != previous { changed() }
    }

    /// 普通历史保留 7 天，过期自动删除；固定内容不过期。
    /// 不单独开计时器：复制新内容、打开面板、恢复记录时顺便清理。
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    func removeExpired(now: Date = Date()) {
        guard isLoaded else { return }
        let cutoff = now.addingTimeInterval(-Self.retention)
        let previous = items
        items.removeAll { !$0.isPinned && $0.copiedAt < cutoff }
        if items != previous { changed() }
    }

    func enforceLimits() {
        let previous = items
        trim()
        if items != previous { changed() }
    }

    private func trim() {
        // 固定内容不被自动清理；容量都被固定项占满时拒绝新增条目。
        while items.count > maxItems || byteCount > maxBytes {
            guard let oldest = items.filter({ !$0.isPinned }).min(by: { $0.copiedAt < $1.copiedAt }) else { break }
            items.removeAll { $0.id == oldest.id }
        }
    }

    private func changed() {
        revision += 1
        Task { await flush() }
    }

    /// 保存失败只影响本模块，保留内存历史并在界面给出可重试状态。
    func flush() async {
        guard isLoaded else { return }
        let currentRevision = revision
        let snapshot = items
        do {
            try await disk.save(snapshot, revision: currentRevision)
            if revision == currentRevision { error = nil }
        } catch {
            if revision == currentRevision { self.error = "历史更改尚未保存，请检查磁盘空间后重试。" }
        }
    }
}
