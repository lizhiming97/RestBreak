import SwiftUI

/// 设置窗口「外观」页：选休息背景（毛玻璃 / 风景渐变 / 我的照片）、选照片文件夹、预览
struct AppearancePage: View {
    @EnvironmentObject private var coordinator: BreakCoordinator
    /// 照片文件夹里的图片数；nil 表示还没选或文件夹读不到
    @State private var photoCount: Int?

    var body: some View {
        AppearanceCard {
            VStack(alignment: .leading, spacing: 3) {
                Text("休息背景")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppearanceColors.textPrimary)
                Text("弹出休息时铺满屏幕的画面")
                    .font(.system(size: 11))
                    .foregroundStyle(AppearanceColors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 14)

            HStack(spacing: 14) {
                ForEach(OverlayStyle.allCases, id: \.self) { style in
                    StyleTile(style: style, isSelected: coordinator.settings.overlayStyle == style) {
                        select(style)
                    }
                }
            }
            .padding(18)

            if coordinator.settings.overlayStyle == .photos {
                AppearanceDivider()
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(coordinator.settings.photoFolder?.name ?? "还没有选择文件夹")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AppearanceColors.textPrimary)
                        Text(folderDetail)
                            .font(.system(size: 11))
                            .foregroundStyle(photoCount == 0 || folderUnreadable ? .red : AppearanceColors.textSecondary)
                    }
                    Spacer()
                    Button(coordinator.settings.photoFolder == nil ? "选择文件夹…" : "更换…") { chooseFolder() }
                        .buttonStyle(AppearancePillButton())
                }
                .padding(.horizontal, 18)
                .frame(minHeight: 62)
            }

            AppearanceDivider()
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("预览")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppearanceColors.textPrimary)
                    Text("全屏看看效果，8 秒后自动关闭")
                        .font(.system(size: 11))
                        .foregroundStyle(AppearanceColors.textSecondary)
                }
                Spacer()
                Button("预览休息画面") { coordinator.previewOverlay() }
                    .buttonStyle(AppearancePillButton())
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 62)
        }
        .onAppear(perform: refreshCount)
    }

    private var folderUnreadable: Bool {
        coordinator.settings.photoFolder != nil && photoCount == nil
    }

    private var folderDetail: String {
        guard coordinator.settings.photoFolder != nil else { return "休息时从文件夹（含子文件夹）里随机挑一张照片" }
        guard let photoCount else { return "读不到这个文件夹（可能被移动或删除），请重新选择" }
        if photoCount == 0 { return "文件夹里没有图片，休息时会改用风景渐变" }
        return "共 \(photoCount) 张图片，每次休息随机挑一张，不会连续重复"
    }

    private func select(_ style: OverlayStyle) {
        coordinator.settings.overlayStyle = style
        // 选「我的照片」但还没选文件夹 → 直接弹出选择窗口
        if style == .photos && coordinator.settings.photoFolder == nil { chooseFolder() }
    }

    private func chooseFolder() {
        guard let folder = coordinator.photos.chooseFolder() else { return }
        coordinator.settings.photoFolder = folder
        refreshCount()
    }

    private func refreshCount() {
        photoCount = coordinator.settings.photoFolder.flatMap { coordinator.photos.imageCount(in: $0) }
    }
}

/// 一个背景样式的缩略图卡片，选中时蓝色描边
private struct StyleTile: View {
    let style: OverlayStyle
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            thumbnail
                .frame(height: 96)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? AppearanceColors.accent : AppearanceColors.cardBorder,
                                  lineWidth: isSelected ? 2.5 : 1))
            HStack(spacing: 5) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AppearanceColors.accent : AppearanceColors.textSecondary.opacity(0.5))
                Text(style.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppearanceColors.textPrimary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .animation(.snappy(duration: 0.15), value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var thumbnail: some View {
        switch style {
        case .frosted:
            ZStack {
                LinearGradient(colors: [Color(white: 0.55), Color(white: 0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "square.on.square")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.white.opacity(0.7))
            }
        case .scenery:
            // 把几套风景并排展示
            HStack(spacing: 0) {
                ForEach(Scenery.all.prefix(4), id: \.name) { scenery in
                    LinearGradient(colors: scenery.colors.map { Color(red: $0.r, green: $0.g, blue: $0.b) },
                                   startPoint: .top, endPoint: .bottom)
                }
            }
        case .photos:
            ZStack {
                LinearGradient(colors: [Color(red: 0.55, green: 0.70, blue: 0.85), Color(red: 0.35, green: 0.50, blue: 0.40)],
                               startPoint: .top, endPoint: .bottom)
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }
}

private struct AppearanceCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(.white, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppearanceColors.cardBorder, lineWidth: 1))
    }
}

private struct AppearanceDivider: View {
    var body: some View {
        Rectangle().fill(AppearanceColors.divider).frame(height: 1).padding(.horizontal, 18)
    }
}

private struct AppearancePillButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(AppearanceColors.textPrimary)
            .padding(.horizontal, 16)
            .frame(height: 28)
            .background(Color(red: 0.94, green: 0.94, blue: 0.95).opacity(configuration.isPressed ? 0.6 : 1),
                        in: RoundedRectangle(cornerRadius: 8))
    }
}

private enum AppearanceColors {
    static let accent = Color(red: 0.24, green: 0.48, blue: 0.97)
    static let textPrimary = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let textSecondary = Color(red: 0.54, green: 0.54, blue: 0.56)
    static let divider = Color(red: 0.918, green: 0.918, blue: 0.925)
    static let cardBorder = Color(red: 0.906, green: 0.906, blue: 0.914)
}
