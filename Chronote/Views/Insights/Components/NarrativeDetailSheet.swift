import SwiftUI

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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    headlineBlock
                    bodyBlock
                    if payload.isIncomplete {
                        incompleteBanner
                    }
                }
                .padding(.horizontal, 24)
                // 顶部留白:headline 是首个内容,不让它紧贴 navbar(用户决定 2026-05-14)。
                .padding(.top, 24)
                .padding(.bottom, 40)
                .lumoryReadableContent(maxWidth: LumoryAdaptivePresentation.chatContentMaxWidth)
            }
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
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
            }
        }
    }

    // MARK: - Sections

    // **2026-05-14 用户决定**:detail sheet 不显 range 标题("最近一个月")/ 日期 / 篇数,
    // 直接从 AI headline 诗意大字开始。headline 存在时下挂 Divider 跟 body 分隔;headline
    // 缺失(v2 老 cache / incomplete)时整块不渲染,body 直接打头不会出现孤零零的 Divider。
    @ViewBuilder
    private var headlineBlock: some View {
        if let headline = payload.headline, !headline.isEmpty {
            Text(headline)
                .font(LumoryFonts.narrativeBodyTitle)
                .foregroundStyle(.primary.opacity(0.85))
                .lineSpacing(6)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Divider()
        }
    }

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
