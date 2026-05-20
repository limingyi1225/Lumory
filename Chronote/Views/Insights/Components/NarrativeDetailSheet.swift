import SwiftUI
import CoreData
#if canImport(UIKit)
import UIKit
#endif

// MARK: - NarrativeDetailSheet
//
// NarrativeSummaryCard tap 后 present 的沉浸阅读 view。**直接从 AI headline 诗意大字开始**,
// 接完整 body。**不显** range 标题("最近一个月"等)/ 日期 / 篇数 —— 沉浸阅读页只要内容本身
// (用户决定 2026-05-14),时间窗口归 InsightsView 卡片侧表达。
//
// 用 `lumoryAdaptiveModal(item:)` 模式 present(parent 用 `NarrativeDetailSubject` 包 payload),
// payload 是 snapshot 拷贝(struct value type),sheet 期间 parent state 变化(range reload /
// stream 完成)不影响 detail 渲染。
//
// **wave17 删除右上角"重新生成"按钮**(用户决定 2026-05-13)。Settings 的"清除 AI 回顾缓存"已
// 给用户重生成的兜底入口,detail 内仍保留同款按钮反而让"沉浸阅读"页面产生 CTA 冲突。

struct NarrativeDetailSheet: View {
    let payload: AIConversation.NarrativePayload

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.managedObjectContext) private var viewContext

    /// §2.3 (2026-05-19) — narrative 回顾历史入口。从这里 present 的 ConversationHistoryView 只显
    /// `.narrative` kind,跟 AskPastView 的"提问历史"完全分开,不再用 mixed 列表。
    @State private var showHistory: Bool = false
    @State private var moodProfile: NarrativeDetailMoodProfile = .empty

    var body: some View {
        NavigationStack {
            ZStack {
                NarrativeDetailAmbientBackground(payload: payload, moodProfile: moodProfile)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        headlineBlock
                        bodyBlock
                        if payload.isIncomplete {
                            incompleteBanner
                        }
                        provenanceFooter
                    }
                    .padding(.horizontal, 24)
                    // 上方留白:整体上移，与透明导航栏更紧凑地融合
                    .padding(.top, hSizeClass == .compact ? -8 : -12)
                    .padding(.bottom, 40)
                    .lumoryReadableContent(maxWidth: LumoryAdaptivePresentation.chatContentMaxWidth)
                }
            }
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            #endif
            .toolbar {
                // iPad / regular size class 走 fullScreenCover 没有下拉手势,留小关闭按钮兜底。
                if hSizeClass == .regular {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel(NSLocalizedString("关闭", comment: "Close"))
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    historyIconButton
                }
            }
            .lumoryAdaptiveModal(isPresented: $showHistory) {
                ConversationHistoryView(filterKind: .narrative)
                    .environment(\.managedObjectContext, viewContext)
            }
            .task(id: moodProfileTaskID) {
                let loaded = await NarrativeDetailMoodProfile.load(
                    rangeStart: payload.rangeStart,
                    rangeEnd: payload.rangeEnd
                )
                guard !Task.isCancelled else { return }
                moodProfile = loaded
            }
        }
    }

    private var moodProfileTaskID: String {
        "\(payload.rangeStart.timeIntervalSinceReferenceDate)-\(payload.rangeEnd.timeIntervalSinceReferenceDate)"
    }

    private var historyIconButton: some View {
        Button {
            #if canImport(UIKit)
            HapticManager.shared.impact(.light)
            #endif
            showHistory = true
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("回顾历史", comment: "Reflection history"))
        .accessibilityIdentifier("narrativeDetailHistoryButton")
    }

    @ViewBuilder
    private var headlineBlock: some View {
        Group {
            if let headline = payload.headline, !headline.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(headline)
                        .font(LumoryFonts.narrativeBodyTitle)
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                }
            }
        }
    }

    /// §2.6 P2-03 (2026-05-19) — 沉浸阅读底部 provenance:range · 篇数 · 生成时间。
    /// 用户能快速验证"这段来自哪个时间窗 / 多少篇日记 / 什么时候算的",建立信任。
    @ViewBuilder
    private var provenanceFooter: some View {
        // (2026-05-19 user feedback round 2) 删 info.circle 图标 — 灰字本身已足够 self-evident,
        // i-in-circle 视觉上像可点击 affordance 但实际只是装饰,反而让用户疑惑要不要 tap。
        let parts = provenanceParts
        if !parts.isEmpty {
            HStack(spacing: 6) {
                Text(parts.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
        }
    }

    /// 拼接 provenance 文本片段 — range / 篇数 / 生成时间,缺哪段就跳哪段(v1 老 cache 兼容)。
    private var provenanceParts: [String] {
        var parts: [String] = []
        let rangeStr = rangeLabel(start: payload.rangeStart, end: payload.rangeEnd)
        if !rangeStr.isEmpty { parts.append(rangeStr) }
        if let count = payload.entryCount, count > 0 {
            parts.append(String(
                format: NSLocalizedString("%d 篇日记", comment: "Narrative provenance entry count"),
                count
            ))
        }
        if let generatedAt = payload.generatedAt {
            parts.append(String(
                format: NSLocalizedString("生成于 %@", comment: "Narrative provenance generated time"),
                LumoryDateFormatters.fullDateTime.string(from: generatedAt)
            ))
        }
        return parts
    }

    private func rangeLabel(start: Date, end: Date) -> String {
        let f = LumoryDateFormatters.monthDay
        return "\(f.string(from: start)) – \(f.string(from: end))"
    }

    // MARK: - Sections

    private var bodyBlock: some View {
        // wave17 — Text → MarkdownText 渲染。narrative body 现在可以走 # 标题 / **bold** / list /
        // > quote / `code` 等 markdown 块级语义,跟 AskPastView 一致(AskPastView 也用 MarkdownText)。
        // 老 narrative cache 里的纯文本仍能正确渲染(MarkdownText 容错纯文本 → 单段落)。
        MarkdownText(
            markdown: payload.body,
            inlineFont: .body,
            lineSpacing: 6,
            preserveLineBreaks: true
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private var incompleteBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            Text(NSLocalizedString("narrative.summary.incomplete", comment: "Incomplete hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let reason = payload.truncatedReason, !reason.isEmpty {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .liquidGlassCard(
            cornerRadius: LumoryCornerRadius.inline,
            tint: Color.orange,
            tintStrength: 0.14
        )
    }

}

private struct NarrativeDetailMoodProfile: Equatable {
    let count: Int
    let avgMood: Double
    let moodLow: Double
    let moodHigh: Double
    let lowCount: Int
    let highCount: Int

    static let empty = NarrativeDetailMoodProfile(
        count: 0,
        avgMood: 0.5,
        moodLow: 0.5,
        moodHigh: 0.5,
        lowCount: 0,
        highCount: 0
    )

    var isMixed: Bool {
        lowCount >= 1
            && highCount >= 1
            && (moodHigh - moodLow) >= 0.22
    }

    var highShare: Double {
        Double(highCount) / max(1.0, Double(count))
    }

    var lowShare: Double {
        Double(lowCount) / max(1.0, Double(count))
    }

    static func load(rangeStart: Date, rangeEnd: Date) async -> NarrativeDetailMoodProfile {
        await PersistenceController.shared.container.performBackgroundTask { context -> NarrativeDetailMoodProfile in
            let request = NSFetchRequest<NSDictionary>(entityName: "DiaryEntry")
            request.resultType = .dictionaryResultType
            request.predicate = NSPredicate(
                format: "date >= %@ AND date <= %@",
                rangeStart as NSDate,
                rangeEnd as NSDate
            )
            request.propertiesToFetch = ["moodValue"]

            guard let rows = try? context.fetch(request) else { return .empty }
            let moods = rows.compactMap { row -> Double? in
                (row["moodValue"] as? NSNumber)?.doubleValue
            }
            return make(from: moods)
        }
    }

    private static func make(from moods: [Double]) -> NarrativeDetailMoodProfile {
        guard !moods.isEmpty else { return .empty }
        let avg = moods.reduce(0, +) / Double(moods.count)
        // 跟 ThemeCard 一致:0.45/0.55 是 mood spectrum 的中性带,不计入两极色斑。
        let lowMoods = moods.filter { $0 < 0.45 }
        let highMoods = moods.filter { $0 > 0.55 }
        let moodLow = lowMoods.isEmpty ? avg : lowMoods.reduce(0, +) / Double(lowMoods.count)
        let moodHigh = highMoods.isEmpty ? avg : highMoods.reduce(0, +) / Double(highMoods.count)
        return NarrativeDetailMoodProfile(
            count: moods.count,
            avgMood: avg,
            moodLow: moodLow,
            moodHigh: moodHigh,
            lowCount: lowMoods.count,
            highCount: highMoods.count
        )
    }
}

private struct NarrativeDetailAmbientBackground: View {
    let payload: AIConversation.NarrativePayload
    let moodProfile: NarrativeDetailMoodProfile

    @Environment(\.colorScheme) private var colorScheme

    private var baseColor: Color {
        #if canImport(UIKit)
        Color(UIColor.systemBackground)
        #else
        Color.white
        #endif
    }

    private var seed: Int {
        let key = "\(payload.rangeKind ?? "narrative")|\(payload.headline ?? "")|\(payload.rangeStart.timeIntervalSince1970)"
        var hash = 5381
        for byte in key.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ Int(byte)
        }
        return hash & .max
    }

    private var avgColor: Color {
        Color.moodSpectrum(value: moodProfile.avgMood)
    }

    private var lowColor: Color {
        Color.moodSpectrum(value: moodProfile.moodLow)
    }

    private var highColor: Color {
        Color.moodSpectrum(value: moodProfile.moodHigh)
    }

    private var washOpacity: Double {
        colorScheme == .dark ? 0.38 : 0.27
    }

    private static let mixedAnchors: [(high: UnitPoint, low: UnitPoint)] = [
        (.bottomTrailing, .topLeading),
        (.bottomLeading, .topTrailing)
    ]

    private static let solidAnchors: [UnitPoint] = [
        .topLeading, .topTrailing, .bottomLeading, .bottomTrailing,
        .top, .bottom, .leading, .trailing
    ]

    private func blobRadius(share: Double, in size: CGSize) -> CGFloat {
        let diagonal = hypot(size.width, size.height)
        return diagonal * (0.38 + 0.62 * CGFloat(share))
    }

    private func solidBlobRadius(in size: CGSize) -> CGFloat {
        hypot(size.width, size.height) * 0.94
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                baseColor

                if moodProfile.isMixed {
                    let pair = Self.mixedAnchors[seed % Self.mixedAnchors.count]
                    RadialGradient(
                        gradient: Gradient(colors: [avgColor.opacity(washOpacity * 0.28), avgColor.opacity(0)]),
                        center: .center,
                        startRadius: 0,
                        endRadius: solidBlobRadius(in: geo.size)
                    )
                    RadialGradient(
                        gradient: Gradient(colors: [highColor.opacity(washOpacity), highColor.opacity(0)]),
                        center: pair.high,
                        startRadius: 0,
                        endRadius: blobRadius(share: moodProfile.highShare, in: geo.size)
                    )
                    RadialGradient(
                        gradient: Gradient(colors: [lowColor.opacity(washOpacity), lowColor.opacity(0)]),
                        center: pair.low,
                        startRadius: 0,
                        endRadius: blobRadius(share: moodProfile.lowShare, in: geo.size)
                    )
                    RadialGradient(
                        gradient: Gradient(colors: [baseColor.opacity(colorScheme == .dark ? 0.46 : 0.62), baseColor.opacity(0)]),
                        center: .center,
                        startRadius: 0,
                        endRadius: hypot(geo.size.width, geo.size.height) * 0.34
                    )
                } else {
                    let anchor = Self.solidAnchors[seed % Self.solidAnchors.count]
                    RadialGradient(
                        gradient: Gradient(colors: [avgColor.opacity(washOpacity + 0.06), avgColor.opacity(0)]),
                        center: anchor,
                        startRadius: 0,
                        endRadius: solidBlobRadius(in: geo.size)
                    )
                }

                LinearGradient(
                    colors: [
                        baseColor.opacity(colorScheme == .dark ? 0.18 : 0.08),
                        baseColor.opacity(colorScheme == .dark ? 0.34 : 0.26),
                        baseColor.opacity(colorScheme == .dark ? 0.64 : 0.78)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }
}
