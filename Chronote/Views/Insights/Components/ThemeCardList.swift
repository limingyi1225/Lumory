import SwiftUI

// MARK: - ThemeCardList
//
// Insights Dashboard 第二块。横向滚动卡片：主题名、出现次数、平均心情、sparkline。
// 点击卡片 → 触发 onSelect，外部视图负责导航到筛选后的日记列表。

struct ThemeCardList: View {
    let themes: [InsightsEngine.Theme]
    let isLoading: Bool
    let onSelect: (InsightsEngine.Theme) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(NSLocalizedString("主题", comment: "Themes section"))
                    .font(.headline)
                Spacer()
                if !themes.isEmpty {
                    Text(String(format: NSLocalizedString("%d 个主题", comment: "Themes count"), themes.count))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)

            if isLoading && themes.isEmpty {
                skeleton
            } else if themes.isEmpty {
                emptyState
            } else {
                // 横向 ScrollView 跨越了外层 Insights 的 GlassEffectContainer 边界,
                // 这里再套一层自己的 container,确保卡片之间的折射/模糊能正确合批并一次性渲染。
                ScrollView(.horizontal, showsIndicators: false) {
                    GlassEffectContainer(spacing: 12) {
                        HStack(spacing: 12) {
                            ForEach(themes) { theme in
                                Button {
                                    #if canImport(UIKit)
                                    HapticManager.shared.click()
                                    #endif
                                    onSelect(theme)
                                } label: {
                                    ThemeCard(theme: theme)
                                        .frame(width: 180)
                                        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                }
                                .buttonStyle(PressableScaleButtonStyle())
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
    }

    private var skeleton: some View {
        HStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.secondary.opacity(0.06))
                    .frame(width: 180, height: 130)
            }
        }
        .padding(.horizontal, 16)
    }

    private var emptyState: some View {
        HStack {
            Text(NSLocalizedString("AI 正在整理主题，或暂无足够日记", comment: "Empty themes"))
                .font(.footnote)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Single Theme Card

struct ThemeCard: View {
    let theme: InsightsEngine.Theme

    /// 有足够数据点才画 sparkline —— 趋势至少要有 3 个实际写过的 bucket 才有意义。
    private var hasMeaningfulTrend: Bool {
        // `trend` 在无数据的 bucket 里填 0.5（中性）。至少要 3 个非中性 bucket 才展示曲线。
        theme.count >= 3 && theme.trend.filter { abs($0 - 0.5) > 0.001 }.count >= 3
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(theme.name)
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(String(format: NSLocalizedString("%d 次", comment: "Theme count"), theme.count))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            // 心情色块
            moodBar

            // 底部：有趋势时展示 sparkline；否则展示情绪分数和定性标签，更有意义。
            bottomRow
                .frame(height: 36)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 130)
        .liquidGlassCard(cornerRadius: 16, tint: Color.moodSpectrum(value: theme.avgMood), tintStrength: 0.18, interactive: true)
        .shadow(color: Color.primary.opacity(0.04), radius: 6, y: 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String(
                format: NSLocalizedString("主题 %@，出现 %d 次，平均情绪 %d 分", comment: "A11y: theme card"),
                theme.name, theme.count, Int(theme.avgMood * 100)
            )
        )
    }

    private var moodBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(Color.moodSpectrum(value: theme.avgMood))
                    .frame(width: geo.size.width * CGFloat(theme.avgMood))
            }
        }
        .frame(height: 5)
    }

    @ViewBuilder
    private var bottomRow: some View {
        if hasMeaningfulTrend {
            sparkline
        } else {
            summaryRow
        }
    }

    private var sparkline: some View {
        GeometryReader { geo in
            let values = theme.trend
            let width = geo.size.width
            let height = geo.size.height
            let stepX = values.count > 1 ? width / CGFloat(values.count - 1) : width
            Path { path in
                for (i, v) in values.enumerated() {
                    let x = CGFloat(i) * stepX
                    let y = height * (1 - CGFloat(v))
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(Color.moodSpectrum(value: theme.avgMood), lineWidth: 2)
        }
    }

    /// 数据太少不画图；用文字概括 + 平均分更直接。
    private var summaryRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.moodSpectrum(value: theme.avgMood))
                .frame(width: 8, height: 8)
            Text(qualitativeLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "%d", Int(theme.avgMood * 100)))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color.primary.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var qualitativeLabel: String {
        switch theme.avgMood {
        case ..<0.25:  return NSLocalizedString("低落", comment: "Mood: low")
        case ..<0.45:  return NSLocalizedString("偏低", comment: "Mood: slightly low")
        case ..<0.55:  return NSLocalizedString("平静", comment: "Mood: neutral")
        case ..<0.75:  return NSLocalizedString("积极", comment: "Mood: positive")
        default:       return NSLocalizedString("高涨", comment: "Mood: high")
        }
    }
}
