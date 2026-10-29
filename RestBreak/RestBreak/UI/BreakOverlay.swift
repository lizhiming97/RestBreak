import AppKit
import SwiftUI

/// 遮罩上要显示的内容
struct BreakOverlayContent {
    let title: String
    let suggestion: String
    let startedAt: Date
    let endsAt: Date
    let postponeMinutes: Int
    let canPostpone: Bool
    let canSkip: Bool
    var background: OverlayBackground = .frosted
}

/// 管理全屏休息遮罩：每块屏幕一个窗口，淡入淡出
@MainActor
final class BreakOverlayController: NSObject {
    /// 正在显示的内容和按钮回调；插拔显示器时要用它们重建窗口
    private struct Presentation {
        let content: BreakOverlayContent
        let onPostpone: () -> Void
        let onSkip: () -> Void
    }

    private var windows: [BreakOverlayWindow] = []
    private var presentation: Presentation?
    /// 休息开始时设置窗口开着（App 临时是普通 App），休息结束后要切回去
    private var restoreRegularPolicy = false

    override init() {
        super.init()
        // 显示器接上、拔掉、改分辨率时，系统会发这个通知
        NotificationCenter.default.addObserver(self, selector: #selector(screensDidChange),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
    }

    func show(_ content: BreakOverlayContent, onPostpone: @escaping () -> Void, onSkip: @escaping () -> Void) {
        presentation = Presentation(content: content, onPostpone: onPostpone, onSkip: onSkip)
        // 设置窗口开着时 App 是普通 App，窗口进不了别的 App 的全屏空间（休息画面就盖不住全屏）。
        // 休息期间先切回菜单栏 App；切换是异步的，所以下一轮再建窗口（2026-10-26 用户发现全屏时休息失效）
        if NSApp.activationPolicy() == .regular {
            restoreRegularPolicy = true
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.async { [weak self] in self?.buildWindows(fadeIn: true) }
        } else {
            buildWindows(fadeIn: true)
        }
    }

    /// 休息中屏幕变了：按新的屏幕重新铺一遍遮罩（倒计时按结束时间算，不会重置）
    @objc private func screensDidChange(_ notification: Notification) {
        guard presentation != nil else { return }
        buildWindows(fadeIn: false)
    }

    private func buildWindows(fadeIn: Bool) {
        guard let presentation else { return }
        closeWindowsImmediately()

        // 主屏排第一个，让它成为接收键盘的窗口
        let screens = NSScreen.screens.sorted { a, _ in a == NSScreen.main }
        for screen in screens {
            let window = BreakOverlayWindow(screen: screen)

            // 前景：SwiftUI 画的内容（背景 + 深色蒙层 + 文字 + 圆环 + 按钮）
            let hosting = NSHostingView(rootView: BreakOverlayView(content: presentation.content,
                                                                   onPostpone: presentation.onPostpone,
                                                                   onSkip: presentation.onSkip))
            hosting.autoresizingMask = [.width, .height]

            if case .frosted = presentation.content.background {
                // 毛玻璃：系统模糊窗口后面的内容，SwiftUI 内容叠在上面
                let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.frame.size))
                blur.material = .fullScreenUI
                blur.blendingMode = .behindWindow
                blur.state = .active
                blur.autoresizingMask = [.width, .height]
                hosting.frame = blur.bounds
                blur.addSubview(hosting)
                window.contentView = blur
            } else {
                // 风景、照片：背景由 SwiftUI 画满整个窗口
                hosting.frame = NSRect(origin: .zero, size: screen.frame.size)
                window.contentView = hosting
            }
            window.alphaValue = fadeIn ? 0 : 1
            window.orderFrontRegardless()
            windows.append(window)
        }

        // 激活自己，按钮才能直接点到
        NSApp.activate()
        windows.first?.makeKey()
        // 休息期间锁住切换：不能 ⌘Tab 切 App、不能划动或 Mission Control 切桌面空间
        // （不锁的话，划到别的全屏空间就把休息画面甩掉了）。不点推迟/跳过就只能等休息结束
        NSApp.presentationOptions = [.hideDock, .disableProcessSwitching, .disableHideApplication]

        if fadeIn {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.6
                for window in windows { window.animator().alphaValue = 1 }
            }
        }
    }

    func hide() {
        presentation = nil
        NSApp.presentationOptions = []
        if restoreRegularPolicy {
            restoreRegularPolicy = false
            // 设置窗口还开着才切回普通 App（休息中关掉了就保持菜单栏 App）
            if NSApp.windows.contains(where: { $0.title == "星期五 · 设置" && $0.isVisible }) {
                NSApp.setActivationPolicy(.regular)
            }
        }
        let closing = windows
        windows = []
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.5
            for window in closing { window.animator().alphaValue = 0 }
        }
        // 等淡出动画结束再真正关掉窗口
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(550))
            for window in closing { window.orderOut(nil) }
        }
    }

    private func closeWindowsImmediately() {
        for window in windows { window.orderOut(nil) }
        windows = []
    }
}

/// 无边框、盖住一切（包括全屏 App）的窗口
final class BreakOverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless],
                   backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
    }

    // 无边框窗口默认不能成为 key window，按钮会点不动，这里放开
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - 遮罩内容（SwiftUI）

struct BreakOverlayView: View {
    let content: BreakOverlayContent
    let onPostpone: () -> Void
    let onSkip: () -> Void

    var body: some View {
        ZStack {
            OverlayBackgroundView(background: content.background,
                                  duration: content.endsAt.timeIntervalSince(content.startedAt))

            VStack(spacing: 36) {
                Text(content.title)
                    .font(.system(size: 17, weight: .medium))
                    .tracking(6)
                    .foregroundStyle(.white.opacity(0.6))

                Text(content.suggestion)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 720)

                // 每秒刷新一次圆环
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    CountdownRing(remaining: content.endsAt.timeIntervalSince(timeline.date),
                                  total: content.endsAt.timeIntervalSince(content.startedAt))
                }

                HStack(spacing: 14) {
                    if content.canPostpone {
                        Button("推迟 \(content.postponeMinutes) 分钟", action: onPostpone)
                    }
                    if content.canSkip {
                        Button("跳过", action: onSkip)
                    }
                }
                .buttonStyle(OverlayButtonStyle())
            }
            .padding(48)
        }
        .ignoresSafeArea()
    }
}

/// 遮罩背景 + 让文字看得清的深色蒙层
struct OverlayBackgroundView: View {
    let background: OverlayBackground
    /// 休息时长，照片慢慢放大的动画按它来
    var duration: TimeInterval = 20

    var body: some View {
        switch background {
        case .frosted:
            Color.black.opacity(0.55)
        case .scenery(let scenery):
            ZStack {
                FlowingGradient(scenery: scenery)
                Color.black.opacity(0.22)
            }
        case .photo(let image):
            ZStack {
                SlowZoomImage(image: image, duration: duration)
                // 上下稍暗、中间更暗，保证白字在任何照片上都清楚
                LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.5), .black.opacity(0.35)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
    }
}

/// 缓慢流动的渐变：渐变方向来回摆动，由系统动画驱动，很省电
struct FlowingGradient: View {
    let scenery: Scenery
    @State private var shifted = false

    var body: some View {
        LinearGradient(colors: scenery.colors.map { Color(red: $0.r, green: $0.g, blue: $0.b) },
                       startPoint: shifted ? UnitPoint(x: 0.3, y: 0) : UnitPoint(x: 0.7, y: 0),
                       endPoint: shifted ? UnitPoint(x: 0.7, y: 1) : UnitPoint(x: 0.2, y: 1))
            .ignoresSafeArea()
            .onAppear {
                withAnimation(.easeInOut(duration: 10).repeatForever(autoreverses: true)) { shifted = true }
            }
    }
}

/// 铺满屏幕的照片，休息期间缓慢放大一点点（「肯·伯恩斯」效果）
private struct SlowZoomImage: View {
    let image: NSImage
    let duration: TimeInterval
    @State private var zoomed = false

    var body: some View {
        GeometryReader { geometry in
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect(zoomed ? 1.08 : 1.0)
                .clipped()
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.linear(duration: max(duration, 10))) { zoomed = true }
        }
    }
}

/// 圆环倒计时
private struct CountdownRing: View {
    let remaining: TimeInterval
    let total: TimeInterval

    private var progress: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, remaining / total))
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.15), lineWidth: 6)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: progress)
            Text(TimeText.clock(remaining))
                .font(.system(size: 40, weight: .light, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .frame(width: 180, height: 180)
    }
}

/// 半透明胶囊按钮
private struct OverlayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(.white.opacity(configuration.isPressed ? 0.25 : 0.12), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.2), lineWidth: 1))
            .contentShape(Capsule())
    }
}
