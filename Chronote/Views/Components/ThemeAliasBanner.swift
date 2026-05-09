import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - ThemeAliasBanner
//
// Home 顶部软提示。看到 ThemeAliasResolver 有 high-confidence pending 建议
// 就滑下来,问"「宝贝」是不是 Abby?",带 [合并到 Abby] / [合并到 宝贝] / [自定义...] / [稍后] / [不是]。
//
// 设计原则:
//   - 不是 sheet/alert,不打断主流程,液态玻璃 + 5 秒折叠 + 可手动滑掉
//   - 录音/输入中(busy 参数)不展示
//   - high 优先,无 high 时 fallback 任意 pending(包括 medium)。早期"只 high 弹"在
//     用户测试中体感割裂(跨语言 / 昵称对应 AI 经常给 medium,banner 长时间不出 →
//     用户感觉没在工作),改成全等价处理。冷却期(coolUntil)期间整体不弹。
//   - 同一会话最多展示一次(由 sessionShown 守卫)

struct ThemeAliasBanner: View {
    @ObservedObject var resolver: ThemeAliasResolver
    /// 父视图传入"是否处于录音 / 编辑 / 输入态" —— 这些状态下绝对不弹。
    let isBusy: Bool

    @State private var isCollapsed: Bool = false
    @State private var collapseWorkItem: DispatchWorkItem?
    /// Picker sheet 的稳定承载点 —— 放在 banner 顶层 state,**不**绑在 `content(for:)` 子树。
    /// 之前用 `@State Bool` + `.sheet(isPresented:)` 挂在 content 内,父级 `Group { if let topSuggestion, !isBusy }`
    /// 一旦在 sheet 打开期间翻成 nil/true(下一条 pending 解析、recording 启动…)就把整个 content 子树拆掉,
    /// sheet 跟着死,用户搜索/选择被无情打断。改成 `.sheet(item:)` 挂在外层 Group 之上,即使 banner content 离开
    /// 视图树 sheet 还在 `pickerSubject` 上活着,picker 自己 dismiss 才回 nil。
    @State private var pickerSubject: PendingSuggestion?

    /// high 优先 + medium 兜底 —— 跨语言/昵称对应 AI 经常给 medium,只弹 high 用户测试时
    /// 看不到 banner(只有红点,体感割裂)。两种都弹,医动作一致(保存为/更多/忽略)。
    /// 用户处理完一条 banner 自动切到下一条;队列空 banner 自然消失。
    /// 连续 reject 多次进入 7 天冷却(resolver.coolUntil)期间 banner 整体不弹。
    private var topSuggestion: PendingSuggestion? {
        if let coolUntil = resolver.coolUntil, Date() < coolUntil { return nil }
        return resolver.pending.first { $0.confidence == .high }
            ?? resolver.pending.first
    }

    private var shouldDisplay: Bool {
        topSuggestion != nil && !isBusy
    }

    var body: some View {
        // 始终在树里,但不显示时返回 EmptyView,这样切换 high-confidence pending 时
        // 父级的 safeAreaInset 不会闪烁尺寸。
        Group {
            if let suggestion = topSuggestion, !isBusy {
                content(for: suggestion)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                EmptyView()
            }
        }
        .animation(AnimationConfig.bannerAppear, value: shouldDisplay)
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: isCollapsed)
        // **关键**:.sheet 挂在 Group 之上(条件渲染之外),sheet 的承载视图永远在树里。
        // 之前挂在 `content(for:)` 内,topSuggestion 变 nil 或 isBusy 翻 true 时整个 content 子树
        // 被拆掉,sheet 跟着死 —— 用户在 picker 里选择被无情打断。
        .sheet(item: $pickerSubject) { subject in
            SuggestionTargetPickerSheet(suggestion: subject) { chosen in
                confirm(suggestion: subject, canonical: chosen)
            }
            .lumorySheetDecoration()
        }
        .onChange(of: pickerSubject != nil) { _, presented in
            // sheet 打开期间暂停自动折叠;关掉后再起 5 秒计时(若 banner 还在树里)。
            if presented {
                collapseWorkItem?.cancel()
                collapseWorkItem = nil
            } else {
                scheduleCollapse()
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(for suggestion: PendingSuggestion) -> some View {
        VStack(spacing: 8) {
            if isCollapsed {
                collapsedRow(for: suggestion)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .id("collapsed")
            } else {
                expandedCard(for: suggestion)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .id("expanded-\(suggestion.id.uuidString)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        // .sheet 已挪到 body 顶层 Group 之上(`pickerSubject` 驱动) —— 这里不再挂,
        // 避免 content(for:) 子树离开视图树时 sheet 被拆。
        .onAppear {
            scheduleCollapse()
        }
        .onChange(of: suggestion.id) { _, _ in
            // 切到下一条建议:重置折叠 + 重新计时
            isCollapsed = false
            scheduleCollapse()
        }
        .onDisappear {
            collapseWorkItem?.cancel()
            collapseWorkItem = nil
        }
    }

    // MARK: - Expanded card

    @ViewBuilder
    private func expandedCard(for suggestion: PendingSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(headline(for: suggestion))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    collapse(haptic: false)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("折叠", comment: "Collapse"))
            }

            buttonRow(for: suggestion)
        }
        .padding(14)
        // 中性 liquid glass —— 跟 picker / pendingCard / 待审卡片设计统一(用户要求)。
        // sparkles icon 自身已是 accent 色,够提示"有 actionable 建议",卡片本体 tint 反而过载。
        .liquidGlassCard(cornerRadius: 18, interactive: false)
        // P1-Dark-3 阴影 0.06 在 OLED 暗色不可见,提到 0.18 让卡片有 depth。
        .shadow(color: Color.primary.opacity(0.18), radius: 10, y: 3)
        // .sheet 已挪到 content(for:) 那一层 —— 这里不再挂,避免折叠时 sheet 被拆。
    }

    @ViewBuilder
    private func buttonRow(for suggestion: PendingSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 主操作:合并到 AI 推的 canonical(撑满整行,视觉最显眼)
            actionChip(
                title: String(format: NSLocalizedString("合并到 %@", comment: "Merge into canonical"), suggestion.canonicalGuess),
                style: .primary,
                fullWidth: true
            ) {
                confirm(suggestion: suggestion, canonical: suggestion.canonicalGuess)
            }

            // 次要行:换名字 + 忽略。secondary 撑满次行剩余宽度,忽略自然宽度。
            HStack(spacing: 8) {
                actionChip(
                    title: String(
                        format: NSLocalizedString("把「%@」合并到其他主题", comment: "Pick another canonical for newTag"),
                        suggestion.newTag
                    ),
                    style: .secondary,
                    fullWidth: true
                ) {
                    pickerSubject = suggestion
                }

                actionChip(
                    title: NSLocalizedString("忽略", comment: "Reject (ignore) merge"),
                    style: .ghost
                ) {
                    reject(suggestion: suggestion)
                }
            }
        }
    }

    // MARK: - Collapsed row

    @ViewBuilder
    private func collapsedRow(for suggestion: PendingSuggestion) -> some View {
        // 折叠态做成左对齐的紧凑 pill,不拉满整行 —— 视觉上更轻盈,
        // 暗示"软提示"而非"占位拦截"。点开后回到 expanded 卡片。
        // 数 high + medium —— banner 都弹,跟 redDot 保持一致。
        let count = resolver.pending.count
        HStack {
            Button {
                #if canImport(UIKit)
                HapticManager.shared.click()
                #endif
                isCollapsed = false
                scheduleCollapse()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(String(
                        format: NSLocalizedString("%d 条主题建议", comment: "Banner collapsed pending count"),
                        count
                    ))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.primary)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                // 中性 glass —— sparkles icon 自身已是 accent 色,够提示"有 actionable 建议"
                .liquidGlassCapsule(interactive: true)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Helpers

    private func headline(for suggestion: PendingSuggestion) -> String {
        String(
            format: NSLocalizedString("「%@」是不是 %@?", comment: "Banner headline"),
            suggestion.newTag,
            suggestion.canonicalGuess
        )
    }

    private func scheduleCollapse() {
        collapseWorkItem?.cancel()
        let item = DispatchWorkItem {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                isCollapsed = true
            }
        }
        collapseWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: item)
    }

    private func collapse(haptic: Bool) {
        collapseWorkItem?.cancel()
        if haptic {
            #if canImport(UIKit)
            HapticManager.shared.click()
            #endif
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
            isCollapsed = true
        }
    }

    private func confirm(suggestion: PendingSuggestion, canonical: String) {
        #if canImport(UIKit)
        HapticManager.shared.notification(.success)
        #endif
        resolver.confirm(suggestion, canonical: canonical)
        // P0-2 全局 toast — 跟 Detail 保存 / Home 删除统一语言。"已合并到 X"。
        LumoryToastCenter.shared.show(
            String(format: NSLocalizedString("已合并到「%@」", comment: "Toast after merging theme alias"), canonical),
            severity: .success
        )
        // 处理完一条 → banner 自动切到下一条 pending(如果有)。重置折叠 + 重启 5s 计时。
        advanceToNext()
    }

    private func reject(suggestion: PendingSuggestion) {
        #if canImport(UIKit)
        HapticManager.shared.click()
        #endif
        resolver.reject(suggestion)
        // 同上:reject 后 advance 到下一条。resolver 内部 bumpDismissCount 连续 3 次进 7 天冷却。
        advanceToNext()
    }

    /// confirm/reject 后 banner 自动 advance 到下一条 pending —— 队列空 banner 自然消失。
    /// 重置折叠状态 + 重启 5s 计时,让用户对新一条有清晰的视觉切换。
    private func advanceToNext() {
        isCollapsed = false
        scheduleCollapse()
    }
}

// MARK: - Action chip

private struct ActionChipStyle {
    enum Variant { case primary, secondary, ghost }
}

private extension ThemeAliasBanner {
    @ViewBuilder
    func actionChip(
        title: String,
        style: ActionChipStyle.Variant,
        icon: String? = nil,
        fullWidth: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption.weight(.semibold))
                }
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // **关键**:frame(maxWidth) 必须放在 background modifier 之前,
            // 这样 capsule 背景才会跟着撑满。之前在 Button 外侧加 .frame 只让 hit 区域变宽,
            // capsule 仍然 size-to-fit,视觉上不撑满(就是用户截图看到的那种居中小胶囊)。
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 30)
            .modifier(ChipBackgroundModifier(variant: style))
        }
        .buttonStyle(.plain)
    }
}

private struct ChipBackgroundModifier: ViewModifier {
    let variant: ActionChipStyle.Variant
    func body(content: Content) -> some View {
        switch variant {
        case .primary:
            content
                .foregroundStyle(Color.white)
                .background(
                    Capsule().fill(Color.accentColor)
                )
        case .secondary:
            content
                .foregroundStyle(Color.primary)
                // 中性 glass(去 accent tint)—— 跟 picker / 待审卡片设计一致
                .liquidGlassCapsule(interactive: true)
        case .ghost:
            content
                .foregroundStyle(Color.secondary)
                .background(
                    Capsule().fill(Color.secondary.opacity(0.10))
                )
        }
    }
}
