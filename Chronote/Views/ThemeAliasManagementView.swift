import SwiftUI
import CoreData

// MARK: - ThemeAliasManagementView
//
// Settings → 主题别名 的承载页。三个区:
//   1) 顶部:扫描已有主题(一次性 LLM scan,把潜在 alias 加入 pending 队列)
//   2) 待审 (pending):每条建议一张玻璃卡 + 合并/不合并/自定义
//   3) 已合并 (groups):列出现有 canonical → aliases,可以 swipe 删除整组 / 长按拆某个 alias

struct ThemeAliasManagementView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @ObservedObject private var resolver = ThemeAliasResolver.shared
    @ObservedObject private var judgeService = ThemeAliasJudgeService.shared

    @State private var customEditorTarget: PendingSuggestion?
    /// 弹"是否真的从所有日记删除这个主题"alert 的目标。
    @State private var groupPendingDeletion: String?
    /// P1-Theme-5 弹"是否拆开"confirmationDialog 的目标。拆开 = 别名变独立主题(可逆,但用户多半再合并)。
    @State private var groupPendingUnmerge: String?
    @State private var showResetNegativeAlert = false
    @State private var deleteFailureMessage: String?
    /// (2026-05-19 P1-10 audit)"全部忽略"确认 — 之前一点直接 clearAllPending 写负对,
    /// 用户经常误以为是"暂时跳过",其实是永久否决。加确认。
    @State private var showClearAllPendingConfirm: Bool = false

    /// 引文 entry 的预取缓存。@State 在 view-local 生命周期内保留,避开了
    /// "每次 render 都同步 fetchSamples → 主线程 jank"(codex P2 fix)。
    /// 用 lightweight DTO 而非 NSManagedObject(后者非 Sendable + 跨 task boundary 风险)。
    @State private var citationCache: [UUID: CitationSnapshot] = [:]

    struct CitationSnapshot: Equatable {
        let id: UUID
        let date: Date
        let snippet: String
    }

    var body: some View {
        Form {
            scanSection
            emptyStateSection
            pendingSection
            groupsSection
            negativeResetSection
        }
        #if os(macOS)
        .listStyle(.plain)
        #else
        .listStyle(.insetGrouped)
        #endif
        .scrollContentBackground(.hidden)
        // 删了原本的 .background(backgroundGradient.ignoresSafeArea()) — 它跟 SettingsView 自己的
        // backgroundGradient 在 NavigationStack push/pop transition 中间帧叠加,造成"暗一闪"。
        // 让此页直接透出 sheet 的纯白底(lumorySheetDecoration 已改纯白),无 overlay = 无 fade-in 闪。
        .navigationTitle(NSLocalizedString("合并主题", comment: "Merge themes title"))
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // P0-2 此页是 Settings 嵌套 sheet,2 层深 — root toast overlay 被 sheet 压住看不见,
        // 必须在这一层重挂,confirm 成功 toast 在用户当前可见层渲染。
        .lumoryToastOverlay()
        // F8 — iPad fullScreenCover(picker sheet 在 Settings → ThemeAlias → 自定义合并 3 层深;
        // iPad formSheet 跟下方 Theme list 浮卡叠加视觉混乱)
        .lumoryAdaptiveModal(item: $customEditorTarget) { suggestion in
            SuggestionTargetPickerSheet(suggestion: suggestion) { chosen in
                confirm(suggestion, canonical: chosen)
            }
        }
        .alert(
            groupPendingDeletion.map {
                String(format: NSLocalizedString("删除主题「%@」?", comment: "Delete group alert title"), $0)
            } ?? "",
            isPresented: Binding(
                get: { groupPendingDeletion != nil },
                set: { if !$0 { groupPendingDeletion = nil } }
            )
        ) {
            Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {
                groupPendingDeletion = nil
            }
            Button(NSLocalizedString("删除", comment: "Delete"), role: .destructive) {
                guard let canonical = groupPendingDeletion else { return }
                groupPendingDeletion = nil
                Task {
                    let outcome = await ThemeManagementService.shared.deleteTheme(canonical: canonical)
                    if !outcome.succeeded {
                        deleteFailureMessage = String(
                            format: NSLocalizedString("删除「%@」失败,可能是磁盘空间不足或同步冲突。请稍后重试。", comment: "Delete theme failed"),
                            canonical
                        )
                    } else {
                        InsightsResultCache.shared.clear()
                        showThemeDeletedToast(name: canonical, undoPayload: outcome.undoPayload)
                    }
                }
            }
        } message: {
            Text(NSLocalizedString("将从所有日记里抹掉这个主题(包括它的所有别名)。原日记内容不变。删除后可短暂撤销。", comment: "Delete theme message"))
        }
        // P1-Theme-5 拆开 group 加确认 — 跟"删除"等 destructive 操作对齐,防误触。
        .confirmationDialog(
            groupPendingUnmerge.map {
                String(format: NSLocalizedString("拆开「%@」分组?", comment: "Unmerge group confirm"), $0)
            } ?? "",
            isPresented: Binding(
                get: { groupPendingUnmerge != nil },
                set: { if !$0 { groupPendingUnmerge = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("拆开", comment: "Unmerge confirm action"), role: .destructive) {
                guard let canonical = groupPendingUnmerge else { return }
                groupPendingUnmerge = nil
                resolver.deleteGroup(canonical: canonical)
            }
            Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {
                groupPendingUnmerge = nil
            }
        } message: {
            Text(NSLocalizedString("所有别名会拆回独立主题,原日记内容不变。可以在新待审里重新合并。", comment: "Unmerge group message"))
        }
        .alert(
            NSLocalizedString("删除失败", comment: "Delete failed alert"),
            isPresented: Binding(
                get: { deleteFailureMessage != nil },
                set: { if !$0 { deleteFailureMessage = nil } }
            )
        ) {
            Button(NSLocalizedString("好", comment: "OK"), role: .cancel) {
                deleteFailureMessage = nil
            }
        } message: {
            Text(deleteFailureMessage ?? "")
        }
        // (D-06 superreview 2026-05-19)"全部忽略"确认 — `resolver.clearAllPending()` 实际只
        // 软清空 pending 数组,**不写 negativePair**,下次 AI 扫描这些对子会重新出现。原文案
        // "标为不是"承诺永久否决,跟代码行为相反 → 改成"忽略 / 下次会重现"的诚实文案。
        // 如果未来产品决定真做永久否决,要么改 clearAllPending 调 reject 循环,要么再加一个
        // "全部标为不是"按钮真写 negativePair,跟"忽略"区分开。
        .confirmationDialog(
            String(
                format: NSLocalizedString("忽略全部 %d 条待审建议?", comment: "Confirm ignore all pending"),
                resolver.pending.count
            ),
            isPresented: $showClearAllPendingConfirm,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("全部忽略", comment: "Confirm ignore all"), role: .destructive) {
                #if canImport(UIKit)
                HapticManager.shared.notification(.warning)
                #endif
                resolver.clearAllPending()
            }
            Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) { }
        } message: {
            Text(NSLocalizedString("它们会在下次 AI 扫描时重新出现。",
                                   comment: "Confirm ignore all body"))
        }
        .alert(
            NSLocalizedString("清空所有否决记录?", comment: "Reset rejections alert"),
            isPresented: $showResetNegativeAlert
        ) {
            Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) { }
            Button(NSLocalizedString("清空", comment: "Reset"), role: .destructive) {
                resolver.resetNegativePairs()
            }
        } message: {
            Text(NSLocalizedString("下次扫描时,之前点过『不是』的对子会重新被 AI 考虑。", comment: "Reset rejections message"))
        }
        .task {
            // 首次进入此页:如果 alias map 还是空 + pending 也空 + judge 不在跑,
            // 自动后台扫一次。**持久化标记在 resolver.didAutoScanOnce**(codex P2 fix),
            // view 重建后不会重复触发。
            await maybeAutoScan()
        }
        .task(id: citationCacheKey) {
            // 预取所有 pending 引文 entry,缓存到 @State —— 之前 citationsView body 里同步 fetch,
            // 多 pending 时主线程 jank(codex P2 fix)。task(id:) 在 pending 发生增删时重跑。
            await prefetchCitations()
        }
    }

    @ViewBuilder
    private var emptyStateSection: some View {
        if resolver.groups.isEmpty,
           resolver.pending.isEmpty,
           !judgeService.scanProgress.isRunning {
            Section {
                EmptyStateView(
                    systemImage: "sparkles",
                    title: NSLocalizedString("还没有合并过的主题", comment: "Theme alias empty title"),
                    message: NSLocalizedString("AI 扫描会找出意思相近的主题,比如昵称、同义词或中英文写法。确认后,洞察和回顾会把它们当作同一个主题。", comment: "Theme alias empty body"),
                    size: .inline
                )
            }
        }
    }

    /// task(id:) 的 fingerprint —— pending 增删 / 切到不同条目都触发 prefetch。
    private var citationCacheKey: String {
        resolver.pending.map { $0.id.uuidString }.sorted().joined()
    }

    // MARK: - Scan section

    @ViewBuilder
    private var scanSection: some View {
        Section(
            header: header(NSLocalizedString("AI 扫描", comment: "Scan section header")),
            footer: Text(NSLocalizedString("扫描只会生成待审建议,不会自动改写日记内容。处理中可以随时停止。", comment: "Theme alias scan privacy footer"))
        ) {
            Button {
                #if canImport(UIKit)
                HapticManager.shared.click()
                #endif
                if judgeService.scanProgress.isRunning {
                    judgeService.cancelScan()
                } else {
                    judgeService.scanAllHistory()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: scanIconName)
                        .foregroundStyle(Color.accentColor)
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(scanButtonTitle)
                            .foregroundStyle(Color.primary)
                        if let phaseText = scanPhaseText {
                            // P1-Theme-6 phase 切换加 transition,scan 是 30-90s 长任务,
                            // 文字静态切换让用户以为卡死。
                            Text(phaseText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .transition(.opacity)
                                .id(phaseText)
                        }
                        if judgeService.scanProgress.isRunning, resolver.pendingCount > 0 {
                            Text(String(format: NSLocalizedString("当前待审 %d 条", comment: "Current pending count"), resolver.pendingCount))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    if judgeService.scanProgress.isRunning {
                        ProgressView()
                    }
                }
                .animation(AnimationConfig.smoothTransition, value: scanPhaseText)
            }
        }
    }

    /// 按钮文案随状态切换 —— 没扫过就"扫描",扫过一次后改成"重新扫描"让用户明白可重复触发。
    private var scanButtonTitle: String {
        let hasState = !resolver.groups.isEmpty || !resolver.pending.isEmpty
            || judgeService.scanProgress.phase == .done
        if judgeService.scanProgress.isRunning {
            return NSLocalizedString("停止扫描", comment: "Stop scanning")
        }
        return hasState
            ? NSLocalizedString("重新扫描", comment: "Re-scan themes")
            : NSLocalizedString("扫描已有主题", comment: "Scan existing themes")
    }

    private var scanIconName: String {
        if judgeService.scanProgress.isRunning { return "stop.circle" }
        let hasState = !resolver.groups.isEmpty || !resolver.pending.isEmpty
            || judgeService.scanProgress.phase == .done
        return hasState ? "arrow.clockwise.circle" : "wand.and.stars"
    }

    private var scanPhaseText: String? {
        switch judgeService.scanProgress.phase {
        case .idle:
            return nil
        case .fetchingInventory:
            return NSLocalizedString("正在统计标签…", comment: "Scan phase fetch")
        case .judging:
            return NSLocalizedString("正在分析主题…", comment: "Scan phase judge")
        case .applying:
            return NSLocalizedString("正在整理建议…", comment: "Scan phase apply")
        case .done:
            let n = judgeService.scanProgress.suggestionsAdded
            return n == 0
                ? NSLocalizedString("没有找到可能合并的主题。", comment: "Scan empty")
                : String(format: NSLocalizedString("扫到 %d 条建议", comment: "Scan added"), n)
        case .failed(let reason):
            return reason
        }
    }

    // MARK: - Pending section

    @ViewBuilder
    private var pendingSection: some View {
        if !resolver.pending.isEmpty {
            Section {
                ForEach(resolver.pending) { suggestion in
                    pendingCard(for: suggestion)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
            } header: {
                HStack {
                    Text(String(format: NSLocalizedString("待审 (%d)", comment: "Pending header"), resolver.pending.count))
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if resolver.pending.count >= 3 {
                        // P1-Theme-1 显式 "全部忽略" 文字按钮 — 替原 ellipsis.circle Menu(触发区小、
                        // 字号 caption 灰色,用户找不到批量操作)。.glass small button 跟周围 row 节奏一致。
                        // (2026-05-19 P1-10 audit)加确认 — 一次性写一堆负对,用户后悔会发现无法
                        // 通过"重新扫描"恢复(下次 AI 不会再提议这些对),只能去"清空否决记录"。
                        Button(role: .destructive) {
                            showClearAllPendingConfirm = true
                        } label: {
                            Text(NSLocalizedString("全部忽略", comment: "Dismiss all pending alias suggestions"))
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .accessibilityLabel(NSLocalizedString("全部忽略待审主题", comment: "Dismiss all pending"))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func pendingCard(for suggestion: PendingSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题 + 置信度
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // P1-Theme-2 两行结构 — 大字主题名 + 小字解释问题,比"「宝贝」=Abby?"等号问号更自然。
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.newTag)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.primary)
                    Text(String(format: NSLocalizedString("这可能是「%@」的别称?", comment: "Pending card subtitle"),
                                suggestion.canonicalGuess))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // confidence pill —— high 用中性灰(banner 已弹过,卡片只是 reference);
                // medium 用 orange 提示"AI 不太确定,慎重判断"。降低色彩噪声。
                Text(confidenceLabel(suggestion.confidence))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.secondary.opacity(0.12))
                    )
                    .foregroundStyle(suggestion.confidence == .medium ? Color.orange : Color.secondary)
            }

            // 引文样例
            if !suggestion.sampleEntryIds.isEmpty {
                citationsView(ids: suggestion.sampleEntryIds, canonical: suggestion.canonicalGuess)
            }

            // 操作按钮 —— 跟 banner 统一:主操作撑满第一行,次要 + 忽略 同第二行。
            VStack(alignment: .leading, spacing: 8) {
                chip(
                    title: String(format: NSLocalizedString("合并到 %@", comment: "Merge into canonical"), suggestion.canonicalGuess),
                    style: .primary,
                    fullWidth: true
                ) { confirm(suggestion, canonical: suggestion.canonicalGuess) }

                HStack(spacing: 8) {
                    chip(
                        // P1-Theme-3 文案修正 — "把「X」合并到其他主题" 太长会 .lineLimit(1) 截断,
                        // 缩成"选择合并目标" / "Choose target..." 简洁不丢语义。
                        title: NSLocalizedString("选择合并目标…", comment: "Pick a merge target manually"),
                        style: .secondary,
                        fullWidth: true
                    ) {
                        customEditorTarget = suggestion
                    }
                    chip(
                        // (2026-05-19 P1-10 audit)文案改 "不是" — "忽略" 让人以为是临时跳过,
                        // 实际是永久否决(写 negativePair,下次 AI 也不会再提议同对)。"不是" 更
                        // 贴近 "不,这不是同一个主题"的语义,跟 negative pair 行为对齐。
                        title: NSLocalizedString("不是", comment: "Reject (not same theme)"),
                        style: .ghost
                    ) { reject(suggestion) }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 中性 liquid glass —— 跟 picker / SuggestionTargetPickerSheet 设计一致,
        // 不再用 confidence color 给整张卡 tint(之前蓝色/橙色 tint 让 Settings 整页过载)。
        .liquidGlassCard(cornerRadius: LumoryCornerRadius.card, interactive: false)
    }

    @ViewBuilder
    private func citationsView(ids: [UUID], canonical: String) -> some View {
        // 走 @State 缓存 —— 之前同步 fetchSamples 在每次 body 渲染时打 Core Data,
        // 多 pending 卡片 → 主线程 jank。codex P2 fix。
        let snapshots = ids.compactMap { citationCache[$0] }
        if !snapshots.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(snapshots, id: \.id) { snap in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(snippetText(for: snap))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func snippetText(for snap: CitationSnapshot) -> String {
        let format = NSLocalizedString("M月d日", comment: "Date short")
        let dateStr = Self.snippetDateFormatter(format: format).string(from: snap.date)
        return "\(dateStr) — \(snap.snippet)"
    }

    private static let snippetDateFormatterLock = NSLock()
    private static var snippetDateFormatterCache: [String: DateFormatter] = [:]

    private static func snippetDateFormatter(format: String) -> DateFormatter {
        snippetDateFormatterLock.lock()
        defer { snippetDateFormatterLock.unlock() }
        if let cached = snippetDateFormatterCache[format] { return cached }
        let formatter = DateFormatter()
        formatter.dateFormat = format
        snippetDateFormatterCache[format] = formatter
        return formatter
    }

    // MARK: - Groups section

    @ViewBuilder
    private var groupsSection: some View {
        if !resolver.groups.isEmpty {
            Section(header: header(String(format: NSLocalizedString("已合并 (%d)", comment: "Merged groups header"), resolver.groups.count))) {
                mergedGroupsPanel
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    // P1-Theme-4 跟 pendingSection (16/16 horizontal) 对齐 — 0/0 让 liquidGlass
                    // 卡跟 Form .insetGrouped 系统 chrome 边缘重合产生双圆角阴影,违反 CLAUDE.md 约定。
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
        }
    }

    // MARK: - Negative pairs reset section

    @ViewBuilder
    private var negativeResetSection: some View {
        if !resolver.negativePairs.isEmpty {
            Section(
                header: header(NSLocalizedString("否决记录", comment: "Rejected pairs section")),
                footer: Text(NSLocalizedString("点过『不是』的对子被永久跳过。如果想让 AI 重新考虑这些对子(下次扫描时再次提议),清空这里。", comment: "Reset negative footer"))
            ) {
                Button(role: .destructive) {
                    showResetNegativeAlert = true
                } label: {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                            .foregroundStyle(.orange)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(NSLocalizedString("清空否决记录", comment: "Reset rejections"))
                                .foregroundStyle(Color.primary)
                            Text(String(format: NSLocalizedString("共 %d 条", comment: "Negative pair count"), resolver.negativePairs.count))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private var sortedGroupKeys: [String] {
        resolver.groups.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    @ViewBuilder
    private var mergedGroupsPanel: some View {
        let keys = sortedGroupKeys
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 0) {
                ForEach(keys.indices, id: \.self) { index in
                    let canonical = keys[index]
                    groupPanelRow(canonical: canonical, aliases: resolver.groups[canonical] ?? [])

                    if index < keys.count - 1 {
                        Divider()
                            .padding(.leading, 18)
                            .padding(.trailing, 14)
                    }
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlassCard(cornerRadius: LumoryCornerRadius.nestedRow, interactive: false)
        }
    }

    @ViewBuilder
    private func groupPanelRow(canonical: String, aliases: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(canonical)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 8)
                Text(String(format: NSLocalizedString("%d 个别名", comment: "Alias count"), aliases.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Menu {
                    Button {
                        // P1-Theme-5 加 confirmationDialog — "拆开"会让别名重新成独立主题,跟"删除"
                        // 一样有不可逆影响(用户大概率重新合并),之前无确认直接执行。
                        groupPendingUnmerge = canonical
                    } label: {
                        Label(NSLocalizedString("拆开", comment: "Unmerge group"), systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                    }
                    Button(role: .destructive) {
                        groupPendingDeletion = canonical
                    } label: {
                        Label(NSLocalizedString("删除", comment: "Delete theme"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("更多操作", comment: "More actions"))
            }
            FlowLayout(spacing: 6) {
                ForEach(aliases, id: \.self) { alias in
                    Menu {
                        Button(role: .destructive) {
                            resolver.unmerge(canonical: canonical, removeAlias: alias)
                        } label: {
                            Label(NSLocalizedString("从这组拆出", comment: "Unmerge alias"), systemImage: "scissors")
                        }
                    } label: {
                        Text(alias)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            // 中性 glass capsule(去蓝)
                            .liquidGlassCapsule(interactive: true)
                            .foregroundStyle(Color.primary)
                    }
                    .buttonStyle(.plain)
                    .menuActionDismissBehavior(.enabled)
                }
            }
        }
        .padding(.init(top: 10, leading: 18, bottom: 10, trailing: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helpers

    private func confirm(_ suggestion: PendingSuggestion, canonical: String) {
        #if canImport(UIKit)
        HapticManager.shared.notification(.success)
        #endif
        resolver.confirm(suggestion, canonical: canonical)
        // P0-2 全局 toast — 跟 banner confirm 统一文案,在 Settings 深层也能看到。
        LumoryToastCenter.shared.show(
            String(format: NSLocalizedString("已合并到「%@」", comment: "Toast after merging theme alias"), canonical),
            severity: .success
        )
    }

    private func showThemeDeletedToast(
        name: String,
        undoPayload: ThemeManagementService.ThemeDeletionUndoPayload?
    ) {
        ThemeDeletionToast.show(name: name, undoPayload: undoPayload) {
            InsightsResultCache.shared.clear()
        }
    }

    private func reject(_ suggestion: PendingSuggestion) {
        #if canImport(UIKit)
        HapticManager.shared.click()
        #endif
        resolver.reject(suggestion)
    }

    private func confidenceLabel(_ c: PendingSuggestion.Confidence) -> String {
        switch c {
        case .high: return NSLocalizedString("高置信", comment: "High confidence")
        case .medium: return NSLocalizedString("中置信", comment: "Medium confidence")
        }
    }

    /// 一次性预取所有 pending 引文 entry,落到 @State citationCache。
    /// 走 background context + DTO 跨边界(NSManagedObject 不 Sendable)。
    private func prefetchCitations() async {
        let allIDs = Set(resolver.pending.flatMap { $0.sampleEntryIds })
        // 无条件清一次 stale —— 旧实现把这步藏在 `missing.isEmpty` guard 内,
        // 当 missing 非空(常见)时 stale 不清,长期使用会让 cache 跟着已 confirm/reject 的 pending
        // 累积旧 entry。把清洗提到 guard 之前保证每次都跑。
        let stale = Set(citationCache.keys).subtracting(allIDs)
        if !stale.isEmpty {
            for k in stale { citationCache.removeValue(forKey: k) }
        }
        let missing = allIDs.subtracting(citationCache.keys)
        guard !missing.isEmpty else { return }
        let snapshots = await PersistenceController.shared.container.performBackgroundTask { context in
            let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", Array(missing) as NSArray)
            request.sortDescriptors = [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)]
            guard let entries = try? context.fetch(request) else { return [CitationSnapshot]() }
            return entries.compactMap { entry -> CitationSnapshot? in
                guard let id = entry.id else { return nil }
                let body: String
                if let summary = entry.summary, !summary.isEmpty {
                    body = summary
                } else {
                    body = entry.text ?? ""
                }
                let normalizedBody = body
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                let snippet = String(normalizedBody.prefix(50)) + (normalizedBody.count > 50 ? "…" : "")
                return CitationSnapshot(id: id, date: entry.date ?? Date(), snippet: snippet)
            }
        }
        for snap in snapshots {
            citationCache[snap.id] = snap
        }
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }

    @MainActor
    private func maybeAutoScan() async {
        // 持久化标记在 resolver(codex P2 fix):
        // 之前的 view-local @State hasAutoScannedOnce 会在用户每次 push 进来都重置 → 反复触发 AI 扫描。
        // 现在状态在 resolver,跨 view 重建仍生效。
        guard !resolver.didAutoScanOnce else { return }
        guard resolver.groups.isEmpty,
              resolver.pending.isEmpty,
              !judgeService.scanProgress.isRunning else {
            // 不会自动扫了,但也算"已经走过自动判断流程",写入持久化标记避免下次再 evaluate。
            resolver.markAutoScanned()
            return
        }

        // 只在用户已经积累 ≥ 20 条 distinct theme 才自动跑(空库存跑也没意义)。
        let distinctCount = await Task.detached(priority: .utility) { () -> Int in
            let bg = PersistenceController.shared.container.newBackgroundContext()
            return await bg.perform {
                let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
                request.predicate = NSPredicate(format: "themes != nil AND themes != %@", "")
                request.fetchBatchSize = 200
                guard let entries = try? bg.fetch(request) else { return 0 }
                var seen = Set<String>()
                for e in entries {
                    for t in e.themeArray { seen.insert(t.lowercased()) }
                    if seen.count >= 20 { break }
                }
                return seen.count
            }
        }.value
        guard distinctCount >= 20 else {
            // 库存不够,也标记"评估过了"——避免每次进来都重复 fetch + 计数,
            // 用户主题量 < 20 时不会自动扫,他想扫直接点按钮。
            resolver.markAutoScanned()
            return
        }
        Log.info("[ThemeAliasManagement] auto-scan triggered, distinctTags=\(distinctCount)", category: .ai)
        resolver.markAutoScanned()
        judgeService.scanAllHistory()
    }

    // MARK: - Chip

    fileprivate enum ChipKind { case primary, secondary, ghost }

    @ViewBuilder
    fileprivate func chip(
        title: String,
        icon: String? = nil,
        style: ChipKind,
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
            // frame(maxWidth) 必须在 background modifier 之前,否则 capsule 仍 size-to-fit
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 30)
            .modifier(MgmtChipModifier(kind: style))
        }
        .buttonStyle(.plain)
    }
}

private struct MgmtChipModifier: ViewModifier {
    let kind: ThemeAliasManagementView.ChipKind
    func body(content: Content) -> some View {
        switch kind {
        case .primary:
            content
                .foregroundStyle(Color.white)
                .background(Capsule().fill(Color.accentColor))
        case .secondary:
            content
                .foregroundStyle(Color.primary)
                // 中性 glass capsule —— 不传 tint,避免 banner / picker / 待审三处都泛蓝
                .liquidGlassCapsule(interactive: true)
        case .ghost:
            content
                .foregroundStyle(Color.secondary)
                .background(Capsule().fill(Color.secondary.opacity(0.10)))
        }
    }
}

// 复用 Components/FlowLayout.swift 里的共享 FlowLayout。
