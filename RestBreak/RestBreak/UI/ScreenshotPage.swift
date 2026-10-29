import SwiftUI

/// 设置窗口「截图」页：快捷键、截图选项、翻译密钥。
/// 不放录屏权限状态：第一次按截图快捷键时会自动请求权限，没权限时也会弹说明。
struct ScreenshotPage: View {
    @EnvironmentObject private var coordinator: BreakCoordinator
    @StateObject private var recorder = ShortcutRecorder()

    var body: some View {
        ShortcutCard(title: "快捷键", actions: ShortcutAction.allCases.filter(\.isScreenshot), recorder: recorder)
            .onDisappear { recorder.stop() }

        Card {
            SettingRow(title: "显示放大镜", subtitle: "光标旁显示像素、坐标和颜色值") {
                Toggle("", isOn: $coordinator.settings.showMagnifier).blueSwitch()
            }
            RowDivider()
            SettingRow(title: "贴图透明度", subtitle: "贴图上按住 ⌥ 滚动可以再调") {
                ValueSlider(value: Binding(get: { (coordinator.settings.pinOpacity * 10).rounded() },
                                           set: { coordinator.settings.pinOpacity = $0 / 10 }),
                            range: 2...10, unit: .percentTens)
            }
        }

        TranslationCard()
    }
}

/// 「翻译」卡片：腾讯云机器翻译的密钥（存钥匙串）、测试
private struct TranslationCard: View {
    @State private var secretId = ""
    @State private var secretKey = ""
    @State private var saved = TencentTranslate.Credentials(secretId: "", secretKey: "")
    @State private var status: Status = .idle

    private enum Status: Equatable {
        case idle, testing, success(String), failure(String)
    }

    private var draft: TencentTranslate.Credentials {
        TencentTranslate.Credentials(secretId: secretId, secretKey: secretKey)
    }

    var body: some View {
        Card {
            CardHeader(title: "翻译（腾讯云）")
            SettingRow(title: "SecretId", subtitle: "腾讯云「API 密钥」页获取") {
                keyField(TextField("AKID…", text: $secretId))
            }
            RowDivider()
            SettingRow(title: "SecretKey", subtitle: "只保存在本机钥匙串里") {
                keyField(SecureField("密钥", text: $secretKey))
            }
            RowDivider()
            SettingRow(title: statusTitle, subtitle: statusDetail, subtitleColor: statusColor) {
                HStack(spacing: 8) {
                    Button("如何申请") {
                        NSWorkspace.shared.open(URL(string: "https://console.cloud.tencent.com/cam/capi")!)
                    }
                    .buttonStyle(PillButtonStyle())
                    Button(status == .testing ? "测试中…" : "保存并测试") { saveAndTest() }
                        .buttonStyle(PillButtonStyle())
                        .disabled(!draft.isComplete || status == .testing)
                }
            }
        }
        .onAppear {
            saved = TencentTranslator.credentials ?? .init(secretId: "", secretKey: "")
            secretId = saved.secretId
            secretKey = saved.secretKey
        }
    }

    private func keyField(_ field: some View) -> some View {
        field
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 10)
            .frame(width: 240, height: 28)
            .background(SettingsTheme.fieldBackground, in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusTitle: String {
        switch status {
        case .success: "连接正常"
        case .failure: "连接失败"
        default: saved.isComplete ? "已设置密钥" : "未设置密钥"
        }
    }

    private var statusDetail: String {
        switch status {
        case .success(let result): "「你好」→「\(result)」"
        case .failure(let message): message
        case .testing: "正在连接腾讯云…"
        case .idle: "每月 500 万字符免费"
        }
    }

    private var statusColor: Color? {
        switch status {
        case .success: .green
        case .failure: .red
        default: nil
        }
    }

    private func saveAndTest() {
        let credentials = draft
        TencentTranslator.saveCredentials(credentials)
        saved = credentials
        status = .testing
        Task {
            do {
                let result = try await TencentTranslator.translate("你好", target: "en", credentials: credentials)
                status = .success(result)
            } catch {
                status = .failure((error as? TranslateError ?? .network).message)
            }
        }
    }
}
