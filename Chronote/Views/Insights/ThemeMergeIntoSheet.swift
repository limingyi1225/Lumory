import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - ThemeMergeIntoSheet
//
// Insights ThemeCard 长按 → "合并到其他主题" → 这个 sheet。列出所有其他主题让用户选 target。
// 选完后回调 onConfirm(target),InsightsView 走 ThemeAliasResolver.mergeThemes。

struct ThemeMergeSheetOutcome: Equatable {
    let title: String
    let toastMessage: String?
    let isSuccess: Bool

    static func success(title: String, toastMessage: String) -> ThemeMergeSheetOutcome {
        ThemeMergeSheetOutcome(title: title, toastMessage: toastMessage, isSuccess: true)
    }

    static func noop(message: String) -> ThemeMergeSheetOutcome {
        ThemeMergeSheetOutcome(title: message, toastMessage: nil, isSuccess: false)
    }
}

struct ThemeMergeIntoSheet: View {
    let source: InsightsEngine.Theme
    let candidates: [InsightsEngine.Theme]
    let onConfirm: (InsightsEngine.Theme) -> ThemeMergeSheetOutcome
    let onComplete: (ThemeMergeSheetOutcome) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""
    // P1-Ins-16 改全局 toast 后,650ms 庆祝 overlay 整段被删 — 三个相关 @State(confirmingTarget /
    // confirmationTitle / confirmationSucceeded)以及配套 confirmingOverlay 方法 + 6 处条件 modifier
    // 清理(reviewer Wave-D BUG-P1)。`select` guard 因此简化为只看 pendingMergeTarget。
    /// 用户点了 target,但 source 是某个组的成员 → 合并会把组内其他 alias 也搬过去。
    /// 弹 alert 显式列出附带搬移的标签,让用户确认。空 = 无需弹。
    @State private var pendingMergeTarget: InsightsEngine.Theme?
    @State private var pendingMergeCollateral: [String] = []

    private var filteredCandidates: [InsightsEngine.Theme] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return candidates }
        return candidates.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                backgroundGradient.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        sourceHeader
                            .padding(.horizontal, 16)
                            .padding(.top, 8)

                        if filteredCandidates.isEmpty {
                            emptyState
                                .padding(.top, 40)
                        } else {
                            GlassEffectContainer(spacing: 10) {
                                VStack(spacing: 10) {
                                    ForEach(filteredCandidates) { target in
                                        candidateCard(for: target)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 24)
                        }
                    }
                    .lumoryReadableContent(maxWidth: LumoryAdaptivePresentation.formContentMaxWidth)
                }
                .accessibilityIdentifier("themeMergeScrollView")
            }
            .searchable(text: $searchText, prompt: NSLocalizedString("搜索主题", comment: "Search theme prompt"))
            .navigationTitle(NSLocalizedString("合并主题", comment: "Merge themes title"))
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "Cancel")) { dismiss() }
                }
            }
            .alert(
                String(
                    format: NSLocalizedString("合并主题「%@」到「%@」?", comment: "Merge collateral alert title"),
                    source.name,
                    pendingMergeTarget?.name ?? ""
                ),
                isPresented: Binding(
                    get: { pendingMergeTarget != nil },
                    set: { if !$0 { pendingMergeTarget = nil; pendingMergeCollateral = [] } }
                )
            ) {
                Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {
                    pendingMergeTarget = nil
                    pendingMergeCollateral = []
                }
                Button(NSLocalizedString("继续合并", comment: "Confirm merge with collateral")) {
                    if let target = pendingMergeTarget {
                        pendingMergeTarget = nil
                        pendingMergeCollateral = []
                        performConfirm(target: target)
                    }
                }
            } message: {
                Text(String(
                    format: NSLocalizedString("以下别名也会一起搬到目标组:%@", comment: "Merge collateral alert body"),
                    pendingMergeCollateral.map { "「\($0)」" }.joined(separator: "、")
                ))
            }
        }
    }

    // MARK: Subviews

    private var sourceHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(NSLocalizedString("把这个主题合并到", comment: "Merge into header"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.moodSpectrum(value: source.avgMood))
                    .frame(width: 10, height: 10)
                Text(source.name)
                    .font(.title3.weight(.semibold))
                Spacer()
                Text(String(format: NSLocalizedString("%d 次", comment: "Theme count"), source.count))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlassCard(cornerRadius: 14, tint: Color.moodSpectrum(value: source.avgMood), tintStrength: 0.16, interactive: false)
        }
    }

    @ViewBuilder
    private func candidateCard(for target: InsightsEngine.Theme) -> some View {
        Button {
            select(target)
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color.moodSpectrum(value: target.avgMood))
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Text(String(format: NSLocalizedString("%d 次 · 平均情绪 %d",
                                                          comment: "Theme stats line"),
                                target.count, Int(target.avgMood * 100)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Image(systemName: "arrow.triangle.merge")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlassCard(cornerRadius: 14, tint: Color.moodSpectrum(value: target.avgMood), tintStrength: 0.10, interactive: true)
        }
        .buttonStyle(PressableScaleButtonStyle())
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(NSLocalizedString("没有匹配的主题", comment: "No matching themes"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color.moodSpectrum(value: source.avgMood).opacity(0.10),
                Color.clear
            ],
            startPoint: .top,
            endPoint: .center
        )
    }

    // MARK: Actions

    private func select(_ target: InsightsEngine.Theme) {
        guard pendingMergeTarget == nil else { return }
        // mergeThemes 语义:source 若是某 group 的 alias / canonical,**整组**搬到 target。
        // 没被告知的话 long-press 合并感觉只搬一个名字。这里先 preview,有附带搬移就弹 alert。
        let collateral = ThemeAliasResolver.shared.collateralLabels(forMerging: source.name, into: target.name)
        if collateral.isEmpty {
            performConfirm(target: target)
        } else {
            pendingMergeTarget = target
            pendingMergeCollateral = collateral
        }
    }

    private func performConfirm(target: InsightsEngine.Theme) {
        let outcome = onConfirm(target)
        #if canImport(UIKit)
        if outcome.isSuccess {
            HapticManager.shared.notification(.success)
        } else {
            HapticManager.shared.click()
        }
        #endif
        // P1-Ins-16 移除 650ms confirmingOverlay 阻塞 — 批量合并 5 个等 5×650ms 体验差。
        // 立即 dismiss + 经 onComplete 走全局 toast(InsightsView 已接 LumoryToastCenter),
        // 用户感知"sheet 一关 toast 就出"很顺。
        dismiss()
        onComplete(outcome)
    }
}
