import SwiftUI
import CoreData

struct OnThisDayHighlight: Identifiable {
    let id: NSManagedObjectID
    let title: String
    let entry: DiaryEntry
}

@available(iOS 17.0, *)
struct OnThisDaySection: View {
    let highlights: [OnThisDayHighlight]
    let appLanguage: String
    let onTap: (DiaryEntry) -> Void

    private var visibleHighlights: [OnThisDayHighlight] {
        highlights.filter { highlight in
            highlight.entry.managedObjectContext != nil && !highlight.entry.isDeleted
        }
    }

    var body: some View {
        if !visibleHighlights.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(visibleHighlights) { highlight in
                        OnThisDayCard(
                            title: highlight.title,
                            entry: highlight.entry,
                            appLanguage: appLanguage,
                            onTap: { onTap(highlight.entry) }
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
        }
    }
}

@available(iOS 17.0, *)
private struct OnThisDayCard: View {
    let title: String
    @ObservedObject var entry: DiaryEntry
    let appLanguage: String
    let onTap: () -> Void

    private var previewText: String {
        if let summary = entry.wrappedSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return summary
        }
        return entry.wrappedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        if entry.managedObjectContext != nil && !entry.isDeleted {
            Button {
                #if canImport(UIKit)
                HapticManager.shared.impact(.light)
                #endif
                onTap()
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(entry.moodColor)

                        Text(title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)

                        Spacer(minLength: 0)

                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary.opacity(0.7))
                    }

                    Text(LumoryDateFormatters.monthDay(language: appLanguage).string(from: entry.wrappedDate))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if !previewText.isEmpty {
                        Text(previewText)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .lineSpacing(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(width: 260, alignment: .leading)
                .frame(minHeight: 104, alignment: .top)
                // §4.6 (2026-05-19) — `.liquidGlassCard + .moodAccentBar` 配对走共享 modifier。
                .lumoryAccentCard(mood: entry.moodColor, cornerRadius: LumoryCornerRadius.inline)
            }
            .buttonStyle(PressableScaleButtonStyle())
            .accessibilityLabel("\(title), \(LumoryDateFormatters.monthDay(language: appLanguage).string(from: entry.wrappedDate))")
        }
    }
}
