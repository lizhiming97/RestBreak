import AppKit

/// 截图标注的宿主（框选界面）需要提供的东西
@MainActor
protocol AnnotationHost: AnyObject {
    /// 当前选区（屏幕内左上角坐标）
    var annotationSelection: CGRect? { get }
    var annotationSnapshot: ScreenSnapshot? { get }
    /// 屏幕内左上角坐标 → 视图坐标
    func viewRect(_ rect: CGRect) -> NSRect
    var hostView: NSView { get }
    /// 标注或工具状态变了：宿主刷新工具栏位置、控制点、光标
    func annotationDidChange()
}

/// 管理一次截图里的标注：选工具、画草稿、选中/移动/删除、文字输入、撤销重做、标注图层。
/// 坐标一律是屏幕内左上角坐标（和 CaptureGeometry 一致）。
@MainActor
final class AnnotationEditor: NSObject, NSTextFieldDelegate {
    weak var host: AnnotationHost?
    /// 改了某个工具的样式（写回设置，下次截图还记得）
    var onStyleChange: ((AnnotationTool, ToolStyle) -> Void)?

    let toolbar = AnnotationToolbarModel()
    private(set) var document = AnnotationDocument()
    private(set) var tool: AnnotationTool?
    private var styles: [AnnotationTool: ToolStyle] = [:]
    private var selectedID: UUID?
    /// 正在画、还没松手的标注
    private var draft: Annotation?
    private var dragStart: CGPoint?
    /// 正在拖动已有标注：拖动开始时的位置
    private var moveOrigin: CGPoint?
    private let cache = MosaicCache()

    /// 画着标注和底图的图层，只盖住选区
    let annotationLayer = CALayer()
    /// 选中标注的虚线框（不进导出）
    let outlineLayer = CAShapeLayer()
    /// 马赛克范围框：正在拖的马赛克，以及选了马赛克工具时已有的马赛克（不进导出）。
    /// 白色背景上打码几乎看不出来，有框才知道自己打在了哪里
    let mosaicOutlineLayer = CAShapeLayer()

    /// 正在输入的文字框，以及它对应的标注（新建时还不在 document 里）
    private var textField: NSTextField?
    private var editingText: Annotation?

    var isEditingText: Bool { textField != nil }
    var hasAnnotations: Bool { !document.isEmpty }

    override init() {
        super.init()
        annotationLayer.delegate = self
        annotationLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        annotationLayer.isHidden = true
        outlineLayer.fillColor = nil
        outlineLayer.strokeColor = NSColor(red: 0.24, green: 0.48, blue: 0.97, alpha: 1).cgColor
        outlineLayer.lineWidth = 1
        outlineLayer.lineDashPattern = [4, 3]
        outlineLayer.actions = ["path": NSNull()]
        mosaicOutlineLayer.fillColor = NSColor(red: 0.24, green: 0.48, blue: 0.97, alpha: 0.08).cgColor
        mosaicOutlineLayer.strokeColor = NSColor(red: 0.24, green: 0.48, blue: 0.97, alpha: 1).cgColor
        mosaicOutlineLayer.lineWidth = 1.5
        mosaicOutlineLayer.lineDashPattern = [5, 3]
        mosaicOutlineLayer.actions = ["path": NSNull()]

        toolbar.onSelectTool = { [weak self] tool in self?.select(tool: tool) }
        toolbar.onChangeStyle = { [weak self] style in self?.changeStyle(style) }
        toolbar.onUndo = { [weak self] in self?.undo() }
        toolbar.onRedo = { [weak self] in self?.redo() }
    }

    /// 新的一次截图：清空标注，载入每个工具记住的样式
    func reset(styles: [AnnotationTool: ToolStyle], scale: CGFloat) {
        endTextEditing(commit: false)
        self.styles = styles
        document = AnnotationDocument()
        tool = nil
        selectedID = nil
        draft = nil
        annotationLayer.contentsScale = scale
        syncToolbar()
        redraw()
    }

    /// 放弃所有标注（清除选区时）
    func discardAll() {
        endTextEditing(commit: false)
        document = AnnotationDocument()
        selectedID = nil
        draft = nil
        syncToolbar()
        redraw()
    }

    private func style(for tool: AnnotationTool) -> ToolStyle { styles[tool] ?? .default }

    // MARK: - 工具和样式

    func select(tool newTool: AnnotationTool?) {
        endTextEditing(commit: true)
        tool = newTool
        selectedID = nil
        syncToolbar()
        redraw()
    }

    private func changeStyle(_ style: ToolStyle) {
        if let id = selectedID, let annotation = document.items.first(where: { $0.id == id }) {
            document.update(id) { item in
                item.style = style
                if item.tool == .text { item.textSize = AnnotationRenderer.textSize(item.text, fontSize: item.fontSize) }
            }
            remember(style, for: annotation.tool)
        } else if var editing = editingText, let field = textField {
            editing.style = style
            editingText = editing
            applyTextStyle(to: field, annotation: editing)
            remember(style, for: .text)
        } else if let tool {
            remember(style, for: tool)
        }
        syncToolbar()
        redraw()
    }

    private func remember(_ style: ToolStyle, for tool: AnnotationTool) {
        styles[tool] = style
        onStyleChange?(tool, style)
    }

    func undo() {
        endTextEditing(commit: true)
        document.undo()
        dropStaleSelection()
        syncToolbar()
        redraw()
    }

    func redo() {
        endTextEditing(commit: true)
        document.redo()
        dropStaleSelection()
        syncToolbar()
        redraw()
    }

    /// 删除选中的标注；没选中返回 false
    func deleteSelected() -> Bool {
        guard let id = selectedID else { return false }
        document.remove(id)
        selectedID = nil
        syncToolbar()
        redraw()
        return true
    }

    /// Esc 的前几步：结束文字 → 取消选中标注 → 取消工具。都没有可做的返回 false
    func handleEscape() -> Bool {
        if isEditingText { endTextEditing(commit: true); return true }
        if selectedID != nil { selectedID = nil; syncToolbar(); redraw(); return true }
        if tool != nil { select(tool: nil); return true }
        return false
    }

    private func dropStaleSelection() {
        if let id = selectedID, !document.items.contains(where: { $0.id == id }) { selectedID = nil }
    }

    // MARK: - 鼠标（返回 true 表示已处理，宿主不再按调整选区处理）

    /// 选了工具时，点击都由标注处理
    var wantsMouse: Bool { tool != nil }

    func mouseDown(at p: CGPoint, clickCount: Int) -> Bool {
        guard let tool, let selection = host?.annotationSelection else { return false }
        if isEditingText {
            endTextEditing(commit: true)
            return true   // 这一下只用来结束输入
        }
        // 点在已有标注上：选中它，准备拖动；双击文字重新编辑
        if let hit = document.item(at: p) {
            if clickCount >= 2, hit.tool == .text {
                beginTextEditing(existing: hit)
                return true
            }
            selectedID = hit.id
            moveOrigin = p
            document.beginTransient()
            syncToolbar()
            redraw()
            return true
        }
        selectedID = nil
        guard selection.contains(p) else {
            syncToolbar()
            redraw()
            return true   // 选区外不画
        }
        let style = style(for: tool)
        switch tool {
        case .text:
            beginTextEditing(new: Annotation(tool: .text, points: [p], style: style))
        case .number:
            document.add(Annotation(tool: .number, points: [p], style: style, number: document.nextNumber()))
        default:
            dragStart = p
            draft = Annotation(tool: tool, points: [p, p], style: style)
        }
        syncToolbar()
        redraw()
        return true
    }

    func mouseDragged(to p: CGPoint, shift: Bool) -> Bool {
        if let origin = moveOrigin, let id = selectedID {
            let delta = CGSize(width: p.x - origin.x, height: p.y - origin.y)
            moveOrigin = p
            document.updateTransient { items in
                if let i = items.firstIndex(where: { $0.id == id }) { items[i] = items[i].moved(by: delta) }
            }
            redraw()
            return true
        }
        guard var draft, let start = dragStart else { return tool != nil }
        switch draft.tool {
        case .pen:
            if let last = draft.points.last, hypot(p.x - last.x, p.y - last.y) >= 1 { draft.points.append(p) }
        case .highlighter:
            if shift {
                draft.points = [start, Annotation.constrained(from: start, to: p, tool: .highlighter)]
            } else if let last = draft.points.last, hypot(p.x - last.x, p.y - last.y) >= 1 {
                // 从「⇧ 直线」松开 ⇧ 时，接着从当前位置画
                if draft.points.count == 2, draft.points[0] == start, draft.points[1] != p { draft.points.removeLast() }
                draft.points.append(p)
            }
        default:
            draft.points = [start, shift ? Annotation.constrained(from: start, to: p, tool: draft.tool) : p]
        }
        self.draft = draft
        redraw()
        return true
    }

    func mouseUp() -> Bool {
        if moveOrigin != nil {
            moveOrigin = nil
            document.commitTransient()
            syncToolbar()
            redraw()
            return true
        }
        guard let draft else { return tool != nil }
        self.draft = nil
        dragStart = nil
        // 太小的（基本是误点）不要
        let b = draft.tool == .pen || draft.tool == .highlighter ? draft.bounds : draft.rect
        let tooSmall: Bool = switch draft.tool {
        case .pen, .highlighter: draft.points.count < 2 && b.width < 2
        case .arrow: hypot(draft.points[1].x - draft.points[0].x, draft.points[1].y - draft.points[0].y) < 4
        default: b.width < 3 || b.height < 3
        }
        if !tooSmall { document.add(draft) }
        syncToolbar()
        redraw()
        return true
    }

    /// 选了工具时鼠标处的光标
    func cursor(at p: CGPoint) -> NSCursor? {
        guard let tool, let selection = host?.annotationSelection else { return nil }
        if document.item(at: p) != nil { return .openHand }
        guard selection.contains(p) else { return .arrow }
        return tool == .text ? .iBeam : .crosshair   // 画图用系统的细十字
    }

    // MARK: - 文字输入

    private func beginTextEditing(new annotation: Annotation) {
        startField(for: annotation)
    }

    private func beginTextEditing(existing annotation: Annotation) {
        selectedID = nil
        startField(for: annotation)
        redraw()
    }

    private func startField(for annotation: Annotation) {
        guard let host else { return }
        editingText = annotation
        let field = NSTextField(string: annotation.text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = false
        field.cell?.wraps = false
        field.cell?.isScrollable = false
        field.delegate = self
        applyTextStyle(to: field, annotation: annotation)
        host.hostView.addSubview(field)
        textField = field
        layoutField()
        host.hostView.window?.makeFirstResponder(field)
        // 光标放到文字末尾
        field.currentEditor()?.selectedRange = NSRange(location: (annotation.text as NSString).length, length: 0)
        syncToolbar()
        redraw()   // 编辑中的那条文字先不画，避免和输入框重影
    }

    private func applyTextStyle(to field: NSTextField, annotation: Annotation) {
        field.font = AnnotationRenderer.font(size: annotation.fontSize)
        field.textColor = AnnotationRenderer.nsColor(annotation.style.color)
        layoutField()
    }

    /// 输入框跟着文字变大
    private func layoutField() {
        guard let field = textField, var editing = editingText, let host, let origin = editing.points.first else { return }
        editing.text = field.stringValue
        let size = AnnotationRenderer.textSize(field.stringValue, fontSize: editing.fontSize)
        editingText = editing
        let rect = CGRect(origin: origin, size: CGSize(width: size.width + 12, height: size.height))
        // NSTextField 自己有约 2pt 的左边距，往左挪一点对齐导出位置
        field.frame = host.viewRect(rect).offsetBy(dx: AnnotationRenderer.textPadding - 2, dy: 0)
        outlineLayer.path = CGPath(rect: host.viewRect(CGRect(origin: origin, size: size)).insetBy(dx: -2, dy: -2),
                                   transform: nil)
    }

    func controlTextDidChange(_ obj: Notification) {
        layoutField()
    }

    /// Enter 换行，Esc 结束
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            textView.insertNewlineIgnoringFieldEditor(nil)
            layoutField()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endTextEditing(commit: true)
            return true
        default:
            return false
        }
    }

    /// 结束文字输入：有字就保存（新建或更新），没字就丢掉
    func endTextEditing(commit: Bool) {
        guard let field = textField, var editing = editingText else { return }
        textField = nil
        editingText = nil
        editing.text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : field.stringValue
        editing.textSize = AnnotationRenderer.textSize(editing.text, fontSize: editing.fontSize)
        field.delegate = nil
        field.removeFromSuperview()
        if let host { host.hostView.window?.makeFirstResponder(host.hostView) }

        let exists = document.items.contains { $0.id == editing.id }
        if commit, !editing.text.isEmpty {
            if exists {
                document.update(editing.id) { $0.text = editing.text; $0.textSize = editing.textSize; $0.style = editing.style }
            } else {
                document.add(editing)
            }
        } else if commit, exists {
            document.remove(editing.id)   // 把已有文字删光了 = 删除这条
        }
        syncToolbar()
        redraw()
    }

    // MARK: - 绘制

    /// 当前要显示的标注：文档里的 + 草稿；正在编辑的文字由输入框显示
    private var visibleAnnotations: [Annotation] {
        var items = document.items
        if let editing = editingText { items.removeAll { $0.id == editing.id } }
        if let draft { items.append(draft) }
        return items
    }

    /// 选区或标注变了：重画标注图层、更新虚线框
    func redraw() {
        guard let host, let selection = host.annotationSelection, host.annotationSnapshot != nil,
              !(document.isEmpty && draft == nil && editingText == nil)
        else {
            annotationLayer.isHidden = true
            annotationLayer.contents = nil
            outlineLayer.path = nil
            mosaicOutlineLayer.path = nil
            host?.annotationDidChange()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        annotationLayer.isHidden = false
        annotationLayer.frame = host.viewRect(selection)
        annotationLayer.setNeedsDisplay()
        if isEditingText {
            layoutField()
        } else if let id = selectedID, let selected = document.items.first(where: { $0.id == id }) {
            outlineLayer.path = CGPath(rect: host.viewRect(selected.bounds).insetBy(dx: -3, dy: -3), transform: nil)
        } else {
            outlineLayer.path = nil
        }
        mosaicOutlineLayer.path = mosaicOutlinePath(in: host, clippedTo: selection)
        CATransaction.commit()
        host.annotationDidChange()
    }

    /// 马赛克范围框：正在拖的那块；选了马赛克工具时再加上已有的马赛克
    private func mosaicOutlinePath(in host: AnnotationHost, clippedTo selection: CGRect) -> CGPath? {
        var rects: [CGRect] = []
        if let draft, draft.tool == .mosaic { rects.append(draft.rect) }
        if tool == .mosaic { rects += document.items.filter { $0.tool == .mosaic }.map(\.rect) }
        let visible = rects.map { $0.intersection(selection) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        guard !visible.isEmpty else { return nil }
        let path = CGMutablePath()
        for rect in visible { path.addRect(host.viewRect(rect)) }
        return path
    }

    /// 导出选区 + 标注（先结束文字输入）
    func export() -> CGImage? {
        endTextEditing(commit: true)
        guard let host, let selection = host.annotationSelection, let snapshot = host.annotationSnapshot else { return nil }
        return AnnotationRenderer.export(selection: selection, source: snapshot.image, scale: snapshot.scale,
                                         annotations: document.items, cache: cache)
    }

    private func syncToolbar() {
        toolbar.tool = tool
        toolbar.canUndo = document.canUndo
        toolbar.canRedo = document.canRedo
        if let id = selectedID, let selected = document.items.first(where: { $0.id == id }) {
            toolbar.propertyTool = selected.tool
            toolbar.style = selected.style
        } else if let editing = editingText {
            toolbar.propertyTool = .text
            toolbar.style = editing.style
        } else if let tool {
            toolbar.propertyTool = tool
            toolbar.style = style(for: tool)
        } else {
            toolbar.propertyTool = nil
        }
    }
}

extension AnnotationEditor: CALayerDelegate {
    /// 标注图层的内容：选区底图 + 所有标注（和导出用同一个函数）
    nonisolated func draw(_ layer: CALayer, in ctx: CGContext) {
        // 图层总是在主线程上绘制；context 只在这次调用里用
        nonisolated(unsafe) let context = ctx
        MainActor.assumeIsolated {
            guard let host, let selection = host.annotationSelection, let snapshot = host.annotationSnapshot else { return }
            AnnotationRenderer.drawComposite(in: context, selection: selection, source: snapshot.image,
                                             scale: snapshot.scale, annotations: visibleAnnotations, cache: cache)
        }
    }
}
