import CoreGraphics
import Foundation

/// 长截图的拼接工作：在后台串行队列上做，不卡界面。
/// 只留一个「待处理」位置：上一帧还没拼完又来了新的，就用新的替换（中间那帧丢掉），不会越积越多。
final class ScrollStitchWorker: @unchecked Sendable {
    struct Update: Sendable {
        enum Kind: Sendable { case started, appended, contained, still, lost, full }
        let kind: Kind
        let height: Int
        /// 有新内容时附带缩略图（最多每 0.2 秒一张）
        let thumbnail: CGImage?
    }

    private let queue = DispatchQueue(label: "com.lizhiming.RestBreak.scroll-stitch", qos: .userInitiated)
    private let lock = NSLock()
    // 下面两个只在持锁时读写
    private var pending: CGImage?
    private var draining = false

    // 下面这些只在 queue 上读写
    private let limit: Int
    private var previous: GrayFrame?
    private var canvas: ScrollCanvas?
    private var firstImage: CGImage?
    private var strips: [CGImage] = []
    private var latestImage: CGImage?
    private var frameIndex = 0
    private var lastThumbnail = Date.distantPast
    private var stopped = false

    /// 每处理完一帧回调一次（在后台队列上调用）
    private let onUpdate: @Sendable (Update) -> Void

    init(limit: Int, onUpdate: @escaping @Sendable (Update) -> Void) {
        self.limit = limit
        self.onUpdate = onUpdate
    }

    /// 截到新的一帧（任意线程）
    func submit(_ image: CGImage) {
        lock.lock()
        pending = image
        let start = !draining
        draining = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let image = pending else { draining = false; lock.unlock(); return }
            pending = nil
            lock.unlock()
            process(image)
        }
    }

    private func process(_ image: CGImage) {
        guard !stopped else { return }
        let gray = GrayFrame(image: image)
        guard let previous, var canvas else {
            self.previous = gray
            canvas = ScrollCanvas(frameHeight: image.height, limit: limit)
            firstImage = image
            latestImage = image
            emit(.started, force: true)
            return
        }
        guard gray.width == previous.width, gray.height == previous.height else { return }
        // 和上一帧完全一样：没有新信息
        if gray.full == previous.full { return }
        frameIndex += 1
        switch MotionEstimator.estimate(previous: previous, next: gray) {
        case .indeterminate:
            // 看不出来：保留上一帧，下一帧继续和它比
            emit(.lost)
        case .still:
            canvas.touch(frame: frameIndex)
            self.canvas = canvas
            self.previous = gray
            latestImage = image
            emit(.still)
        case .moved(let d):
            if !canvas.bandsKnown {
                let bands = MotionEstimator.fixedBands(previous: previous, next: gray)
                canvas.setBands(top: bands.top, bottom: bands.bottom)
            }
            let outcome = canvas.apply(d, frame: frameIndex)
            self.canvas = canvas
            self.previous = gray
            latestImage = image
            switch outcome {
            case .appended(let rows):
                if let strip = LongImageComposer.copyRows(image, rows: rows) { strips.append(strip) }
                emit(.appended)
            case .contained: emit(.contained)
            case .limitReached: emit(.full, force: true)
            }
        }
    }

    /// 合成用的片段：第一帧（去掉底栏）+ 每一条 + 最近一帧的底栏
    private func pieces() -> [(image: CGImage, rows: Range<Int>)] {
        guard let canvas, let firstImage else { return [] }
        let final = canvas.finalPieces()
        var result: [(image: CGImage, rows: Range<Int>)] = [(firstImage, final[0].rows)]
        result += strips.map { ($0, 0..<$0.height) }
        if canvas.bandsKnown, canvas.bottom > 0, let latestImage, let footer = final.last {
            result.append((latestImage, footer.rows))
        }
        return result
    }

    private func emit(_ kind: Update.Kind, force: Bool = false) {
        let height = canvas?.height ?? 0
        var thumbnail: CGImage?
        if kind == .appended || force, force || Date().timeIntervalSince(lastThumbnail) > 0.2 {
            thumbnail = LongImageComposer.thumbnail(pieces(), width: 360)
            lastThumbnail = Date()
        }
        onUpdate(Update(kind: kind, height: height, thumbnail: thumbnail))
    }

    /// 结束：等正在拼的那帧做完，合成整张长图
    func finish() -> CGImage? {
        queue.sync {
            stopped = true
            let image = LongImageComposer.compose(pieces())
            release()
            return image
        }
    }

    func cancel() {
        queue.async { [self] in
            stopped = true
            release()
        }
    }

    private func release() {
        previous = nil
        firstImage = nil
        latestImage = nil
        strips = []
    }
}
