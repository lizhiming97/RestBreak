// SPDX-License-Identifier: GPL-3.0-only
// 下拉面板：上方是已收起的图标（图像代理与左右键转发改编自 IceBar.swift），下方是逐项开关。
import AppKit
import SwiftUI

/// 面板里的一行：菜单栏上的一个图标。
public struct ShelfRow: Identifiable {
    public let item: MenuBarItem
    let image: CGImage?
    public let isHidden: Bool
    /// 系统固定项和宿主（星期五）自己的图标：显示但不能收纳。
    public let isPinned: Bool
    public var id: CGWindowID { item.id }
}

@MainActor
final class ShelfMenuPanel: NSPanel {
    private let dismiss: () -> Void
    override var canBecomeKey: Bool { true }

    init(controller: ShelfController, frame: CGRect, dark: Bool,
         onOpen: @escaping (CGWindowID, CGMouseButton) -> Void, onDismiss: @escaping () -> Void) {
        dismiss = onDismiss
        super.init(contentRect: frame, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        title = "菜单栏图标"
        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        // 与系统下拉菜单同一种材质和圆角。
        let material = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        material.material = .menu
        material.state = .active
        material.blendingMode = .behindWindow
        material.wantsLayer = true
        material.layer?.cornerRadius = 10
        material.layer?.masksToBounds = true
        material.autoresizingMask = [.width, .height]
        let host = NSHostingView(rootView: ShelfMenuView(controller: controller, onOpen: onOpen))
        host.frame = material.bounds
        host.autoresizingMask = [.width, .height]
        material.addSubview(host)
        contentView = material
    }

    /// 行数变化（开关移动后）时保持顶边不动，向下伸缩。
    func resize(height: CGFloat) {
        guard abs(frame.height - height) > 0.5 else { return }
        setFrame(CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height), display: true)
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    /// 图标颜色取决于菜单栏背后的壁纸，不一定跟随系统深浅色：按图标亮度决定面板明暗，白色图标才看得清。
    static func prefersDark(_ images: [CGImage]) -> Bool {
        var luminance = 0.0, alpha = 0.0
        for image in images {
            var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
            pixels.withUnsafeMutableBytes { bytes in
                guard let context = CGContext(data: bytes.baseAddress, width: 8, height: 8,
                    bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            }
            for index in stride(from: 0, to: pixels.count, by: 4) {
                luminance += 0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])
                alpha += Double(pixels[index + 3])
            }
        }
        return alpha > 0 && luminance / alpha > 0.5
    }
}

/// 开关用星期五设置页的强调色；其余都用系统语义色，和系统菜单保持一致。
private let fridayAccent = Color(red: 0.24, green: 0.48, blue: 0.97)

private struct ShelfMenuView: View {
    @ObservedObject var controller: ShelfController
    let onOpen: (CGWindowID, CGMouseButton) -> Void

    private var rows: [ShelfRow] { controller.panelRows }
    private var hiddenRows: [ShelfRow] { rows.filter(\.isHidden) }
    private var canToggle: Bool { !controller.hasPendingRestore && !controller.isStopping }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("菜单栏图标").font(.system(size: 13, weight: .semibold))
                Spacer()
                if hiddenRows.contains(where: { !$0.isPinned }) {
                    Button("全部显示") { controller.revealAll() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .disabled(!canToggle || !controller.movingIDs.isEmpty)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 38)

            if controller.hasPendingRestore {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(.secondary)
                    Text("有一个图标临时放在外面").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("放回去") { controller.restoreTemporaryItem() }
                        .buttonStyle(.borderless).font(.system(size: 12)).disabled(controller.isBusy)
                }
                .padding(.horizontal, 14)
                .frame(height: 34)
            }

            tray
                .padding(.horizontal, 10)
                .frame(height: 46)

            Divider().padding(.horizontal, 10).padding(.vertical, 6)

            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        ShelfRowView(row: row, isMoving: controller.movingIDs.contains(row.id), canToggle: canToggle) { hidden in
                            controller.setHidden(row.id, hidden: hidden, on: controller.panelDisplayID)
                        }
                    }
                }
                .padding(.horizontal, 5)
            }
            .scrollIndicators(.automatic)
            .padding(.bottom, 8)
        }
    }

    /// 收起区：面板里唯一的凹槽，图标按真实尺寸排开，点一下打开它原来的菜单。
    private var tray: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06))
            if hiddenRows.isEmpty {
                Text("打开下面的开关，图标会收进这里")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(hiddenRows) { row in
                            ItemProxy(row: row, onClick: onOpen)
                                .frame(width: max(30, row.item.frame.width + 4), height: 36)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .scrollIndicators(.never)
                .defaultScrollAnchor(.leading)
            }
        }
    }
}

private struct ShelfRowView: View {
    let row: ShelfRow
    let isMoving: Bool
    let canToggle: Bool
    let onToggle: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            IconImage(image: row.image)
                .frame(width: 40, height: 22)
            Text(row.item.displayName)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            trailing.frame(minWidth: 34, alignment: .trailing)
        }
        .padding(.horizontal, 9)
        .frame(height: ShelfGeometry.menuRowHeight)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color.primary.opacity(hovering && !row.isPinned ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(row.isPinned ? "系统固定项，不能收纳" : (row.isHidden ? "已收起，关闭开关即在菜单栏显示" : "打开开关即收起"))
    }

    @ViewBuilder private var trailing: some View {
        if row.isPinned {
            Text("固定").font(.system(size: 12)).foregroundStyle(.tertiary)
        } else if isMoving {
            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 26, height: 16)
        } else {
            Toggle("", isOn: Binding(get: { row.isHidden }, set: { onToggle($0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(fridayAccent)
                .labelsHidden()
                .disabled(!canToggle)
        }
    }
}

/// 菜单栏截图通常比图标高（含上下留白），按原始点尺寸居中裁切，不缩放成模糊的小图。
private struct IconImage: View {
    let image: CGImage?
    var body: some View {
        if let image {
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            Image(nsImage: NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale,
                                                                height: CGFloat(image.height) / scale)))
                .frame(width: 40, height: 22)
                .clipped()
        } else {
            Image(systemName: "app.dashed").font(.system(size: 13)).foregroundStyle(.tertiary)
        }
    }
}

/// 用 AppKit 精确区分左右键，事件在松手后触发，避免和后续模拟拖动重叠。
private struct ItemProxy: NSViewRepresentable {
    let row: ShelfRow
    let onClick: (CGWindowID, CGMouseButton) -> Void
    func makeNSView(context: Context) -> ProxyView { ProxyView(row: row, onClick: onClick) }
    func updateNSView(_ nsView: ProxyView, context: Context) {}

    final class ProxyView: NSView {
        let row: ShelfRow
        let onClick: (CGWindowID, CGMouseButton) -> Void
        private var pressed = false { didSet { needsDisplay = true } }
        init(row: ShelfRow, onClick: @escaping (CGWindowID, CGMouseButton) -> Void) {
            self.row = row
            self.onClick = onClick
            super.init(frame: .zero)
            toolTip = row.item.displayName
            setAccessibilityElement(true)
            setAccessibilityLabel(row.item.displayName)
            setAccessibilityRole(.button)
        }
        required init?(coder: NSCoder) { nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            if pressed {
                NSColor.labelColor.withAlphaComponent(0.1).setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 4), xRadius: 5, yRadius: 5).fill()
            }
            if let cg = row.image {
                let scale = window?.backingScaleFactor ?? 2
                let size = NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale)
                NSImage(cgImage: cg, size: size).draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                                                 width: size.width, height: size.height))
            } else {
                // 系统拒绝图像时仍保留可操作入口，不伪造“已捕获图标”。
                let label = String(row.item.displayName.prefix(1)) as NSString
                label.draw(at: NSPoint(x: bounds.midX - 6, y: bounds.midY - 9),
                           withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor])
            }
        }
        override func mouseDown(with event: NSEvent) { pressed = true }
        override func rightMouseDown(with event: NSEvent) { pressed = true }
        override func mouseUp(with event: NSEvent) {
            pressed = false
            if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick(row.id, .left) }
        }
        override func rightMouseUp(with event: NSEvent) {
            pressed = false
            if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick(row.id, .right) }
        }
        override func accessibilityPerformPress() -> Bool { onClick(row.id, .left); return true }
    }
}
