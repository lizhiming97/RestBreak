import Foundation

/// 截图时能被「单击直接选中」的目标
struct CaptureTarget: Equatable, Sendable {
    enum Kind: Int, Sendable {
        // rawValue 越小越优先：鼠标同时在多个目标上时选优先级高的
        case menuBarItem = 0   // 菜单栏右侧的单个图标（电量、Wi-Fi、时间…）
        case menu = 1          // 展开的菜单
        case menuBar = 2       // 整条菜单栏
        case window = 3        // 普通窗口（含贴图）
    }

    /// 屏幕内坐标（左上角原点，单位：点）
    var frame: CGRect
    var kind: Kind
}

/// 选区的 8 个控制点
enum SelectionHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

/// 截图框选用到的纯数学计算。
/// 所有坐标都是「某块屏幕内、左上角原点、单位为点」，和截图图像的方向一致。
enum CaptureGeometry {
    /// 控制点的可点范围（半径）
    static let handleRadius: CGFloat = 6
    /// 工具栏和选区、屏幕边缘的间距
    static let toolbarGap: CGFloat = 8

    /// 拖动起点、终点 → 选区（任意方向都行，限制在屏幕内）
    static func rect(from start: CGPoint, to end: CGPoint, in bounds: CGRect) -> CGRect {
        let a = clamp(start, in: bounds), b = clamp(end, in: bounds)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// 整体移动选区，碰到屏幕边缘就停
    static func moved(_ rect: CGRect, by delta: CGSize, in bounds: CGRect) -> CGRect {
        var r = rect.offsetBy(dx: delta.width, dy: delta.height)
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        return r
    }

    /// 鼠标在哪个控制点上（没有则 nil）
    static func handle(at point: CGPoint, of rect: CGRect) -> SelectionHandle? {
        SelectionHandle.allCases.first { handle in
            let p = position(of: handle, in: rect)
            return abs(point.x - p.x) <= handleRadius && abs(point.y - p.y) <= handleRadius
        }
    }

    /// 控制点的位置
    static func position(of handle: SelectionHandle, in r: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: r.minX, y: r.minY)
        case .top: CGPoint(x: r.midX, y: r.minY)
        case .topRight: CGPoint(x: r.maxX, y: r.minY)
        case .right: CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
        case .left: CGPoint(x: r.minX, y: r.midY)
        }
    }

    /// 拖动控制点调整选区：被拖的边跟着鼠标，对边不动；越过对边时自动翻转
    static func resized(_ r: CGRect, handle: SelectionHandle, to point: CGPoint, in bounds: CGRect) -> CGRect {
        let p = clamp(point, in: bounds)
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        switch handle {
        case .topLeft: minX = p.x; minY = p.y
        case .top: minY = p.y
        case .topRight: maxX = p.x; minY = p.y
        case .right: maxX = p.x
        case .bottomRight: maxX = p.x; maxY = p.y
        case .bottom: maxY = p.y
        case .bottomLeft: minX = p.x; maxY = p.y
        case .left: minX = p.x
        }
        return rect(from: CGPoint(x: minX, y: minY), to: CGPoint(x: maxX, y: maxY), in: bounds)
    }

    /// 方向键：移动 1 点；resize 为 true 时改右边/下边，最小 1×1
    static func nudged(_ r: CGRect, dx: CGFloat, dy: CGFloat, resize: Bool, in bounds: CGRect) -> CGRect {
        guard resize else { return moved(r, by: CGSize(width: dx, height: dy), in: bounds) }
        let width = min(max(r.width + dx, 1), bounds.maxX - r.minX)
        let height = min(max(r.height + dy, 1), bounds.maxY - r.minY)
        return CGRect(x: r.minX, y: r.minY, width: width, height: height)
    }

    /// 鼠标下的目标：先按种类优先级，同一种类取列表里靠前的（列表按从前到后排列）
    static func target(at point: CGPoint, in targets: [CaptureTarget]) -> CaptureTarget? {
        targets.enumerated()
            .filter { $0.element.frame.contains(point) }
            .min { ($0.element.kind.rawValue, $0.offset) < ($1.element.kind.rawValue, $1.offset) }?
            .element
    }

    /// 工具栏左上角：优先选区下方（右对齐），放不下放上方，都放不下放进选区底部；水平方向不超出屏幕
    static func toolbarOrigin(for selection: CGRect, toolbar: CGSize, in bounds: CGRect) -> CGPoint {
        let gap = toolbarGap
        func clampedX(_ x: CGFloat) -> CGFloat {
            min(max(x, bounds.minX + gap), bounds.maxX - toolbar.width - gap)
        }
        if selection.maxY + gap + toolbar.height <= bounds.maxY - gap {
            return CGPoint(x: clampedX(selection.maxX - toolbar.width), y: selection.maxY + gap)
        }
        if selection.minY - gap - toolbar.height >= bounds.minY + gap {
            return CGPoint(x: clampedX(selection.maxX - toolbar.width), y: selection.minY - gap - toolbar.height)
        }
        return CGPoint(x: clampedX(selection.maxX - gap - toolbar.width), y: selection.maxY - gap - toolbar.height)
    }

    /// 点 → 图像像素（取整到整像素，至少 1×1）
    static func pixelRect(for rect: CGRect, scale: CGFloat) -> CGRect {
        let x = (rect.minX * scale).rounded(), y = (rect.minY * scale).rounded()
        let width = max((rect.maxX * scale - x).rounded(), 1)
        let height = max((rect.maxY * scale - y).rounded(), 1)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// 选区左上角显示的尺寸文字（像素），如「1280×720」
    static func pixelSize(for rect: CGRect, scale: CGFloat) -> String {
        let p = pixelRect(for: rect, scale: scale)
        return "\(Int(p.width))×\(Int(p.height))"
    }

    /// 保存时的默认文件名：截图 2026-10-21 15.30.12.png
    static func defaultFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "截图 \(formatter.string(from: date)).png"
    }

    private static func clamp(_ p: CGPoint, in b: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, b.minX), b.maxX), y: min(max(p.y, b.minY), b.maxY))
    }
}

/// 放大镜里颜色值的显示格式（按 Shift 切换）。rawValue 存在 UserDefaults 里
enum ColorFormat: String, Sendable {
    case rgb   // 251, 252, 250
    case hex   // #FBFCFA

    func text(red: Int, green: Int, blue: Int) -> String {
        switch self {
        case .rgb: "\(red), \(green), \(blue)"
        case .hex: String(format: "#%02X%02X%02X", red, green, blue)
        }
    }

    var toggled: ColorFormat { self == .rgb ? .hex : .rgb }

    private static let key = "magnifierColorFormat"

    /// 上次用的格式，下次截图还记得
    static var current: ColorFormat {
        get { UserDefaults.standard.string(forKey: key).flatMap(ColorFormat.init(rawValue:)) ?? .rgb }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

/// 识别结果面板放在截图旁边的位置（左下角坐标，和 NSScreen 一致）：
/// 依次试右边、左边、下面、上面，选第一个完整放得下的，并和截图对齐；
/// 都放不下就放在空间最大的一侧并限制在屏幕内（可能盖住截图一部分，但不会跑出屏幕）
enum PanelPlacement {
    static let gap: CGFloat = 12
    static let margin: CGFloat = 8

    static func frame(for size: CGSize, beside shot: CGRect, in area: CGRect) -> CGRect {
        let usable = area.insetBy(dx: margin, dy: margin)
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, usable.minX), usable.maxX - size.width) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, usable.minY), usable.maxY - size.height) }
        // 左右放时顶部和截图顶部对齐；上下放时左边和截图左边对齐
        let topAligned = clampY(shot.maxY - size.height)
        let leftAligned = clampX(shot.minX)
        let candidates = [
            CGRect(x: shot.maxX + gap, y: topAligned, width: size.width, height: size.height),                // 右
            CGRect(x: shot.minX - gap - size.width, y: topAligned, width: size.width, height: size.height),   // 左
            CGRect(x: leftAligned, y: shot.minY - gap - size.height, width: size.width, height: size.height), // 下
            CGRect(x: leftAligned, y: shot.maxY + gap, width: size.width, height: size.height),               // 上
        ]
        if let fit = candidates.first(where: { usable.contains($0) }) { return fit }

        // 都放不下：选空间最大的一侧，再整体挪进屏幕
        let spaces = [usable.maxX - shot.maxX, shot.minX - usable.minX, shot.minY - usable.minY, usable.maxY - shot.maxY]
        let best = candidates[spaces.indices.max { spaces[$0] < spaces[$1] } ?? 0]
        return CGRect(x: clampX(best.minX), y: clampY(best.minY), width: size.width, height: size.height)
    }
}
