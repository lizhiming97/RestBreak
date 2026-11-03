import AppKit
import ImageIO
import SwiftUI

@MainActor
final class ClipboardPanelController: NSObject, NSWindowDelegate {
    private var window: NSPanel?
    private weak var coordinator: ClipboardCoordinator?
    private var closing = false

    init(coordinator: ClipboardCoordinator) { self.coordinator = coordinator }

    func show() {
        guard let coordinator else { return }
        if let window { window.makeKeyAndOrderFront(nil); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
                            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "星期五 · 剪贴板"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        let hosting = NSHostingView(rootView: ClipboardHistoryView(coordinator: coordinator, store: coordinator.store))
        hosting.sizingOptions = []
        panel.contentView = hosting
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - 240, y: frame.midY - 260))
        }
        window = panel
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard !closing else { return }
        closing = true
        window?.delegate = nil
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        closing = false
    }

    func windowWillClose(_ notification: Notification) { coordinator?.dismiss() }
    func windowDidResignKey(_ notification: Notification) {
        // 弹出「清空全部」确认框（sheet）时面板也会失去焦点，这时不能关，否则确认框跟着消失。
        // 等下一轮再判断：sheet 已挂上或面板又拿回焦点，就保留面板。
        Task { @MainActor [weak self] in
            guard let self, let window, !window.isKeyWindow, window.attachedSheet == nil else { return }
            coordinator?.close()
        }
    }
}

struct ClipboardHistoryView: View {
    @ObservedObject var coordinator: ClipboardCoordinator
    @ObservedObject var store: ClipboardStore
    @State private var query = ""
    @State private var selected: UUID?
    @State private var confirmClear = false
    @FocusState private var searchFocused: Bool

    private var results: [ClipboardItem] { store.ordered.filter { $0.matches(query) } }
    private var selection: UUID? { selected.flatMap { id in results.contains { $0.id == id } ? id : nil } ?? results.first?.id }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("剪贴板", systemImage: "doc.on.clipboard").font(.headline)
                Spacer()
                Text(coordinator.isRecording ? "记录中" : "记录已暂停")
                    .font(.caption).foregroundStyle(.secondary)
                Button { coordinator.close(); coordinator.onOpenSettings?() } label: {
                    Image(systemName: "gearshape")
                }.buttonStyle(.plain).help("剪贴板设置")
            }.padding(.horizontal, 18).padding(.top, 32).padding(.bottom, 14)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索文字或来源应用", text: $query)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .onSubmit { if let selection { coordinator.use(selection) } }
                    .onMoveCommand(perform: moveSelection)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }.padding(10).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
                .padding(.horizontal, 14).padding(.bottom, 10)

            if let error = store.error {
                HStack {
                    Text(error).font(.caption)
                    Button("重试") { coordinator.retry() }
                }.foregroundStyle(.red).padding(12)
            }
            if let message = coordinator.message {
                Text(message).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 8)
            }

            if results.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: query.isEmpty ? "doc.on.clipboard" : "magnifyingglass").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text(query.isEmpty ? "复制过的内容，随时找回来" : "没有匹配的内容").font(.headline)
                    Text(query.isEmpty ? (coordinator.preferences.enabled ? "复制一段文字或一张图片，它会出现在这里。" : "开启后，文字和图片历史只保存在这台 Mac。") : "试试其他关键词，或清空搜索。")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if !coordinator.preferences.enabled {
                        Button("开启剪贴板历史") { coordinator.preferences.enabled = true }
                            .buttonStyle(.borderedProminent)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(25)
            } else {
                List(selection: $selected) {
                    ForEach(results) { item in
                        ClipboardRow(item: item).tag(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { coordinator.use(item.id) }
                            .contextMenu {
                                Button("复制") { coordinator.use(item.id) }
                                Button("复制为纯文本") { coordinator.use(item.id, plainText: true) }.disabled(item.text == nil)
                                Divider()
                                Button(item.isPinned ? "取消固定" : "固定") { store.togglePin(item.id) }
                                Button("删除", role: .destructive) { store.delete(item.id) }
                            }
                    }
                }.listStyle(.inset)
                    .onMoveCommand(perform: moveSelection)
            }

            Divider()
            HStack(spacing: 10) {
                Menu {
                    Button(coordinator.paused ? "恢复记录" : "暂停记录") { coordinator.togglePause() }
                        .disabled(!coordinator.preferences.enabled)
                    Button("清空普通历史") { store.clear() }
                    Button("清空全部历史…", role: .destructive) { confirmClear = true }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 25)
                Text("\(results.count) 条").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("固定") { if let selection { store.togglePin(selection) } }.disabled(selection == nil)
                    .keyboardShortcut("p", modifiers: .option)
                Button("纯文本") { if let selection { coordinator.use(selection, plainText: true) } }
                    .disabled(!results.contains { $0.id == selection && $0.text != nil })
                Button("复制 ↩") { if let selection { coordinator.use(selection) } }.disabled(selection == nil)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }.controlSize(.small).padding(12)
        }
        .frame(width: 480, height: 520)
        .background(.regularMaterial)
        .onAppear { selected = results.first?.id; searchFocused = true }
        .onChange(of: query) { _, _ in selected = results.first?.id }
        .onChange(of: results.map(\.id)) { _, ids in
            if selected == nil || !ids.contains(selected!) { selected = ids.first }
        }
        .onExitCommand { coordinator.dismiss() }
        .confirmationDialog("清空全部历史，包括固定内容？", isPresented: $confirmClear) {
            Button("清空全部", role: .destructive) { store.clear(includingPinned: true) }
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !results.isEmpty, direction == .up || direction == .down else { return }
        let index = results.firstIndex { $0.id == selection } ?? 0
        selected = results[min(results.count - 1, max(0, index + (direction == .down ? 1 : -1)))].id
    }
}

private struct ClipboardRow: View {
    let item: ClipboardItem
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.5))
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFit().padding(3)
                } else {
                    Image(systemName: item.imageData == nil ? "text.alignleft" : "photo").foregroundStyle(.secondary)
                }
            }.frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).lineLimit(2).font(.system(size: 13))
                HStack(spacing: 6) {
                    Text(item.sourceApp?.split(separator: ".").last.map(String.init) ?? "未知来源")
                    Text("·")
                    Text(item.copiedAt, style: .time)
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if item.isPinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 4).help(String((item.text ?? item.title).prefix(2000)))
            .onAppear {
                guard thumbnail == nil, let data = item.imageData,
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 96,
                        kCGImageSourceCreateThumbnailWithTransform: true
                      ] as CFDictionary) else { return }
                thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }
    }
}
