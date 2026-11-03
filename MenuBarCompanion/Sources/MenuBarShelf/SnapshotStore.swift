// SPDX-License-Identifier: GPL-3.0-only
// 星期五菜单显示收纳内容用的快照：星期五在沙盒里不能枚举其他应用的图标，由本组件整理好写进共享的 App Group 文件夹。
import AppKit
import ImageIO
import UniformTypeIdentifiers

public struct ShelfSnapshot: Codable, Equatable {
    public struct Entry: Codable, Equatable {
        public let id: UInt32
        public let name: String
        public let hidden: Bool
        public let pinned: Bool
        /// 图像文件名（同目录）；系统拒绝截图时为 nil。
        public let image: String?
        /// 单色图标：星期五按模板图像显示，跟随菜单深浅色。
        public let template: Bool
        /// 来源应用：截不到图时星期五显示该应用自己的图标。
        public var bundleID: String? = nil
        /// 稳定标识（应用 + 序号）：星期五发命令时用它，不用会在屏幕间互换的窗口编号。
        public var key: String = ""
    }
    public var enabled: Bool
    public var pendingRestore: Bool
    /// 未能启用的原因："permission" 表示组件缺少辅助功能或屏幕录制授权。
    public var status: String?
    public var entries: [Entry]
}

enum SnapshotStore {
    static let groupID = "B45N72QF4V.com.lizhiming.RestBreak"
    /// 只有名字的跨进程信号（与星期五现有 Darwin 通知同一套）。
    static let changedNotice = "com.lizhiming.RestBreak.menubar.changed"
    static let requestNotice = "com.lizhiming.RestBreak.menubar.request"

    static var directory: URL? {
        // 组件签名带同一 App Group 权限；没有权限（本地 ad-hoc 构建）时不写，星期五显示为未启用。
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("MenuBarShelf", isDirectory: true)
    }

    static func imageName(for id: UInt32) -> String { "\(id).png" }

    /// 写快照；图像只在文件不存在时生成（窗口编号在应用生命周期内不变），并删掉已不存在的图标文件。
    static func write(_ snapshot: ShelfSnapshot, image: (UInt32) -> CGImage?) -> Bool {
        guard let directory else { return false }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var entries: [ShelfSnapshot.Entry] = []
        for entry in snapshot.entries {
            let name = imageName(for: entry.id)
            let url = directory.appendingPathComponent(name)
            var template = entry.template
            var hasImage = fm.fileExists(atPath: url.path)
            if !hasImage, let cg = image(entry.id).flatMap(trimmed) {
                template = isMonochrome(cg)
                hasImage = writePNG(cg, to: url)
                if hasImage { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
            } else if hasImage, let previous = lastTemplates[entry.id] {
                template = previous
            }
            lastTemplates[entry.id] = template
            entries.append(.init(id: entry.id, name: entry.name, hidden: entry.hidden, pinned: entry.pinned,
                                 image: hasImage ? name : nil, template: template, bundleID: entry.bundleID, key: entry.key))
        }
        let keep = Set(entries.compactMap(\.image)).union(["snapshot.json", "diagnose.txt"])
        for file in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where !keep.contains(file) {
            try? fm.removeItem(at: directory.appendingPathComponent(file))
        }
        var final = snapshot
        final.entries = entries
        guard let data = try? JSONEncoder().encode(final) else { return false }
        return (try? data.write(to: directory.appendingPathComponent("snapshot.json"), options: .atomic)) != nil
    }
    private static var lastTemplates: [UInt32: Bool] = [:]

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name as CFString), nil, nil, true)
    }

    /// 菜单栏截图包含整条菜单栏高度的透明留白；裁到不透明区域，星期五菜单里才不会缩成很小的图。
    static func trimmed(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return image }
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 12 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // CGContext 的行从下往上，裁切矩形用图像坐标（从上往下）。
        let pad = 2
        let rect = CGRect(x: max(0, minX - pad), y: max(0, height - 1 - maxY - pad),
                          width: min(width, maxX + pad + 1) - max(0, minX - pad),
                          height: min(height, height - minY + pad) - max(0, height - 1 - maxY - pad))
        return image.cropping(to: rect)
    }

    /// 绝大多数不透明像素没有色彩（菜单栏常见的黑白图标）。
    static func isMonochrome(_ image: CGImage) -> Bool {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        var opaque = 0, colorful = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 50 {
            let alpha = Double(pixels[index + 3]) / 255
            let rgb = [pixels[index], pixels[index + 1], pixels[index + 2]].map { Double($0) / alpha }
            opaque += 1
            if (rgb.max() ?? 0) - (rgb.min() ?? 0) > 40 { colorful += 1 }
        }
        return opaque > 0 && Double(colorful) / Double(opaque) < 0.05
    }

    private static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
