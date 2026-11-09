import AppKit
import SwiftUI

/// 一次长截图（2026-11-09 第二版，思路参考 Snow Shot）：
/// - 连续录选区（每秒最多 30 帧），后台每次只拼最新的一帧（`ScrollStitchWorker`）；
/// - 默认自动滚动：每 0.2 秒让「星期五鼠标」往选区中间那个窗口发一次滚动（直接发给那个窗口，**不动光标**），
///   鼠标停在控制面板上时暂停；也可以暂停后自己滚，往回滚不会出错；
/// - 自动滚动时画面 1.5 秒不再往下走，视为到底，自动完成。
/// 只在长截图进行中工作，结束时全部停掉，平时没有任何开销。
@MainActor
final class ScrollingCaptureSession: ObservableObject {
    /// 长图最长多少像素（再长导出和标注都很吃内存）
    static let heightLimit = 30_000
    /// 自动滚动：每 0.2 秒往下 120 点（组件拆成 4 小段连续发出，看起来是匀速往下走）
    static let autoInterval: Duration = .milliseconds(200)
    static let autoStep = 120

    @Published private(set) var thumbnail: CGImage?
    @Published private(set) var heightInPixels = 0
    @Published private(set) var hint = "正在准备…"
    @Published private(set) var isWarning = false
    @Published private(set) var isFull = false
    /// 正在自动滚动（点「暂停」后改为自己滚）
    @Published private(set) var isAutoScrolling = false

    /// 用户点了完成（长图、像素密度）或取消（nil）
    var onEnd: ((CGImage?, CGFloat) -> Void)?

    let rect: NSRect
    let screen: NSScreen
    private let scale: CGFloat
    private var stream: ScreenCapturer.RegionStream?
    private var worker: ScrollStitchWorker?
    private var autoTask: Task<Void, Never>?
    private var deniedObserver: NSObjectProtocol?
    private var isActive = false
    private var panel: ScrollingCapturePanel?

    /// 最近一次画面往下走（有新内容）的时间；自动滚动用来判断到底
    private var lastProgress = ContinuousClock.now
    private var hasAppended = false
    /// 连续「看不出来」的帧数
    private var lostFrames = 0

    /// 选区中心（全局坐标，左上角原点），自动滚动发给这个位置下面的窗口
    private var scrollPoint: CGPoint {
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.maxY
        return CGPoint(x: rect.midX, y: mainHeight - rect.midY)
    }

    init(rect: NSRect, screen: NSScreen) {
        self.rect = rect
        self.screen = screen
        scale = screen.backingScaleFactor
    }

    func start() {
        isActive = true
        panel = ScrollingCapturePanel(session: self)
        let canAuto = MouseCompanionClient.shared.installedURL() != nil
        setHint(canAuto ? Self.autoHint : "在框里往下滚动，星期五会自动拼接", warning: false)
        // 鼠标组件没有辅助功能权限、或选区中间找不到窗口：改回自己滚
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            DispatchQueue.main.async { NotificationCenter.default.post(name: .autoScrollDenied, object: nil) }
        }, MouseCompanionClient.autoScrollDenied as CFString, nil, .deliverImmediately)
        deniedObserver = NotificationCenter.default.addObserver(forName: .autoScrollDenied, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.isAutoScrolling else { return }
                self.stopAuto()
                self.setHint("自动滚动需要「星期五鼠标」的辅助功能权限（设置 › 鼠标顺滑 › 去授权）。现在请自己往下滚", warning: true)
            }
        }
        let worker = ScrollStitchWorker(limit: Self.heightLimit) { [weak self] update in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(update) } }
        }
        self.worker = worker
        Task { [weak self] in
            // 等框选画面完全撤掉再开始录
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, self.isActive else { return }
            do {
                self.stream = try await ScreenCapturer.streamRegion(self.rect, on: self.screen) { image in worker.submit(image) }
                guard self.isActive else { self.stream?.stop(); return }
                if canAuto { self.startAuto() }
            } catch {
                self.fail("无法截取这块区域，请重新框选")
            }
        }
    }

    private static let autoHint = "正在自动往下滚动，到底会自动完成。鼠标停在这个面板上可暂停"

    private func received(_ update: ScrollStitchWorker.Update) {
        guard isActive else { return }
        if let thumbnail = update.thumbnail { self.thumbnail = thumbnail }
        heightInPixels = update.height
        switch update.kind {
        case .appended:
            hasAppended = true
            lastProgress = .now
            lostFrames = 0
            if !isAutoScrolling { setHint("继续往下滚，到底后点「完成」", warning: false) }
        case .contained, .still, .started:
            lostFrames = 0
        case .lost:
            lostFrames += 1
            if lostFrames >= 15 { setHint("画面变化太大，跟丢了。往回滚一点再继续", warning: true) }
        case .full:
            isFull = true
            stopAuto()
            setHint("已达到长度上限，点「完成」", warning: true)
        }
    }

    // MARK: - 自动滚动

    private func startAuto() {
        isAutoScrolling = true
        lastProgress = .now
        setHint(Self.autoHint, warning: false)
        autoTask?.cancel()
        autoTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.autoInterval, tolerance: .milliseconds(10))
                guard let self, self.isActive, self.isAutoScrolling else { return }
                // 鼠标停在控制面板上：先不滚（方便点按钮）
                if self.panel?.containsMouse == true { self.lastProgress = .now; continue }
                if ContinuousClock.now - self.lastProgress > .milliseconds(1500) {
                    if self.hasAppended {
                        self.setHint("已经到底", warning: false)
                        self.finish()
                    } else {
                        self.stopAuto()
                        self.setHint("框中间的内容滚不动。把框放在要截的那一栏里，或暂停后自己滚", warning: true)
                    }
                    return
                }
                MouseCompanionClient.shared.autoScroll(at: self.scrollPoint, down: Self.autoStep)
            }
        }
    }

    private func stopAuto() {
        isAutoScrolling = false
        autoTask?.cancel()
        autoTask = nil
    }

    /// 点「暂停自动滚动 / 继续自动滚动」
    func toggleAutoScroll() {
        guard isActive, MouseCompanionClient.shared.installedURL() != nil else { return }
        if isAutoScrolling {
            stopAuto()
            setHint("已暂停，可以自己滚，或点「继续」", warning: false)
        } else {
            startAuto()
        }
    }

    private func setHint(_ text: String, warning: Bool) {
        hint = text
        isWarning = warning
    }

    func finish() {
        guard isActive else { return }
        let image = worker?.finish()
        stop()
        onEnd?(image, scale)
    }

    func cancel() {
        guard isActive else { return }
        worker?.cancel()
        stop()
        onEnd?(nil, scale)
    }

    private func fail(_ text: String) {
        worker?.cancel()
        stop()
        Toast.show(text, symbol: "exclamationmark.circle.fill", at: NSPoint(x: rect.midX, y: rect.midY))
        onEnd?(nil, scale)
    }

    private func stop() {
        isActive = false
        stopAuto()
        stream?.stop()
        stream = nil
        worker = nil
        if let deniedObserver { NotificationCenter.default.removeObserver(deniedObserver) }
        deniedObserver = nil
        panel?.close()
        panel = nil
        thumbnail = nil
    }
}

@MainActor
final class ScrollingCapturePanel {
    private let border: NSWindow
    private let controls: NSPanel

    init(session: ScrollingCaptureSession) {
        let rect = session.rect
        border = NSWindow(contentRect: rect.insetBy(dx: -3, dy: -3), styleMask: .borderless, backing: .buffered, defer: false)
        border.isOpaque = false
        border.backgroundColor = .clear
        border.ignoresMouseEvents = true
        border.hasShadow = false
        border.level = .statusBar
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        border.isReleasedWhenClosed = false
        let frameView = NSView()
        frameView.wantsLayer = true
        frameView.layer?.borderColor = NSColor(red: 0.24, green: 0.48, blue: 0.97, alpha: 1).cgColor
        frameView.layer?.borderWidth = 2
        frameView.layer?.cornerRadius = 3
        border.contentView = frameView

        let hosting = NSHostingView(rootView: ScrollingCaptureControls(session: session))
        let size = NSSize(width: 220, height: 380)
        let area = session.screen.visibleFrame
        var origin = NSPoint(x: rect.maxX + 14, y: rect.maxY - size.height)
        if origin.x + size.width > area.maxX { origin.x = rect.minX - 14 - size.width }   // 右边放不下放左边
        if origin.x < area.minX { origin.x = rect.maxX - size.width - 10 }                  // 都放不下放在选区里的右侧
        origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
        controls = NSPanel(contentRect: NSRect(origin: origin, size: size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        controls.isOpaque = false
        controls.backgroundColor = .clear
        controls.hasShadow = true
        controls.level = .statusBar
        controls.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        controls.isReleasedWhenClosed = false
        controls.isMovableByWindowBackground = true
        controls.contentView = hosting

        border.orderFrontRegardless()
        controls.orderFrontRegardless()
    }

    /// 鼠标在控制面板上（自动滚动暂停）
    var containsMouse: Bool { NSMouseInRect(NSEvent.mouseLocation, controls.frame, false) }

    func close() {
        border.orderOut(nil)
        controls.orderOut(nil)
        controls.contentView = nil
    }
}

private struct ScrollingCaptureControls: View {
    @ObservedObject var session: ScrollingCaptureSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "rectangle.expand.vertical")
                Text("长截图").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(session.heightInPixels) 像素").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    Group {
                        if let thumbnail = session.thumbnail {
                            Image(decorative: thumbnail, scale: 2).resizable().aspectRatio(contentMode: .fit)
                        } else {
                            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 80)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .onChange(of: session.heightInPixels) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Text(session.hint)
                .font(.system(size: 12))
                .foregroundStyle(session.isWarning ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if MouseCompanionClient.shared.installedURL() != nil {
                Button(session.isAutoScrolling ? "暂停自动滚动" : "继续自动滚动") { session.toggleAutoScroll() }
                    .controlSize(.small)
            }
            HStack {
                Button("取消") { session.cancel() }
                Spacer()
                Button("完成") { session.finish() }
                    .buttonStyle(.borderedProminent)
                    .tint(ToolbarColors.accent)
            }
        }
        .padding(12)
        .frame(width: 220, height: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private extension Notification.Name {
    static let autoScrollDenied = Notification.Name("ScrollingCapture.autoScrollDenied")
}
