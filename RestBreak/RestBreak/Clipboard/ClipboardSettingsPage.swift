import SwiftUI
import UniformTypeIdentifiers

struct ClipboardSettingsPage: View {
    @EnvironmentObject private var app: BreakCoordinator
    @StateObject private var recorder = ShortcutRecorder()

    var body: some View {
        ClipboardOptions(coordinator: app.clipboard, store: app.clipboard.store)
        ShortcutCard(title: "快捷键", actions: [.clipboardHistory], recorder: recorder)
            .onDisappear { recorder.stop() }
    }
}

private struct ClipboardOptions: View {
    @ObservedObject var coordinator: ClipboardCoordinator
    @ObservedObject var store: ClipboardStore
    @State private var confirmClear = false

    var body: some View {
        Card {
            SettingRow(title: "剪贴板历史", subtitle: "记录复制的文字和图片，只保存在这台 Mac") {
                Toggle("", isOn: $coordinator.preferences.enabled).blueSwitch()
            }
            RowDivider()
            SettingRow(title: "历史记录", subtitle: "\(store.items.count) 条 · \(ByteCountFormatter.string(fromByteCount: Int64(store.byteCount), countStyle: .file))") {
                Button("打开历史") { coordinator.show() }.buttonStyle(PillButtonStyle())
            }
            RowDivider()
            SettingRow(title: "记录状态", subtitle: coordinator.isRecording ? "正在记录；锁屏和睡眠时自动暂停" : "已暂停，不会补录暂停期间的内容") {
                Button(coordinator.paused ? "恢复记录" : "暂停记录") { coordinator.togglePause() }
                    .buttonStyle(PillButtonStyle()).disabled(!coordinator.preferences.enabled)
            }
        }

        Card {
            SettingRow(title: "条目上限", subtitle: "超出后清理最旧的普通历史，保留固定内容") {
                Picker("", selection: $coordinator.preferences.maxItems) {
                    ForEach([50, 100, 200, 500], id: \.self) { Text("\($0) 条").tag($0) }
                }.frame(width: 110)
            }
            RowDivider()
            SettingRow(title: "内容容量", subtitle: "单次内容超过 8 MB 时跳过") {
                Picker("", selection: $coordinator.preferences.maxMegabytes) {
                    ForEach([16, 32, 64, 128], id: \.self) { Text("\($0) MB").tag($0) }
                }.frame(width: 110)
            }
            RowDivider()
            SettingRow(title: "清理历史", subtitle: "不更改系统剪贴板中的当前内容") {
                Menu("清理") {
                    Button("清空普通历史") { store.clear() }
                    Button("清空全部（包括固定）…", role: .destructive) { confirmClear = true }
                }.frame(width: 90)
            }
            if store.byteCount > store.maxBytes || store.items.count > store.maxItems {
                Text("固定内容已超过当前上限，请取消部分固定或提高容量。")
                    .font(.caption).foregroundStyle(.secondary).padding(14)
            }
        }

        Card {
            CardHeader(title: "不记录这些应用")
            Text("自动跳过带密码或临时内容标记的复制。\n排除规则按复制时的前台应用判断。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.vertical, 10)
            ForEach(coordinator.preferences.excludedApps, id: \.self) { bundleID in
                HStack {
                    Text(bundleID).font(.system(size: 11)).lineLimit(1)
                    Spacer()
                    Button("移除") { coordinator.preferences.excludedApps.removeAll { $0 == bundleID } }
                }.padding(.horizontal, 18).padding(.vertical, 5)
            }
            HStack {
                Spacer()
                Button("添加应用…", action: chooseApplication).buttonStyle(PillButtonStyle())
            }.padding(14)
        }

        Card {
            SettingRow(title: "自动粘贴（实验）", subtitle: "历史条目右键使用；普通复制无需此权限") {
                Button("授权辅助功能") { coordinator.requestPastePermission() }.buttonStyle(PillButtonStyle())
            }
        }
        if let error = store.error {
            HStack {
                Text(error).font(.caption).foregroundStyle(.red)
                Button("重试") { coordinator.retry() }
            }
        }
        Text("支持文字和图片。历史保存在本机，正常复制不会弹出提醒。")
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14)
            .task {
                await store.load()
                coordinator.configure()
            }
            .confirmationDialog("清空全部历史，包括固定内容？", isPresented: $confirmClear) {
                Button("清空全部", role: .destructive) { store.clear(includingPinned: true) }
            }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        if !coordinator.preferences.excludedApps.contains(bundleID) {
            coordinator.preferences.excludedApps.append(bundleID)
        }
    }
}
