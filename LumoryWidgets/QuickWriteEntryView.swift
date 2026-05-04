import SwiftUI
import WidgetKit

struct QuickWriteEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuickWriteEntry

    var body: some View {
        Group {
            switch family {
            case .systemSmall:
                smallLayout
            case .systemMedium:
                mediumLayout
            case .systemLarge:
                largeLayout
            default:
                smallLayout
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "lumory://compose"))
    }

    // MARK: - Small

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "pencil.and.scribble")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Spacer()
                moodDot
            }
            Spacer()
            Text(stateTitle)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(streakLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Medium

    private var mediumLayout: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "pencil.and.scribble")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Spacer()
                Text(stateTitle)
                    .font(.headline)
                Text(streakLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                todayMoodBar
                statsLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Large

    private var largeLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Image(systemName: "pencil.and.scribble")
                        .font(.title)
                        .foregroundStyle(.tint)
                    Text(stateTitle)
                        .font(.title3.bold())
                }
                Spacer()
                moodDot
                    .frame(width: 28, height: 28)
            }

            HStack(spacing: 16) {
                statBlock(value: "\(entry.effectiveStreak)", label: NSLocalizedString("widget.stats.streak", comment: ""))
                statBlock(value: "\(entry.totalEntries)", label: NSLocalizedString("widget.stats.total_entries", comment: ""))
                statBlock(value: "\(entry.totalWords)", label: NSLocalizedString("widget.stats.total_words", comment: ""))
                statBlock(value: "\(entry.longestStreak)", label: NSLocalizedString("widget.stats.longest_streak", comment: ""))
            }

            Divider()

            if entry.recent.isEmpty {
                Text(NSLocalizedString("widget.empty.no_entries", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(NSLocalizedString("widget.recent.title", comment: ""))
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ForEach(entry.recent.prefix(3)) { snippet in
                        recentRow(snippet)
                    }
                }
            }
        }
    }

    // MARK: - Pieces

    private var stateTitle: String {
        if entry.wroteToday {
            return NSLocalizedString("widget.state.recorded", comment: "")
        } else {
            return NSLocalizedString("widget.cta.write_today", comment: "")
        }
    }

    private var streakLine: String {
        if entry.effectiveStreak > 0 {
            return String(format: NSLocalizedString("widget.streak.day_count", comment: ""), entry.effectiveStreak)
        } else {
            return NSLocalizedString("widget.streak.zero", comment: "")
        }
    }

    /// 今日心情语义:今天写过 → 用 lastEntryMood 染色;今天没写 → neutral 灰色。
    /// **不**用历史 mood 冒充今日心情。
    @ViewBuilder
    private var moodDot: some View {
        if entry.wroteToday, let mood = entry.lastEntryMood {
            Circle().fill(Color.moodSpectrum(value: mood))
        } else {
            Circle().fill(Color.gray.opacity(0.4))
        }
    }

    @ViewBuilder
    private var todayMoodBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(NSLocalizedString("widget.mood.today", comment: ""))
                .font(.caption2)
                .foregroundStyle(.secondary)
            RoundedRectangle(cornerRadius: 4)
                .fill(moodBarColor)
                .frame(height: 8)
        }
    }

    private var moodBarColor: Color {
        if entry.wroteToday, let mood = entry.lastEntryMood {
            return Color.moodSpectrum(value: mood)
        } else {
            return Color.gray.opacity(0.3)
        }
    }

    @ViewBuilder
    private var statsLine: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: NSLocalizedString("widget.stats.entries_words", comment: ""),
                       entry.totalEntries, entry.totalWords))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func statBlock(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.bold())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func recentRow(_ snippet: WidgetSnapshot.Snippet) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.moodSpectrum(value: snippet.moodValue))
                .frame(width: 8, height: 8)
            Text(formatRecentDate(snippet.date))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
            Text(snippet.displayText ?? NSLocalizedString("widget.recent.fallback", comment: ""))
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    private func formatRecentDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd"
        return formatter.string(from: date)
    }
}
