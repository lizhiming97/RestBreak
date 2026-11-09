import AppKit
import SwiftUI

/// 长截图拼好后的预览窗口：长图可以上下滚动，工具栏和普通截图一样（标注、提取文字、翻译、贴图、保存、复制）。
/// 标注直接复用截图的 AnnotationEditor：「选区」就是当前看得见的那一段，标注按整张长图的坐标保存，
/// 导出时再画到整张图上。这样标注图层只有窗口那么大，长图再长也不吃显存。
@MainActor
final class LongImageWindow: NSWindow {
    /// 工具栏操作；导出的图带着标注
    var onAction: ((CaptureAction, LongImageWindow) -> Void)?
    let canvas: LongImageCanvas
    let scrollView = NSScrollView()
    let toolbarView: NSHostingView<AnnotationToolbar>
    /// 工具栏所在的顶栏：和长图分开（2026-11-09 用户反馈工具栏贴着长图像是挡住了截图）
    private let headerBar = NSVisualEffectView()
    private let divider = NSBox()
    /// 长图四周留白，边缘看得清清楚楚
    static let margin: CGFloat = 20
    /// 滚动区域里的容器：比长图大一圈留白，窗口更宽时让长图居中
    private let container = FlippedView()

    init(image: CGImage, scale: CGFloat, on screen: NSScreen, annotationStyles: [AnnotationTool: ToolStyle]) {
        canvas = LongImageCanvas(image: image, scale: scale)
        toolbarView = NSHostingView(rootView: AnnotationToolbar(model: canvas.editor.toolbar))
        let toolbarSize = toolbarView.fittingSize
        let area = screen.visibleFrame
        let imageSize = canvas.frame.size
        let width = min(max(imageSize.width + Self.margin * 2, toolbarSize.width + 16), area.width * 0.85)
        let height = min(imageSize.height + toolbarSize.height + Self.margin * 2 + 8, area.height * 0.9)
        let frame = NSRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
        super.init(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                   backing: .buffered, defer: false)
        title = "长截图 · \(image.width)×\(image.height)"
        isReleasedWhenClosed = false
        minSize = NSSize(width: max(360, toolbarSize.width + 16), height: 300)
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 2
        // 长图加细边框和淡阴影，放在留白的容器里
        canvas.wantsLayer = true
        canvas.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
            shadow.shadowBlurRadius = 8
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            return shadow
        }()
        canvas.layer?.borderWidth = 0.5
        canvas.layer?.borderColor = NSColor.separatorColor.cgColor
        container.addSubview(canvas)
        scrollView.documentView = container
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(visibleAreaChanged),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        headerBar.material = .titlebar
        headerBar.blendingMode = .withinWindow
        headerBar.state = .followsWindowActiveState
        headerBar.addSubview(toolbarView)
        divider.boxType = .separator
        let root = NSView()
        root.addSubview(scrollView)
        root.addSubview(headerBar)
        root.addSubview(divider)
        contentView = root
        layoutContent()

        canvas.editor.reset(styles: annotationStyles, scale: scale)
        canvas.editor.toolbar.onAction = { [weak self] action in
            guard let self else { return }
            self.onAction?(action, self)
        }
        // 比窗口宽的长图先缩到刚好放下（含两边留白）
        let available = scrollView.contentSize.width
        let needed = imageSize.width + Self.margin * 2
        if needed > available { scrollView.magnification = max(0.1, available / needed) }
        layoutContent()
        scrollView.contentView.scroll(to: .zero)
        visibleAreaChanged()
    }

    /// 带标注的整张长图
    func exportImage() -> CGImage? { canvas.exportFullImage() }

    /// 长图在屏幕上的大小（点），贴图和保存用
    var imagePointSize: CGSize { canvas.frame.size }

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        layoutContent()
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        layoutContent()
    }

    private func layoutContent() {
        guard let root = contentView else { return }
        let size = toolbarView.fittingSize
        let bounds = root.bounds
        // 顶栏：工具栏居中；下面一条分隔线；再往下才是长图区域，互不重叠
        let headerHeight = size.height + 4
        headerBar.frame = NSRect(x: 0, y: bounds.height - headerHeight, width: bounds.width, height: headerHeight)
        toolbarView.frame = NSRect(x: (bounds.width - size.width) / 2, y: 2, width: size.width, height: size.height)
        divider.frame = NSRect(x: 0, y: headerBar.frame.minY - 1, width: bounds.width, height: 1)
        scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, divider.frame.minY))
        // 容器至少和可见宽度一样宽，长图在里面水平居中、四周留白
        let magnification = max(scrollView.magnification, 0.01)
        let visibleWidth = scrollView.contentSize.width / magnification
        let image = canvas.frame.size
        let width = max(image.width + Self.margin * 2, visibleWidth)
        container.frame = NSRect(x: 0, y: 0, width: width, height: image.height + Self.margin * 2)
        canvas.setFrameOrigin(NSPoint(x: ((width - image.width) / 2).rounded(), y: Self.margin))
        visibleAreaChanged()
    }

    /// 标注的「选区」= 长图看得见的那一段（画布自己的坐标）
    @objc private func visibleAreaChanged() {
        canvas.visibleArea = canvas.visibleRect
    }

    // 快捷键和截图框选一致：Enter / ⌘C 复制、⌘S 保存、Space 贴图、Esc 取消、⌘Z 撤销
    override func keyDown(with event: NSEvent) {
        guard !canvas.editor.isEditingText else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 36, 76: onAction?(.copy, self)
        case 49: onAction?(.pin, self)
        case 53:
            if !canvas.editor.handleEscape() { onAction?(.cancel, self) }
        case 51, 117: _ = canvas.editor.deleteSelected()
        default: super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !canvas.editor.isEditingText else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (flags, event.keyCode) {
        case (.command, 8): onAction?(.copy, self); return true          // ⌘C
        case (.command, 1): onAction?(.save, self); return true          // ⌘S
        case (.command, 6): canvas.editor.undo(); return true            // ⌘Z
        case ([.command, .shift], 6): canvas.editor.redo(); return true  // ⌘⇧Z
        case (.command, 13): onAction?(.cancel, self); return true       // ⌘W
        default: return super.performKeyEquivalent(with: event)
        }
    }

    override func close() {
        NotificationCenter.default.removeObserver(self)
        canvas.editor.endTextEditing(commit: false)
        super.close()
    }
}

/// 长图画布：按需画看得见的那一段（不把整张长图塞进一个图层），并作为标注的宿主
@MainActor
final class LongImageCanvas: NSView, AnnotationHost {
    let editor = AnnotationEditor()
    private let image: CGImage
    private let scale: CGFloat
    /// 当前看得见的区域（画布坐标，左上角原点，点），也是标注的「选区」
    var visibleArea: CGRect = .zero {
        didSet {
            let clipped = visibleArea.intersection(bounds)
            guard clipped != oldValue else { return }
            visibleArea = clipped
            editor.redraw()
        }
    }

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
        super.init(frame: NSRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        for sublayer in [editor.annotationLayer, editor.mosaicOutlineLayer, editor.outlineLayer] {
            layer?.addSublayer(sublayer)
        }
        editor.host = self
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = dirtyRect.intersection(bounds)
        guard !rect.isEmpty,
              let crop = image.cropping(to: CaptureGeometry.pixelRect(for: rect, scale: scale)) else { return }
        // 画布是翻转坐标（y 向下），CGImage 要翻回来画
        context.saveGState()
        context.interpolationQuality = .medium
        context.translateBy(x: 0, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(crop, in: CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height))
        context.restoreGState()
    }

    func exportFullImage() -> CGImage? {
        editor.endTextEditing(commit: true)
        return AnnotationRenderer.export(selection: bounds, source: image, scale: scale,
                                         annotations: editor.document.items, cache: MosaicCache())
    }

    // MARK: - 标注宿主

    var annotationSelection: CGRect? { visibleArea.isEmpty ? nil : visibleArea }
    var annotationSource: AnnotationSource? { AnnotationSource(image: image, scale: scale) }
    func viewRect(_ rect: CGRect) -> NSRect { rect }   // 画布本身就是左上角原点
    var hostView: NSView { self }
    func annotationDidChange() { window?.invalidateCursorRects(for: self) }

    // MARK: - 鼠标

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        _ = editor.mouseDown(at: point(event), clickCount: event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        _ = editor.mouseDragged(to: point(event), shift: event.modifierFlags.contains(.shift))
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        _ = editor.mouseUp()
    }

    override func resetCursorRects() {
        if editor.tool != nil { addCursorRect(visibleRect, cursor: editor.tool == .text ? .iBeam : .crosshair) }
    }
}

/// 左上角原点的容器（长图从上往下排）
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
