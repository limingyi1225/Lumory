import SwiftUI
import CoreData

// MARK: - InsightsView
//
// Insights 主入口。一屏式滚动：NarrativeSummaryCard → WritingHeatmap
// → ThemeCardList → AskPast preset chips。
// 所有数据源自 InsightsEngine，TimeRange 切换会重新拉所有模块。

struct InsightsView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    /// iPad / regular size class 下 lumoryAdaptiveModal 走 fullScreenCover 没有下拉手势,
    /// 必须保留小关闭按钮。iPhone compact 删 toolbar,纯下拉手势。
    @Environment(\.horizontalSizeClass) private var hSizeClass

    // 默认 `.month`(2026-05-14 用户决定:进 Insights 默认看最近 30 天,而非全部时间)。
    // 用户切换后持久化,后续恢复上次选择。**key 从 v1 → v2**:旧 install 把上次选择持久化成
    // 了 `.all`,不 bump key 的话改默认对老用户不生效;bump 让所有 install 重置到新默认 `.month`。
    @AppStorage("insights.lastRange.v2", store: AppGroup.userDefaults) private var storedRangeRaw: String = TimeRange.month.rawValue
    @State private var range: TimeRange = .month
    @State private var didHydrateStoredRange = false

    // 各模块数据
    @State private var themes: [InsightsEngine.Theme] = []
    @State private var dailyCells: [DailyCell] = []
    @State private var dailyCellsCache: [String: [DailyCell]] = [:]
    /// 行动区 preset chip 文案 — 走 PromptSuggestionEngine.shared.current.askPastPresets,
    /// 跟 AskPastView 共用同一份 cache。空 = 隐整个 chip 区(冷启动/总 entries<3 时);
    /// 有值 = 显最多 3 条(tap 直接走 InsightsView 的 askPastIntent → AskPastView auto-submit)。
    @State private var presetChips: [String] = []
    /// 浓缩卡专用 — `writingStats.totalEntries` 是全局,不是当前 range;`dailyCells` 是
    /// heatmap 22 周窗口,无序;所以单独走 `engine.entryCount(in:)`。
    /// **Optional 当 loading sentinel**:nil = reload 还没拿到这次 range 的 narrative inputs
    /// (上次 range 的旧值无效);`Some(0)` = 真值 = 该 range 内无日记 → 卡走"日记太少"empty。
    /// 这样既解决"切 range cache 命中时 stale props"(SWR 命中后数据立即
    /// 触发,但 entryCount 还是上次的),也避免"空库时 0 跟 sentinel 冲突永远 skeleton"。
    @State private var rangeEntryCount: Int?
    @State private var rangeMostRecentEntryDate: Date?

    @State private var isLoadingThemes = false
    /// AskPastView modal 入口 — item: 模式带 initialQuestion payload。
    /// chip tap 时设 `AskPastIntent(initialQuestion: question)`,AskPastView `.task` 内
    /// 自动 submit。nil = sheet 关闭。
    @State private var askPastIntent: AskPastIntent?
    @State private var themeFilter: InsightsEngine.Theme?
    @State private var themeToDelete: InsightsEngine.Theme?
    @State private var isDeletingTheme = false
    @State private var deleteFailureMessage: String?
    @State private var themeToMerge: InsightsEngine.Theme?
    // wave17 简化(superreview P1-7/P1-8):MoodStoryChart 删除后 caller 只塞 .day,
    // bucket / MoodPoint 退化成 single-Date 入参。PointDetailSubject(date wrapper)
    // 让 .lumoryAdaptiveModal(item:) 仍能用 Identifiable 路径。
    @State private var selectedDay: PointDetailSubject?
    /// chip header 右上角 refresh 按钮的 loading flag。tap → forceRefresh → 完成后回填。
    /// refresh 期间老 chip 仍可见,只把 icon 换成 ProgressView,不闪空 / 不闪 skeleton。
    @State private var isRefreshingChips: Bool = false
    @State private var didWarmRangeSnapshots: Bool = false

    // P0-2 toast 已迁到全局 LumoryToastCenter,旧 local toastMessage / toastTask state 删除。

    // Load token — 避免老请求完成后覆盖新 range 的数据
    @State private var loadToken: UUID = UUID()

    private let engine = InsightsEngine.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                // GlassEffectContainer 把多个 glassEffect 的折射/模糊合并成一个 GPU pass，
                // 显著降低滚动时的掉帧。Apple 在 Liquid Glass 文档里明确建议大批量玻璃叠放时必用。
                GlassEffectContainer(spacing: 16) {
                    LazyVStack(spacing: 16) {
                        // wave15 v3 — Narrative 浓缩卡升为页面第一个内容(rangeSelector 挪到
                        // navbar .principal toolbar slot,见 .toolbar { } 块)。"AI 替你读完
                        // 先给结论"作为情感性开场,工具控件不抢戏 — Apple Photos / Music
                        // 同款 pattern。reload 拿到本次 range 真值前用 skeleton 占位
                        // (Optional sentinel — 0 也是合法值表示空库,卡内会走 entryCount < 3 路径)。
                        if let entryCount = rangeEntryCount {
                            NarrativeSummaryCard(
                                range: range,
                                dateInterval: range.dateInterval,
                                entryCount: entryCount,
                                mostRecentEntryDate: rangeMostRecentEntryDate
                            )
                        } else {
                            SkeletonNarrativeSummaryCard()
                        }

                        // MoodStoryChart 整块删除(用户决定 2026-05-12)— "情绪故事"
                        // chart 信息密度低,Y 轴 + 折线对长期日记用户 read-once 后没新意,
                        // 还跟下面 WritingHeatmap 的 mood 色信号重复(都告诉你"哪天什么心情")。

                        // 先给写作节奏,再给主题语义。Heatmap 是更轻的证据层,
                        // 放在 theme cards 前面能让下面的彩色主题卡不直接压到 Summary 后。
                        WritingHeatmap(cells: dailyCells) { date in
                            let day = Calendar.current.startOfDay(for: date)
                            // 检查该天确实有 cell(否则 heatmap 触发空白格子时不弹 sheet)。
                            guard dailyCells.contains(where: { Calendar.current.isDate($0.date, inSameDayAs: day) }) else { return }
                            selectedDay = PointDetailSubject(id: day)
                        }
                        .padding(.horizontal, 16)

                        ThemeCardList(
                            themes: themes,
                            isLoading: isLoadingThemes,
                            onSelect: { theme in themeFilter = theme },
                            onDelete: { theme in themeToDelete = theme },
                            onMergeRequest: { theme in themeToMerge = theme }
                        )

                        // 行动区 — chip 有就显 chip,**没 chip 也显一个稳定的"问问过去"入口**
                        // (2026-05-19 P1-04 audit):presetChips 为空时(冷启动 / <3 日记 / refresh 失败)
                        // 用户失去了进 AskPastView 的视觉路径。改成至少一个 fallback CTA,确保入口稳。
                        askPastActionBlock
                            .padding(.horizontal, 16)
                            // 间距交给 ThemeCardList 内部 8pt 呼吸 + LazyVStack 16pt,总视觉间距
                            // 约 24pt,跟上方证据模块之间的节奏一致。
                            .padding(.bottom, 32)
                    }
                }
                .lumoryReadableContent(maxWidth: LumoryAdaptivePresentation.insightsContentMaxWidth)
            }
            // iOS 26 顶部边缘软渐隐 — Insights 滚动顶部跟 large title 过渡更自然。
            .scrollEdgeEffectStyle(.soft, for: .top)
            .accessibilityIdentifier("insightsRootScrollView")
            .scrollIndicators(.hidden)
            // wave15 v2 — 删 navigationTitle("洞察")。这页主角是 NarrativeSummaryCard
            // 浓缩卡 + 各模块图表,加个页面标题反而抢戏。空 title + inline mode 仍保留 navbar
            // chrome 给 iPad close button 用。
            .navigationTitle("")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                // wave15 v3 — rangeSelector 挪进 navbar .principal slot(原在 LazyVStack
                // 顶部当作"页面第一个元素",但 segmented picker 当头条太工具感,把页面情感
                // 性洞察的开场抢了)。Apple Photos / Music 同款 — picker 在 navbar 居中,
                // 始终可达(scroll 时 navbar fixed 不缩),narrative 卡升为页面第一内容。
                // **限宽 260pt**:segmented 默认 maxWidth=.infinity 会贪满中央 slot,挤压
                // iPad close button 或两侧 system gutter。260pt 容下 4 个 shortLabel 等宽分配。
                ToolbarItem(placement: .principal) {
                    rangeSelector
                        .frame(maxWidth: hSizeClass == .regular ? 320 : 260)
                }
                // iPhone compact 走 sheet 有下拉手势 dismiss,不需 close button。
                // iPad / regular size class 走 fullScreenCover 没下拉手势,留小关闭按钮兜底。
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
                // (2026-05-19 user feedback round 3) — toolbar trailing 不放 Ask Past 入口。
                // 入口走页面最底的 askPastActionBlock 标题行,标题 "问问过去的你" 本身可点 → 进 empty 态。
            }
            .onAppear {
                guard !didHydrateStoredRange else { return }
                didHydrateStoredRange = true
                range = TimeRange(rawValue: storedRangeRaw) ?? .month
            }
            .task(id: range) { await reload() }
            .onReceive(NotificationCenter.default.publisher(for: .themeAliasMapDidChange)) { _ in
                // 用户合并/拆分别名后,主题卡片要立刻按新 canonical 重聚合。
                Task { await reload() }
            }
            // wave14 — 允许下滑手势关闭(原 interactiveDismissDisabled: true 屏蔽过)。
            // AskPastView dismiss 时已自带 cancel stream task 逻辑(见其 cancellation button),
            // 下滑关闭走 .onDisappear 也会取消,不会泄漏 in-flight task。
            .lumoryAdaptiveModal(item: $askPastIntent) { intent in
                AskPastView(initialQuestion: intent.initialQuestion)
                    .environment(\.managedObjectContext, viewContext)
            }
            .lumoryAdaptiveModal(item: $themeFilter) { theme in
                ThemeFilteredEntriesView(
                    theme: theme,
                    allThemes: themes,
                    onMerged: { message in
                        LumoryToastCenter.shared.show(message, severity: .success)
                    },
                    onDeleted: { name, undoPayload in
                        showThemeDeletedToast(name: name, undoPayload: undoPayload)
                    },
                    onEntryDeleted: {
                        reloadAfterChildEntryDelete()
                    }
                )
                .environment(\.managedObjectContext, viewContext)
            }
            .lumoryAdaptiveModal(item: $selectedDay) { subject in
                PointDetailSheet(
                    date: subject.date,
                    onEntryDeleted: {
                        reloadAfterChildEntryDelete()
                    }
                )
                    .environment(\.managedObjectContext, viewContext)
                    .presentationDetents([.medium, .large])
            }
            .alert(
                themeToDelete.map {
                    String(format: NSLocalizedString("删除主题「%@」?", comment: "Delete theme alert title"), $0.name)
                } ?? "",
                isPresented: Binding(
                    get: { themeToDelete != nil },
                    set: { if !$0 { themeToDelete = nil } }
                )
            ) {
                Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {
                    themeToDelete = nil
                }
                Button(NSLocalizedString("删除", comment: "Delete"), role: .destructive) {
                    guard let theme = themeToDelete else { return }
                    themeToDelete = nil
                    Task { await deleteTheme(theme) }
                }
            } message: {
                Text(NSLocalizedString("将从所有日记里抹掉这个主题(包括它的所有别名)。原日记内容不变。删除后可短暂撤销。", comment: "Delete theme message"))
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
            .lumoryAdaptiveModal(item: $themeToMerge) { source in
                ThemeMergeIntoSheet(
                    source: source,
                    candidates: themes.filter { $0.id != source.id }
                ) { target in
                    let outcome = ThemeAliasResolver.shared.mergeThemes(source: source.name, into: target.name)
                    switch outcome {
                    case .merged:
                        // resolve target 到 canonical(目标可能是别人的 alias),toast 显示真 canonical 不撒谎。
                        let resolvedTarget = ThemeAliasResolver.shared.canonicalize(target.name)
                        let message = String(
                            format: NSLocalizedString("已把「%@」合并到「%@」", comment: "Merge toast"),
                            source.name,
                            resolvedTarget
                        )
                        return .success(
                            title: String(
                                format: NSLocalizedString("已合并到「%@」", comment: "Merged success"),
                                resolvedTarget
                            ),
                            toastMessage: message
                        )
                    case .noop:
                        return .noop(message: NSLocalizedString("它们已经是同一组了", comment: "Merge no-op toast"))
                    }
                } onComplete: { outcome in
                    guard let message = outcome.toastMessage else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(120))
                        LumoryToastCenter.shared.show(message, severity: .success)
                    }
                }
            }
            // P0-2 InsightsView 是 sheet 内容,root LumoryToastOverlay 被 sheet 压在下面,
            // 必须在这一层重挂,合并主题完成等内部触发才能可见。共享 LumoryToastCenter 单例。
            .lumoryToastOverlay()
        }
    }

    private func deleteTheme(_ theme: InsightsEngine.Theme) async {
        guard !isDeletingTheme else { return }
        isDeletingTheme = true
        defer { isDeletingTheme = false }
        let outcome = await ThemeManagementService.shared.deleteTheme(canonical: theme.name)
        if outcome.succeeded {
            Log.info("[InsightsView] deleted theme \(theme.name), affected entries=\(outcome.affected)", category: .ui)
            InsightsResultCache.shared.clear()
            dailyCellsCache.removeAll()
            await reload()
            showThemeDeletedToast(name: theme.name, undoPayload: outcome.undoPayload)
        } else {
            // CoreData save 失败 —— 用户看到主题没消失会困惑,显式提示。
            deleteFailureMessage = String(
                format: NSLocalizedString("删除「%@」失败,可能是磁盘空间不足或同步冲突。请稍后重试。", comment: "Delete theme failed"),
                theme.name
            )
        }
    }

    private func showThemeDeletedToast(
        name: String,
        undoPayload: ThemeManagementService.ThemeDeletionUndoPayload?
    ) {
        ThemeDeletionToast.show(name: name, undoPayload: undoPayload) {
            InsightsResultCache.shared.clear()
            dailyCellsCache.removeAll()
            await reload()
        }
    }

    // MARK: Range selector

    /// iOS 26 原生 segmented Picker:自动获得液态玻璃材质 + 拖拽切换 + 系统触觉。
    /// 不再自绘 capsule + matchedGeometryEffect,代码量从 ~40 行降到 ~10 行。
    private var rangeSelector: some View {
        Picker(NSLocalizedString("时间范围", comment: "Time range picker"), selection: $range) {
            ForEach(TimeRange.allCases) { tr in
                // 视觉上是 shortLabel("月"),但 VoiceOver 读 label 的全文("最近 30 天")。
                // 不加 a11y label 的话 VoiceOver 只会读"月"用户根本听不懂。
                Text(tr.shortLabel)
                    .tag(tr)
                    .accessibilityLabel(tr.label)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel(NSLocalizedString("时间范围", comment: "Time range picker"))
        .onChange(of: range) { _, _ in
            storedRangeRaw = range.rawValue
            HapticManager.shared.impact(.soft)
        }
    }

    // MARK: AskPast 行动区(hero header 入口 + chip 快捷快入)

    /// (2026-05-19 user feedback round 3)Ask Past 入口设计:
    /// - hero header "问问过去的你" 是**永远可点击**的标题行,tap → 进 AskPast empty 态自由提问
    /// - chip 列表作为"快捷快入" — 有就显在下面,没就只显 header
    /// - refresh icon 独立挂在 header 右侧(跟 hero button 同 HStack 但是 sibling,不嵌套)
    /// 用户在 Insights 上始终能找到进 AskPastView 的路径,标题本身即入口。
    private var askPastActionBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            askPastHeroHeader
            if !presetChips.isEmpty {
                presetChipsList
                    .padding(.top, 2)
            }
        }
        // 整块 a11y container — UI test 走 hero / chip 自己的 label 定位,这里挂兜底 hint。
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("与过去对话", comment: "Accessibility: Ask Your Past"))
    }

    /// Hero header:**标题本身即入口**。tap 整个 sparkles + "问问过去的你" + ↗ 区进 AskPast empty 态。
    /// 右侧的 refresh icon 是 sibling button(只在有 chip 时显),不嵌套在 hero button 内 — SwiftUI
    /// 嵌套 button 在 .glass / contentShape 上交互可能被 outer 吞,sibling 布局更稳。
    private var askPastHeroHeader: some View {
        HStack(spacing: 8) {
            Button {
                HapticManager.shared.impact(.light)
                askPastIntent = AskPastIntent(initialQuestion: nil)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(NSLocalizedString("问问过去的你", comment: "Ask Your Past CTA title"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Image(systemName: "arrow.up.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("insightsAskPastHeroEntry")
            .accessibilityLabel(NSLocalizedString("问问过去的你", comment: "Ask Your Past CTA title"))

            Spacer(minLength: 8)

            // refresh icon — 只在 chip 列表非空时显,避免空态时孤一个 refresh 没语义
            if !presetChips.isEmpty {
                chipsRefreshButton
            }
        }
        .padding(.horizontal, 4)
    }

    /// chip 列表本身 — header 由 askPastHeroHeader 承担,这里只渲染 ForEach。
    /// 多个相邻 glass 元素归同一个 GlassEffectContainer,折射合批,边缘观感统一
    /// (跟 AskPastView 内 presetGrid 同 idiom)。spacing 10pt 让相邻 chip 间有清晰间隙。
    private var presetChipsList: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 10) {
                // **P2 fix (2026-05-13 superreview)**:`PromptSuggestionEngine` 偶尔吐出
                // 重复 chip text(LLM 输出非确定),`id: \.self` 让 String 当 id → 同 chip
                // 渲染冲突。改 enumerated offset 当稳定 id。
                ForEach(Array(presetChips.prefix(3).enumerated()), id: \.offset) { offset, question in
                    presetChipButton(question, index: offset)
                }
            }
        }
    }

    /// header 右上角 refresh icon — `isRefreshingChips` 期间换成小 ProgressView。
    /// AskPastView 的 presetGrid 内有同 idiom(line 144),保持视觉一致。
    @ViewBuilder
    private var chipsRefreshButton: some View {
        if isRefreshingChips {
            ProgressView()
                .scaleEffect(0.55)
                .frame(width: 18, height: 18)
        } else {
            Button {
                Task { await regenerateChips() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18, alignment: .center)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("换一组", comment: "Refresh presets"))
        }
    }

    /// 单颗 chip = iOS 26 `.buttonStyle(.glass)` 原生玻璃药丸。Apple 系统层处理形状 / 阴影 /
    /// hover / press,我们只给 label 内容(问题文本 + 右上箭头)。
    private func presetChipButton(_ question: String, index: Int) -> some View {
        Button {
            HapticManager.shared.impact(.light)
            askPastIntent = AskPastIntent(initialQuestion: question)
        } label: {
            HStack(spacing: 10) {
                Text(question)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
        }
        .buttonStyle(.glass)
        .accessibilityLabel(question)
        .accessibilityIdentifier("insightsAskPastPresetChip\(index)")
    }

    /// 用户点 chip 区 refresh icon → 同 AskPastView.regeneratePresets 逻辑:
    /// forceRefresh AI 一次 + 完后回填 prefix(3)。期间老 chip 仍在,仅 icon 转 ProgressView。
    private func regenerateChips() async {
        isRefreshingChips = true
        _ = await PromptSuggestionEngine.shared.forceRefresh()
        if let bundle = PromptSuggestionEngine.shared.current, !bundle.askPastPresets.isEmpty {
            presetChips = Array(bundle.askPastPresets.prefix(3))
        }
        isRefreshingChips = false
    }

    // MARK: Data loading

    private func reload() async {
        let interval = range.dateInterval
        let token = UUID()
        // View struct 的 method 隐式 @MainActor,这些写入直接同步即可,
        // 不必再 `await MainActor.run`(SwiftUI 已经把 reload 调用调度到 main)。
        loadToken = token

        // SWR: 命中缓存 → 立刻显示旧数据,跳过 loading skeleton。
        // 后台仍跑 reload,完成后用新数据覆盖。详见 InsightsResultCache.swift 注释。
        // wave15 v3 — entryCount/mostRecent 也走 SWR(原入口强制 reset nil 导致命中
        // 仍走 SkeletonNarrativeSummaryCard 中间态,LazyVStack reflow → 切 range 闪烁)。
        // 命中即 hydrate 全套,只在真 cache miss 才走 nil + Skeleton 路径。
        if let cached = InsightsResultCache.shared.snapshot(for: range) {
            self.themes = cached.themes
            self.dailyCells = cached.dailyCells
            self.rangeEntryCount = cached.entryCount
            self.rangeMostRecentEntryDate = cached.mostRecentEntryDate
            self.isLoadingThemes = false
        } else {
            // cache miss(第一次切到这个 range)→ 真值还要等 async,显 Skeleton 占位。
            rangeEntryCount = nil
            rangeMostRecentEntryDate = nil
            isLoadingThemes = true
        }

        // Fix #23: range 切换时 SwiftUI cancel 外层 Task,但 `engine.*` 内部的
        // `performBackgroundTask` 不响应外层 Task cancellation —— 旧实现下快速来回切 range
        // 会让 N 个 bg fetch 同时跑完,挤压 store coordinator。
        // 现在每次 await 后立刻检查 cancellation,并在 fetchDailyCells 的 bg 闭包入口检查,
        // 让后续 stages 直接 bail。loadToken 旧逻辑保留作"写 UI 前再 stale-check"防线。
        if Task.isCancelled { return }

        // MoodStoryChart 删除后,pointsTask 一并退出 — 不再发 moodSeries 请求,
        // 省一次 bg fetch + reduce 聚合。PointDetailSheet wave17 API 改 (date:onEntryDeleted:),
        // 只走 heatmap tap → selectedDay = PointDetailSubject(id: day) 的路径。
        // 主题卡限制 5 太少 —— 用户重度使用后 distinct 主题 >50,只看 top 5 体感"内容量薄"。
        // 30 是横向滚多过 1-2 屏的合理上限,继续拉大对感知没增益但内存压力上升。
        async let themesTask = engine.themes(in: interval, limit: 30)
        async let cellsTask = fetchDailyCells(in: interval)
        // wave14 — 浓缩卡的 staleness 判定基础:writingStats.totalEntries 是全局,dailyCells
        // 是 22 周窗口,都不能用作"当前 range 的真实 entryCount/mostRecent"。
        async let entryCountTask = engine.entryCount(in: interval)
        async let mostRecentDateTask = engine.mostRecentEntryDate(in: interval)

        let (loadedThemes, loadedCells, loadedEntryCount, loadedMostRecent) =
            await (themesTask, cellsTask, entryCountTask, mostRecentDateTask)

        // 子任务都返回后,如果外层已被 cancel,token 已经被新 reload 推进了,直接 return
        // 让新 reload 接管 UI 状态(它自己的 isLoading/UUID 都已置好)。
        if Task.isCancelled { return }

        // 只在 token 还是最新时才把结果写进 UI,避免"被挤下的老 reload 把过期数据盖上"。
        // 被挤下的老 reload 走到这里 guard 失败后**直接 return**,不触碰 loading flag:
        // 后继 reload 在它自己的开头已经把 loadToken 刷新 + isLoading 重置 true,
        // 由它自己的结尾负责清 false。老 reload 若在这里抢先清 false,新 reload 还没返回,
        // UI 会出现"已加载 → 又加载中"的视觉抖动。
        guard token == loadToken else { return }
        self.themes = loadedThemes
        self.dailyCells = loadedCells
        self.rangeEntryCount = loadedEntryCount
        self.rangeMostRecentEntryDate = loadedMostRecent
        self.isLoadingThemes = false

        InsightsResultCache.shared.update(
            .init(
                themes: loadedThemes,
                dailyCells: loadedCells,
                entryCount: loadedEntryCount,
                mostRecentEntryDate: loadedMostRecent
            ),
            for: range
        )

        // 行动区 chip 跟主 reload 并行 hydrate(不阻塞主数据)。命中 cache 立即填,miss 静默
        // 后台 refreshIfNeeded → 几百 ms 后回填。chip 没显出来主页面也照常用,只是少个 affordance。
        updatePresetChipsFromCache()
        warmRangeSnapshotsIfNeeded(excluding: range)
    }

    private func warmRangeSnapshotsIfNeeded(excluding currentRange: TimeRange) {
        guard !didWarmRangeSnapshots else { return }
        let allRanges = TimeRange.allCases
        guard let currentIndex = allRanges.firstIndex(of: currentRange),
              allRanges.indices.contains(currentIndex + 1) else { return }
        let rangeToWarm = allRanges[currentIndex + 1]
        guard InsightsResultCache.shared.snapshot(for: rangeToWarm) == nil else { return }
        didWarmRangeSnapshots = true

        Task(priority: .utility) { @MainActor in
            // Warm only the next broader range. The old "warm every other range" path could do
            // 12 background fetches on first Insights open, even when users never switch ranges.
            let interval = rangeToWarm.dateInterval
            async let themesTask = engine.themes(in: interval, limit: 30)
            async let cellsTask = fetchDailyCells(in: interval)
            async let entryCountTask = engine.entryCount(in: interval)
            async let mostRecentDateTask = engine.mostRecentEntryDate(in: interval)
            let (warmedThemes, warmedCells, warmedEntryCount, warmedMostRecent) =
                await (themesTask, cellsTask, entryCountTask, mostRecentDateTask)
            if Task.isCancelled { return }
            InsightsResultCache.shared.update(
                .init(
                    themes: warmedThemes,
                    dailyCells: warmedCells,
                    entryCount: warmedEntryCount,
                    mostRecentEntryDate: warmedMostRecent
                ),
                for: rangeToWarm
            )
        }
    }

    /// 从 PromptSuggestionEngine 拿 askPastPresets,跟 AskPastView 内 presetGrid 共用同一份
    /// SuggestionBundle cache(同 PromptSuggestionEngine.shared.current)。命中 → 立即填;
    /// miss → utility 优先级后台 refreshIfNeeded,跑完回填。
    /// **不阻塞主 reload**:chip 是辅助 affordance,主页面没 chip 也能滚 narrative / chart / 主题。
    private func updatePresetChipsFromCache() {
        let cachedChips = Self.presetChipQuestions(from: PromptSuggestionEngine.shared.current)
        if !cachedChips.isEmpty {
            presetChips = cachedChips
            return
        }
        // **P1 fix (2026-05-14 superreview round 3)**:cache 空时立即清掉旧 presetChips。
        // 单删走 `PromptSuggestionEngine.clearCache()` 后 cache 为空,但若不清 UI state,
        // 后台 refresh 失败 / 因 <3 条跳过时,页面会继续显示引用已删 entry 的旧问题。
        presetChips = []
        Task(priority: .utility) { @MainActor in
            await PromptSuggestionEngine.shared.refreshIfNeeded()
            let refreshedChips = Self.presetChipQuestions(from: PromptSuggestionEngine.shared.current)
            if !refreshedChips.isEmpty {
                presetChips = refreshedChips
            }
        }
    }

    static func presetChipQuestions(from bundle: SuggestionBundle?) -> [String] {
        guard let bundle, !bundle.askPastPresets.isEmpty else { return [] }
        return Array(bundle.askPastPresets.prefix(3))
    }

    private func reloadAfterChildEntryDelete() {
        dailyCellsCache.removeAll()
        InsightsResultCache.shared.clear()
        Task { await reload() }
    }

    private func fetchDailyCells(in range: DateInterval, lookbackDays: Int = 161) async -> [DailyCell] {
        // 同一份 cells 喂给两个组件:
        // - WritingHeatmap 想要恒定 22 周滚窗(视觉稳定,无论 TimeRange 怎么切都能填满)
        // - CalendarMonthModule 需要覆盖用户可能切换到的较早月份(例如 .all 或 .year)
        // 取并集:min(today - lookbackDays, range.start) → max(today, range.end)
        // 22 周 heatmap 会按周边界向左扩到 today-147...today-153;取 161 天给一周 buffer,
        // 防月/季 range 左侧真实日记被误渲染成空格。
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let lookbackStart = calendar.date(byAdding: .day, value: -lookbackDays, to: today) ?? today
        let rangeStart = calendar.startOfDay(for: range.start)
        let rangeEndDay = calendar.startOfDay(for: range.end)
        let rangeEnd = calendar.date(byAdding: .day, value: 1, to: rangeEndDay) ?? range.end
        let start = min(lookbackStart, rangeStart)
        let end = max(today, rangeEnd)
        let fetchRange = DateInterval(start: start, end: end)
        let cacheKey = "\(Int(start.timeIntervalSinceReferenceDate)):\(Int(end.timeIntervalSinceReferenceDate))"

        // 函数 @MainActor 隐式继承,直接读 cache。
        if let cached = dailyCellsCache[cacheKey] {
            return cached
        }

        // Fix #23: 入口先 short-circuit。外层 SwiftUI .task(id: range) 已经被 cancel 过的话,
        // 没必要再去 store coordinator 排队抢锁。
        if Task.isCancelled { return [] }

        // 把外层 cancellation 传到 bg 闭包内的关键 checkpoint。`performBackgroundTask` 自己
        // 不感知 Task cancellation,只能在闭包里手动读 `Task.isCancelled` 在快速来回切 range
        // 时让旧 fetch 早 bail —— 至少省掉聚合循环。Fetch 本身已经发出去了,不可中断。
        let cells: [DailyCell] = await PersistenceController.shared.container.performBackgroundTask { context -> [DailyCell] in
            // checkpoint 1: fetch 之前
            if Task.isCancelled { return [] }

            // 真·投影:用 dictionaryResultType 只取三列,省掉对象 fault 与 text/embedding/imagesData
            // 的潜在 lazy load。(之前 propertiesToFetch + returnsObjectsAsFaults=false 在默认
            // managedObjectResultType 下只是 prefetch hint,实际仍构建完整 DiaryEntry。)
            let request = NSFetchRequest<NSDictionary>(entityName: "DiaryEntry")
            request.resultType = .dictionaryResultType
            request.predicate = NSPredicate(
                format: "date >= %@ AND date <= %@",
                fetchRange.start as NSDate,
                fetchRange.end as NSDate
            )
            request.propertiesToFetch = ["date", "moodValue", "wordCount"]
            guard let rows = try? context.fetch(request) else { return [] }

            // checkpoint 2: fetch 完成后,聚合循环之前。大数据集时这里能省掉 N 次 dict lookup。
            if Task.isCancelled { return [] }

            var grouped: [Date: DailyAggregate] = [:]
            grouped.reserveCapacity(rows.count)
            for row in rows {
                guard let date = row["date"] as? Date else { continue }
                let mood = (row["moodValue"] as? NSNumber)?.doubleValue ?? 0.5
                let words = (row["wordCount"] as? NSNumber)?.intValue ?? 0
                let day = calendar.startOfDay(for: date)
                var agg = grouped[day] ?? DailyAggregate()
                agg.moodSum += mood
                agg.count += 1
                agg.words += words
                grouped[day] = agg
            }
            return grouped.map { day, agg in
                DailyCell(date: day, mood: agg.moodSum / Double(agg.count), wordCount: agg.words)
            }
        }
        if !Task.isCancelled {
            dailyCellsCache[cacheKey] = cells
            if dailyCellsCache.count > 6 {
                let evictionKey = dailyCellsCache.keys.min { lhs, rhs in
                    Self.dailyCellsCacheStart(lhs) < Self.dailyCellsCacheStart(rhs)
                } ?? cacheKey
                dailyCellsCache.removeValue(forKey: evictionKey)
            }
        }
        return cells
    }

    private static func dailyCellsCacheStart(_ key: String) -> Int {
        Int(key.split(separator: ":").first.map(String.init) ?? "") ?? Int.min
    }
}

// MARK: - AskPastIntent

/// `lumoryAdaptiveModal(item:)` 的 payload。每次创建换 UUID,即便同一 question 也能让 modal
/// 重新 present(用户连点同一个 chip 时第二次也响应)。`initialQuestion: nil` 走 empty 入口
/// (目前没有这种 caller,但保留 None 路径方便未来加"自由提问"入口)。
private struct AskPastIntent: Identifiable {
    let id = UUID()
    let initialQuestion: String?
}

private struct DailyAggregate {
    var moodSum = 0.0
    var count = 0
    var words = 0
}
