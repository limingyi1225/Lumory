import SwiftUI
import CoreData

// MARK: - Design B · Timeline
//
// 杂志式时间线：顶部 14 天 mood 色带做一眼概览，主体是竖直时间线（彩色节点 + 卡片），
// 没有常驻输入，右下角 FAB 打开写作页。适合回看型用户。

struct DesignBTimeline: View {
    let entries: [DiaryEntry]

    private let H = DesignPreviewHelpers.self

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    topBar
                        .padding(.top, 12)
                    headerText
                    moodStrip
                    timelineList
                        .padding(.top, 8)
                    Color.clear.frame(height: 80)
                }
            }
            .background(Color(.systemBackground))

            fab
        }
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
        .foregroundColor(.primary.opacity(0.6))
        .padding(.horizontal, 20)
    }

    private var headerText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Journal")
                .font(.system(size: 28, weight: .bold))
            Text(H.bigDate(Date()))
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Mood strip

    private var moodStrip: some View {
        let days = last14Days
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("过去 14 天")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.8)
                Spacer()
                if let avg = days.compactMap({ $0.mood }).average {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.moodSpectrum(value: avg))
                            .frame(width: 8, height: 8)
                        Text("均值")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            HStack(spacing: 3) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(day.mood.map { Color.moodSpectrum(value: $0) } ?? Color.secondary.opacity(0.1))
                        .frame(height: 38)
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private struct DayMood {
        let date: Date
        let mood: Double?
    }

    private var last14Days: [DayMood] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var byDay: [Date: [Double]] = [:]
        for entry in entries {
            guard let date = entry.date else { continue }
            let day = cal.startOfDay(for: date)
            byDay[day, default: []].append(entry.moodValue)
        }
        return (0..<14).reversed().compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let avg = byDay[day]?.average
            return DayMood(date: day, mood: avg)
        }
    }

    // MARK: - Timeline

    private var timelineList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.prefix(25).enumerated()), id: \.element.objectID) { index, entry in
                timelineNode(
                    for: entry,
                    isFirst: index == 0,
                    isLast: index == min(entries.count, 25) - 1
                )
            }
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private func timelineNode(for entry: DiaryEntry, isFirst: Bool, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.secondary.opacity(isFirst ? 0 : 0.2))
                        .frame(width: 1.5, height: 12)
                    Rectangle()
                        .fill(Color.secondary.opacity(isLast ? 0 : 0.2))
                        .frame(width: 1.5)
                }
                Circle()
                    .fill(Color.moodSpectrum(value: entry.moodValue))
                    .frame(width: 14, height: 14)
                    .overlay(
                        Circle()
                            .stroke(Color(.systemBackground), lineWidth: 2.5)
                    )
                    .padding(.top, 8)
            }
            .frame(width: 14)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(H.relativeDateLabel(entry.date))
                        .font(.caption.weight(.bold))
                        .foregroundColor(.primary)
                    Text(H.time(entry.date))
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                if let summary = entry.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 15, weight: .semibold))
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
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.secondary.opacity(0.05))
            )
            .padding(.bottom, 14)
        }
    }

    // MARK: - FAB

    private var fab: some View {
        Button { } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 58, height: 58)
                .background(
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.moodSpectrum(value: H.avgMood(entries)),
                                    Color.moodSpectrum(value: min(1, H.avgMood(entries) + 0.15))
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 6)
                )
        }
        .buttonStyle(.plain)
        .padding(.trailing, 22)
        .padding(.bottom, 28)
    }
}

// MARK: - Helpers

private extension Array where Element == Double {
    var average: Double? {
        guard !isEmpty else { return nil }
        return reduce(0, +) / Double(count)
    }
}
