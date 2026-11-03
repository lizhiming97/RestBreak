// CC BY-NC 4.0. Friday integration around Mos-derived smoothing.
import AppKit
import CoreVideo

/// 所有输入状态在主线程修改。DisplayLink 回调只排一个待处理帧，避免阻塞时积压滚动。
public final class ScrollEngine {
    public var onStatus: ((String) -> Void)?
    public private(set) var running = false
    public private(set) var configuration = ScrollConfiguration()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var displayLink: CVDisplayLink?
    private var healthTimer: Timer?
    private let smoother = MosSmoother()
    private let frameLock = NSLock()
    private var frameQueued = false
    private var generation: UInt64 = 0
    private var template: CGEvent?
    private var targetPID: pid_t = 0
    private var lastInputTime: TimeInterval = 0
    private var lastFrameTime: TimeInterval = 0
    private var targetBundleID: String?
    private var pixelsY = PixelAccumulator()
    private var pixelsX = PixelAccumulator()
    public init() {}

    public func update(_ settings: ScrollConfiguration) {
        configuration = settings
        configuration.normalize()
        cancelMotion()
        if !configuration.enabled { stop() }
    }

    @discardableResult
    public func start() -> Bool {
        precondition(Thread.isMainThread)
        guard configuration.enabled else { return false }
        if running { return true }
        guard AXIsProcessTrusted() else { onStatus?("请先授权辅助功能，然后点击重试。"); return false }
        let events: [CGEventType] = [.scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved, .flagsChanged]
        let mask = events.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap,
                                         options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let engine = Unmanaged<ScrollEngine>.fromOpaque(context).takeUnretainedValue()
            return engine.receive(type: type, event: event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            onStatus?("无法接管滚轮，请检查辅助功能权限后重试。")
            return false
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        var link: CVDisplayLink?
        if CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link {
            displayLink = link
            CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, context in
                guard let context else { return kCVReturnSuccess }
                Unmanaged<ScrollEngine>.fromOpaque(context).takeUnretainedValue().queueFrame()
                return kCVReturnSuccess
            }, Unmanaged.passUnretained(self).toOpaque())
        }
        if displayLink == nil && (configuration.smoothVertical || configuration.smoothHorizontal) {
            stop()
            onStatus?("无法创建平滑滚动时钟，已恢复原生滚动。")
            return false
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        running = CGEvent.tapIsEnabled(tap: tap)
        guard running else { stop(); onStatus?("滚轮接管未成功，请检查权限。"); return false }
        // 低频权限/超时检查；只在功能开启时存在，不盲目重启被系统禁用的 tap。
        healthTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !AXIsProcessTrusted() || self.tap.map({ !CGEvent.tapIsEnabled(tap: $0) }) != false {
                self.stop()
                self.onStatus?("权限已变化或输入监听已暂停，原生滚动可用。点击重试恢复。")
            }
        }
        onStatus?("已开启 · 普通鼠标滚轮增强")
        return true
    }

    public func stop() {
        precondition(Thread.isMainThread)
        cancelMotion()
        healthTimer?.invalidate(); healthTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil; tap = nil; displayLink = nil
        running = false
    }

    public func cancelMotion() {
        if let displayLink, CVDisplayLinkIsRunning(displayLink) { CVDisplayLinkStop(displayLink) }
        frameLock.lock(); generation &+= 1; frameLock.unlock()
        smoother.reset()
        template = nil; targetPID = 0; targetBundleID = nil
        lastFrameTime = 0
        pixelsY = PixelAccumulator(); pixelsX = PixelAccumulator()
    }

    private func receive(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancelMotion()
            // 离开 CGEvent 回调后销毁 tap，避免在回调栈里释放 run loop source。
            DispatchQueue.main.async { [weak self] in
                self?.stop()
                self?.onStatus?("系统已暂停输入监听，原生滚动可用。点击重试恢复。")
            }
            return Unmanaged.passUnretained(event)
        }
        guard running, configuration.enabled else { return Unmanaged.passUnretained(event) }
        if ScrollEventAdapter.isSynthetic(event) { return Unmanaged.passUnretained(event) }
        guard type == .scrollWheel else {
            // 点击、移出当前区域、切换修饰键立即刹车，不把惯性带入另一窗口或缩放操作。
            if smoother.active { cancelMotion() }
            return Unmanaged.passUnretained(event)
        }
        guard ScrollEventAdapter.isDiscreteWheel(event), !event.flags.contains(.maskControl),
              !event.flags.contains(.maskCommand) else {
            cancelMotion()
            return Unmanaged.passUnretained(event)
        }
        let rawPID = event.getIntegerValueField(.eventTargetUnixProcessID)
        guard rawPID > 0, rawPID <= Int64(Int32.max) else {
            // 无法识别真正接收窗口时不猜前台 App，保持系统行为。
            cancelMotion()
            return Unmanaged.passUnretained(event)
        }
        let pid = pid_t(rawPID)
        if pid != targetPID || template?.location != event.location || Date.timeIntervalSinceReferenceDate - lastInputTime > 0.45 {
            cancelMotion()
            targetPID = pid
            targetBundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        }
        if let targetBundleID, configuration.excludedApps.contains(targetBundleID) {
            cancelMotion()
            return Unmanaged.passUnretained(event)
        }
        if configuration.reverseVertical { ScrollEventAdapter.reverse(event, horizontal: false) }
        if configuration.reverseHorizontal { ScrollEventAdapter.reverse(event, horizontal: true) }
        let y = ScrollEventAdapter.value(event, horizontal: false)
        let x = ScrollEventAdapter.value(event, horizontal: true)
        let smoothY = configuration.smoothVertical ? y : 0
        let smoothX = configuration.smoothHorizontal ? x : 0
        guard smoothY != 0 || smoothX != 0 else { return Unmanaged.passUnretained(event) }
        guard let displayLink, let copy = event.copy() else { return Unmanaged.passUnretained(event) }
        // 成功启动输出之后才吞掉原始轴，失败则原样放行（已设置的方向反转保留）。
        if !CVDisplayLinkIsRunning(displayLink) && CVDisplayLinkStart(displayLink) != kCVReturnSuccess {
            cancelMotion()
            return Unmanaged.passUnretained(event)
        }
        template = copy
        lastInputTime = Date.timeIntervalSinceReferenceDate
        smoother.add(y: smoothY, x: smoothX, configuration: configuration)
        if smoothY != 0 { ScrollEventAdapter.clear(event, horizontal: false) }
        if smoothX != 0 { ScrollEventAdapter.clear(event, horizontal: true) }
        let remaining = ScrollEventAdapter.value(event, horizontal: false) != 0 || ScrollEventAdapter.value(event, horizontal: true) != 0
        return remaining ? Unmanaged.passUnretained(event) : nil
    }

    private func queueFrame() {
        frameLock.lock()
        guard !frameQueued else { frameLock.unlock(); return }
        frameQueued = true
        let scheduledGeneration = generation
        frameLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.frameLock.lock()
            self.frameQueued = false
            let valid = scheduledGeneration == self.generation
            self.frameLock.unlock()
            if valid { self.tick() }
        }
    }

    private func tick() {
        let now = Date.timeIntervalSinceReferenceDate
        guard running, let template, targetPID > 0, now - lastInputTime < 3,
              lastFrameTime == 0 || now - lastFrameTime < 0.25 else { cancelMotion(); return }
        lastFrameTime = now
        let value = smoother.next(transition: configuration.transition)
        guard smoother.active else { cancelMotion(); return }
        let y = pixelsY.take(value.y), x = pixelsX.take(value.x)
        guard y != 0 || x != 0,
              let event = ScrollEventAdapter.frame(from: template, y: y, x: x) else { return }
        event.postToPid(targetPID)
    }
}
