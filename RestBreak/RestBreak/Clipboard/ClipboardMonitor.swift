import AppKit

/// macOS 14 的跨应用采集使用 changeCount 采样；未变化时只读计数，不读正文、不写盘。
@MainActor
final class ClipboardMonitor: NSObject {
    let pasteboard: NSPasteboard
    var sourceApp: () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    var excludedApps: [String] = []
    var onCapture: ((ClipboardCapture.Result) -> Void)?
    private(set) var isRunning = false
    private var timer: Timer?
    private var changeCount: Int

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        changeCount = pasteboard.changeCount
        super.init()
    }

    func setRunning(_ running: Bool) {
        guard running != isRunning else { return }
        timer?.invalidate()
        timer = nil
        // 暂停、锁屏期间的最后一次复制不在恢复后追溯保存。
        changeCount = pasteboard.changeCount
        isRunning = running
        guard running else { return }
        let timer = Timer(timeInterval: 0.5, target: self, selector: #selector(poll), userInfo: nil, repeats: true)
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func resetBaseline() { changeCount = pasteboard.changeCount }

    @objc func poll() {
        guard isRunning, pasteboard.changeCount != changeCount else { return }
        let observedCount = pasteboard.changeCount
        let result = ClipboardCapture.read(pasteboard, sourceApp: sourceApp(), excluding: excludedApps)
        if case .changedDuringRead = result { return }
        changeCount = observedCount
        onCapture?(result)
    }
}
