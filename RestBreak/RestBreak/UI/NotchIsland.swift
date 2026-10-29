import AppKit
import SwiftUI

/// 从刘海「流」出来的管家推送（像 iPhone 的灵动岛）。所有提醒类的弹出都走这里，一次一条，其余排队。
/// 出场三步：刘海 → 收起态（刘海左右各露出一点：左图标、右几个字）→ 展开（来意 + 标题 + 原因 + 按钮）。
/// 设计（2026-10-24，参考 GitHub 上 DynamicNotch / Atoll / CodeIsland 后重做，效果图 `设计/提醒样式/E-管家推送-新版.png`）：
/// - 纯黑底和刘海融为一体，肩部是大而顺的内凹弧；
/// - 展开后第一行和刘海同高：左边是来意（图标 + 两三个字），右边是时间，不留空黑带；
/// - 按钮深色、平分整行：次按钮深灰白字，主按钮放最右，用淡强调色底 + 强调色字（不用亮色实心）；
/// - 强提醒用强调色细描边 + 光晕，不压暗屏幕。
struct IslandItem {
    struct Action {
        let title: String
        var primary = false
        let run: () -> Void
    }

    /// 同一个 key 只显示一次（排队时去重、按 key 收起）
    let key: String
    var intent: IslandIntent
    var symbol: String
    /// 来意文字（第一行左边），不填就用 intent 的默认说法
    var kind: String?
    /// 收起态右边的几个字
    var compact: String
    var title: String
    /// 为什么是现在
    var message: String
    /// 第一行右边的时间
    var trailing: String?
    /// 强提醒：细描边 + 光晕，点了才收
    var firm = false
    /// 展开后多少秒自动收起；nil = 点了才收
    var autoDismiss: TimeInterval? = 15
    var actions: [Action]
    var onTimeout: (() -> Void)?
    /// 真正在灵动岛上显示的那一刻
    var onShown: (() -> Void)?
    /// 因为一直忙（休息、开会、全屏）等太久，没显示就丢掉了
    var onDropped: (() -> Void)?

    /// 到点的普通提醒用茶绿，琥珀只留给强提醒
    var tint: Color { intent == .due && !firm ? IslandTheme.tea : intent.tint }
}

/// 管家为什么现在来找你。决定颜色和默认的来意文字
enum IslandIntent {
    case due        // 到点了：你交代过的事
    case urgent     // 快来不及了
    case forgot     // 你可能忘了
    case pause      // 你该停一停了
    case info       // 值得让你知道

    init(_ intent: PushIntent) {
        switch intent {
        case .due: self = .due
        case .urgent: self = .urgent
        case .forgot: self = .forgot
        case .pause: self = .pause
        case .info: self = .info
        }
    }

    var tint: Color {
        switch self {
        case .due: IslandTheme.amber
        case .urgent: IslandTheme.sky
        case .forgot: IslandTheme.tea
        case .pause: IslandTheme.rose
        case .info: IslandTheme.amber
        }
    }

    var label: String {
        switch self {
        case .due: "到点了"
        case .urgent: "快开始了"
        case .forgot: "可能忘了"
        case .pause: "该停一停"
        case .info: "告诉你一声"
        }
    }
}

enum IslandTheme {
    static let ink = Color.black
    static let textPrimary = Color(red: 0.96, green: 0.96, blue: 0.97)
    static let textSecondary = Color(red: 0.58, green: 0.58, blue: 0.61)
    static let neutralButton = Color(white: 0.17)
    static let tea = Color(red: 0.40, green: 0.84, blue: 0.76)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.30)
    static let sky = Color(red: 0.45, green: 0.70, blue: 1.0)
    static let rose = Color(red: 1.0, green: 0.50, blue: 0.52)

    static let expandedWidth: CGFloat = 400
    /// 收起态时刘海左右各多出的宽度
    static let compactSide: CGFloat = 64
    static let shoulder: CGFloat = 16

    /// 按标题里的关键词挑图标（提醒数据里没有分类）
    static func symbol(for title: String) -> String {
        let table: [([String], String)] = [
            (["水"], "drop.fill"),
            (["药", "胶囊", "抗生素", "维生素", "保健品"], "pills.fill"),
            (["买", "超市", "快递", "取件"], "cart.fill"),
            (["生日", "纪念日", "礼物"], "gift.fill"),
            (["房租", "还款", "信用卡", "缴费", "交费", "续费"], "creditcard.fill"),
            (["会", "站会", "评审"], "calendar"),
            (["电话", "回电"], "phone.fill"),
            (["吃饭", "午饭", "晚饭"], "fork.knife"),
            (["睡", "休息"], "moon.fill"),
            (["运动", "走", "拉伸"], "figure.walk"),
        ]
        return table.first { keys, _ in keys.contains { title.contains($0) } }?.1 ?? "bell.fill"
    }
}

/// 刘海延伸出来的形状：肩部用三次曲线做大而顺的内凹弧，和屏幕顶边相切；底部大圆角
struct NotchShape: Shape {
    var shoulder: CGFloat = IslandTheme.shoulder
    var bottom: CGFloat = 24

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, bottom) }
        set { shoulder = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let s = min(shoulder, r.width / 4)
        let b = max(0, min(bottom, (r.height - s) / 2, (r.width - 2 * s) / 2))
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addCurve(to: CGPoint(x: r.minX + s, y: r.minY + s),
                   control1: CGPoint(x: r.minX + s * 0.75, y: r.minY), control2: CGPoint(x: r.minX + s, y: r.minY + s * 0.25))
        p.addLine(to: CGPoint(x: r.minX + s, y: r.maxY - b))
        p.addCurve(to: CGPoint(x: r.minX + s + b, y: r.maxY),
                   control1: CGPoint(x: r.minX + s, y: r.maxY - b * 0.45), control2: CGPoint(x: r.minX + s + b * 0.45, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - s - b, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.maxX - s, y: r.maxY - b),
                   control1: CGPoint(x: r.maxX - s - b * 0.45, y: r.maxY), control2: CGPoint(x: r.maxX - s, y: r.maxY - b * 0.45))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.minY + s))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.minY),
                   control1: CGPoint(x: r.maxX - s, y: r.minY + s * 0.25), control2: CGPoint(x: r.maxX - s * 0.75, y: r.minY))
        p.closeSubpath()
        return p
    }
}

@MainActor
final class IslandModel: ObservableObject {
    enum Stage { case notch, compact, expanded }

    @Published var item: IslandItem?
    @Published var stage: Stage = .notch
    @Published var hovering = false
    /// 展开内容的实际高度（量出来的，用来让黑色形状平滑长高）
    @Published var expandedHeight: CGFloat = 150
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct IslandView: View {
    @ObservedObject var model: IslandModel
    /// 刘海大小（没有刘海的屏幕上是一小段菜单栏高的胶囊）
    let notch: CGSize

    private var shoulder: CGFloat { IslandTheme.shoulder }

    var body: some View {
        let stage = model.item == nil ? .notch : model.stage
        let size: CGSize = switch stage {
        case .notch: CGSize(width: notch.width + 2 * 10, height: notch.height)
        case .compact: CGSize(width: notch.width + 2 * (IslandTheme.compactSide + 10), height: notch.height)
        case .expanded: CGSize(width: IslandTheme.expandedWidth, height: model.expandedHeight)
        }
        let item = model.item
        let tint = item?.tint ?? .clear
        let firm = item?.firm == true && stage == .expanded
        // 收起态肩部小一点、底角圆一点，像刘海本身被拉长
        let shoulder = stage == .expanded ? self.shoulder : 10

        VStack(spacing: 0) {
            // 黑色形状严格按当前阶段的大小画；内容用 overlay 叠上去，不影响大小（否则 400 宽的展开内容会把收起态撑宽）
            NotchShape(shoulder: shoulder, bottom: stage == .expanded ? 24 : 12)
                .fill(IslandTheme.ink)
                .overlay {
                    if firm { NotchShape(shoulder: shoulder, bottom: 24).stroke(tint.opacity(0.55), lineWidth: 1) }
                }
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .top) {
                    if let item {
                        ZStack(alignment: .top) {
                            compactContent(item)
                                .frame(width: notch.width + 2 * (IslandTheme.compactSide + 10))
                                .opacity(stage == .compact ? 1 : 0)
                            expandedContent(item)
                                .fixedSize(horizontal: false, vertical: true)
                                .background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
                                .opacity(stage == .expanded ? 1 : 0)
                        }
                        .frame(width: size.width, height: size.height, alignment: .top)
                        .clipped()
                    }
                }
            .shadow(color: shadow(stage, item: item), radius: firm ? 26 : 18, y: 8)
            .onHover { inside in
                model.hovering = inside
                if inside && model.stage == .compact { model.stage = .expanded }   // 收起态时鼠标移上去就展开
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(HeightKey.self) { if $0 > 0 { model.expandedHeight = $0 } }
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: model.stage)
        .environment(\.colorScheme, .dark)
    }

    private func shadow(_ stage: IslandModel.Stage, item: IslandItem?) -> Color {
        guard stage == .expanded, let item else { return .clear }
        return item.firm ? item.tint.opacity(0.28) : .black.opacity(0.35)
    }

    /// 收起态：左边图标，右边几个字，分别在刘海两侧
    private func compactContent(_ item: IslandItem) -> some View {
        HStack(spacing: 0) {
            Image(systemName: item.symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(item.tint)
                .frame(width: IslandTheme.compactSide)
            Spacer(minLength: notch.width)
            Text(item.compact)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(item.tint)
                .lineLimit(1)
                .frame(width: IslandTheme.compactSide)
        }
        .padding(.horizontal, 10)
        .frame(height: notch.height)
    }

    /// 展开：第一行和刘海同高（来意 / 时间），然后标题、原因、按钮
    private func expandedContent(_ item: IslandItem) -> some View {
        let tint = item.tint
        // 次按钮在左，主按钮在最右
        let actions = item.actions.filter { !$0.primary } + item.actions.filter(\.primary)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: item.symbol).font(.system(size: 12, weight: .bold))
                Text(item.kind ?? item.intent.label).font(.system(size: 12, weight: .medium))
                Spacer(minLength: notch.width)
                if let trailing = item.trailing {
                    Text(trailing)
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(IslandTheme.textSecondary)
                }
            }
            .foregroundStyle(tint)
            .frame(height: notch.height)
            Text(item.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(IslandTheme.textPrimary)
                .lineLimit(2)
                .padding(.top, 10)
            Text(item.message)
                .font(.system(size: 13))
                .foregroundStyle(IslandTheme.textSecondary)
                .lineSpacing(3)
                .lineLimit(3)
                .padding(.top, 4)
            if !actions.isEmpty {
                HStack(spacing: 10) {
                    ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                        Button(action: action.run) {
                            Text(action.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(action.primary ? tint : IslandTheme.textPrimary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 34)
                                .background(action.primary ? tint.opacity(0.18) : IslandTheme.neutralButton, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 16)
            }
        }
        .padding(.horizontal, shoulder + 22)
        .padding(.bottom, 18)
        .frame(width: IslandTheme.expandedWidth, alignment: .leading)
    }
}

/// 岛所在的透明窗口：贴着屏幕顶边居中，透明部分点击会穿透到下面
final class IslandPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // 比菜单栏高一层，才能盖住刘海两侧；低于休息遮罩和截图框选
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { false }
}

/// 管理岛的显示、排队、自动收起
@MainActor
final class NotchIsland {
    private let model = IslandModel()
    private var panel: IslandPanel?
    private var queue: [IslandItem] = []
    private var timer: Task<Void, Never>?
    /// 窗口比岛大一圈，留给阴影和光晕
    private static let panelSize = NSSize(width: IslandTheme.expandedWidth + 80, height: 260)
    /// 收起态停留多久再展开
    private static let compactDuration: TimeInterval = 1.6

    func show(_ item: IslandItem) {
        if model.item?.key == item.key || queue.contains(where: { $0.key == item.key }) { return }
        if model.item != nil {
            queue.append(item)
            return
        }
        present(item)
    }

    /// 收起某一条（用户点了按钮、强提醒过期、提醒被删）
    func dismiss(key: String) {
        queue.removeAll { $0.key == key }
        guard model.item?.key == key else { return }
        collapse()
    }

    /// 删掉某条提醒时，把它在排队和正在显示的都收掉
    func dismiss(prefix: String) {
        queue.removeAll { $0.key.hasPrefix(prefix) }
        if model.item?.key.hasPrefix(prefix) == true { collapse() }
    }

    private func present(_ item: IslandItem) {
        item.onShown?()
        let (screen, notch) = Self.notchScreen()
        let panel = self.panel ?? IslandPanel(size: Self.panelSize)
        if self.panel == nil {
            panel.contentView = NSHostingView(rootView: IslandView(model: model, notch: notch))
            self.panel = panel
        } else if let hosting = panel.contentView as? NSHostingView<IslandView> {
            hosting.rootView = IslandView(model: model, notch: notch)
        }
        let frame = screen.frame
        panel.setFrame(NSRect(x: frame.midX - Self.panelSize.width / 2, y: frame.maxY - Self.panelSize.height,
                              width: Self.panelSize.width, height: Self.panelSize.height), display: false)
        model.item = item
        model.stage = .notch
        panel.orderFrontRegardless()
        // 刘海 → 收起态 → 展开，每一步都有动画
        DispatchQueue.main.async { [model] in model.stage = .compact }
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.compactDuration))
            guard let self, !Task.isCancelled, self.model.item?.key == item.key else { return }
            self.model.stage = .expanded
            guard let duration = item.autoDismiss else { return }
            var elapsed: TimeInterval = 0
            while elapsed < duration {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                if !self.model.hovering { elapsed += 0.2 }   // 鼠标停在上面时不计时
            }
            guard self.model.item?.key == item.key else { return }
            item.onTimeout?()
            self.collapse()
        }
    }

    /// 展开 → 收起态 → 刘海 → 隐藏；有排队的接着显示下一条
    private func collapse() {
        timer?.cancel()
        let key = model.item?.key
        model.stage = .compact
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.model.item?.key == key else { return }
            self.model.stage = .notch
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard self.model.item?.key == key else { return }
                self.model.item = nil
                if self.queue.isEmpty {
                    // 用完就释放窗口，平时不占内存
                    self.panel?.orderOut(nil)
                    self.panel?.contentView = nil
                    self.panel = nil
                } else {
                    self.present(self.queue.removeFirst())
                }
            }
        }
    }

    /// 有刘海的屏幕优先（内建屏）；都没有就用主屏，在顶部中间显示一段胶囊
    static func notchScreen() -> (NSScreen, CGSize) {
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            let left = screen.auxiliaryTopLeftArea?.width ?? 0
            let right = screen.auxiliaryTopRightArea?.width ?? 0
            let width = left > 0 && right > 0 ? screen.frame.width - left - right : 180
            return (screen, CGSize(width: width, height: screen.safeAreaInsets.top))
        }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let menuBar = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        return (screen, CGSize(width: 180, height: menuBar))
    }
}
