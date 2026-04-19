import SwiftUI
import CoreData

// MARK: - Design A · Morning Letter
//
// 极简晨信风：浮动图标、大号 serif 日期、mood 小色条、轻量输入卡、
// 条目列表用左侧 mood 色条 + 干净排版，不做 section header 分组。

struct DesignAMorningLetter: View {
    let entries: [DiaryEntry]

    private let H = DesignPreviewHelpers.self

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 56)
                    heroDate
                    compactInput
                        .padding(.top, 28)
                    entriesList
                        .padding(.top, 32)
                }
            }

            floatingTopBar
        }
        .background(Color(.systemBackground))
    }

    // MARK: - Top bar

    private var floatingTopBar: some View {
        HStack {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 19, weight: .regular))
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .regular))
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 18, weight: .regular))
                .padding(.leading, 16)
        }
        .foregroundColor(.primary.opacity(0.55))
        .padding(.horizontal, 22)
        .padding(.top, 14)
    }

    // MARK: - Hero

    private var heroDate: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(H.fullWeekday(Date()))
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(1.5)
            Text(H.bigDate(Date()))
                .font(.system(size: 36, weight: .semibold, design: .serif))
                .foregroundColor(.primary)
            Capsule()
                .fill(Color.moodSpectrum(value: H.avgMood(entries)).opacity(0.8))
                .frame(width: 40, height: 3)
                .padding(.top, 8)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    // MARK: - Compact input stub

    private var compactInput: some View {
        HStack(spacing: 10) {
            Text("今天怎么样？")
                .font(.system(size: 16))
                .foregroundColor(.secondary.opacity(0.7))
            Spacer()
            Image(systemName: "mic")
                .foregroundColor(.secondary)
            Image(systemName: "photo")
                .foregroundColor(.secondary)
                .padding(.leading, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.07))
        )
        .padding(.horizontal, 20)
    }

    // MARK: - Entries

    private var entriesList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.prefix(40)), id: \.objectID) { entry in
                letterRow(for: entry)
                Divider()
                    .padding(.leading, 44)
                    .opacity(0.4)
            }
        }
        .padding(.bottom, 40)
    }

    @ViewBuilder
    private func letterRow(for entry: DiaryEntry) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Capsule()
                .fill(Color.moodSpectrum(value: entry.moodValue))
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(H.relativeDateLabel(entry.date))
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    Text(H.time(entry.date))
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.6))
                    Spacer()
                }

                if let summary = entry.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }
                Text(entry.text ?? "")
                    .font(.system(size: 15))
                    .foregroundColor(.primary.opacity(0.75))
                    .lineLimit(2)
                    .lineSpacing(3)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .contentShape(Rectangle())
    }
}
