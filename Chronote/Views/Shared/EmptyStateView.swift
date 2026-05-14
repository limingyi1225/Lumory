import SwiftUI

// MARK: - EmptyStateView
//
// 统一的空状态组件。**P1-T4 扩展**:
// - `.large`(default,主页 / 全屏空态,40pt 图标)
// - `.compact`(sheet 内 / 小区域空态,28pt 图标)
// - `.inline`(单行内嵌,16pt 图标 + 文字)
// - 可选 CTA 按钮(action + actionLabel)— 让用户从空态直接进入下一步
// - 图标可选 `liquidGlassCircle()` 背景(只 large 默认开,compact / inline 默认关)
//
// 老 init `(systemImage:title:message:)` 保留向后兼容,新代码用全参数版。
//
// 接入清单(7 处自绘空态):
//   AskPastView 空 presets / ThemeFilteredEntriesView / PointDetailSheet /
//   ThemeMergeIntoSheet / SuggestionTargetPickerSheet / ThemeCardList /
//   ThemeAliasManagementView

struct EmptyStateView: View {
    enum Size {
        case large, compact, inline

        var iconSize: CGFloat {
            switch self {
            case .large: return 40
            case .compact: return 28
            case .inline: return 16
            }
        }

        var titleFont: Font {
            switch self {
            case .large: return .headline
            case .compact: return .subheadline.weight(.semibold)
            case .inline: return .footnote.weight(.medium)
            }
        }

        var messageFont: Font {
            switch self {
            case .large: return .subheadline
            case .compact, .inline: return .footnote
            }
        }

        var spacing: CGFloat {
            switch self {
            case .large: return 14
            case .compact: return 8
            case .inline: return 6
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .large: return 32
            case .compact: return 20
            case .inline: return 12
            }
        }

        var verticalPadding: CGFloat {
            switch self {
            case .large: return 24
            case .compact: return 16
            case .inline: return 8
            }
        }
    }

    let systemImage: String
    let title: String
    let message: String?
    let size: Size
    let showsIconBackground: Bool
    let actionLabel: String?
    let action: (() -> Void)?

    init(
        systemImage: String,
        title: String,
        message: String? = nil,
        size: Size = .large,
        showsIconBackground: Bool? = nil,
        actionLabel: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.size = size
        // showsIconBackground 默认值:large 开,其它关。caller 可显式覆写。
        self.showsIconBackground = showsIconBackground ?? (size == .large)
        self.actionLabel = actionLabel
        self.action = action
    }

    var body: some View {
        Group {
            if size == .inline {
                inlineLayout
            } else {
                stackLayout
            }
        }
        .padding(.horizontal, size.horizontalPadding)
        .padding(.vertical, size.verticalPadding)
        // inline 设计意图是"单行内嵌占位",caller 可能想嵌进 HStack/List row 跟其他元素并排;
        // 强制 maxWidth: .infinity 会把 sibling 全顶飞(reviewer Wave-B BUG-P1)。inline 走自然宽。
        .frame(
            maxWidth: size == .inline ? nil : .infinity,
            maxHeight: size == .large ? .infinity : nil
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(message ?? "")")
    }

    @ViewBuilder
    private var stackLayout: some View {
        VStack(spacing: size.spacing) {
            iconView
                .padding(.bottom, size == .large ? 2 : 0)

            Text(title)
                .font(size.titleFont)
                .foregroundColor(.primary)
                .multilineTextAlignment(.center)

            if let message {
                Text(message)
                    .font(size.messageFont)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let actionLabel, let action {
                Button(action: action) {
                    Text(actionLabel)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.glass)
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private var inlineLayout: some View {
        // .firstTextBaseline:Image 16pt 高,VStack 含两行 Text 高约 28pt;HStack default .center 让
        // image 居中飘在 title 上方。让 image 跟 title 第一行 baseline 对齐(reviewer Wave-B OPT-MID)。
        HStack(alignment: .firstTextBaseline, spacing: size.spacing) {
            Image(systemName: systemImage)
                .font(.system(size: size.iconSize, weight: .light))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(size.titleFont)
                    .foregroundColor(.primary)
                if let message {
                    Text(message)
                        .font(size.messageFont)
                        .foregroundColor(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var iconView: some View {
        let icon = Image(systemName: systemImage)
            .font(.system(size: size.iconSize, weight: .light))
            .foregroundColor(.secondary)

        if showsIconBackground {
            icon
                .frame(width: size.iconSize * 1.6, height: size.iconSize * 1.6)
                .liquidGlassCircle()
        } else {
            icon
        }
    }
}
