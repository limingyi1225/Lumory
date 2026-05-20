import SwiftUI
import CoreData

/// 主时间线日记卡的纯视觉组件。无 state、无回调,只展示。
/// 行交互(tap / contextMenu / swipe)由 `HomeTimelineRow` 包装。
@available(iOS 17.0, *)
struct HomeTimelineCard: View {
    // `@ObservedObject` 让 AI writeback(`EntryCreationService.performAIWriteback`)异步写回
    // `entry.summary` 时,SwiftUI 能稳定收到 NSManagedObject 的 willChange,触发 body 重算把
    // shimmer 换成真摘要。`let` + FetchedResults publish 在某些场景下不够稳。
    @ObservedObject var entry: DiaryEntry
    let appLanguage: String

    @State private var shimmerPhase: CGFloat = 0
    private let cal = Calendar.current

    /// AI 摘要还没回来:有正文、没 summary。跟 `DiaryEntryRow.isSummaryLoading` 同语义。
    /// guard managedObjectContext / isDeleted 是因为撤销删除后 entry 可能短暂处于游离态。
    private var isSummaryLoading: Bool {
        guard entry.managedObjectContext != nil, !entry.isDeleted else { return false }
        return entry.summary == nil && !(entry.text ?? "").isEmpty
    }

    var body: some View {
        let cornerRadius: CGFloat = 16
        Group {
            if entry.managedObjectContext == nil || entry.isDeleted {
                EmptyView()
            } else {
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
                    } else if isSummaryLoading {
                        summaryLoadingView
                    }
                    if let text = entry.text, !text.isEmpty {
                        Text(text)
                            .font(LumoryFonts.timelineCardPreview)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .lineSpacing(2)
                    }
                }
                .padding(.init(top: 12, leading: 18, bottom: 12, trailing: 14))
                .frame(maxWidth: .infinity, alignment: .leading)
                // §4.6 (2026-05-19) — `.liquidGlassCard + .moodAccentBar` 配对走共享 modifier。
                .lumoryAccentCard(mood: entry.moodColor, cornerRadius: cornerRadius)
                .accessibilityElement(children: .combine)
                .onAppear {
                    if isSummaryLoading { startShimmerAnimation() }
                }
                // **P1 fix (2026-05-13 superreview)**:summary writeback 让 isSummaryLoading
                // 翻 false 后,shimmer view 离开 view tree 但 `repeatForever` 动画上下文仍持有
                // shimmerPhase=1.0;LazyVStack reuse 时 onAppear 不一定再 fire。显式 onChange
                // 启停,且 reset shimmerPhase=0(zero-duration withAnimation 打断 repeat 链)。
                .onChange(of: isSummaryLoading) { _, loading in
                    if loading {
                        startShimmerAnimation()
                    } else {
                        stopShimmerAnimation()
                    }
                }
            }
        }
    }

    /// 标题占位:shimmer 骨架 + "生成中..." — 跟 `DiaryEntryRow.summaryLoadingView` 视觉一致,
    /// 给用户写完日记到 AI 摘要回来这段间隙(几秒到十几秒)一个明确反馈,而不是静默。
    private var summaryLoadingView: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.secondary.opacity(0.2),
                            Color.secondary.opacity(0.4),
                            Color.secondary.opacity(0.2)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 120, height: 14)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [.clear, .white.opacity(0.4), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .offset(x: shimmerPhase * 150 - 75)
                )
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private func startShimmerAnimation() {
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) {
            shimmerPhase = 1.0
        }
    }

    private func stopShimmerAnimation() {
        withAnimation(.linear(duration: 0)) {
            shimmerPhase = 0
        }
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
        return LumoryDateFormatters.twentyFourHourTime.string(from: date)
    }

    private func cleanedSummary(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "*\"“”'‘’ \n\t"))
            .trimmingCharacters(in: CharacterSet(charactersIn: ".。"))
    }
}
