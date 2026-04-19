import SwiftUI
import CoreData

// MARK: - Design D · Soft Journal
//
// Material 柔和风：大圆角卡片 + 柔光阴影 + 温和渐变底色，
// 输入卡永远展开（不是占位），条目分组成 "本周/更早"。
// 气质像 Things / Bear，偏书写型。

struct DesignDSoftJournal: View {
    let entries: [DiaryEntry]

    private let H = DesignPreviewHelpers.self

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                topBar
                    .padding(.top, 10)
                inputCard
                weekSection
                earlierSection
                Color.clear.frame(height: 32)
            }
        }
        .background(softBackground)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 18))
            Spacer()
            HStack(spacing: 14) {
                Image(systemName: "magnifyingglass")
                Image(systemName: "chart.xyaxis.line")
            }
            .font(.system(size: 18))
        }
        .foregroundColor(.primary.opacity(0.55))
        .padding(.horizontal, 20)
    }

    // MARK: - Background

    private var softBackground: some View {
        ZStack {
            Color(.systemGroupedBackground)
            LinearGradient(
                colors: [
                    Color.moodSpectrum(value: H.avgMood(entries)).opacity(0.08),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Input card (expanded)

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(H.bigDate(Date()))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(1.0)
                Spacer()
                Text(H.fullWeekday(Date()))
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.7))
            }

            Text("今天是怎样的一天？")
                .font(.system(size: 19, weight: .semibold))
                .foregroundColor(.primary)

            Text("在这里开始写⋯⋯")
                .font(.system(size: 14))
                .foregroundColor(.secondary.opacity(0.7))
                .padding(.top, 2)

            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .frame(height: 1)
                .padding(.top, 4)

            HStack(spacing: 10) {
                softActionButton(icon: "photo", tint: .secondary)
                softActionButton(icon: "mic.fill", tint: .secondary)
                Spacer()
                Image(systemName: "paperplane.fill")
                    .foregroundColor(.white)
                    .font(.system(size: 15, weight: .semibold))
                    .padding(12)
                    .background(
                        Circle()
                            .fill(Color.moodSpectrum(value: H.avgMood(entries)))
                    )
            }
            .padding(.top, 2)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.06), radius: 16, x: 0, y: 4)
        )
        .padding(.horizontal, 16)
    }

    private func softActionButton(icon: String, tint: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 15))
            .foregroundColor(tint)
            .frame(width: 38, height: 38)
            .background(
                Circle()
                    .fill(Color.secondary.opacity(0.12))
            )
    }

    // MARK: - Sections

    private var weekSection: some View {
        let weekEntries = entries.filter { entry in
            guard let date = entry.date else { return false }
            return date >= Date().addingTimeInterval(-7 * 24 * 3600)
        }
        return Group {
            if !weekEntries.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("本周")
                        .font(.title3.weight(.bold))
                        .padding(.horizontal, 20)
                    VStack(spacing: 10) {
                        ForEach(weekEntries, id: \.objectID) { entry in
                            softCard(for: entry)
                        }
                    }
                }
            }
        }
    }

    private var earlierSection: some View {
        let earlier = entries.filter { entry in
            guard let date = entry.date else { return false }
            return date < Date().addingTimeInterval(-7 * 24 * 3600)
        }.prefix(12)
        return Group {
            if !earlier.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("更早")
                        .font(.title3.weight(.bold))
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                    VStack(spacing: 10) {
                        ForEach(Array(earlier), id: \.objectID) { entry in
                            softCard(for: entry)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func softCard(for entry: DiaryEntry) -> some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.moodSpectrum(value: entry.moodValue))
                .frame(width: 5)
                .frame(height: 52)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(H.relativeDateLabel(entry.date))
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(H.moodEmoji(entry.moodValue))
                        .font(.system(size: 13))
                }
                Text(entry.summary ?? entry.text ?? "")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if let text = entry.text, !text.isEmpty, entry.summary?.isEmpty == false {
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary.opacity(0.8))
                        .lineLimit(1)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 2)
        )
        .padding(.horizontal, 16)
    }
}
