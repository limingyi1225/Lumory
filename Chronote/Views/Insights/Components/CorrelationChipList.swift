import SwiftUI

// MARK: - CorrelationChipList
//
// 第三块：AI 生成的 3-5 条关联洞察事实，用短卡片展示。
// Phase 1 里先从本地统计计算出发；Phase 1.3 再把 AI 生成的自然语言版本接上。

struct CorrelationFact: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case overall         // 整体均值
        case topTheme        // 最高频主题
        case bestMoodTheme   // 情绪最好的主题
        case worstMoodTheme  // 情绪最差的主题
        case streak          // 连续书写
    }

    let kind: Kind
    let title: String
    let value: String
    let systemIcon: String
    let isPositive: Bool

    /// 稳定 id：以 kind 为主键。同一类型只会在列表里出现一次，避免 SwiftUI diff 抖动。
    var id: String { kind.rawValue }
}

struct CorrelationChipList: View {
    let facts: [CorrelationFact]
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(NSLocalizedString("关联洞察", comment: "Correlation insights"))
                    .font(.headline)
                Spacer()
                if isLoading {
                    ProgressView().scaleEffect(0.7)
                }
            }

            if facts.isEmpty && !isLoading {
                Text(NSLocalizedString("更多数据后，这里会浮现模式", comment: "Empty correlations"))
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(facts) { fact in
                        CorrelationChip(fact: fact)
                    }
                }
            }
        }
        .padding(16)
        .insightsCard()
    }
}

struct CorrelationChip: View {
    let fact: CorrelationFact

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: fact.systemIcon)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(accent)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 30, height: 30)
                .background(Circle().fill(accent.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(fact.title)
                    .font(.footnote)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(fact.value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .accessibilityElement(children: .combine)
    }

    private var accent: Color {
        fact.isPositive ? Color.moodSpectrum(value: 0.85) : Color.moodSpectrum(value: 0.15)
    }
}

// MARK: - Local fact generator
//
// Phase 1 使用本地统计生成事实，不依赖 AI —— 保证 Dashboard 冷启动秒出。
// 生成器是纯函数：同样的输入 → 同样的 facts，便于测试和缓存。

enum CorrelationFactGenerator {
    static func generate(
        points: [InsightsEngine.MoodPoint],
        themes: [InsightsEngine.Theme],
        stats: InsightsEngine.WritingStats
    ) -> [CorrelationFact] {
        var facts: [CorrelationFact] = []

        // 1. 本段时间平均 vs 中性
        if !points.isEmpty {
            let avg = points.reduce(0) { $0 + $1.mood } / Double(points.count)
            let delta = avg - 0.5
            facts.append(CorrelationFact(
                kind: .overall,
                title: delta >= 0
                    ? NSLocalizedString("这段时间整体偏积极", comment: "Overall positive")
                    : NSLocalizedString("这段时间整体偏低落", comment: "Overall low"),
                value: String(format: "%@%.0f", delta >= 0 ? "+" : "", delta * 100),
                systemIcon: delta >= 0 ? "arrow.up.right.circle" : "arrow.down.right.circle",
                isPositive: delta >= 0
            ))
        }

        // 2. 最显著的主题
        if let top = themes.first {
            facts.append(CorrelationFact(
                kind: .topTheme,
                title: String(format: NSLocalizedString("最常出现的是 %@", comment: "Top theme"), top.name),
                value: String(format: NSLocalizedString("%d 次", comment: "N occurrences"), top.count),
                systemIcon: "tag.fill",
                isPositive: top.avgMood >= 0.5
            ))
        }

        // 3. 情绪最高/低的主题
        if themes.count >= 2 {
            let sortedByMood = themes.sorted { $0.avgMood > $1.avgMood }
            if let best = sortedByMood.first, let worst = sortedByMood.last, best.name != worst.name {
                facts.append(CorrelationFact(
                    kind: .bestMoodTheme,
                    title: String(format: NSLocalizedString("写到 %@ 时情绪最好", comment: "Best mood theme"), best.name),
                    value: String(format: "%.0f/100", best.avgMood * 100),
                    systemIcon: "sun.max.fill",
                    isPositive: true
                ))
                facts.append(CorrelationFact(
                    kind: .worstMoodTheme,
                    title: String(format: NSLocalizedString("写到 %@ 时情绪最低", comment: "Worst mood theme"), worst.name),
                    value: String(format: "%.0f/100", worst.avgMood * 100),
                    systemIcon: "cloud.fill",
                    isPositive: false
                ))
            }
        }

        // 4. 连续天数
        if stats.currentStreak >= 3 {
            facts.append(CorrelationFact(
                kind: .streak,
                title: NSLocalizedString("保持书写的势头", comment: "Streak encouragement"),
                value: String(format: NSLocalizedString("连续 %d 天", comment: "N-day streak"), stats.currentStreak),
                systemIcon: "flame.fill",
                isPositive: true
            ))
        }

        return Array(facts.prefix(5))
    }
}
