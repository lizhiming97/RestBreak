import AppKit
import SwiftUI

/// 工具栏的状态和回调。CaptureView 改它，SwiftUI 工具栏跟着刷新。
@MainActor
final class AnnotationToolbarModel: ObservableObject {
    /// 当前选中的工具（nil = 没选工具，可以调整选区）
    @Published var tool: AnnotationTool?
    /// 属性条显示哪个工具的属性：选了工具时是这个工具，选中某个标注时是那个标注的工具；nil 时不显示属性条
    @Published var propertyTool: AnnotationTool?
    /// 属性条上显示的样式
    @Published var style = ToolStyle.default
    @Published var canUndo = false
    @Published var canRedo = false

    var onSelectTool: (AnnotationTool?) -> Void = { _ in }
    var onChangeStyle: (ToolStyle) -> Void = { _ in }
    var onUndo: () -> Void = {}
    var onRedo: () -> Void = {}
    var onAction: (CaptureAction) -> Void = { _ in }
}

/// 截图工具栏：实心圆角条，跟随系统浅色/深色模式；SF Symbols 统一 17pt medium；下方按需出现属性条。
struct AnnotationToolbar: View {
    @ObservedObject var model: AnnotationToolbarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            mainBar
            if let tool = model.propertyTool {
                PropertyBar(tool: tool, style: model.style, onChange: model.onChangeStyle)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.snappy(duration: 0.18), value: model.propertyTool)
        // SF Symbols 有按系统语言变化的版本（如中文系统下 textformat 会变成「格式」两个字），统一用英文版图标
        .environment(\.locale, Locale(identifier: "en_US"))
        .padding(8)   // 给阴影留位置
        .fixedSize()
    }

    private var mainBar: some View {
        HStack(spacing: 4) {
            ForEach(Array(AnnotationTool.allCases.enumerated()), id: \.element) { index, tool in
                ToolbarIconButton(symbol: tool.symbol, help: "\(tool.title) (\(index + 1))",
                                  isSelected: model.tool == tool) {
                    model.onSelectTool(model.tool == tool ? nil : tool)
                }
            }
            ToolbarSeparator()
            ToolbarIconButton(symbol: "arrow.uturn.backward", help: "撤销 (⌘Z)", isEnabled: model.canUndo,
                              action: model.onUndo)
            ToolbarIconButton(symbol: "arrow.uturn.forward", help: "重做 (⌘⇧Z)", isEnabled: model.canRedo,
                              action: model.onRedo)
            ToolbarSeparator()
            ToolbarIconButton(symbol: "text.viewfinder", help: "提取文字") { model.onAction(.extractText) }
            ToolbarIconButton(symbol: "translate", help: "翻译") { model.onAction(.translate) }
            ToolbarSeparator()
            ToolbarIconButton(symbol: "pin", help: "贴到桌面 (Space)") { model.onAction(.pin) }
            ToolbarIconButton(symbol: "square.and.arrow.down", help: "保存 (⌘S)") { model.onAction(.save) }
            ToolbarIconButton(symbol: "xmark", help: "取消 (Esc)") { model.onAction(.cancel) }
            ToolbarIconButton(symbol: "checkmark", help: "复制 (Enter)", tint: ToolbarColors.accent) {
                model.onAction(.copy)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .toolbarBackground()
    }
}

/// 工具栏配色：跟随系统浅色 / 深色模式。
/// 不用半透明玻璃：截图时背景五花八门，半透明的条和图标容易和背景混在一起。
enum ToolbarColors {
    static let accent = Color(red: 0x3D / 255, green: 0x7B / 255, blue: 0xF7 / 255)

    static func bar(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.17, green: 0.17, blue: 0.18) : Color.white
    }

    /// 选中工具的底色：浅色模式淡蓝灰，深色模式稍亮的灰（参考用户给的截图工具）
    static func selected(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.16) : Color(red: 0.90, green: 0.93, blue: 0.98)
    }

    static func icon(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.95) : Color(red: 0.11, green: 0.11, blue: 0.12)
    }

    static func hover(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.07)
    }

    static func separator(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.12)
    }

    static func border(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.12)
    }
}

/// 36×36 的图标按钮：细线图标；悬停浅灰底；选中淡蓝底 + 蓝色图标；不可用时变淡
private struct ToolbarIconButton: View {
    let symbol: String
    let help: String
    var isSelected = false
    var isEnabled = true
    var tint: Color?
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(isSelected ? ToolbarColors.accent : (tint ?? ToolbarColors.icon(scheme)))
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? ToolbarColors.selected(scheme)
                              : (isHovered && isEnabled ? ToolbarColors.hover(scheme) : .clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.3)
        .toolbarTip(help)
        .accessibilityLabel(help)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

private struct ToolbarSeparator: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Rectangle()
            .fill(ToolbarColors.separator(scheme))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 4)
    }
}

/// 属性条：粗细（或字号）+ 颜色；马赛克是「像素块 / 模糊」+ 强度
private struct PropertyBar: View {
    let tool: AnnotationTool
    let style: ToolStyle
    let onChange: (ToolStyle) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(StrokeSize.allCases, id: \.self) { size in
                SizeButton(tool: tool, size: size, isSelected: style.size == size) {
                    var new = style
                    new.size = size
                    onChange(new)
                }
            }
            ToolbarSeparator()
            if tool == .mosaic {
                ForEach(MosaicStyle.allCases, id: \.self) { mosaic in
                    TextChip(title: mosaic.title, isSelected: style.mosaic == mosaic) {
                        var new = style
                        new.mosaic = mosaic
                        onChange(new)
                    }
                }
            } else {
                ForEach(AnnotationColor.allCases, id: \.self) { color in
                    ColorDot(color: color, isSelected: style.color == color) {
                        var new = style
                        new.color = color
                        onChange(new)
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .toolbarBackground()
    }
}

/// 粗细档：三个由小到大的圆点；文字工具显示三个大小不同的「A」
private struct SizeButton: View {
    let tool: AnnotationTool
    let size: StrokeSize
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Group {
                if tool == .text {
                    Text("A").font(.system(size: [11, 14, 17][size.rawValue], weight: .semibold))
                } else {
                    Circle().frame(width: [4, 7, 11][size.rawValue], height: [4, 7, 11][size.rawValue])
                }
            }
            .foregroundStyle(isSelected ? ToolbarColors.accent : ToolbarColors.icon(scheme))
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? ToolbarColors.selected(scheme) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .toolbarTip(tool == .text ? ["小号字", "中号字", "大号字"][size.rawValue] : ["细", "中", "粗"][size.rawValue])
    }
}

/// 颜色圆点：选中时外面一圈蓝色
private struct ColorDot: View {
    let color: AnnotationColor
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(AnnotationRenderer.nsColor(color)))
                // 白点在浅色条上、黑点在深色条上都要看得见
                .overlay(Circle().strokeBorder(ToolbarColors.border(scheme).opacity(2.5), lineWidth: 0.5))
                .frame(width: 16, height: 16)
                .padding(3)
                .overlay(Circle().strokeBorder(isSelected ? ToolbarColors.accent : .clear, lineWidth: 2))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .toolbarTip(color.title)
        .accessibilityLabel("\(color.title)色")
    }
}

private struct TextChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? ToolbarColors.accent : ToolbarColors.icon(scheme))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? ToolbarColors.selected(scheme) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 实心圆角条的背景（跟随浅色 / 深色模式），加细边和阴影，压在任何截图内容上都分得清
private struct ToolbarBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(ToolbarColors.bar(scheme), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ToolbarColors.border(scheme), lineWidth: 0.5))
            .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.22), radius: 10, y: 3)
    }
}

private extension View {
    func toolbarBackground() -> some View {
        modifier(ToolbarBackground())
    }

    /// 鼠标停在按钮上时显示中文提示（见 ToolbarTip）
    func toolbarTip(_ text: String) -> some View {
        onHover { inside in
            if inside { ToolbarTip.show(text) } else { ToolbarTip.hide() }
        }
        .simultaneousGesture(TapGesture().onEnded { ToolbarTip.hide() })
    }
}

/// 工具栏按钮的中文提示气泡。
/// 不用系统的 .help：系统提示窗口的层级比全屏框选窗口低，会被盖在下面看不到。
/// 这里自己开一个更高层级的小窗口，停留约 0.1 秒后淡入显示在鼠标上方。
@MainActor
enum ToolbarTip {
    private static var panel: NSPanel?
    private static var pending: Task<Void, Never>?

    static func show(_ text: String) {
        pending?.cancel()
        // 已经有提示在显示（在按钮之间移动）时立即切换，否则稍等一下，避免划过时闪烁
        let delay: Duration = panel?.isVisible == true ? .zero : .milliseconds(100)
        pending = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            present(text)
        }
    }

    static func hide() {
        pending?.cancel()
        pending = nil
        panel?.orderOut(nil)
    }

    private static func present(_ text: String) {
        let hosting = NSHostingView(rootView: TipBubble(text: text))
        let size = hosting.fittingSize
        let mouse = NSEvent.mouseLocation
        var frame = NSRect(x: mouse.x - size.width / 2, y: mouse.y + 18, width: size.width, height: size.height)
        if let area = NSScreen.screens.first(where: { $0.frame.contains(mouse) })?.frame {
            frame.origin.x = min(max(frame.minX, area.minX + 4), area.maxX - size.width - 4)
            if frame.maxY > area.maxY - 4 { frame.origin.y = mouse.y - 26 - size.height }   // 上面放不下就放下面
        }
        let panel = self.panel ?? makePanel()
        let wasVisible = self.panel?.isVisible == true
        panel.contentView = hosting
        panel.setFrame(frame, display: true)
        if !wasVisible {
            // 第一次出现时 0.12 秒淡入；在按钮之间切换时直接换文字，不闪
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        } else {
            panel.orderFrontRegardless()
        }
        self.panel = panel
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        // 比框选窗口（.screenSaver）高一层
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        return panel
    }
}

/// 深色圆角提示气泡（浅色、深色模式下都用深色，和参考图一致）
private struct TipBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color(white: 0.18).opacity(0.94), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .padding(4)
            .fixedSize()
    }
}
