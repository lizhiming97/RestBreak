import Foundation

/// 标注工具。rawValue 会写进设置 JSON，不要随便改名。
enum AnnotationTool: String, Codable, CaseIterable, CodingKeyRepresentable, Sendable {
    case rectangle, ellipse, arrow, pen, highlighter, text, mosaic, number

    var title: String {
        switch self {
        case .rectangle: "矩形"
        case .ellipse: "椭圆"
        case .arrow: "箭头"
        case .pen: "画笔"
        case .highlighter: "荧光笔"
        case .text: "文字"
        case .mosaic: "马赛克"
        case .number: "序号"
        }
    }

    /// 工具栏图标（SF Symbols）
    var symbol: String {
        switch self {
        case .rectangle: "square"
        case .ellipse: "circle"
        case .arrow: "arrow.up.right"
        case .pen: "scribble.variable"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .mosaic: "checkerboard.rectangle"
        case .number: "1.circle"
        }
    }

    /// 拖两个点画出来的工具（矩形类）：按住 ⇧ 变成正方形 / 正圆
    var isBoxShape: Bool { self == .rectangle || self == .ellipse || self == .mosaic }
}

/// 标注颜色（属性条上的 7 个色块）
enum AnnotationColor: String, Codable, CaseIterable, Sendable {
    case red, orange, yellow, green, blue, black, white

    /// sRGB 数值 0～1
    var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .red: (0.96, 0.23, 0.21)
        case .orange: (1.0, 0.58, 0.0)
        case .yellow: (1.0, 0.84, 0.04)
        case .green: (0.2, 0.78, 0.35)
        case .blue: (0.24, 0.48, 0.97)
        case .black: (0.11, 0.11, 0.12)
        case .white: (1, 1, 1)
        }
    }

    var title: String {
        switch self {
        case .red: "红"
        case .orange: "橙"
        case .yellow: "黄"
        case .green: "绿"
        case .blue: "蓝"
        case .black: "黑"
        case .white: "白"
        }
    }
}

/// 粗细三档
enum StrokeSize: Int, Codable, CaseIterable, Sendable {
    case small, medium, large
}

/// 马赛克样式
enum MosaicStyle: String, Codable, CaseIterable, Sendable {
    case pixelate   // 像素块
    case blur       // 模糊

    var title: String { self == .pixelate ? "像素块" : "模糊" }
}

/// 一个工具的样式（每个工具各记各的）
struct ToolStyle: Codable, Equatable, Sendable {
    var color: AnnotationColor
    var size: StrokeSize
    var mosaic: MosaicStyle

    static let `default` = ToolStyle(color: .red, size: .medium, mosaic: .pixelate)
}

/// 一个标注。坐标是「屏幕内、左上角原点、单位为点」，和 CaptureGeometry 一致。
struct Annotation: Identifiable, Equatable, Sendable {
    var id = UUID()
    var tool: AnnotationTool
    /// 矩形/椭圆/箭头/马赛克：[起点, 终点]；画笔/荧光笔：经过的点；文字：[左上角]；序号：[圆心]
    var points: [CGPoint]
    var style: ToolStyle
    var text = ""
    /// 文字占的大小（由界面量好后填入，用来命中和画选中框）
    var textSize: CGSize = .zero
    var number = 0

    // MARK: 尺寸

    private var sizeIndex: Int { style.size.rawValue }

    /// 线宽（矩形、椭圆、箭头、画笔、荧光笔）
    var lineWidth: CGFloat {
        tool == .highlighter ? [12, 18, 26][sizeIndex] : [2, 4, 7][sizeIndex]
    }

    /// 文字字号
    var fontSize: CGFloat { [14, 20, 28][sizeIndex] }

    /// 序号圆的直径
    var numberDiameter: CGFloat { [20, 26, 34][sizeIndex] }

    /// 马赛克强度：像素块边长或模糊半径（点）
    var mosaicAmount: CGFloat {
        style.mosaic == .pixelate ? [6, 10, 16][sizeIndex] : [4, 8, 14][sizeIndex]
    }

    // MARK: 几何

    /// 两点围成的矩形（矩形、椭圆、马赛克）
    var rect: CGRect {
        guard let a = points.first, let b = points.last else { return .zero }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// 包围框（选中时的虚线框、命中判断）
    var bounds: CGRect {
        switch tool {
        case .rectangle, .ellipse, .mosaic:
            return rect
        case .arrow, .pen, .highlighter:
            let xs = points.map(\.x), ys = points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .zero }
            let pad = lineWidth / 2 + (tool == .arrow ? lineWidth * 2 : 0)
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -pad, dy: -pad)
        case .text:
            return CGRect(origin: points.first ?? .zero, size: textSize)
        case .number:
            let c = points.first ?? .zero, r = numberDiameter / 2
            return CGRect(x: c.x - r, y: c.y - r, width: numberDiameter, height: numberDiameter)
        }
    }

    /// 点击是否落在这个标注上。线条按到线的距离；空心框只认边；马赛克、文字、序号认整块。
    func hitTest(_ p: CGPoint, tolerance: CGFloat = 5) -> Bool {
        let reach = tolerance + lineWidth / 2
        switch tool {
        case .rectangle:
            let r = rect
            return r.insetBy(dx: -reach, dy: -reach).contains(p) && !r.insetBy(dx: reach, dy: reach).contains(p)
        case .ellipse:
            let r = rect
            let a = r.width / 2, b = r.height / 2
            guard a > 0, b > 0 else { return Self.distance(from: p, toSegment: r.origin, CGPoint(x: r.maxX, y: r.maxY)) <= reach }
            let nx = (p.x - r.midX) / a, ny = (p.y - r.midY) / b
            let d = (nx * nx + ny * ny).squareRoot()
            return abs(d - 1) * min(a, b) <= reach
        case .arrow, .pen, .highlighter:
            if points.count == 1 { return hypot(p.x - points[0].x, p.y - points[0].y) <= reach }
            return zip(points, points.dropFirst()).contains { Self.distance(from: p, toSegment: $0, $1) <= reach }
        case .mosaic, .text, .number:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        }
    }

    func moved(by delta: CGSize) -> Annotation {
        var copy = self
        copy.points = points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) }
        return copy
    }

    /// 按住 ⇧ 时的终点：矩形类变正方形，线条吸附到 45° 的倍数
    static func constrained(from start: CGPoint, to end: CGPoint, tool: AnnotationTool) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        if tool.isBoxShape {
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        }
        let length = hypot(dx, dy)
        let step = Double.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: start.x + length * cos(angle), y: start.y + length * sin(angle))
    }

    /// 点到线段的距离
    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

/// 一次截图里的所有标注，带撤销 / 重做（每一步存一份完整快照，标注数量少，简单可靠）
struct AnnotationDocument: Equatable, Sendable {
    private(set) var items: [Annotation] = []
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    /// 拖动移动开始前的快照：拖动过程中多次修改，松手时只记一步撤销
    private var transientBase: [Annotation]?

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var isEmpty: Bool { items.isEmpty }

    mutating func add(_ annotation: Annotation) {
        change { $0.append(annotation) }
    }

    mutating func remove(_ id: UUID) {
        change { $0.removeAll { $0.id == id } }
    }

    mutating func update(_ id: UUID, _ body: (inout Annotation) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change { body(&$0[index]) }
    }

    /// 开始一段连续修改（拖动移动）
    mutating func beginTransient() {
        transientBase = items
    }

    mutating func updateTransient(_ body: (inout [Annotation]) -> Void) {
        body(&items)
    }

    /// 结束连续修改：有变化才记一步撤销
    mutating func commitTransient() {
        guard let base = transientBase else { return }
        transientBase = nil
        guard base != items else { return }
        undoStack.append(base)
        redoStack.removeAll()
    }

    mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(items)
        items = previous
    }

    mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(items)
        items = next
    }

    /// 点击位置上最上面的标注
    func item(at point: CGPoint) -> Annotation? {
        items.last { $0.hitTest(point) }
    }

    /// 下一个序号：现有最大编号 + 1（删除不重排）
    func nextNumber() -> Int {
        (items.filter { $0.tool == .number }.map(\.number).max() ?? 0) + 1
    }

    private mutating func change(_ body: (inout [Annotation]) -> Void) {
        let before = items
        body(&items)
        guard before != items else { return }
        undoStack.append(before)
        redoStack.removeAll()
    }
}
