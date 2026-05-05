import SwiftUI
import WidgetKit

// MARK: - 锁屏 streak widget
//
// 跟 QuickWriteWidget 共用 `WidgetSnapshotStore`,只读 `effectiveStreak`。
// 不需要新 timeline provider —— 直接复用 `QuickWriteProvider`。
//
// `.accessoryCircular`:锁屏 / always-on / Apple Watch 风格的圆形 ring。中心数字 = streak,外圈
//   gauge 用 `Gauge(value: streakProgress, in: 0...1)` 给视觉填充感。
// `.accessoryRectangular`:锁屏左右两条 rect 区域,系统标题 + streak + last entry mood 一行。

struct LockStreakWidget: Widget {
    /// Tap 跳 compose deeplink — 跟主 widget 同 URL,LumoryURLRouter 已 wire `mingyi-lumory://compose`
    /// 的 focus 路径。
    static let composeURL = URL(string: "mingyi-lumory://compose")

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: LumoryWidgetKind.lockStreak, provider: QuickWriteProvider()) { entry in
            LockStreakEntryView(entry: entry)
        }
        .configurationDisplayName(LocalizedStringResource("widget.lockStreak.display_name"))
        .description(LocalizedStringResource("widget.lockStreak.description"))
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct LockStreakEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuickWriteEntry

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        default: circular
        }
    }

    /// 圆形 — 锁屏左下/右下 / Apple Watch corner。中心 streak 数字,外圈进度环走"距 longest 多远"
    /// (longest>0 时);longest=0 时退化成"1 = 今天起步"的小满 ring。
    private var circular: some View {
        let streak = entry.effectiveStreak
        let longest = max(entry.longestStreak, 1)
        let progress = min(Double(streak) / Double(longest), 1)

        return Gauge(value: progress) {
            Image(systemName: "flame.fill")
        } currentValueLabel: {
            Text("\(streak)")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
        }
        .gaugeStyle(.accessoryCircular)
        .widgetURL(LockStreakWidget.composeURL)
    }

    /// 横长条 — 锁屏左下方"小工具"通栏。两行:flame + streak / "longest N 最长"
    private var rectangular: some View {
        let streak = entry.effectiveStreak
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "flame.fill")
                    .imageScale(.small)
                Text(String(format: NSLocalizedString("widget.streak.day_count", comment: ""), streak))
                    .font(.system(.headline, design: .rounded))
                    .lineLimit(1)
            }
            Text(String(format: NSLocalizedString("widget.streak.longest_inline", comment: ""), entry.longestStreak))
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(LockStreakWidget.composeURL)
    }

    /// 一行字符 — 系统状态栏 / 时间下方:"🔥 5"
    private var inline: some View {
        let streak = entry.effectiveStreak
        return Text("🔥 \(streak)")
            .widgetURL(LockStreakWidget.composeURL)
    }

}
