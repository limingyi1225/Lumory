import SwiftUI
import CoreData

/// 主时间线日记卡的纯视觉组件。无 state、无回调,只展示。
/// 行交互(tap / contextMenu / swipe)由 `HomeTimelineRow` 包装。
@available(iOS 17.0, *)
struct HomeTimelineCard: View {
    let entry: DiaryEntry
    let appLanguage: String

    private let cal = Calendar.current

    /// `HH:mm` 是 locale-independent 数字格式,行内自享 cache 避免每次 diff 重 alloc。
    /// weekday / monthDay 按 `appLanguage` 锁语言走 `LumoryDateFormatters` 共享 cache。
    private static let timeOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        let cornerRadius: CGFloat = 16
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(relativeDateLabel(entry.date))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.primary)
                    .textCase(.uppercase)
                    .tracking(0.4)
                Text(timeLabel(entry.date))
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.7))
                Spacer(minLength: 0)
            }
            if let summary = entry.summary, !summary.isEmpty {
                Text(cleanedSummary(summary))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(2)
            }
            if let text = entry.text, !text.isEmpty {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .lineSpacing(2)
            }
        }
        .padding(.init(top: 12, leading: 18, bottom: 12, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard(cornerRadius: cornerRadius, interactive: true)
        .moodAccentBar(entry.moodColor, cornerRadius: cornerRadius)
        .accessibilityElement(children: .combine)
    }

    private func relativeDateLabel(_ date: Date?) -> String {
        guard let date else { return "" }
        if cal.isDateInToday(date) { return NSLocalizedString("今天", comment: "Today") }
        if cal.isDateInYesterday(date) { return NSLocalizedString("昨天", comment: "Yesterday") }
        let days = cal.dateComponents(
            [.day],
            from: cal.startOfDay(for: date),
            to: cal.startOfDay(for: Date())
        ).day ?? 0
        let formatter = days < 7
            ? LumoryDateFormatters.weekdayFull(language: appLanguage)
            : LumoryDateFormatters.monthDay(language: appLanguage)
        return formatter.string(from: date)
    }

    private func timeLabel(_ date: Date?) -> String {
        guard let date else { return "" }
        return Self.timeOnlyFormatter.string(from: date)
    }

    private func cleanedSummary(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "*\"“”'‘’ \n\t"))
            .trimmingCharacters(in: CharacterSet(charactersIn: ".。"))
    }
}
