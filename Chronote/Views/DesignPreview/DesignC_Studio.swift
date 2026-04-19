import SwiftUI
import CoreData

// MARK: - Design C · Studio
//
// 创作者风：顶部 hero 卡（今日大色块 + 连续天数 + 简单气候图标），
// 下方紧凑列表，底部 sticky 聊天式输入框（像 iMessage）。
// 情绪可视化最强。

struct DesignCStudio: View {
    let entries: [DiaryEntry]

    private let H = DesignPreviewHelpers.self

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    topBar
                        .padding(.top, 10)
                    heroCard
                        .padding(.horizontal, 16)
                    recentSection
                    Color.clear.frame(height: 16)
                }
            }
            .background(Color(.systemBackground))

            stickyInput
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
        .padding(.horizontal, 18)
    }

    // MARK: - Hero

    private var heroCard: some View {
        let avg = H.avgMood(entries, lookback: 3)
        return ZStack {
            LinearGradient(
                colors: [
                    Color.moodSpectrum(value: avg).opacity(0.85),
                    Color.moodSpectrum(value: min(1, avg + 0.1)).opacity(0.55),
                    Color.moodSpectrum(value: max(0, avg - 0.1)).opacity(0.45)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(H.bigDate(Date()))
                            .font(.system(size: 14, weight: .semibold))
                        Text(H.fullWeekday(Date()))
                            .font(.caption2)
                            .foregroundColor(.primary.opacity(0.7))
                    }
                    Spacer()
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(.yellow, .primary.opacity(0.35))
                }
                Spacer()
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text("\(H.streak(entries))")
                        .font(.system(size: 54, weight: .bold, design: .rounded))
                    Text("天")
                        .font(.system(size: 18, weight: .semibold))
                        .offset(y: -4)
                    Spacer()
                }
                Text("连续记录")
                    .font(.caption)
                    .foregroundColor(.primary.opacity(0.7))
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundColor(.primary)
        }
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: - Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("最近")
                    .font(.title3.weight(.bold))
                Spacer()
                Text("\(entries.count) 条")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)

            VStack(spacing: 10) {
                ForEach(Array(entries.prefix(15)), id: \.objectID) { entry in
                    compactCard(for: entry)
                }
            }
        }
    }

    @ViewBuilder
    private func compactCard(for entry: DiaryEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.moodSpectrum(value: entry.moodValue))
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.summary ?? "无标题")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(H.relativeDateLabel(entry.date))
                        .font(.caption2.weight(.medium))
                        .foregroundColor(.secondary)
                }
                Text(entry.text ?? "")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .lineSpacing(2)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
        .padding(.horizontal, 16)
    }

    // MARK: - Sticky input

    private var stickyInput: some View {
        HStack(spacing: 10) {
            Image(systemName: "face.smiling")
                .foregroundColor(.secondary)
                .font(.system(size: 20))

            HStack {
                Text("说点什么…")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary.opacity(0.7))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(Color.secondary.opacity(0.12))
            )

            Image(systemName: "mic.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(Color.moodSpectrum(value: H.avgMood(entries)), Color.secondary.opacity(0.15))

            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 30))
                .foregroundColor(.accentColor)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .padding(.bottom, 2)
        .background(
            .ultraThinMaterial
        )
        .overlay(
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .frame(height: 0.5),
            alignment: .top
        )
    }
}
