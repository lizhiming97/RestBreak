import Foundation

/// 休息遮罩的背景样式
enum OverlayStyle: String, Codable, CaseIterable, Sendable {
    case frosted   // 毛玻璃（模糊身后的桌面）
    case scenery   // 内置风景渐变，每次随机一套
    case photos    // 用户选的照片文件夹，每次随机一张

    var title: String {
        switch self {
        case .frosted: "毛玻璃"
        case .scenery: "风景渐变"
        case .photos: "我的照片"
        }
    }
}

/// 用户选的照片文件夹。沙盒里要用「安全书签」才能在下次启动后继续读取这个文件夹
struct PhotoFolderRef: Codable, Equatable, Sendable {
    /// 显示用的文件夹名
    var name: String
    /// 安全书签数据（URL.bookmarkData(options: .withSecurityScope)）
    var bookmark: Data
}

/// 一套内置风景渐变（颜色用 0～1 的 RGB）
struct Scenery: Equatable, Sendable {
    struct RGB: Equatable, Sendable {
        let r: Double, g: Double, b: Double
    }

    let name: String
    /// 从上到下的几种颜色
    let colors: [RGB]

    static let all: [Scenery] = [
        Scenery(name: "晨曦", colors: [RGB(r: 0.98, g: 0.75, b: 0.55), RGB(r: 0.95, g: 0.55, b: 0.55),
                                     RGB(r: 0.55, g: 0.45, b: 0.70), RGB(r: 0.25, g: 0.30, b: 0.55)]),
        Scenery(name: "森林", colors: [RGB(r: 0.62, g: 0.80, b: 0.62), RGB(r: 0.28, g: 0.55, b: 0.42),
                                     RGB(r: 0.12, g: 0.35, b: 0.30), RGB(r: 0.06, g: 0.18, b: 0.18)]),
        Scenery(name: "海洋", colors: [RGB(r: 0.55, g: 0.85, b: 0.92), RGB(r: 0.20, g: 0.60, b: 0.80),
                                     RGB(r: 0.08, g: 0.35, b: 0.62), RGB(r: 0.04, g: 0.15, b: 0.35)]),
        Scenery(name: "暮色", colors: [RGB(r: 0.98, g: 0.62, b: 0.35), RGB(r: 0.85, g: 0.35, b: 0.40),
                                     RGB(r: 0.40, g: 0.20, b: 0.45), RGB(r: 0.12, g: 0.08, b: 0.25)]),
        Scenery(name: "极光", colors: [RGB(r: 0.30, g: 0.95, b: 0.70), RGB(r: 0.15, g: 0.60, b: 0.65),
                                     RGB(r: 0.20, g: 0.20, b: 0.50), RGB(r: 0.05, g: 0.06, b: 0.20)]),
        Scenery(name: "薰衣草", colors: [RGB(r: 0.88, g: 0.80, b: 0.98), RGB(r: 0.68, g: 0.58, b: 0.90),
                                      RGB(r: 0.45, g: 0.38, b: 0.75), RGB(r: 0.22, g: 0.18, b: 0.45)]),
    ]
}

/// 随机挑一个，并保证不和上一次重复（只有一个可选项时除外）
struct NoRepeatPicker<Element: Equatable> {
    private var last: Element?

    mutating func next(from items: [Element]) -> Element? {
        let candidates = items.count > 1 ? items.filter { $0 != last } : items
        let pick = candidates.randomElement()
        last = pick
        return pick
    }
}

/// 列出照片文件夹里的图片
enum PhotoLibrary {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "gif", "bmp"]

    /// 文件夹（含子文件夹）里所有图片，忽略隐藏文件；最多取 2000 张，避免文件夹太大时卡住
    static func imageFiles(in folder: URL, limit: Int = 2000) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            guard imageExtensions.contains(url.pathExtension.lowercased()) else { continue }
            result.append(url)
            if result.count >= limit { break }
        }
        return result
    }
}
