import AppKit
import UniformTypeIdentifiers

/// 截图和贴图的流程：按快捷键 → 截屏 → 框选 → 复制 / 保存 / 贴到桌面；也负责管理所有贴图
@MainActor
final class ScreenshotController {
    private let overlay = CaptureOverlayController()
    private var pins: [PinWindow] = []
    private(set) var isCapturing = false
    /// 截图前的前台 App，截完把焦点还给它
    private var previousApp: NSRunningApplication?
    /// 截图过程中打开的保存框（休息开始时要一起关掉）
    private weak var savePanel: NSSavePanel?
    /// 这次截图贴出来的贴图用多少透明度
    private var pinOpacity = 1.0

    /// 识别结果面板（同一时间只开一个）
    private var textPanel: TextResultPanel?
    /// 打开设置窗口的「截图」页（翻译没设置密钥时用）
    var onOpenSettings: (() -> Void)?
    /// 框选界面已经显示（菜单开着时截图：截到菜单后再把菜单收起来）
    var onOverlayShown: (() -> Void)?

    /// 标注时改了某个工具的颜色/粗细（写回设置）
    var onAnnotationStyleChange: ((AnnotationTool, ToolStyle) -> Void)?

    /// 第一次截图时用系统授权弹窗；之后再没权限就弹我们自己的说明
    private static let requestedKey = "didRequestScreenCapture"

    init() {
        overlay.onAction = { [weak self] action, view in self?.handle(action, from: view) }
        overlay.onScreensChanged = { [weak self] in self?.cancel() }
        overlay.onAnnotationStyleChange = { [weak self] tool, style in self?.onAnnotationStyleChange?(tool, style) }
        // 不预热 ScreenCaptureKit：平时不截图就不连录屏服务，第一次截图时再取显示器列表
    }

    // MARK: - 截图

    func startCapture(settings: AppSettings) {
        guard !isCapturing else { return }
        guard ScreenCapturer.hasPermission else {
            // 每次都向系统申请一次：系统设置里没有这个 App（或者签名变了、旧授权对不上）时会重新登记；
            // 已经拒绝过的不会再弹系统窗口，就弹我们自己的说明
            let askedBefore = UserDefaults.standard.bool(forKey: Self.requestedKey)
            UserDefaults.standard.set(true, forKey: Self.requestedKey)
            ScreenCapturer.requestPermission()
            if askedBefore { showPermissionAlert() }
            return
        }

        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        pinOpacity = settings.pinOpacity
        isCapturing = true
        let showMagnifier = settings.showMagnifier
        let annotationStyles = settings.annotationStyles
        Task {
            do {
                // 窗口平时不预建（省内存），截图时先建好再截屏（建窗口只要几毫秒）
                overlay.prepare()
                let snapshots = try await ScreenCapturer.captureAllScreens()
                // 截屏的这一点时间里可能已经被取消了（比如休息开始）
                guard isCapturing else { return }
                guard !snapshots.isEmpty else { throw CocoaError(.featureUnsupported) }
                overlay.show(snapshots, showMagnifier: showMagnifier, annotationStyles: annotationStyles)
                onOverlayShown?()
                onOverlayShown = nil
            } catch {
                guard isCapturing else { return }
                isCapturing = false
                NSSound.beep()
                Toast.show("截图失败", symbol: "exclamationmark.circle.fill", at: NSEvent.mouseLocation)
            }
        }
    }

    /// 取消正在进行的截图（休息开始、显示器变化时）
    func cancel() {
        guard isCapturing else { return }
        // 先结束截图再关保存框，保存框的「取消」回调就不会把选区又显示出来
        let panel = savePanel
        finish()
        panel?.cancel(nil)
    }

    private func handle(_ action: CaptureAction, from view: CaptureView) {
        guard action != .cancel else { finish(); return }
        guard let image = view.selectedImage(), let rect = view.selectionInScreen else { return }
        switch action {
        case .copy:
            ImageExport.copy(image, pointSize: rect.size)
            finish()
            Toast.show("已复制", at: NSPoint(x: rect.midX, y: rect.midY))
        case .pin:
            finish()
            let screen = view.window?.screen ?? NSScreen.main
            pin(image, frame: screen.map { PinFrame.fitted(rect, on: $0) } ?? rect)
        case .save:
            overlay.temporarilyHide()
            savePanel = ImageExport.save(image, pointSize: rect.size) { [weak self] result in
                guard let self, self.isCapturing else { return }
                switch result {
                case .saved: self.finish()
                case .cancelled, .failed: self.overlay.restore(focusing: view)
                }
            }
        case .extractText, .translate:
            finish()
            // 截图贴在原位置保留着，面板放在它旁边，方便对照
            let screen = view.window?.screen ?? NSScreen.main
            let pinFrame = screen.map { PinFrame.fitted(rect, on: $0) } ?? rect
            pin(image, frame: pinFrame)
            showText(of: image, near: pinFrame, translate: action == .translate)
        case .cancel:
            break
        }
    }

    private func finish() {
        overlay.hide()
        isCapturing = false
        previousApp?.activate()
        previousApp = nil
    }

    // MARK: - 贴图

    /// 把剪贴板里的图片（或文字卡片）贴在鼠标位置
    func pinClipboard(settings: AppSettings) {
        let pasteboard = NSPasteboard.general
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2

        let content: (image: CGImage, size: CGSize)?
        if let image = NSImage(pasteboard: pasteboard),
           let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            content = (cgImage, image.size)
        } else if let text = pasteboard.string(forType: .string) {
            content = TextCard.render(text, scale: scale)
        } else {
            content = nil
        }
        guard let content, let screen else {
            NSSound.beep()
            return
        }
        let frame = NSRect(x: mouse.x - content.size.width / 2, y: mouse.y - content.size.height / 2,
                           width: content.size.width, height: content.size.height)
        pinOpacity = settings.pinOpacity
        pin(content.image, frame: PinFrame.fitted(frame, on: screen))
    }

    private func pin(_ image: CGImage, frame: NSRect) {
        let window = PinWindow(image: image, frame: frame, opacity: pinOpacity)
        window.onClose = { [weak self] closed in self?.pins.removeAll { $0 === closed } }
        window.onCloseAll = { [weak self] in self?.closeAllPins() }
        window.onExtractText = { [weak self] pin in
            self?.showText(of: pin.image, near: pin.frame, translate: false)
        }
        window.orderFrontRegardless()
        pins.append(window)
    }

    // MARK: - 提取文字 / 翻译

    /// 弹出识别结果面板：先识别文字，translate 为 true 时识别完直接翻译
    private func showText(of image: CGImage, near anchor: NSRect, translate: Bool) {
        textPanel?.orderOut(nil)
        let panel = TextResultPanel(near: anchor)
        panel.model.onClose = { [weak self, weak panel] in
            panel?.orderOut(nil)
            if self?.textPanel === panel { self?.textPanel = nil }
        }
        panel.model.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        panel.model.recognize(image, thenTranslate: translate)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        textPanel = panel
    }

    func closeAllPins() {
        for pin in pins { pin.orderOut(nil) }
        pins.removeAll()
    }

    // MARK: - 权限

    private func showPermissionAlert() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "需要录屏权限"
        alert.informativeText = "请在「系统设置 › 隐私与安全性 › 录屏与系统录音」里打开「星期五」。打开后需要重新打开星期五才能生效。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "重新打开星期五")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            ScreenCapturer.openPrivacySettings()
        case .alertSecondButtonReturn:
            relaunch()
        default:
            break
        }
    }

    /// 重新打开自己：先启动一个新的实例，再退出当前的
    private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}

/// 复制、保存图片。尺寸按「点」记录，Retina 截图粘贴到别处时大小正确、依然清晰
@MainActor
enum ImageExport {
    enum SaveResult { case saved, cancelled, failed }

    static func copy(_ image: CGImage, pointSize: CGSize) {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = pointSize
        let nsImage = NSImage(size: pointSize)
        nsImage.addRepresentation(rep)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([nsImage])
    }

    /// 弹出系统保存框，默认文件名「截图 2026-10-21 15.30.12.png」；系统会记住上次的目录
    @discardableResult
    static func save(_ image: CGImage, pointSize: CGSize,
                     completion: @escaping (SaveResult) -> Void) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = CaptureGeometry.defaultFileName()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        NSApp.activate()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return completion(.cancelled) }
            let rep = NSBitmapImageRep(cgImage: image)
            rep.size = pointSize
            do {
                guard let data = rep.representation(using: .png, properties: [:]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try data.write(to: url, options: .atomic)
                completion(.saved)
            } catch {
                NSAlert(error: error).runModal()
                completion(.failed)
            }
        }
        return panel
    }
}
