import CoreGraphics
import Foundation

/// 长截图拼接（2026-11-09 第二版，思路参考 Snow Shot 的设计，代码自己写）：
///
/// 1. **每一帧都和上一帧比**，算出画面移动了多少，累计出「现在看到的是长图的哪一段」。
///    只有超出长图底部的那部分才接上去；往回滚只是位置往上移，不算出错，之后再往下滚还能接着拼。
/// 2. **分格投票，容忍局部差异**：画面缩小 4 倍、切成小格子，每个有纹理的格子各自找「最像的位移」并投票；
///    没动的格子（侧边栏、导航栏）不投票；票数最多的位移再回到原图精确到像素，最差的 1/4 格子不算
///    （闪烁的光标、动画、悬停高亮）。
///
/// 位移 d 的含义：新帧第 y 行 = 上一帧第 y + d 行。d > 0 表示内容往上走了（用户往下滚）。

// MARK: - 灰度帧

/// 一帧画面的灰度数据：原图大小一份（精确比对），缩小 4 倍一份（粗略找位移）
struct GrayFrame {
    static let downsample = 4

    let width: Int
    let height: Int
    let full: [UInt8]
    let smallWidth: Int
    let smallHeight: Int
    let small: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        full = pixels
        let f = Self.downsample
        let smallWidth = max(1, width / f), smallHeight = max(1, height / f)
        self.smallWidth = smallWidth
        self.smallHeight = smallHeight
        var small = [UInt8](repeating: 0, count: smallWidth * smallHeight)
        pixels.withUnsafeBufferPointer { src in
            for sy in 0..<smallHeight {
                for sx in 0..<smallWidth {
                    var sum = 0
                    for dy in 0..<f {
                        let row = min(height - 1, sy * f + dy) * width
                        for dx in 0..<f { sum += Int(src[row + min(width - 1, sx * f + dx)]) }
                    }
                    small[sy * smallWidth + sx] = UInt8(sum / (f * f))
                }
            }
        }
        self.small = small
    }

    init(image: CGImage) {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        // 位图第 0 行就是图像最上面一行
        self.init(width: width, height: height, pixels: pixels)
    }
}

// MARK: - 位移估计

enum MotionEstimator {
    enum Motion: Equatable {
        case moved(Int)
        case still            // 没动（可能有局部动画、光标闪烁）
        case indeterminate    // 看不出来（大片空白、变化太大、接不上）
    }

    /// 最大位移：帧高的 60%（每秒最多 30 帧，正常滚动每帧只走几十像素）
    static let maxShiftFraction = 0.6
    static let tilesX = 6
    static let tilesY = 8
    /// 格子灰度标准差低于这个算没有纹理（空白）
    static let minTexture = 6.0
    /// 投票格子在原位置平均差小于这个算「没动」
    static let staticError = 1.0
    /// 格子最佳位移的平均差上限（缩小图，0～255）
    static let maxTileError = 14.0
    /// 最佳位移要明显好于其他位移，否则这一格不投票（重复的纹理）
    static let distinctRatio = 0.7
    static let minVotes = 3
    /// 原图精确比对：去掉最差的 1/4 格子后平均差的上限
    static let maxRefinedError = 10.0

    private struct Tile {
        let x0: Int, y0: Int, x1: Int, y1: Int   // 缩小图坐标
    }

    static func estimate(previous: GrayFrame, next: GrayFrame) -> Motion {
        guard previous.width == next.width, previous.height == next.height,
              next.smallHeight >= tilesY * 2, next.smallWidth >= tilesX * 2 else { return .indeterminate }
        let sw = next.smallWidth, sh = next.smallHeight
        let maxShift = Int(Double(sh) * maxShiftFraction)
        var tiles: [Tile] = []
        for ty in 0..<tilesY {
            for tx in 0..<tilesX {
                tiles.append(Tile(x0: tx * sw / tilesX, y0: ty * sh / tilesY,
                                  x1: (tx + 1) * sw / tilesX, y1: (ty + 1) * sh / tilesY))
            }
        }

        var votes: [(d: Int, tile: Tile)] = []
        var staticTiles = 0
        next.small.withUnsafeBufferPointer { n in
            previous.small.withUnsafeBufferPointer { p in
                for tile in tiles {
                    guard texture(n, sw, tile) >= minTexture else { continue }
                    if error(n, p, sw, tile, 0) < staticError { staticTiles += 1; continue }
                    var best = (d: 0, e: Double.infinity)
                    var errors: [(Int, Double)] = []
                    let lower = max(-maxShift, -tile.y0), upper = min(maxShift, sh - tile.y1)
                    guard lower <= upper else { continue }
                    // 粗找时隔一个点取一个（大选区也只要几十毫秒），精确位移交给下面的原图比对
                    for d in lower...upper {
                        let e = error(n, p, sw, tile, d, step: 2)
                        errors.append((d, e))
                        if e < best.e { best = (d, e) }
                    }
                    guard best.e <= maxTileError else { continue }
                    let second = errors.filter { abs($0.0 - best.d) > 2 }.map(\.1).min() ?? .infinity
                    guard best.e <= second * distinctRatio || second == .infinity else { continue }
                    votes.append((best.d, tile))
                }
            }
        }
        guard !votes.isEmpty else { return staticTiles > 0 ? .still : .indeterminate }

        // 票数最多的位移（相邻 ±1 算同一票）
        var bestCluster = (d: 0, support: 0)
        for candidate in Set(votes.map(\.d)) {
            let support = votes.filter { abs($0.d - candidate) <= 1 }.count
            if support > bestCluster.support || (support == bestCluster.support && abs(candidate) < abs(bestCluster.d)) {
                bestCluster = (candidate, support)
            }
        }
        if bestCluster.d == 0 { return .still }
        guard bestCluster.support >= minVotes,
              Double(bestCluster.support) >= Double(votes.count) * 0.4 else { return .indeterminate }
        let inliers = votes.filter { abs($0.d - bestCluster.d) <= 1 }.map(\.tile)

        // 回到原图精确到像素
        let f = GrayFrame.downsample
        let center = bestCluster.d * f
        var refined = (d: center, e: Double.infinity)
        next.full.withUnsafeBufferPointer { n in
            previous.full.withUnsafeBufferPointer { p in
                for d in (center - f - 1)...(center + f + 1) {
                    var tileErrors: [Double] = []
                    for tile in inliers {
                        let full = Tile(x0: tile.x0 * f, y0: tile.y0 * f, x1: tile.x1 * f, y1: tile.y1 * f)
                        guard full.y0 + d >= 0, full.y1 + d <= next.height else { continue }
                        tileErrors.append(error(n, p, next.width, full, d, step: 2))
                    }
                    guard !tileErrors.isEmpty else { continue }
                    tileErrors.sort()
                    let kept = tileErrors.prefix(max(1, tileErrors.count - tileErrors.count / 4))
                    let mean = kept.reduce(0, +) / Double(kept.count)
                    if mean < refined.e { refined = (d, mean) }
                }
            }
        }
        guard refined.e <= maxRefinedError else { return .indeterminate }
        return refined.d == 0 ? .still : .moved(refined.d)
    }

    /// 格子的灰度标准差
    private static func texture(_ pixels: UnsafeBufferPointer<UInt8>, _ width: Int, _ tile: Tile) -> Double {
        var sum = 0.0, squares = 0.0, count = 0.0
        for y in tile.y0..<tile.y1 {
            for x in tile.x0..<tile.x1 {
                let v = Double(pixels[y * width + x])
                sum += v; squares += v * v; count += 1
            }
        }
        guard count > 0 else { return 0 }
        let mean = sum / count
        return (max(0, squares / count - mean * mean)).squareRoot()
    }

    /// 新帧格子 vs 上一帧下移 d 行的同一块：平均绝对差
    private static func error(_ next: UnsafeBufferPointer<UInt8>, _ previous: UnsafeBufferPointer<UInt8>,
                              _ width: Int, _ tile: Tile, _ d: Int, step: Int = 1) -> Double {
        var total = 0, count = 0
        var y = tile.y0
        while y < tile.y1 {
            let a = y * width, b = (y + d) * width
            var x = tile.x0
            while x < tile.x1 {
                total += abs(Int(next[a + x]) - Int(previous[b + x]))
                count += 1
                x += step
            }
            y += step
        }
        return count == 0 ? .infinity : Double(total) / Double(count)
    }

    /// 顶部、底部不跟着滚的行（导航栏 / 底栏）：两帧同一行几乎一样。最多各占帧高 40%
    static func fixedBands(previous: GrayFrame, next: GrayFrame) -> (top: Int, bottom: Int) {
        let width = next.width, height = next.height
        func same(_ row: Int) -> Bool {
            var total = 0, count = 0
            var x = 0
            while x < width {
                total += abs(Int(next.full[row * width + x]) - Int(previous.full[row * width + x]))
                count += 1
                x += 2
            }
            return Double(total) / Double(max(1, count)) < 1.0
        }
        let limit = Int(Double(height) * 0.4)
        var top = 0
        while top < limit, same(top) { top += 1 }
        var bottom = 0
        while bottom < limit, height - 1 - bottom > top, same(height - 1 - bottom) { bottom += 1 }
        return (top, bottom)
    }
}

// MARK: - 长图画布

/// 记住长图由哪些帧的哪些行组成，以及现在看到的是长图的哪一段
struct ScrollCanvas: Equatable {
    struct Piece: Equatable {
        let frame: Int
        let rows: Range<Int>
    }

    enum Outcome: Equatable {
        case appended(Range<Int>)   // 新帧这些行接到了长图底部
        case contained              // 往回滚或在已有范围里，没有新内容
        case limitReached
    }

    let frameHeight: Int
    let limit: Int
    /// 顶部导航栏、底部底栏的行数（第一次移动时认定）
    private(set) var top = 0
    private(set) var bottom = 0
    private(set) var bandsKnown = false
    /// 当前帧的内容区顶端在「内容坐标」里的位置
    private(set) var position = 0
    /// 已经拼到的内容长度
    private(set) var contentEnd: Int
    private(set) var pieces: [Piece]
    /// 最近一帧（结束时补它的底栏）
    private(set) var latestFrame = 0
    private(set) var isFull = false

    init(frameHeight: Int, limit: Int) {
        self.frameHeight = frameHeight
        self.limit = limit
        contentEnd = frameHeight
        pieces = [Piece(frame: 0, rows: 0..<frameHeight)]
    }

    private var contentHeight: Int { frameHeight - top - bottom }

    /// 长图当前高度（含底栏）
    var height: Int { top + contentEnd + bottom }

    /// 第一次检测到移动时认定导航栏和底栏：第一帧只保留到底栏之前，底栏结束时再补
    mutating func setBands(top: Int, bottom: Int) {
        guard !bandsKnown else { return }
        bandsKnown = true
        self.top = top
        self.bottom = bottom
        contentEnd = frameHeight - top - bottom
        pieces[0] = Piece(frame: 0, rows: 0..<(frameHeight - bottom))
    }

    /// 新帧（编号 frame）比上一帧往下移了 d 行（负数往上）
    mutating func apply(_ d: Int, frame: Int) -> Outcome {
        latestFrame = frame
        guard !isFull else { return .limitReached }
        position += d
        let visibleEnd = position + contentHeight
        guard visibleEnd > contentEnd else { return .contained }
        let added = min(visibleEnd - contentEnd, contentHeight)
        guard height + added <= limit else {
            position -= d
            isFull = true
            return .limitReached
        }
        let end = frameHeight - bottom
        let rows = (end - added)..<end
        pieces.append(Piece(frame: frame, rows: rows))
        contentEnd += added
        return .appended(rows)
    }

    /// 没有移动的新帧也记一下（底栏用最新的）
    mutating func touch(frame: Int) { latestFrame = frame }

    /// 合成用的片段：最后补上最近一帧的底栏
    func finalPieces() -> [Piece] {
        guard bandsKnown, bottom > 0 else { return pieces }
        return pieces + [Piece(frame: latestFrame, rows: (frameHeight - bottom)..<frameHeight)]
    }
}

// MARK: - 合成

enum LongImageComposer {
    /// 复制出若干行成为独立的图（cropping 会一直引用整帧，长截图帧多时很占内存）
    static func copyRows(_ image: CGImage, rows: Range<Int>) -> CGImage? {
        compose([(image, rows)])
    }

    /// 缩略图：按目标宽度等比缩小后再接
    static func thumbnail(_ pieces: [(image: CGImage, rows: Range<Int>)], width target: Int) -> CGImage? {
        guard let width = pieces.first?.image.width, width > 0 else { return nil }
        let ratio = min(1, CGFloat(target) / CGFloat(width))
        let total = max(1, Int((CGFloat(pieces.reduce(0) { $0 + $1.rows.count }) * ratio).rounded()))
        let outWidth = max(1, Int((CGFloat(width) * ratio).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: outWidth, height: total, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        var top: CGFloat = 0
        for piece in pieces {
            let height = CGFloat(piece.rows.count) * ratio
            let rect = CGRect(x: 0, y: piece.rows.lowerBound, width: piece.image.width, height: piece.rows.count)
            if let crop = piece.image.cropping(to: rect) {
                context.draw(crop, in: CGRect(x: 0, y: CGFloat(total) - top - height, width: CGFloat(outWidth), height: height))
            }
            top += height
        }
        return context.makeImage()
    }

    /// 按顺序把各帧的若干行（像素行，0 在最上面）接成一张图
    static func compose(_ pieces: [(image: CGImage, rows: Range<Int>)]) -> CGImage? {
        guard let width = pieces.first?.image.width else { return nil }
        let height = pieces.reduce(0) { $0 + $1.rows.count }
        guard height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .none
        var top = 0
        for piece in pieces {
            let rect = CGRect(x: 0, y: piece.rows.lowerBound, width: piece.image.width, height: piece.rows.count)
            if let crop = piece.image.cropping(to: rect) {
                // CGContext 原点在左下角
                context.draw(crop, in: CGRect(x: 0, y: height - top - piece.rows.count, width: width, height: piece.rows.count))
            }
            top += piece.rows.count
        }
        return context.makeImage()
    }
}
