import SwiftUI

// 日记预览视图
struct DiaryPreviewView: View {
    @ObservedObject var entry: DiaryEntry
    let appLanguage: String
    let onTap: () -> Void

    private let cal = Calendar.current
    // weekday / monthDay 按 `appLanguage` 锁定语言,走 `LumoryDateFormatters` 共享 cache;
    // HH:mm 走 `twentyFourHourTime` 共享实例(locale-independent 24h)。

    var body: some View {
        // 确保 entry 仍然有效
        if entry.managedObjectContext != nil && !entry.isFault {
            let cornerRadius: CGFloat = 20

            VStack(alignment: .leading, spacing: 10) {
                // 日期 / 时间 —— 复用时间线卡片上的 uppercase + tracking 风格
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(relativeDateLabel(entry.wrappedDate))
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.primary)
                        .textCase(.uppercase)
                        .tracking(0.4)
                    Text(timeLabel(entry.wrappedDate))
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.7))
                    Spacer(minLength: 0)
                }

                if let summary = entry.wrappedSummary, !summary.isEmpty {
                    // F9 — entry.summary 字号语义化(.headline = 17pt semibold baseline,preview 卡片场景跟 detail 一致)
                    Text(cleanedSummary(summary))
                        .font(.headline)
                        .foregroundColor(.primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }

                if !entry.wrappedText.isEmpty {
                    Text(entry.wrappedText)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .lineLimit(8)
                        .lineSpacing(3)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                if hasAttachments {
                    HStack(spacing: 8) {
                        if entry.wrappedAudioFileName != nil {
                            attachmentBadge(
                                icon: "mic.fill",
                                label: NSLocalizedString("语音", comment: "Voice attachment badge")
                            )
                        }
                        if imageCount > 0 {
                            attachmentBadge(icon: "photo.fill", label: "\(imageCount)")
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.init(top: 16, leading: 20, bottom: 14, trailing: 16))
            .frame(width: 300, height: 400, alignment: .topLeading)
            .liquidGlassCard(cornerRadius: cornerRadius, interactive: false)
            .moodAccentBar(entry.moodColor, cornerRadius: cornerRadius)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(
                .contextMenuPreview,
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .onTapGesture { onTap() }
        } else {
            // 如果 entry 已被删除或无效，显示一个占位符或空视图
            Color.clear.frame(width: 300, height: 400)
        }
    }

    private var hasAttachments: Bool {
        entry.wrappedAudioFileName != nil || imageCount > 0
    }

    private var imageCount: Int {
        entry.imageFileNameArray.count
    }

    @ViewBuilder
    private func attachmentBadge(icon: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(label)
                .font(.caption2.weight(.medium))
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }

    private func relativeDateLabel(_ date: Date) -> String {
        if cal.isDateInToday(date) { return NSLocalizedString("今天", comment: "Today") }
        if cal.isDateInYesterday(date) { return NSLocalizedString("昨天", comment: "Yesterday") }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 0
        return Self.relativeDateString(for: date, days: days, language: appLanguage)
    }

    private func timeLabel(_ date: Date) -> String {
        LumoryDateFormatters.twentyFourHourTime.string(from: date)
    }

    private static func relativeDateString(for date: Date, days: Int, language: String) -> String {
        let formatter = days < 7
            ? LumoryDateFormatters.weekdayFull(language: language)
            : LumoryDateFormatters.monthDay(language: language)
        return formatter.string(from: date)
    }

    private func cleanedSummary(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "*\"“”'‘’ \n\t"))
            .trimmingCharacters(in: CharacterSet(charactersIn: ".。"))
    }
}
