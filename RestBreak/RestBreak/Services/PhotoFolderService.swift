import AppKit
import ImageIO

/// 休息遮罩用的背景（每次休息挑一次，所有屏幕用同一个）
enum OverlayBackground {
    case frosted
    case scenery(Scenery)
    case photo(NSImage)
}

/// 负责「我的照片」：让用户选文件夹、记住授权、每次休息随机挑一张
@MainActor
final class PhotoFolderService {
    private var picker = NoRepeatPicker<URL>()
    private var sceneryPicker = NoRepeatPicker<Int>()

    /// 弹出选择文件夹的窗口；选好后返回可以保存进设置的文件夹引用
    func chooseFolder() -> PhotoFolderRef? {
        let panel = NSOpenPanel()
        panel.title = "选择照片文件夹"
        panel.message = "休息时会从这个文件夹（含子文件夹）里随机挑一张照片作为背景"
        panel.prompt = "选择"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url,
              let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                   includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return nil }
        return PhotoFolderRef(name: url.lastPathComponent, bookmark: bookmark)
    }

    /// 文件夹里有多少张图片（设置页显示用）；文件夹失效时返回 nil
    func imageCount(in folder: PhotoFolderRef) -> Int? {
        withAccess(to: folder) { PhotoLibrary.imageFiles(in: $0).count }
    }

    /// 按设置挑这次休息的背景。照片模式下读不到照片时，退回风景渐变
    func background(for settings: AppSettings, maxPixelSize: CGFloat) -> OverlayBackground {
        switch settings.overlayStyle {
        case .frosted:
            return .frosted
        case .photos:
            if let folder = settings.photoFolder,
               let image = withAccess(to: folder, { randomImage(in: $0, maxPixelSize: maxPixelSize) }) ?? nil {
                return .photo(image)
            }
            return .scenery(randomScenery())
        case .scenery:
            return .scenery(randomScenery())
        }
    }

    func randomScenery() -> Scenery {
        let index = sceneryPicker.next(from: Array(Scenery.all.indices)) ?? 0
        return Scenery.all[index]
    }

    // MARK: - 内部实现

    /// 解析安全书签，在授权范围内执行 body
    private func withAccess<T>(to folder: PhotoFolderRef, _ body: (URL) -> T) -> T? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: folder.bookmark, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        return body(url)
    }

    /// 随机挑一张能读出来的图片，按屏幕大小缩小后再载入，省内存
    private func randomImage(in folder: URL, maxPixelSize: CGFloat) -> NSImage? {
        var files = PhotoLibrary.imageFiles(in: folder)
        for _ in 0..<5 {   // 遇到读不出的文件换一张，最多试 5 次
            guard let url = picker.next(from: files) else { return nil }
            if let image = Self.downsampledImage(at: url, maxPixelSize: maxPixelSize) { return image }
            files.removeAll { $0 == url }
        }
        return nil
    }

    private static func downsampledImage(at url: URL, maxPixelSize: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // 按照片的拍摄方向摆正
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
