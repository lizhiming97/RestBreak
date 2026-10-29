import AppKit
import SwiftUI

/// 文字面板的状态：识别 → （可选）翻译
@MainActor
final class TextResultModel: ObservableObject {
    enum Recognition: Equatable { case running, done, failed }
    enum Translation: Equatable { case none, running, done(String), failed(TranslateError) }

    @Published var recognition = Recognition.running
    /// 识别出的原文（用户可以直接改）
    @Published var text = ""
    @Published var translation = Translation.none
    /// 翻译成哪种语言："en" 或 "zh"
    @Published var target = "en"

    var onClose: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    private var translateTask: Task<Void, Never>?

    func recognize(_ image: CGImage, thenTranslate: Bool) {
        Task {
            do {
                text = try await TextRecognizer.recognize(image)
                recognition = .done
                target = TencentTranslate.defaultTarget(for: text)
                if thenTranslate, !text.isEmpty { translate() }
            } catch {
                recognition = .failed
            }
        }
    }

    func translate() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        translateTask?.cancel()
        translation = .running
        let text = text, target = target
        translateTask = Task {
            do {
                let result = try await TencentTranslator.translate(text, target: target)
                guard !Task.isCancelled else { return }
                translation = .done(result)
            } catch {
                guard !Task.isCancelled else { return }
                translation = .failed(error as? TranslateError ?? .network)
            }
        }
    }

    /// 点译文标题切换方向，切完重新翻译
    func toggleDirection() {
        target = target == "en" ? "zh" : "en"
        translate()
    }
}

/// 识别结果浮窗：无边框、置顶、可拖动，Esc 关闭
final class TextResultPanel: NSPanel {
    let model = TextResultModel()
    /// 截图在屏幕上的位置：面板放在它旁边
    private let anchor: NSRect
    /// 正在由代码摆放位置（区分用户自己拖动）
    private var isPlacing = false
    /// 用户拖过面板后就不再自动摆放
    private var userMoved = false

    init(near anchor: NSRect) {
        self.anchor = anchor
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        let hosting = NSHostingController(rootView: TextResultView(model: model))
        hosting.sizingOptions = .preferredContentSize   // 窗口大小跟着内容变
        contentViewController = hosting
        place()
        // 识别完、翻译完内容变高时，按新大小重新摆一次，保证不出屏幕
        NotificationCenter.default.addObserver(self, selector: #selector(didResize),
                                               name: NSWindow.didResizeNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(didMove),
                                               name: NSWindow.didMoveNotification, object: self)
    }

    @objc private func didResize(_ notification: Notification) {
        if !userMoved && !isPlacing { place() }
    }

    @objc private func didMove(_ notification: Notification) {
        if !isPlacing { userMoved = true }
    }

    override var canBecomeKey: Bool { true }

    /// Esc 关闭
    override func cancelOperation(_ sender: Any?) {
        model.onClose()
    }

    /// 放在截图旁边：右 → 左 → 下 → 上，不出屏幕、尽量不挡截图（规则见 PanelPlacement）
    private func place() {
        layoutIfNeeded()
        let size = contentViewController?.view.fittingSize ?? frame.size
        let screen = NSScreen.screens.max { $0.frame.intersection(anchor).area < $1.frame.intersection(anchor).area }
            ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        isPlacing = true
        setFrame(PanelPlacement.frame(for: size, beside: anchor, in: area), display: true)
        isPlacing = false
    }
}

// MARK: - 面板内容

private enum PanelColors {
    static let text = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let secondary = Color(red: 0.54, green: 0.54, blue: 0.56)
    static let divider = Color.black.opacity(0.08)
    static let accent = Color(red: 0x3D / 255, green: 0x7B / 255, blue: 0xF7 / 255)
}

struct TextResultView: View {
    @ObservedObject var model: TextResultModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(PanelColors.divider).frame(height: 1)
            original
            if model.translation != .none {
                Rectangle().fill(PanelColors.divider).frame(height: 1)
                translation
            }
            Rectangle().fill(PanelColors.divider).frame(height: 1)
            footer
        }
        .frame(width: 440)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
        .environment(\.colorScheme, .light)
        .animation(.snappy(duration: 0.2), value: model.translation)
    }

    private var header: some View {
        HStack {
            Image(systemName: "text.viewfinder")
                .foregroundStyle(PanelColors.accent)
            Text("识别结果")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PanelColors.text)
            Spacer()
            Button(action: model.onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PanelColors.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("关闭 (Esc)")
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    @ViewBuilder
    private var original: some View {
        switch model.recognition {
        case .running:
            placeholder(progress: true, "正在识别文字…")
        case .failed:
            placeholder(progress: false, "识别失败，请重试")
        case .done where model.text.isEmpty:
            placeholder(progress: false, "没有识别到文字")
        case .done:
            TextEditor(text: $model.text)
                .font(.system(size: 13))
                .foregroundStyle(PanelColors.text)
                .scrollContentBackground(.hidden)
                .lineSpacing(3)
                .frame(minHeight: 70, idealHeight: idealHeight(for: model.text), maxHeight: 240)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var translation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: model.toggleDirection) {
                HStack(spacing: 4) {
                    Text(model.target == "en" ? "译文 · 中 → 英" : "译文 · 外 → 中")
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(PanelColors.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("切换翻译方向")

            switch model.translation {
            case .running:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("翻译中…").font(.system(size: 13)).foregroundStyle(PanelColors.secondary)
                }
            case .done(let result):
                ScrollView {
                    Text(result)
                        .font(.system(size: 13))
                        .foregroundStyle(PanelColors.text)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 20, idealHeight: idealHeight(for: result) - 10, maxHeight: 200)
                .fixedSize(horizontal: false, vertical: true)
            case .failed(let error):
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text(error.message).font(.system(size: 12)).foregroundStyle(.orange)
                    Spacer()
                    if error == .missingKey || error == .invalidKey || error == .notActivated {
                        Button("去设置", action: model.onOpenSettings).buttonStyle(PanelButtonStyle())
                    } else {
                        Button("重试", action: model.translate).buttonStyle(PanelButtonStyle())
                    }
                }
            case .none:
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.97, green: 0.97, blue: 0.98))
    }

    private var footer: some View {
        let stats = OCRLayout.stats(model.text)
        let translated: String? = if case .done(let result) = model.translation { result } else { nil }
        return HStack(spacing: 8) {
            Text("\(stats.lines) 行 · \(stats.characters) 字")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(PanelColors.secondary)
            Spacer()
            Button("翻译", action: model.translate)
                .buttonStyle(PanelButtonStyle())
                .disabled(model.text.isEmpty || model.translation == .running)
            Button("复制原文") { copy(model.text) }
                .buttonStyle(PanelButtonStyle(prominent: translated == nil))
                .disabled(model.text.isEmpty)
            if let translated {
                Button("复制译文") { copy(translated) }
                    .buttonStyle(PanelButtonStyle(prominent: true))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    private func placeholder(progress: Bool, _ text: String) -> some View {
        HStack(spacing: 8) {
            if progress { ProgressView().controlSize(.small) }
            Text(text).font(.system(size: 13)).foregroundStyle(PanelColors.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 70)
    }

    /// 按行数估计合适的高度（再由 min / max 限制）
    private func idealHeight(for text: String) -> CGFloat {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { total, line in
            total + max(1, Int(ceil(Double(line.count) / 30)))   // 每行大约 30 个汉字宽
        }
        return CGFloat(lines) * 20 + 16
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Toast.show("已复制", at: NSEvent.mouseLocation)
    }
}

/// 面板按钮：浅灰底；主要按钮蓝底白字
private struct PanelButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(prominent ? .white : PanelColors.text)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(prominent ? PanelColors.accent : Color.black.opacity(0.06)))
            .opacity(configuration.isPressed ? 0.7 : (isEnabled ? 1 : 0.4))
    }
}

private extension CGRect {
    /// 面积（不相交时为 0）
    var area: CGFloat { isNull ? 0 : width * height }
}
