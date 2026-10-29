import AppKit
import SwiftUI

/// 框选完成后用户选的操作
enum CaptureAction {
    case copy, save, pin, cancel
    case extractText   // 提取文字（OCR）
    case translate     // 提取文字并翻译
}

/// 截图框选窗口：无边框、盖住一切（包括菜单栏和全屏 App）
final class CaptureWindow: NSWindow {
    /// 这个窗口盖住的显示器（窗口隐藏时 window.screen 不可靠，所以创建时记下来）
    let displayID: CGDirectDisplayID?

    init(screen: NSScreen) {
        displayID = screen.displayID
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
    }

    // 无边框窗口默认不能成为 key window，收不到键盘，这里放开
    override var canBecomeKey: Bool { true }
}

/// 管理截图框选：每块屏幕一个窗口。启动时就建好并隐藏（预热），按快捷键时只需要放上画面再显示。
@MainActor
final class CaptureOverlayController: NSObject {
    /// 用户选了操作；view 是有选区的那块屏幕
    var onAction: ((CaptureAction, CaptureView) -> Void)?
    /// 截图过程中显示器插拔、改分辨率
    var onScreensChanged: (() -> Void)?
    /// 标注时改了某个工具的颜色/粗细
    var onAnnotationStyleChange: ((AnnotationTool, ToolStyle) -> Void)?

    private var windows: [CaptureWindow] = []
    private var releaseTask: Task<Void, Never>?
    private(set) var isShowing = false

    override init() {
        super.init()
        // 窗口不预建：平时不占内存，按快捷键截图时再建（和截屏并行，用户感觉不到）
        NotificationCenter.default.addObserver(self, selector: #selector(screensDidChange),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
    }

    private var views: [CaptureView] { windows.compactMap { $0.contentView as? CaptureView } }

    private func buildWindows() {
        for window in windows { window.orderOut(nil) }
        windows = NSScreen.screens.map { screen in
            let window = CaptureWindow(screen: screen)
            let view = CaptureView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onAction = { [weak self, weak view] action in
                guard let self, let view else { return }
                self.onAction?(action, view)
            }
            view.editor.onStyleChange = { [weak self] tool, style in self?.onAnnotationStyleChange?(tool, style) }
            view.onMouseEnteredScreen = { [weak self] in self?.focusScreenUnderMouse() }
            view.onBeganSelecting = { [weak self, weak view] in
                // 同一时间只有一块屏幕可以有选区
                for other in self?.views ?? [] where other !== view { other.clearSelection() }
            }
            window.contentView = view
            return window
        }
    }

    @objc private func screensDidChange(_ notification: Notification) {
        ScreenCapturer.invalidateDisplays()
        if isShowing { onScreensChanged?() }
        releaseWindows()
    }

    /// 显示定格画面，开始框选
    func show(_ snapshots: [ScreenSnapshot], showMagnifier: Bool, annotationStyles: [AnnotationTool: ToolStyle]) {
        prepare()
        let mouse = NSEvent.mouseLocation
        var keyWindow: CaptureWindow?
        for window in windows {
            guard let view = window.contentView as? CaptureView,
                  let snapshot = snapshots.first(where: { $0.screen.displayID == window.displayID })
            else { continue }
            view.load(snapshot, showMagnifier: showMagnifier, annotationStyles: annotationStyles)
            window.orderFrontRegardless()
            if window.frame.contains(mouse) { keyWindow = window }
        }
        isShowing = true
        NSApp.activate()
        let key = keyWindow ?? windows.first { $0.isVisible }
        key?.makeKeyAndOrderFront(nil)
        key?.makeFirstResponder(key?.contentView)
        // 菜单栏 App 的激活是异步的：激活完成前设的 key 窗口可能被系统改回主屏。下一轮再按鼠标位置确认一次
        DispatchQueue.main.async { [weak self] in self?.focusScreenUnderMouse() }
    }

    /// 让鼠标所在屏幕的框选窗口接收键盘（Esc、Enter、方向键…）。
    /// 另一块屏幕已经有选区时不抢（用户可能在用键盘微调那个选区）
    func focusScreenUnderMouse() {
        guard isShowing else { return }
        let mouse = NSEvent.mouseLocation
        guard let target = windows.first(where: { NSMouseInRect(mouse, $0.frame, false) && $0.isVisible }),
              !target.isKeyWindow else { return }
        if views.contains(where: { $0.window !== target && $0.selection != nil }) { return }
        target.makeKeyAndOrderFront(nil)
        target.makeFirstResponder(target.contentView)
    }

    /// 结束截图：关掉窗口、释放图像
    func hide() {
        ToolbarTip.hide()
        isShowing = false
        for window in windows {
            window.orderOut(nil)
            (window.contentView as? CaptureView)?.unload()
        }
        // 建一次窗口要几十毫秒：连续截图时复用，3 分钟没再截图才释放
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard let self, !Task.isCancelled, !self.isShowing else { return }
            self.releaseWindows()
        }
    }

    /// 按需建窗口（已经建好就不重复建）
    func prepare() {
        releaseTask?.cancel()
        if windows.isEmpty { buildWindows() }
    }

    /// 用完就释放窗口（每块屏一个全屏窗口 + 图层，常驻要占几十 MB）
    private func releaseWindows() {
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows = []
    }

    /// 弹出保存框时先藏起来（否则保存框会被盖在下面）
    func temporarilyHide() {
        ToolbarTip.hide()
        for window in windows { window.orderOut(nil) }
    }

    /// 保存框取消后回到选区
    func restore(focusing view: CaptureView) {
        for window in windows where (window.contentView as? CaptureView)?.hasSnapshot == true {
            window.orderFrontRegardless()
        }
        NSApp.activate()
        view.window?.makeKeyAndOrderFront(nil)
        view.window?.makeFirstResponder(view)
    }
}

/// 一块屏幕的框选界面。
/// 用 Core Animation 图层绘制：定格图只设置一次，鼠标移动时只改几个图层的位置，所以大屏幕上也很流畅。
/// 注意坐标：CaptureGeometry 用「左上角原点」，NSView 用「左下角原点」，用 toView / toGeo 换算。
final class CaptureView: NSView {
    var onAction: ((CaptureAction) -> Void)?
    var onBeganSelecting: (() -> Void)?

    private enum Phase {
        case hovering                                       // 还没框选，鼠标下的目标高亮
        case dragging(start: CGPoint)                       // 正在拖出选区
        case selected                                       // 选区已确定，显示工具栏
        case moving(original: CGRect, from: CGPoint)        // 拖动选区内部
        case resizing(original: CGRect, handle: SelectionHandle)   // 拖控制点
    }

    private var phase: Phase = .hovering
    private var snapshot: ScreenSnapshot?
    private var showMagnifier = true
    /// 当前选区（左上角坐标）
    private(set) var selection: CGRect?
    /// 鼠标进入这块屏幕（多屏时让键盘焦点跟着鼠标走）
    var onMouseEnteredScreen: (() -> Void)?
    /// 悬停时鼠标下的目标
    private var hoverTarget: CaptureTarget?
    /// 鼠标位置（左上角坐标），鼠标不在这块屏幕时为 nil
    private var mouse: CGPoint?
    /// 拖动距离小于这个值算单击
    private let clickTolerance: CGFloat = 3
    /// 有标注时第一次按 Esc 的时间：1 秒内再按一次才放弃标注
    private var lastEscapeAt: Date?
    /// 放大镜颜色值格式（RGB / HEX），按 Shift 切换
    private var colorFormat = ColorFormat.current
    private var shiftWasDown = false
    /// 标注（第二期）
    let editor = AnnotationEditor()

    private let accent = NSColor(red: 0.24, green: 0.48, blue: 0.97, alpha: 1)

    // 图层
    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let handlesLayer = CAShapeLayer()
    private let sizeBadge = CALayer()
    private let sizeText = CATextLayer()
    private let magnifier = MagnifierLayer()
    private var toolbar: NSHostingView<AnnotationToolbar>?

    var hasSnapshot: Bool { snapshot != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        guard let root = layer else { return }
        imageLayer.contentsGravity = .resize
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.4).cgColor
        borderLayer.fillColor = nil
        borderLayer.strokeColor = accent.cgColor
        borderLayer.lineWidth = 1.5
        handlesLayer.fillColor = NSColor.white.cgColor
        handlesLayer.strokeColor = accent.cgColor
        handlesLayer.lineWidth = 1.5
        sizeBadge.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        sizeBadge.cornerRadius = 4
        sizeText.fontSize = 11
        sizeText.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        sizeText.foregroundColor = NSColor.white.cgColor
        sizeText.alignmentMode = .center
        sizeBadge.addSublayer(sizeText)
        for sublayer in [imageLayer, editor.annotationLayer, dimLayer, borderLayer, editor.mosaicOutlineLayer,
                         editor.outlineLayer,
                         handlesLayer, sizeBadge, magnifier] {
            root.addSublayer(sublayer)
        }
        editor.host = self
        editor.toolbar.onAction = { [weak self] action in self?.onAction?(action) }
        let toolbar = NSHostingView(rootView: AnnotationToolbar(model: editor.toolbar))
        toolbar.isHidden = true
        addSubview(toolbar)
        self.toolbar = toolbar
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - 载入 / 释放

    func load(_ snapshot: ScreenSnapshot, showMagnifier: Bool, annotationStyles: [AnnotationTool: ToolStyle] = [:]) {
        self.snapshot = snapshot
        self.showMagnifier = showMagnifier
        phase = .hovering
        selection = nil
        hoverTarget = nil
        lastEscapeAt = nil
        colorFormat = ColorFormat.current
        let scale = snapshot.screen.backingScaleFactor
        editor.reset(styles: annotationStyles, scale: scale)
        withoutAnimation {
            imageLayer.frame = bounds
            imageLayer.contents = snapshot.image
            sizeText.contentsScale = scale
            magnifier.setScale(scale)
        }
        // 刚显示时鼠标就在这块屏幕上：立即高亮鼠标下的目标
        if let window, window.frame.contains(NSEvent.mouseLocation) {
            let local = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            updateHover(at: toGeo(convert(local, from: nil)))
        } else {
            mouse = nil
        }
        refresh()
    }

    func unload() {
        editor.reset(styles: [:], scale: 1)
        snapshot = nil
        selection = nil
        hoverTarget = nil
        phase = .hovering
        withoutAnimation {
            imageLayer.contents = nil
            magnifier.clear()
        }
        toolbar?.isHidden = true
    }

    /// 另一块屏幕开始框选了，这块屏幕回到全暗
    func clearSelection() {
        editor.select(tool: nil)
        editor.discardAll()
        selection = nil
        hoverTarget = nil
        mouse = nil
        phase = .hovering
        refresh()
    }

    /// 直接设定选区（左上角坐标），相当于用户框选完松手。测试用
    func select(_ rect: CGRect) {
        selection = rect.intersection(geoBounds)
        phase = .selected
        refresh()
    }

    /// 选中区域的图像（带标注，按这块屏幕的像素密度）
    func selectedImage() -> CGImage? {
        editor.export()
    }

    /// 选区在全局屏幕坐标（左下角原点）里的位置，贴图和提示用
    var selectionInScreen: NSRect? {
        guard let selection, let screen = snapshot?.screen else { return nil }
        let local = toView(selection)
        return local.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
    }

    // MARK: - 坐标换算

    private var geoBounds: CGRect { CGRect(origin: .zero, size: bounds.size) }

    private func toGeo(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: bounds.height - p.y) }

    private func toView(_ r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height)
    }

    private func geoPoint(_ event: NSEvent) -> CGPoint {
        toGeo(convert(event.locationInWindow, from: nil))
    }

    // MARK: - 鼠标

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways,
                                                 .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        if window?.isKeyWindow == false { onMouseEnteredScreen?() }
        updateHover(at: geoPoint(event))
        refresh()
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEnteredScreen?()
        updateHover(at: geoPoint(event))
        refresh()
    }

    override func mouseExited(with event: NSEvent) {
        mouse = nil
        if case .hovering = phase { hoverTarget = nil }
        refresh()
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: geoPoint(event))
    }

    private func updateHover(at point: CGPoint) {
        mouse = point
        if case .hovering = phase, let snapshot {
            hoverTarget = CaptureGeometry.target(at: point, in: snapshot.targets)
        }
        updateCursor(at: point)
    }

    override func mouseDown(with event: NSEvent) {
        guard snapshot != nil else { return }
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        let p = geoPoint(event)
        mouse = p
        // 选了标注工具：点击交给标注处理
        if case .selected = phase, editor.wantsMouse,
           editor.mouseDown(at: p, clickCount: event.clickCount) {
            return
        }
        if let selection, case .selected = phase {
            // 已经有标注时，点选区外不重新框选，免得一下丢掉画好的标注
            if editor.hasAnnotations, !selection.contains(p), CaptureGeometry.handle(at: p, of: selection) == nil {
                return
            }
            if let handle = CaptureGeometry.handle(at: p, of: selection) {
                phase = .resizing(original: selection, handle: handle)
            } else if selection.contains(p) {
                phase = .moving(original: selection, from: p)
                NSCursor.closedHand.set()
            } else {
                startDragging(at: p)
            }
        } else {
            startDragging(at: p)
        }
        refresh()
    }

    private func startDragging(at p: CGPoint) {
        onBeganSelecting?()
        selection = nil
        phase = .dragging(start: p)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = geoPoint(event)
        mouse = p
        if case .selected = phase, editor.mouseDragged(to: p, shift: event.modifierFlags.contains(.shift)) {
            return
        }
        switch phase {
        case .dragging(let start):
            if hypot(p.x - start.x, p.y - start.y) >= clickTolerance || selection != nil {
                hoverTarget = nil
                selection = CaptureGeometry.rect(from: start, to: p, in: geoBounds)
            }
        case .moving(let original, let from):
            selection = CaptureGeometry.moved(original, by: CGSize(width: p.x - from.x, height: p.y - from.y),
                                              in: geoBounds)
            editor.redraw()   // 标注图层跟着选区走
        case .resizing(let original, let handle):
            selection = CaptureGeometry.resized(original, handle: handle, to: p, in: geoBounds)
            editor.redraw()
        case .hovering, .selected:
            break
        }
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        if case .selected = phase, editor.mouseUp() {
            updateCursor(at: geoPoint(event))
            refresh()
            return
        }
        switch phase {
        case .dragging:
            if selection == nil, let target = hoverTarget {
                // 单击：选中鼠标下的窗口 / 菜单栏 / 图标
                selection = target.frame.intersection(geoBounds)
            }
            if let s = selection, s.width < 2 || s.height < 2 { selection = nil }
            phase = selection == nil ? .hovering : .selected
            hoverTarget = nil
        case .moving, .resizing:
            phase = .selected
        case .hovering, .selected:
            break
        }
        updateHover(at: geoPoint(event))
        refresh()
    }

    override func rightMouseDown(with event: NSEvent) {
        handleEscape()
    }

    /// Esc（和右键）一步步往回退：结束文字 → 取消选中标注 → 取消工具 → 清除选区 → 退出截图。
    /// 有标注时清除选区要 1 秒内按两次，免得一下丢掉画好的标注。
    private func handleEscape() {
        if editor.handleEscape() { return }
        guard let selection else {
            onAction?(.cancel)
            return
        }
        if editor.hasAnnotations {
            if let last = lastEscapeAt, Date().timeIntervalSince(last) < 1 {
                lastEscapeAt = nil
            } else {
                lastEscapeAt = Date()
                if let screen = snapshot?.screen {
                    let r = toView(selection).offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
                    Toast.show("再按一次 Esc 放弃标注", symbol: "exclamationmark.circle.fill",
                               at: NSPoint(x: r.midX, y: r.midY))
                }
                return
            }
        }
        backToHovering(at: mouse)
    }

    private func backToHovering(at point: CGPoint?) {
        editor.discardAll()
        selection = nil
        phase = .hovering
        if let point { updateHover(at: point) }
        refresh()
    }

    /// 光标：框选前用圆圈十字（方便对准）；选好以后恢复成普通鼠标，让人知道工具栏可以点
    private func updateCursor(at p: CGPoint) {
        guard let selection, case .selected = phase else {
            CaptureCursor.crosshair.set()
            return
        }
        if isOverToolbar(p) {
            NSCursor.arrow.set()
        } else if let cursor = editor.cursor(at: p) {
            cursor.set()
        } else if let handle = CaptureGeometry.handle(at: p, of: selection) {
            resizeCursor(for: handle).set()
        } else if selection.contains(p) {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    /// 鼠标是否在工具栏（含属性条）上
    private func isOverToolbar(_ p: CGPoint) -> Bool {
        guard let toolbar, !toolbar.isHidden else { return false }
        return toolbar.frame.contains(NSPoint(x: p.x, y: bounds.height - p.y))
    }

    private func resizeCursor(for handle: SelectionHandle) -> NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition = switch handle {
            case .topLeft: .topLeft
            case .top: .top
            case .topRight: .topRight
            case .right: .right
            case .bottomRight: .bottomRight
            case .bottom: .bottom
            case .bottomLeft: .bottomLeft
            case .left: .left
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        switch handle {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        default: return .crosshair
        }
    }

    // MARK: - 键盘

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // 还没选区、放大镜在显示：⌘C 复制颜色值
        if flags == .command, event.keyCode == 8, selection == nil, magnifierVisible {
            copyColor()
            return true
        }
        guard selection != nil, !editor.isEditingText else { return super.performKeyEquivalent(with: event) }
        switch (flags, event.keyCode) {
        case (.command, 8): onAction?(.copy); return true             // ⌘C
        case (.command, 1): onAction?(.save); return true             // ⌘S
        case (.command, 6): editor.undo(); return true                // ⌘Z
        case ([.command, .shift], 6): editor.redo(); return true      // ⌘⇧Z
        default: return super.performKeyEquivalent(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let hasSelection = selection != nil
        switch event.keyCode {
        case 53:   // Esc
            handleEscape()
        case 51, 117:   // ⌫ / ⌦：删除选中的标注
            _ = editor.deleteSelected()
        case let code where hasSelection && flags.isEmpty && Self.toolKeys[code] != nil:   // 1～8 选工具
            let tool = AnnotationTool.allCases[Self.toolKeys[code]!]
            editor.select(tool: editor.tool == tool ? nil : tool)
        case 36, 76:   // Enter
            if hasSelection { onAction?(.copy) }
        case 49:   // Space
            if hasSelection { onAction?(.pin) }
        case 8 where flags.isEmpty && magnifierVisible:   // C：复制颜色
            copyColor()
        case 123, 124, 125, 126:   // 方向键：没选标注工具时微调选区
            guard let current = selection, editor.tool == nil else { return }
            let dx: CGFloat = event.keyCode == 123 ? -1 : event.keyCode == 124 ? 1 : 0
            let dy: CGFloat = event.keyCode == 126 ? -1 : event.keyCode == 125 ? 1 : 0
            selection = CaptureGeometry.nudged(current, dx: dx, dy: dy, resize: flags.contains(.shift),
                                               in: geoBounds)
            editor.redraw()
        default:
            super.keyDown(with: event)
        }
    }

    /// 数字键 1～8 的按键编号 → 第几个工具
    private static let toolKeys: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7]

    /// 复制放大镜里的颜色值（按当前的 RGB / HEX 格式）
    private func copyColor() {
        guard let c = currentColor else { return }
        let text = colorFormat.text(red: c.red, green: c.green, blue: c.blue)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        magnifier.flashCopied(text)
    }

    /// 按下 Shift 切换 RGB / HEX（只在放大镜显示时）
    override func flagsChanged(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        defer { shiftWasDown = shift }
        guard shift, !shiftWasDown, magnifierVisible else { return super.flagsChanged(with: event) }
        colorFormat = colorFormat.toggled
        ColorFormat.current = colorFormat
        refresh()
    }

    // MARK: - 绘制

    private var magnifierVisible: Bool {
        guard showMagnifier, mouse != nil else { return false }
        switch phase {
        case .hovering, .dragging, .resizing: return true
        case .selected, .moving: return false
        }
    }

    private var currentColor: (red: Int, green: Int, blue: Int)? {
        guard let snapshot, let mouse else { return nil }
        let pixel = CGPoint(x: mouse.x * snapshot.scale, y: mouse.y * snapshot.scale)
        return ScreenCapturer.color(atPixel: pixel, in: snapshot.image)
    }

    /// 根据当前状态更新所有图层（关掉隐式动画，否则会有拖影）
    private func refresh() {
        guard let snapshot else { return }
        let highlighted = selection ?? hoverTarget?.frame.intersection(geoBounds)
        let isSelected: Bool = if case .selected = phase { true } else { false }
        let isInteracting: Bool = switch phase {
        case .moving, .resizing: true
        default: false
        }

        withoutAnimation {
            dimLayer.frame = bounds
            borderLayer.frame = bounds
            handlesLayer.frame = bounds

            let dimPath = CGMutablePath()
            dimPath.addRect(bounds)
            if let highlighted { dimPath.addRect(toView(highlighted)) }
            dimLayer.path = dimPath
            borderLayer.path = highlighted.map { CGPath(rect: toView($0).insetBy(dx: -0.75, dy: -0.75), transform: nil) }

            // 控制点：只在选区确定后显示
            if let selection, isSelected || isInteracting, editor.tool == nil {
                let path = CGMutablePath()
                for handle in SelectionHandle.allCases {
                    let p = CaptureGeometry.position(of: handle, in: selection)
                    let v = CGPoint(x: p.x, y: bounds.height - p.y)
                    path.addEllipse(in: CGRect(x: v.x - 3.5, y: v.y - 3.5, width: 7, height: 7))
                }
                handlesLayer.path = path
            } else {
                handlesLayer.path = nil
            }

            // 尺寸标签：选区左上角上方，放不下放到选区内
            if let selection {
                sizeText.string = CaptureGeometry.pixelSize(for: selection, scale: snapshot.scale)
                let textWidth = ((sizeText.string as? String) ?? "").size(withAttributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)]).width
                let badge = CGSize(width: ceil(textWidth) + 12, height: 20)
                let top = selection.minY - badge.height - 4 >= 0 ? selection.minY - badge.height - 4 : selection.minY + 4
                let x = min(max(selection.minX, 0), bounds.width - badge.width)
                sizeBadge.frame = toView(CGRect(x: x, y: top, width: badge.width, height: badge.height))
                sizeText.frame = CGRect(x: 0, y: 3, width: badge.width, height: 15)
                sizeBadge.isHidden = false
            } else {
                sizeBadge.isHidden = true
            }

            // 放大镜
            if magnifierVisible, let mouse {
                magnifier.isHidden = false
                magnifier.update(image: snapshot.image, scale: snapshot.scale, mouse: mouse,
                                 color: currentColor, format: colorFormat, in: bounds.size)
            } else {
                magnifier.isHidden = true
            }
        }

        // 工具栏：选区确定后显示，拖动/调整时先藏起来
        if let toolbar {
            if let selection, isSelected {
                let size = toolbar.fittingSize
                let origin = CaptureGeometry.toolbarOrigin(for: selection, toolbar: size, in: geoBounds)
                toolbar.frame = toView(CGRect(origin: origin, size: size))
                toolbar.isHidden = false
            } else {
                toolbar.isHidden = true
            }
        }
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

// MARK: - 标注宿主

extension CaptureView: AnnotationHost {
    var annotationSelection: CGRect? { selection }
    var annotationSnapshot: ScreenSnapshot? { snapshot }
    func viewRect(_ rect: CGRect) -> NSRect { toView(rect) }
    var hostView: NSView { self }

    func annotationDidChange() {
        refresh()
        // 属性条出现/消失后 SwiftUI 下一轮才更新尺寸，再排一次工具栏位置
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }
}
