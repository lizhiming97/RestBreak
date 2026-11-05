import AppKit

/// 星期五菜单里的「菜单栏图标」：已收起的图标排成一行，子菜单里打勾决定收起哪些。
/// 星期五在沙盒里不能枚举、移动别的应用的图标；这些都由独立组件完成。
/// 组件把图标列表写进共享的 App Group 文件夹（snapshot.json + 图标 PNG），星期五只读来显示，
/// 点击时用固定格式的网址（只带数字窗口编号）请组件去做。
@MainActor
enum MenuBarShelfMenu {
    struct Snapshot: Decodable {
        struct Entry: Decodable {
            let id: UInt32
            let name: String
            let hidden: Bool
            let pinned: Bool
            let image: String?
            let template: Bool
            let bundleID: String?
            /// 稳定标识（应用 + 序号），发命令用；窗口编号会在屏幕间互换。
            let key: String
        }
        let enabled: Bool
        let pendingRestore: Bool
        let status: String?
        let entries: [Entry]
    }

    static let requestNotice = "com.lizhiming.RestBreak.menubar.request"
    private static var folder: URL? { AppGroup.containerURL?.appendingPathComponent("MenuBarShelf", isDirectory: true) }

    static func read() -> Snapshot? {
        guard let url = folder?.appendingPathComponent("snapshot.json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    /// 组件正在运行并已启用时才有内容；否则菜单只显示「菜单栏图标…」引导去设置。
    static func load() -> Snapshot? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: MenuBarCompanionClient.bundleID).isEmpty,
              let snapshot = read(), snapshot.enabled else { return nil }
        return snapshot
    }

    /// 菜单打开时请组件重新读一次菜单栏，下次打开就是最新的（读取是异步的，不让菜单等）。
    static func requestRefresh() { DarwinNotice.post(requestNotice) }

    /// 图标 PNG 是 2 倍像素；单色图标设为模板图像，跟随菜单深浅色。
    static func image(for entry: Snapshot.Entry, height: CGFloat) -> NSImage? {
        guard let name = entry.image, let url = folder?.appendingPathComponent(name),
              FileManager.default.fileExists(atPath: url.path) else { return appIcon(for: entry, height: height) }
        guard let image = NSImage(contentsOf: url), let rep = image.representations.first,
              rep.pixelsHigh > 0 else { return appIcon(for: entry, height: height) }
        let natural = NSSize(width: CGFloat(rep.pixelsWide) / 2, height: CGFloat(rep.pixelsHigh) / 2)
        let scale = min(1, height / natural.height)
        image.size = NSSize(width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded())
        image.isTemplate = entry.template
        return image
    }

    /// 截不到菜单栏图标时，用来源应用自己的图标代替，至少能认出是哪个应用。
    private static func appIcon(for entry: Snapshot.Entry, height: CGFloat) -> NSImage? {
        guard let id = entry.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: height, height: height)
        return icon
    }

    /// 左键能调到前台的应用：正在运行、有程序坞图标（普通应用）。图标属于主程序包里的辅助程序时
    /// （如飞书的 Lark Helper、WPS 的 wpscloudsvr），打开外层的主程序。系统项、只在菜单栏运行的应用返回 nil。
    static func foregroundApp(for entry: Snapshot.Entry) -> URL? {
        guard let id = entry.bundleID, !id.hasPrefix("com.apple."),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first,
              let url = app.bundleURL else { return nil }
        if let outer = outermostApp(containing: url), outer != url { return outer }
        return app.activationPolicy == .regular ? url : nil
    }

    /// 路径里第一个 .app：/Applications/Lark.app/Contents/…/Lark Helper.app → /Applications/Lark.app
    static func outermostApp(containing url: URL) -> URL? {
        var result = URL(fileURLWithPath: "/")
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            result.appendPathComponent(component)
            if component.hasSuffix(".app") { return result }
        }
        return nil
    }

    /// 加到菜单里；`menu` 关闭后再发命令，避免模拟点击撞上正在跟踪的菜单。
    static func add(to menu: NSMenu, target: AnyObject, fallback: Selector, settings: Selector) {
        guard let snapshot = load() else {
            // 组件上次因缺少授权没能启用：直接说明，点了打开它的设置去授权
            let needsPermission = read()?.status == "permission"
            let item = NSMenuItem(title: needsPermission ? "菜单栏图标需要授权…" : "菜单栏图标…", action: fallback, keyEquivalent: "")
            item.target = target
            item.image = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: nil)
            menu.addItem(item)
            return
        }
        requestRefresh()
        let hidden = snapshot.entries.filter(\.hidden)
        if !hidden.isEmpty {
            let row = NSMenuItem()
            row.view = HiddenIconsView(entries: hidden, menu: menu)
            menu.addItem(row)
        }

        let parent = NSMenuItem(title: "菜单栏图标", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: nil)
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let header = NSMenuItem(title: "打开开关即收起；关掉菜单后一起生效", action: nil, keyEquivalent: "")
        header.isEnabled = false
        submenu.addItem(header)
        Actions.shared.pending = [:]
        let rowWidth = max(260, snapshot.entries.map { SwitchRowView.width(for: $0.name) }.max() ?? 0)
        for entry in snapshot.entries {
            // 自定义视图里的开关点了不会关菜单，可以一次改多个
            let item = NSMenuItem()
            item.view = SwitchRowView(entry: entry, width: rowWidth, enabled: true)
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        if snapshot.pendingRestore {
            let restore = NSMenuItem(title: "放回临时图标", action: #selector(Actions.command(_:)), keyEquivalent: "")
            restore.target = Actions.shared
            restore.representedObject = "restore"
            submenu.addItem(restore)
        }
        if hidden.contains(where: { !$0.pinned }) {
            let all = NSMenuItem(title: "全部显示", action: #selector(Actions.command(_:)), keyEquivalent: "")
            all.target = Actions.shared
            all.representedObject = "reveal-all"
            all.isEnabled = true
            submenu.addItem(all)
        }
        let open = NSMenuItem(title: "收纳设置…", action: settings, keyEquivalent: "")
        open.target = target
        submenu.addItem(open)
        parent.submenu = submenu
        menu.addItem(parent)
    }

    /// 菜单项动作：菜单关闭后再请组件移动/点击。
    @MainActor final class Actions: NSObject {
        static let shared = Actions()
        /// 菜单开着时拨过的开关：窗口编号 → 是否收起。菜单关闭时一起发给组件。
        var pending: [String: Bool] = [:]

        func setPending(_ key: String, hidden: Bool, original: Bool) {
            if hidden == original { pending[key] = nil } else { pending[key] = hidden }
        }

        /// 星期五菜单关闭时调用（菜单开着时模拟拖动会被菜单跟踪打断）。
        func flushPending() {
            let changes = pending
            pending = [:]
            for (key, hidden) in changes.sorted(by: { $0.key < $1.key }) {
                send(hidden ? "hide" : "show", key: key)
            }
        }
        @objc func command(_ sender: NSMenuItem) {
            guard let command = sender.representedObject as? String else { return }
            send(command, key: nil)
        }
        func send(_ command: String, key: String?, button: String? = nil) {
            // 菜单完全收起后再发，组件模拟的拖动/点击才不会被菜单跟踪吃掉
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                MainActor.assumeIsolated {
                    MenuBarCompanionClient.shared.send(command, key: key, button: button)
                }
            }
        }
    }
}

/// 主菜单里的一行：已收起的图标按真实尺寸排开，左键/右键点一下打开它原来的菜单。
private final class HiddenIconsView: NSView {
    private let menuRef: NSMenu
    private static let rowHeight: CGFloat = 30
    private static let inset: CGFloat = 14

    init(entries: [MenuBarShelfMenu.Snapshot.Entry], menu: NSMenu) {
        menuRef = menu
        let buttons = entries.map { IconButton(entry: $0) }
        let width = max(240, buttons.reduce(Self.inset * 2) { $0 + $1.frame.width + 2 })
        super.init(frame: NSRect(x: 0, y: 0, width: min(width, 420), height: Self.rowHeight))
        var x = Self.inset
        for button in buttons {
            button.setFrameOrigin(NSPoint(x: x, y: (Self.rowHeight - button.frame.height) / 2))
            button.onClick = { [weak self] entry, right in self?.open(entry, right: right) }
            addSubview(button)
            x += button.frame.width + 2
        }
        setAccessibilityLabel("已收起的菜单栏图标")
    }
    required init?(coder: NSCoder) { nil }

    /// 左键：有窗口的普通应用调到前台（同程序坞点击）；系统项、只在菜单栏的应用仍打开原菜单。右键：打开原菜单。
    private func open(_ entry: MenuBarShelfMenu.Snapshot.Entry, right: Bool) {
        menuRef.cancelTracking()
        if !right, let app = MenuBarShelfMenu.foregroundApp(for: entry) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            // 已在运行时 LaunchServices 会发「重新打开」，没有窗口的应用会自己开一个主窗口
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, _ in }
            return
        }
        MenuBarShelfMenu.Actions.shared.send("open", key: entry.key, button: right ? "right" : "left")
    }
}

private final class IconButton: NSView {
    private let entry: MenuBarShelfMenu.Snapshot.Entry
    private let image: NSImage?
    var onClick: ((MenuBarShelfMenu.Snapshot.Entry, Bool) -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }

    init(entry: MenuBarShelfMenu.Snapshot.Entry) {
        self.entry = entry
        image = MenuBarShelfMenu.image(for: entry, height: 18)
        let width = max(26, (image?.size.width ?? 16) + 10)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        toolTip = MenuBarShelfMenu.foregroundApp(for: entry) == nil ? entry.name : "\(entry.name)\n点击打开，右键显示菜单"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(entry.name)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        if let image {
            let rect = NSRect(x: (bounds.width - image.size.width) / 2, y: (bounds.height - image.size.height) / 2,
                              width: image.size.width, height: image.size.height)
            if image.isTemplate {
                // 模板图像按当前菜单的文字颜色着色
                let tinted = NSImage(size: image.size, flipped: false) { r in
                    image.draw(in: r)
                    NSColor.labelColor.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: rect)
            } else {
                image.draw(in: rect)
            }
        } else {
            let text = String(entry.name.prefix(1)) as NSString
            text.draw(at: NSPoint(x: bounds.midX - 6, y: bounds.midY - 8),
                      withAttributes: [.font: NSFont.menuFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) { onClick?(entry, false) }
    override func rightMouseUp(with event: NSEvent) { onClick?(entry, true) }
    override func accessibilityPerformPress() -> Bool { onClick?(entry, false); return true }
}

/// 子菜单里的一行：图标 + 名称 + 开关。系统固定项和星期五自己显示「固定」。
private final class SwitchRowView: NSView {
    private static let font = NSFont.menuFont(ofSize: 0)
    private let entry: MenuBarShelfMenu.Snapshot.Entry

    static func width(for name: String) -> CGFloat {
        ceil((name as NSString).size(withAttributes: [.font: font]).width) + 14 + 40 + 10 + 16 + 44 + 14
    }

    init(entry: MenuBarShelfMenu.Snapshot.Entry, width: CGFloat, enabled: Bool) {
        self.entry = entry
        super.init(frame: NSRect(x: 0, y: 0, width: min(width, 420), height: 28))
        let icon = NSImageView(frame: NSRect(x: 14, y: 4, width: 40, height: 20))
        icon.image = MenuBarShelfMenu.image(for: entry, height: 16) ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyDown
        icon.imageAlignment = .alignLeft
        icon.contentTintColor = .labelColor
        addSubview(icon)

        let trailingWidth: CGFloat = entry.pinned ? 36 : 40
        let label = NSTextField(labelWithString: entry.name)
        label.font = Self.font
        label.lineBreakMode = .byTruncatingMiddle
        label.textColor = entry.pinned ? .secondaryLabelColor : .labelColor
        label.frame = NSRect(x: 64, y: 5, width: frame.width - 64 - trailingWidth - 24, height: 18)
        addSubview(label)

        if entry.pinned {
            let fixed = NSTextField(labelWithString: "固定")
            fixed.font = .systemFont(ofSize: 12)
            fixed.textColor = .tertiaryLabelColor
            fixed.alignment = .right
            fixed.frame = NSRect(x: frame.width - 14 - trailingWidth, y: 6, width: trailingWidth, height: 16)
            addSubview(fixed)
            toolTip = "系统固定项或星期五自己，不能收起"
        } else {
            // 系统 NSSwitch 在菜单里（非活动窗口）开着也是灰色，看不出状态；自己画：开 = 星期五蓝，关 = 浅灰
            let toggle = MenuSwitch(isOn: entry.hidden, enabled: enabled)
            toggle.setFrameOrigin(NSPoint(x: frame.width - 14 - toggle.frame.width, y: (28 - toggle.frame.height) / 2))
            toggle.setAccessibilityLabel("收起 \(entry.name)")
            toggle.onChange = { [entry] isOn in
                MenuBarShelfMenu.Actions.shared.setPending(entry.key, hidden: isOn, original: entry.hidden)
            }
            addSubview(toggle)
        }
    }
    required init?(coder: NSCoder) { nil }
}

/// 菜单里用的开关：点了不关菜单，颜色明确表示开/关，拨动有短动画。
private final class MenuSwitch: NSView {
    private static let onColor = NSColor(srgbRed: 0.24, green: 0.48, blue: 0.97, alpha: 1)   // 与设置页强调色一致
    var onChange: ((Bool) -> Void)?
    private(set) var isOn: Bool
    private let enabled: Bool
    private let track = CALayer()
    private let knob = CALayer()

    init(isOn: Bool, enabled: Bool) {
        self.isOn = isOn
        self.enabled = enabled
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 18))
        wantsLayer = true
        track.frame = bounds
        track.cornerRadius = 9
        knob.frame = NSRect(x: 0, y: 0, width: 14, height: 14)
        knob.cornerRadius = 7
        knob.backgroundColor = NSColor.white.cgColor
        knob.shadowOpacity = 0.25
        knob.shadowRadius = 1
        knob.shadowOffset = CGSize(width: 0, height: -0.5)
        layer?.addSublayer(track)
        layer?.addSublayer(knob)
        alphaValue = enabled ? 1 : 0.4
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        apply(animated: false)
    }
    required init?(coder: NSCoder) { nil }

    private func apply(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.15)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.backgroundColor = (isOn ? Self.onColor : NSColor.labelColor.withAlphaComponent(0.15)).cgColor
        }
        knob.position = CGPoint(x: isOn ? bounds.width - 9 : 9, y: bounds.midY)
        CATransaction.commit()
        setAccessibilityValue(isOn)
    }

    override func viewDidChangeEffectiveAppearance() { apply(animated: false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard enabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        toggle()
    }
    override func accessibilityPerformPress() -> Bool { toggle(); return true }

    private func toggle() {
        guard enabled else { return }
        isOn.toggle()
        apply(animated: true)
        onChange?(isOn)
    }
}
