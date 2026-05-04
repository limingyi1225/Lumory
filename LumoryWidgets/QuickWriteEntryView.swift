import SwiftUI
import WidgetKit

/// Quick Write widget 渲染层。
///
/// 设计原则(V3):
/// 1. **Prompt 是标题**。`headline` 三态:
///    - 写过今天 → 状态文字("今天已记录" / "Recorded today")
///    - 没写 + 有 prompt → prompt 原文(无引号)
///    - 没写 + prompt 空 → CTA("记录今天" / "Write today")
///    任何尺寸的大字主体都是 headline,占视觉中心。
/// 2. **Mood 不再做条带**。表达只两处:
///    - 写过今天 → state icon 从绿对勾换成"白勾 + mood 圆"hierarchical 双色,mood 是成功色
///    - 写过今天 → 右上角小 chip("今日心情 + mood dot")
///    没写过今天就完全不显示 mood,避免误导。
/// 3. **大尺寸 4 等分**:header / hero headline / divider / 双列 stat。
///    每段都 `Spacer()` 让间距自动伸缩,杜绝"上面挤、下面空大半"。
/// 4. **字体一律 `.rounded`**,大尺寸 hero 28pt,跟 small 18pt 形成层次。
/// 5. **不**用 `.contentMarginsDisabled()`(配在 `QuickWriteWidget.swift` 里)——
///    iOS 给默认 ~16pt 安全 inset,防文字贴边被圆角切。
struct QuickWriteEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuickWriteEntry

    var body: some View {
        Group {
            switch family {
            case .systemSmall:  smallLayout
            case .systemMedium: mediumLayout
            case .systemLarge:  largeLayout
            default:            smallLayout
            }
        }
        // **closure 形而非 ShapeStyle 形** —— Apple WWDC23 推荐:closure 形让系统能基于 view
        // 抽 tinted 版本给 Smart Stack / StandBy / accented mode。直接传 `.fill.tertiary`
        // 也合法但在 StandBy 下显示成扁平 tertiary 灰,少一档表达力。
        .containerBackground(for: .widget) {
            Rectangle().fill(.fill.tertiary)
        }
        // **`mingyi-lumory://compose`** 是默认 deep-link scheme(reverse-DNS-ish,撞名概率低)。
        // `LumoryURLRouter.route(for:)` 同时也接受 `lumory://`(legacy 兼容,见 Info.plist URL types)。
        .widgetURL(URL(string: "mingyi-lumory://compose"))
    }

    // MARK: - Computed pieces

    /// 三态 headline,见 doc。
    private var headline: String {
        if entry.wroteToday {
            return NSLocalizedString("widget.state.recorded", comment: "")
        }
        if let p = entry.prompt, !p.isEmpty {
            return p
        }
        return NSLocalizedString("widget.cta.write_today", comment: "")
    }

    /// 仅 wroteToday + 有 mood 时返回值。其他情况 nil → 上层完全跳过 mood 渲染。
    private var moodColor: Color? {
        guard entry.wroteToday, let mood = entry.lastEntryMood else { return nil }
        return Color.moodSpectrum(value: mood)
    }

    /// state icon。写过 → "白勾在 mood 色圆里"hierarchical 双色填充(mood 即成就色);
    /// 没写过 → 蓝铅笔(行动召唤)。
    @ViewBuilder
    private func stateIcon(size: CGFloat) -> some View {
        if let mood = moodColor {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white, mood)
        } else if entry.wroteToday {
            // 写过但没 mood(理论上罕见):用 .green 兜底,跟"成功"语义一致
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white, Color.green)
        } else {
            Image(systemName: "pencil.and.scribble")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)
        }
    }

    /// "1 day streak" / "连续 1 天"。0 streak 时返回 nil(调用方决定要不要画占位)。
    private var streakText: String? {
        guard entry.effectiveStreak > 0 else { return nil }
        return String(format: NSLocalizedString("widget.streak.day_count", comment: ""), entry.effectiveStreak)
    }

    private var longestText: String {
        String(format: NSLocalizedString("widget.streak.longest_inline", comment: ""), entry.longestStreak)
    }

    /// 紧凑 stat 行 —— small/medium 底栏用。"连续 1 天 · 最长 13"
    /// 0 streak 退化为 "最长 13" 单条;**全新装机**(streak=0 + longest=0 + 还没写过)
    /// 退化为 fallback CTA 短句,不留死空。
    private var compactStatLine: String? {
        switch (streakText, entry.longestStreak) {
        case (.some(let s), let l) where l > 0: return "\(s) · \(longestText)"
        case (.some(let s), _): return s
        case (.none, let l) where l > 0: return longestText
        case (.none, _) where entry.wroteToday: return nil
        default: return NSLocalizedString("widget.cta.fresh_start", comment: "Fresh-install footer hint")
        }
    }

    // MARK: - Small (≈155×155)

    /// header(icon)+ hero headline + 底部 streak。
    /// **不**在右上角再画一遍 mood —— `stateIcon` 在 wroteToday 时已经把对勾染成 mood 色,
    /// 单一信号比双信号干净。`moodColor` 仍保留供 `stateIcon` 用。
    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            stateIcon(size: 18)
            Spacer(minLength: 8)
            // **不要加 `.fixedSize(horizontal: false, vertical: true)`** —— 它让 Text 取 ideal 高度
            // 忽略 parent 约束,长 prompt + Dynamic Type XXL 下会把底部 stat 行挤出 widget rect
            // (SwiftUI 不裁剪,直接渲染到 widget bounding box 外面看不见)。`lineLimit + minimumScaleFactor`
            // 已经在做 truncation/缩放,够用。
            Text(headline)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(4)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 8)
            if let line = compactStatLine {
                Text(line)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
    }

    // MARK: - Medium (≈337×155)

    /// header full-width + hero headline 大字 + 底栏 stat。
    /// 不分两列 —— prompt 当 hero 时只有一段长字符串,左右切割反而别扭。
    private var mediumLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            stateIcon(size: 22)
            Spacer(minLength: 10)
            // 同 small:不要 `.fixedSize` —— 让 lineLimit + minimumScaleFactor 处理溢出。
            Text(headline)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 10)
            if let line = compactStatLine {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Large (≈337×337)

    /// 4 等分填满:header / hero headline 巨大字 / divider / 双列 stat 数字 hero。
    /// 每段 `Spacer()` 让间距自动伸缩,杜绝"上面挤、下面空大半"。
    private var largeLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            stateIcon(size: 28)

            Spacer(minLength: 16)

            // 同 small/medium:不要 `.fixedSize` —— 30pt × 5 行 ≈ 180pt 加 header + stat row 可能
            // 在长 prompt + Dynamic Type 大号下挤爆 large widget 的 ~305pt 可用高度。
            Text(headline)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(5)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 16)

            Divider().opacity(0.4)

            HStack(alignment: .top, spacing: 24) {
                statColumn(
                    value: "\(entry.effectiveStreak)",
                    label: NSLocalizedString("widget.stats.streak", comment: "")
                )
                Divider().frame(height: 36)
                statColumn(
                    value: "\(entry.longestStreak)",
                    label: NSLocalizedString("widget.stats.longest", comment: "")
                )
                Spacer(minLength: 0)
            }
            .padding(.top, 10)
        }
    }

    /// large 双列 stat —— 数字大字 hero,label 小灰字。
    private func statColumn(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
