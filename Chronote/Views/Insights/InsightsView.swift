import SwiftUI
import CoreData

// MARK: - InsightsView
//
// Phase 1 主入口。一屏式滚动：时段选择器 → MoodStoryChart → ThemeCardList
// → CorrelationChipList → WritingHeatmap → Narrative CTA。
// 所有数据源自 InsightsEngine，TimeRange 切换会重新拉所有模块。

struct InsightsView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    // 默认 `.all` —— 用户直觉上打开 Insight 想看"我的总体主题/总体情绪"，而不是限定月视角。
    // 需要聚焦近期时再手动切到月/季/年。
    @State private var range: TimeRange = .all

    // 各模块数据
    @State private var moodPoints: [InsightsEngine.MoodPoint] = []
    @State private var themes: [InsightsEngine.Theme] = []
    @State private var stats: InsightsEngine.WritingStats = .empty
    @State private var dailyCells: [DailyCell] = []
    @State private var dailyCellsCache: [String: [DailyCell]] = [:]
    @State private var facts: [CorrelationFact] = []

    @State private var isLoadingCharts = false
    @State private var isLoadingThemes = false
    @State private var showNarrative = false
    @State private var showAskPast = false
    @State private var themeFilter: InsightsEngine.Theme?
    @State private var themeToDelete: InsightsEngine.Theme?
    @State private var isDeletingTheme = false
    @State private var deleteFailureMessage: String?
    @State private var themeToMerge: InsightsEngine.Theme?
    @State private var selectedPoint: InsightsEngine.MoodPoint?
    @State private var selectedPointBucket: InsightsEngine.Bucket = .day

    /// 合并/删除 完成后的 transient toast(底部 capsule,3s 后自动消失)。
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?

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
                        rangeSelector
                            .padding(.horizontal, 16)
                            .padding(.top, 8)

                        MoodStoryChart(
                            points: moodPoints,
                            bucket: range.chartBucket,
                            isLoading: isLoadingCharts,
                            onTapPoint: { point in
                                selectedPointBucket = range.chartBucket
                                selectedPoint = point
                            }
                        )
                        .padding(.horizontal, 16)

                        CalendarMonthModule(cells: dailyCells) { date in
                            let day = Calendar.current.startOfDay(for: date)
                            guard let cell = dailyCells.first(where: { Calendar.current.isDate($0.date, inSameDayAs: day) }) else { return }
                            selectedPointBucket = .day
                            selectedPoint = InsightsEngine.MoodPoint(
                                date: day,
                                mood: cell.mood,
                                entryCount: 1
                            )
                        }
                        .padding(.horizontal, 16)

                        ThemeCardList(
                            themes: themes,
                            isLoading: isLoadingThemes,
                            onSelect: { theme in themeFilter = theme },
                            onDelete: { theme in themeToDelete = theme },
                            onMergeRequest: { theme in themeToMerge = theme }
                        )

                        CorrelationChipList(
                            facts: facts,
                            isLoading: isLoadingCharts && facts.isEmpty
                        )
                        .padding(.horizontal, 16)

                        WritingHeatmap(stats: stats, cells: dailyCells)
                            .padding(.horizontal, 16)

                        narrativeCTA
                            .padding(.horizontal, 16)
                            .padding(.bottom, 32)
                    }
                }
                .lumoryReadableContent(maxWidth: LumoryAdaptivePresentation.insightsContentMaxWidth)
            }
            .scrollIndicators(.hidden)
            .navigationTitle(NSLocalizedString("洞察", comment: "Insights"))
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("关闭", comment: "Close")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAskPast = true
                    } label: {
                        Label(NSLocalizedString("回顾", comment: "Ask your past"), systemImage: "bubble.left.and.text.bubble.right")
                    }
                    .accessibilityLabel(NSLocalizedString("与过去对话", comment: "Accessibility: Ask Your Past"))
                }
            }
            .task(id: range) { await reload() }
            .onReceive(NotificationCenter.default.publisher(for: .themeAliasMapDidChange)) { _ in
                // 用户合并/拆分别名后,主题卡片要立刻按新 canonical 重聚合。
                Task { await reload() }
            }
            .fullScreenCover(isPresented: $showNarrative) {
                NarrativeReader(
                    range: range.dateInterval,
                    title: narrativeTitle,
                    engine: engine,
                    moodHint: stats.avgMood
                )
            }
            .lumoryAdaptiveModal(isPresented: $showAskPast, interactiveDismissDisabled: true) {
                AskPastView()
                    .environment(\.managedObjectContext, viewContext)
            }
            .lumoryAdaptiveModal(item: $themeFilter) { theme in
                ThemeFilteredEntriesView(
                    theme: theme,
                    allThemes: themes,
                    onMerged: { message in
                        showToast(message: message)
                    },
                    onDeleted: { name in
                        showToast(message: String(format: NSLocalizedString("已删除主题「%@」", comment: "Delete toast"), name))
                    },
                    onEntryDeleted: {
                        reloadAfterChildEntryDelete()
                    }
                )
                .environment(\.managedObjectContext, viewContext)
            }
            .lumoryAdaptiveModal(item: $selectedPoint) { point in
                PointDetailSheet(
                    point: point,
                    bucket: selectedPointBucket,
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
                Text(NSLocalizedString("将从所有日记里抹掉这个主题(包括它的所有别名)。原日记内容不变。此操作不可撤销。", comment: "Delete theme message"))
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
                        showToast(message: message)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                // 底部 transient toast —— 合并 / 删除 等操作的非阻塞反馈。3s 自动消失。
                if let message = toastMessage {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(Color.moodSpectrum(value: 0.85))
                        Text(message)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Color.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .liquidGlassCard(cornerRadius: 22, interactive: false)
                    .shadow(color: Color.primary.opacity(0.10), radius: 14, y: 4)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 36)
                    .frame(maxWidth: .infinity)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: toastMessage)
            // View struct 是 value type 不会泄漏,但 toastTask 在 view tear-down 后还会向已弃 state
            // 写 nil,iOS 26 beta 会喷 "modifying state during view update"。显式 cancel 干净点。
            .onDisappear { toastTask?.cancel() }
        }
    }

    /// 弹一条 transient toast(底部 capsule,3s 自动消失)。重复调用会取消上一次 task,刷新计时。
    private func showToast(message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            toastMessage = nil
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
        } else {
            // CoreData save 失败 —— 用户看到主题没消失会困惑,显式提示。
            deleteFailureMessage = String(
                format: NSLocalizedString("删除「%@」失败,可能是磁盘空间不足或同步冲突。请稍后重试。", comment: "Delete theme failed"),
                theme.name
            )
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
            HapticManager.shared.impact(.soft)
        }
    }

    // MARK: Narrative CTA

    private var narrativeCTA: some View {
        Button {
            HapticManager.shared.impact(.medium)
            showNarrative = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 22))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: NSLocalizedString("生成%@故事", comment: "Generate story for range"), range.shortLabel))
                        .font(.system(size: 16, weight: .semibold))
                    Text(NSLocalizedString("AI 为你读这段时间的日记，讲成一篇文章", comment: "Narrative CTA subtitle"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.right.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
            }
            .padding(16)
            .foregroundStyle(Color.primary)
            .liquidGlassCard(cornerRadius: 18, tint: Color.accentColor, tintStrength: 0.1, interactive: true)
            .shadow(color: Color.accentColor.opacity(0.15), radius: 10, y: 4)
        }
        .buttonStyle(PressableScaleButtonStyle())
        .accessibilityHint(NSLocalizedString("打开全屏故事阅读器", comment: "Narrative CTA a11y hint"))
    }

    private var narrativeTitle: String {
        String(format: NSLocalizedString("%@回顾", comment: "Range retrospective title"), range.shortLabel)
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
        if let cached = InsightsResultCache.shared.snapshot(for: range) {
            self.moodPoints = cached.moodPoints
            self.themes = cached.themes
            self.stats = cached.stats
            self.dailyCells = cached.dailyCells
            self.facts = cached.facts
            self.isLoadingCharts = false
            self.isLoadingThemes = false
        } else {
            isLoadingCharts = true
            isLoadingThemes = true
        }

        // Fix #23: range 切换时 SwiftUI cancel 外层 Task,但 `engine.*` 内部的
        // `performBackgroundTask` 不响应外层 Task cancellation —— 旧实现下快速来回切 range
        // 会让 N 个 bg fetch 同时跑完,挤压 store coordinator。
        // 现在每次 await 后立刻检查 cancellation,并在 fetchDailyCells 的 bg 闭包入口检查,
        // 让后续 stages 直接 bail。loadToken 旧逻辑保留作"写 UI 前再 stale-check"防线。
        if Task.isCancelled { return }

        async let pointsTask = engine.moodSeries(in: interval, bucket: range.chartBucket)
        // 主题卡限制 5 太少 —— 用户重度使用后 distinct 主题 >50,只看 top 5 体感"内容量薄"。
        // 30 是横向滚多过 1-2 屏的合理上限,继续拉大对感知没增益但内存压力上升。
        async let themesTask = engine.themes(in: interval, limit: 30)
        async let statsTask = engine.writingStats()
        async let cellsTask = fetchDailyCells(in: interval)

        let (points, loadedThemes, loadedStats, loadedCells) = await (pointsTask, themesTask, statsTask, cellsTask)

        // 子任务都返回后,如果外层已被 cancel,token 已经被新 reload 推进了,直接 return
        // 让新 reload 接管 UI 状态(它自己的 isLoading/UUID 都已置好)。
        if Task.isCancelled { return }

        // 只在 token 还是最新时才把结果写进 UI,避免"被挤下的老 reload 把过期数据盖上"。
        // 被挤下的老 reload 走到这里 guard 失败后**直接 return**,不触碰 loading flag:
        // 后继 reload 在它自己的开头已经把 loadToken 刷新 + isLoading 重置 true,
        // 由它自己的结尾负责清 false。老 reload 若在这里抢先清 false,新 reload 还没返回,
        // UI 会出现"已加载 → 又加载中"的视觉抖动。
        guard token == loadToken else { return }
        let newFacts = CorrelationFactGenerator.generate(points: points, themes: loadedThemes, stats: loadedStats)
        self.moodPoints = points
        self.themes = loadedThemes
        self.stats = loadedStats
        self.dailyCells = loadedCells
        self.facts = newFacts
        self.isLoadingCharts = false
        self.isLoadingThemes = false

        InsightsResultCache.shared.update(
            .init(
                moodPoints: points,
                themes: loadedThemes,
                stats: loadedStats,
                dailyCells: loadedCells,
                facts: newFacts
            ),
            for: range
        )
    }

    private func reloadAfterChildEntryDelete() {
        dailyCellsCache.removeAll()
        InsightsResultCache.shared.clear()
        Task { await reload() }
    }

    private func fetchDailyCells(in range: DateInterval, lookbackDays: Int = 140) async -> [DailyCell] {
        // 同一份 cells 喂给两个组件:
        // - WritingHeatmap 想要恒定 140 天滚窗(视觉稳定,无论 TimeRange 怎么切都能填满)
        // - CalendarMonthModule 需要覆盖用户可能切换到的较早月份(例如 .all 或 .year)
        // 取并集:min(today - lookbackDays, range.start) → max(today, range.end)
        // 之前硬编码只取 140 天导致用户切到 .year 或往前翻 6 个月时月历空白。
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
                let mood = (row["moodValue"] as? Double) ?? 0
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

private struct DailyAggregate {
    var moodSum = 0.0
    var count = 0
    var words = 0
}

extension InsightsEngine.WritingStats {
    static let empty = InsightsEngine.WritingStats(
        totalEntries: 0, currentStreak: 0, longestStreak: 0, totalWords: 0, avgMood: 0.5
    )
}

// MARK: - MoodPoint Identifiable fallback

extension InsightsEngine.MoodPoint {
    // 已有 id: Date 实现；此处无需再扩展
}
