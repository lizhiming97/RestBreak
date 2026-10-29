import AppKit
import SwiftUI

/// 贴到桌面的图片：无边框、置顶、所有桌面空间可见，圆角 + 柔和阴影
final class PinWindow: NSPanel {
    let image: CGImage
    var onClose: ((PinWindow) -> Void)?
    var onCloseAll: (() -> Void)?
    /// 右键「提取文字」
    var onExtractText: ((PinWindow) -> Void)?

    /// 至少留多少点在屏幕内，免得拖出去找不回来
    private let minVisible: CGFloat = 40

    init(image: CGImage, frame: NSRect, opacity: Double) {
        self.image = image
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        alphaValue = min(max(opacity, 0.2), 1)
        let view = PinView(frame: NSRect(origin: .zero, size: frame.size))
        view.autoresizingMask = [.width, .height]
        view.pin = self
        contentView = view
        NotificationCenter.default.addObserver(self, selector: #selector(didMove),
                                               name: NSWindow.didMoveNotification, object: self)
    }

    override var canBecomeKey: Bool { true }

    /// 图片在原屏幕上每点几个像素（复制、保存时保持原来的清晰度）
    var pointSize: CGSize { frame.size }

    func closePin() {
        orderOut(nil)
        onClose?(self)
    }

    func setOpacity(_ value: Double) {
        alphaValue = min(max(value, 0.2), 1)
        (contentView as? PinView)?.showOpacity()
    }

    func saveImage() {
        ImageExport.save(image, pointSize: pointSize) { _ in }
    }

    /// 拖到屏幕外面时拉回来，保证至少留一部分在某块屏幕上
    @objc private func didMove(_ notification: Notification) {
        let frame = self.frame
        let visible = NSScreen.screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(frame)
            return overlap.width >= minVisible && overlap.height >= minVisible
        }
        guard !visible, let screen = NSScreen.screens.min(by: {
            distance($0.visibleFrame, frame) < distance($1.visibleFrame, frame)
        }) else { return }
        let area = screen.visibleFrame
        var origin = frame.origin
        origin.x = min(max(origin.x, area.minX - frame.width + minVisible), area.maxX - minVisible)
        origin.y = min(max(origin.y, area.minY - frame.height + minVisible), area.maxY - minVisible)
        setFrameOrigin(origin)
    }

    private func distance(_ a: NSRect, _ b: NSRect) -> CGFloat {
        hypot(a.midX - b.midX, a.midY - b.midY)
    }
}

/// 贴图的内容：图片 + 透明度提示 + 鼠标移上去才出现的关闭按钮；处理双击、按键、⌥ 滚轮、右键菜单
private final class PinView: NSView {
    weak var pin: PinWindow?
    private let imageLayer = CALayer()
    private let badge = CATextLayer()
    private var badgeTask: Task<Void, Never>?
    /// 右上角的 × 关闭按钮（鼠标在贴图上时淡入）
    private let closeButton = PinCloseButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        layer?.addSublayer(imageLayer)

        badge.fontSize = 11
        badge.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        badge.foregroundColor = NSColor.white.cgColor
        badge.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        badge.cornerRadius = 4
        badge.alignmentMode = .center
        badge.opacity = 0
        layer?.addSublayer(badge)

        closeButton.target = self
        closeButton.action = #selector(closePin)
        closeButton.alphaValue = 0
        addSubview(closeButton)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { setCloseButtonVisible(true) }
    override func mouseExited(with event: NSEvent) { setCloseButtonVisible(false) }

    private func setCloseButtonVisible(_ visible: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            closeButton.animator().alphaValue = visible ? 1 : 0
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        imageLayer.contents = pin?.image
        let scale = window?.backingScaleFactor ?? 2
        badge.contentsScale = scale
        layout()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        badge.frame = CGRect(x: bounds.width - 48, y: 6, width: 42, height: 17)
        CATransaction.commit()
        // 右上角，贴图很小时也不超出
        let size = min(PinCloseButton.size, max(bounds.width - 8, 12), max(bounds.height - 8, 12))
        closeButton.frame = NSRect(x: bounds.width - size - 6, y: bounds.height - size - 6, width: size, height: size)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        if event.clickCount == 2 {
            pin?.closePin()
            return
        }
        super.mouseDown(with: event)   // 交给窗口处理拖动
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { pin?.closePin() } else { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, window?.isKeyWindow == true, let pin else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.keyCode {
        case 8: ImageExport.copy(pin.image, pointSize: pin.pointSize); return true   // ⌘C
        case 1: pin.saveImage(); return true                                       // ⌘S
        case 13: pin.closePin(); return true                                       // ⌘W
        default: return super.performKeyEquivalent(with: event)
        }
    }

    /// 按住 ⌥ 滚动滚轮调透明度
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.option), let pin else { return super.scrollWheel(with: event) }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        let step = event.hasPreciseScrollingDeltas ? Double(delta) / 200 : (delta > 0 ? 0.05 : -0.05)
        pin.setOpacity(Double(pin.alphaValue) + step)
    }

    /// 右下角短暂显示透明度
    func showOpacity() {
        guard let pin else { return }
        badge.string = "\(Int((pin.alphaValue * 100).rounded()))%"
        badge.opacity = 1
        badgeTask?.cancel()
        badgeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.badge.opacity = 0   // 隐式动画淡出
        }
    }

    // MARK: - 右键菜单

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(item("复制", #selector(copyImage), key: "c"))
        menu.addItem(item("保存…", #selector(saveImage), key: "s"))
        menu.addItem(item("提取文字", #selector(extractText)))
        let opacity = NSMenuItem(title: "透明度", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for percent in [100, 80, 60, 40] {
            let option = item("\(percent)%", #selector(setOpacity(_:)))
            option.tag = percent
            option.state = Int((pin?.alphaValue ?? 1) * 100 + 0.5) == percent ? .on : .off
            submenu.addItem(option)
        }
        opacity.submenu = submenu
        menu.addItem(opacity)
        menu.addItem(.separator())
        menu.addItem(item("关闭", #selector(closePin), key: "w"))
        menu.addItem(item("关闭所有贴图", #selector(closeAll)))
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func copyImage() {
        guard let pin else { return }
        ImageExport.copy(pin.image, pointSize: pin.pointSize)
    }

    @objc private func saveImage() { pin?.saveImage() }
    @objc private func extractText() { if let pin { pin.onExtractText?(pin) } }
    @objc private func setOpacity(_ sender: NSMenuItem) { pin?.setOpacity(Double(sender.tag) / 100) }
    @objc private func closePin() { pin?.closePin() }
    @objc private func closeAll() { pin?.onCloseAll?() }
}

// MARK: - 贴图位置

enum PinFrame {
    /// 贴图的窗口位置：比屏幕大时等比缩小到可用区域的 80% 以内，再整体挪进屏幕
    static func fitted(_ frame: NSRect, on screen: NSScreen) -> NSRect {
        let area = screen.visibleFrame
        var size = frame.size
        let limit = CGSize(width: area.width * 0.8, height: area.height * 0.8)
        let ratio = min(limit.width / size.width, limit.height / size.height, 1)
        size = CGSize(width: (size.width * ratio).rounded(), height: (size.height * ratio).rounded())
        // 缩小时保持中心不变
        var origin = CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
        if ratio == 1 { origin = frame.origin }
        origin.x = min(max(origin.x, area.minX), area.maxX - size.width)
        origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
        return NSRect(origin: origin, size: size)
    }
}

// MARK: - 剪贴板文字 → 卡片图片

enum TextCard {
    private static let maxCharacters = 2000
    private static let maxWidth: CGFloat = 480
    private static let maxHeight: CGFloat = 600
    private static let padding: CGFloat = 14

    /// 把文字画成白底深字的卡片；scale 为屏幕像素密度。返回图片和它的点尺寸
    @MainActor
    static func render(_ text: String, scale: CGFloat) -> (image: CGImage, size: CGSize)? {
        var string = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty else { return nil }
        if string.count > maxCharacters { string = String(string.prefix(maxCharacters)) + "…" }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1),
            .paragraphStyle: paragraph,
        ])
        let textWidth = maxWidth - padding * 2
        let measured = attributed.boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                                               options: [.usesLineFragmentOrigin, .usesFontLeading])
        let textSize = CGSize(width: ceil(min(measured.width, textWidth)),
                              height: ceil(min(measured.height, maxHeight - padding * 2)))
        let size = CGSize(width: textSize.width + padding * 2, height: textSize.height + padding * 2)

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        attributed.draw(with: NSRect(x: padding, y: padding, width: textSize.width, height: textSize.height),
                        options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
        NSGraphicsContext.restoreGraphicsState()
        guard let image = rep.cgImage else { return nil }
        return (image, size)
    }
}

// MARK: - 「已复制」小提示

@MainActor
enum Toast {
    private static var current: NSPanel?

    /// 在某个位置（全局屏幕坐标）显示一个小提示，1 秒后淡出
    static func show(_ text: String, symbol: String = "checkmark.circle.fill", at point: NSPoint) {
        current?.orderOut(nil)
        let hosting = NSHostingView(rootView: ToastView(text: text, symbol: symbol))
        let size = hosting.fittingSize
        let panel = NSPanel(contentRect: NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                                width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentView = hosting
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        current = panel

        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.1))
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 },
                                                 completionHandler: nil)
            try? await Task.sleep(for: .seconds(0.35))
            panel.orderOut(nil)
            if current === panel { current = nil }
        }
    }
}

private struct ToastView: View {
    let text: String
    let symbol: String

    var body: some View {
        let content = HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(Color(red: 0.36, green: 0.85, blue: 0.5))
            Text(text)
                .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)

        Group {
            if #available(macOS 26, *) {
                content.glassEffect(.regular, in: Capsule())
            } else {
                content.background(.ultraThinMaterial, in: Capsule())
            }
        }
        .environment(\.colorScheme, .dark)
        .padding(10)
        .fixedSize()
    }
}

/// 贴图右上角的关闭按钮：半透明深色圆 + 白色 ×，任何图片上都看得清
private final class PinCloseButton: NSButton {
    static let size: CGFloat = 22
    private var isHovered = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        isBordered = false
        title = ""
        toolTip = "关闭贴图"
        setAccessibilityLabel("关闭贴图")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let circle = bounds.insetBy(dx: 1, dy: 1)
        (isHovered ? NSColor(red: 0.9, green: 0.25, blue: 0.22, alpha: 0.95) : NSColor.black.withAlphaComponent(0.6))
            .setFill()
        NSBezierPath(ovalIn: circle).fill()
        NSColor.white.withAlphaComponent(0.85).setStroke()
        let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        ring.stroke()
        let inset = bounds.width * 0.34
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: inset, y: inset))
        cross.line(to: NSPoint(x: bounds.maxX - inset, y: bounds.maxY - inset))
        cross.move(to: NSPoint(x: inset, y: bounds.maxY - inset))
        cross.line(to: NSPoint(x: bounds.maxX - inset, y: inset))
        cross.lineWidth = 1.8
        cross.lineCapStyle = .round
        NSColor.white.setStroke()
        cross.stroke()
    }
}
