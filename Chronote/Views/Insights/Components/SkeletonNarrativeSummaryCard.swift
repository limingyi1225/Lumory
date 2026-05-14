import SwiftUI

// MARK: - SkeletonNarrativeSummaryCard
//
// **真 cache miss(第一次切到某 range)** 期间的占位。等 InsightsView.reload 跑完
// entryCount async,通常 100-400ms。曾访问过的 range 走 InsightsResultCache SWR 命中,
// 拿到 cached entryCount 直接渲染真卡,不再走本占位。
//
// **布局策略**:跟新版 NarrativeSummaryCard 主态布局**完全对齐** — 同款
// `[✨] [center bar] []` HStack(.firstTextBaseline)+ 同 padding + 同 corner radius +
// 同 shadow,高度只差 ~2-4pt。原版 skeleton 是 wave14 "header + metadata + 3 行段落"
// 仿排版 ~90pt 高,主卡改成一行后切换时 LazyVStack reflow ~50pt,下面 chart/heatmap
// 视觉错位 → 切 range 整页闪。改成同款高度后切换无 reflow。
//
// **静态占位条**(不 shimmer)— 跟生成期间的 NarrativeSkeletonLoader 区分语义:
// 生成 = 长(3-8s)+ shimmer 表达"AI 在路上";cache miss = 短(<400ms)+ 静态表达
// "数据立刻就到"。两个动画都 shimmer 反而让"长等待"跟"短等待"语义模糊。

struct SkeletonNarrativeSummaryCard: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "sparkles")
                // **P2 fix (2026-05-13 superreview)**:跟 NarrativeSummaryCard 主态 sparkles
                // 字号一致(都是 14 / .semibold),共享 LumoryFonts.narrativeEyebrow token —
                // 后续调 token 时一处生效不再漏。
                .font(LumoryFonts.narrativeEyebrow)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor.opacity(0.45))

            RoundedRectangle(cornerRadius: 7)
                .fill(Color.accentColor.opacity(0.12))
                .frame(height: 14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        // chrome 跟 NarrativeSummaryCard.contentCard 完全一致 — corner / shadow 对齐,切换时
        // 只有内容变,容器不变,LazyVStack 不 reflow。wave16 改用 `.insightsCard()` 去 accent
        // tint,跟下方 WritingHeatmap 同一中性玻璃 token。
        .insightsCard(cornerRadius: LumoryCornerRadius.card)
        .padding(.horizontal, 16)
        .accessibilityHidden(true)  // skeleton 是视觉占位,不向 VoiceOver 报告
    }
}
