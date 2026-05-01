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
                            onTapPoint: { point in selectedPoint = point }
                        )
                        .padding(.horizontal, 16)

                        CalendarMonthModule(cells: dailyCells) { date in
                            let day = Calendar.current.startOfDay(for: date)
                            guard let cell = dailyCells.first(where: { Calendar.current.isDate($0.date, inSameDayAs: day) }) else { return }
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
            .sheet(isPresented: $showAskPast) {
                AskPastView()
                    .environment(\.managedObjectContext, viewContext)
                    // "回顾"里用户阅读长文 + 点引用 + 在输入框打字，下滑手势常被误触当做
                    // 页面滚动或失焦，不小心把整个对话关掉就丢了思路。强制必须点"关闭"按钮退出。
                    .interactiveDismissDisabled(true)
            }
            .sheet(item: $themeFilter) { theme in
                ThemeFilteredEntriesView(
                    theme: theme,
                    allThemes: themes,
                    onMerged: { message in
                        showToast(message: message)
                    },
                    onDeleted: { name in
                        showToast(message: String(format: NSLocalizedString("已删除主题「%@」", comment: "Delete toast"), name))
                    }
                )
                .environment(\.managedObjectContext, viewContext)
            }
            .sheet(item: $selectedPoint) { point in
                PointDetailSheet(point: point)
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
            .sheet(item: $themeToMerge) { source in
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
            // ThemeManagementService 已 post .themeAliasMapDidChange,InsightsView 自己监听会 reload。
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
            #if canImport(UIKit)
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            #endif
        }
    }

    // MARK: Narrative CTA

    private var narrativeCTA: some View {
        Button {
            #if canImport(UIKit)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            #endif
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
        isLoadingCharts = true
        isLoadingThemes = true

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
        self.moodPoints = points
        self.themes = loadedThemes
        self.stats = loadedStats
        self.dailyCells = loadedCells
        self.facts = CorrelationFactGenerator.generate(points: points, themes: loadedThemes, stats: loadedStats)
        self.isLoadingCharts = false
        self.isLoadingThemes = false
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
        let cacheKey = "\(Int(start.timeIntervalSinceReferenceDate))-\(Int(end.timeIntervalSinceReferenceDate))"

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
                dailyCellsCache.removeValue(forKey: dailyCellsCache.keys.min() ?? cacheKey)
            }
        }
        return cells
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

// MARK: - Theme filtered entries sheet
//
// 点击 ThemeCard 后弹出：筛选出该主题的所有日记条目，复用 DiaryEntryRow。

private struct ThemeFilteredEntriesView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    let theme: InsightsEngine.Theme
    /// 父视图传入的全部 themes(用来给 merge sheet 列候选,排除自己)
    let allThemes: [InsightsEngine.Theme]
    /// 父视图回调,处理合并成功后的 toast / reload。
    let onMerged: ((_ message: String) -> Void)?
    /// 父视图回调,处理删除主题后的 toast / 关 sheet。
    let onDeleted: ((_ name: String) -> Void)?

    @State private var entries: [DiaryEntry] = []
    /// merge sheet 的 trigger。`.sheet(item:)` 比 `.sheet(isPresented:)` 抗父级 reload —
    /// alias map 变更通知能让父级 InsightsView 重 evaluate `themeFilter`,sheet item identity
    /// 驱动比 Bool 稳。CLAUDE.md `.sheet` 反复踩坑章节。
    @State private var mergeSubject: InsightsEngine.Theme?
    @State private var showDeleteAlert = false
    @State private var deleteFailureMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tag")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text(NSLocalizedString("没有匹配的日记", comment: "No matched entries"))
                            .foregroundColor(.secondary)
                    }
                } else {
                    // .plain + 透明 row + 清空 List 背景 → DiaryEntryRow 自带的 liquidGlassCard
                    // 才能干净地浮在系统的玻璃 sheet 背景上,不被 insetGrouped 的灰底压住。
                    List {
                        ForEach(entries, id: \.objectID) { entry in
                            NavigationLink(value: entry) {
                                DiaryEntryRow(entry: entry)
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .navigationDestination(for: DiaryEntry.self) { entry in
                        DiaryDetailView(entry: entry, startInEditMode: false)
                    }
                }
            }
            .navigationTitle(theme.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("关闭", comment: "Close")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            mergeSubject = theme
                        } label: {
                            Label(
                                NSLocalizedString("合并到其他主题…", comment: "Merge into another theme"),
                                systemImage: "arrow.triangle.merge"
                            )
                        }
                        Button(role: .destructive) {
                            showDeleteAlert = true
                        } label: {
                            Label(
                                NSLocalizedString("删除主题", comment: "Delete theme"),
                                systemImage: "trash"
                            )
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(NSLocalizedString("更多操作", comment: "More actions"))
                }
            }
            .onAppear(perform: fetch)
            .sheet(item: $mergeSubject) { subject in
                ThemeMergeIntoSheet(
                    source: subject,
                    candidates: allThemes.filter { $0.id != subject.id }
                ) { target in
                    let outcome = ThemeAliasResolver.shared.mergeThemes(source: subject.name, into: target.name)
                    switch outcome {
                    case .merged:
                        let resolvedTarget = ThemeAliasResolver.shared.canonicalize(target.name)
                        let message = String(
                            format: NSLocalizedString("已把「%@」合并到「%@」", comment: "Merge toast"),
                            subject.name,
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
                    // 合并后此 filtered view 显示的 theme 已经是别名,关掉让用户看 Insights 重聚合后的 canonical。
                    dismiss()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(160))
                        onMerged?(message)
                    }
                }
            }
            .alert(
                String(format: NSLocalizedString("删除主题「%@」?", comment: "Delete theme alert title"), theme.name),
                isPresented: $showDeleteAlert
            ) {
                Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) { }
                Button(NSLocalizedString("删除", comment: "Delete"), role: .destructive) {
                    Task { await performDelete() }
                }
            } message: {
                Text(NSLocalizedString("将从所有日记里抹掉这个主题(包括它的所有别名)。原日记内容不变。此操作不可撤销。", comment: "Delete theme message"))
            }
            .alert(
                NSLocalizedString("删除失败", comment: "Delete failed"),
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
        }
    }

    private func performDelete() async {
        let outcome = await ThemeManagementService.shared.deleteTheme(canonical: theme.name)
        if outcome.succeeded {
            dismiss()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(160))
                onDeleted?(theme.name)
            }
        } else {
            deleteFailureMessage = String(
                format: NSLocalizedString("删除「%@」失败,可能是磁盘空间不足或同步冲突。请稍后重试。", comment: "Delete theme failed"),
                theme.name
            )
        }
    }

    private func fetch() {
        let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
        // UUID 不符合 CVarArg；需要桥接成 NSArray 让 Core Data 正确匹配每个 UUID。
        // 旧代码 `as [CVarArg]` 在运行时会抛 "Could not cast value of type 'UUID' to 'CVarArg'"。
        request.predicate = NSPredicate(format: "id IN %@", theme.entryIds as NSArray)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)]
        entries = (try? viewContext.fetch(request)) ?? []
    }
}

// MARK: - Point detail sheet (点击图表点时弹出)

private struct PointDetailSheet: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    let point: InsightsEngine.MoodPoint

    @State private var entries: [DiaryEntry] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(entries, id: \.objectID) { entry in
                    NavigationLink(value: entry) {
                        DiaryEntryRow(entry: entry)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay {
                if entries.isEmpty {
                    Text(NSLocalizedString("该时段没有日记", comment: "No entries for bucket"))
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle(dateLabel)
            .navigationDestination(for: DiaryEntry.self) { entry in
                DiaryDetailView(entry: entry, startInEditMode: false)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("关闭", comment: "Close")) { dismiss() }
                }
            }
            .onAppear(perform: fetch)
        }
    }

    private var dateLabel: String {
        point.date.formatted(date: .abbreviated, time: .omitted)
    }

    private func fetch() {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: point.date)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return }
        let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
        request.predicate = NSPredicate(
            format: "date >= %@ AND date < %@",
            dayStart as NSDate,
            dayEnd as NSDate
        )
        request.sortDescriptors = [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)]
        entries = (try? viewContext.fetch(request)) ?? []
    }
}

// MARK: - ThemeMergeIntoSheet
//
// Insights ThemeCard 长按 → "合并到其他主题" → 这个 sheet。列出所有其他主题让用户选 target。
// 选完后回调 onConfirm(target),InsightsView 走 ThemeAliasResolver.mergeThemes。

private struct ThemeMergeSheetOutcome: Equatable {
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

private struct ThemeMergeIntoSheet: View {
    let source: InsightsEngine.Theme
    let candidates: [InsightsEngine.Theme]
    let onConfirm: (InsightsEngine.Theme) -> ThemeMergeSheetOutcome
    let onComplete: (ThemeMergeSheetOutcome) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""
    /// 选中后的过渡状态。真实 merge 已完成后,展示结果 animation,~0.6s 后 dismiss。
    @State private var confirmingTarget: InsightsEngine.Theme?
    @State private var confirmationTitle: String = ""
    @State private var confirmationSucceeded = true
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
                }

                // 合并 in-flight 时全屏 dim + 中央 success animation,~0.6s 后 dismiss
                if let target = confirmingTarget {
                    confirmingOverlay(target: target)
                        .transition(.opacity)
                }
            }
            .searchable(text: $searchText, prompt: NSLocalizedString("搜索主题", comment: "Search theme prompt"))
            .navigationTitle(NSLocalizedString("合并主题", comment: "Merge themes title"))
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "Cancel")) { dismiss() }
                        .disabled(confirmingTarget != nil)
                }
            }
            .interactiveDismissDisabled(confirmingTarget != nil)
            .animation(.spring(response: 0.32, dampingFraction: 0.85), value: confirmingTarget)
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
        .disabled(confirmingTarget != nil)
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

    @ViewBuilder
    private func confirmingOverlay(target: InsightsEngine.Theme) -> some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Image(systemName: confirmationSucceeded ? "checkmark.circle.fill" : "info.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(confirmationSucceeded ? Color.moodSpectrum(value: target.avgMood) : Color.secondary)
                    .symbolEffect(.bounce, value: confirmingTarget != nil)
                Text(confirmationTitle)
                    .font(.headline)
                    .foregroundStyle(Color.primary)
            }
            .padding(28)
            .liquidGlassCard(cornerRadius: 22)
            .shadow(color: Color.primary.opacity(0.12), radius: 18, y: 6)
        }
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
        guard confirmingTarget == nil, pendingMergeTarget == nil else { return }
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
        confirmationTitle = outcome.title
        confirmationSucceeded = outcome.isSuccess
        confirmingTarget = target
        #if canImport(UIKit)
        if outcome.isSuccess {
            HapticManager.shared.notification(.success)
        } else {
            HapticManager.shared.click()
        }
        #endif
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            dismiss()
            onComplete(outcome)
        }
    }
}
