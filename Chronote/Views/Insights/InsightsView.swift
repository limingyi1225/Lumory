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
    @State private var facts: [CorrelationFact] = []

    @State private var isLoadingCharts = false
    @State private var isLoadingThemes = false
    @State private var showNarrative = false
    @State private var showAskPast = false
    @State private var themeFilter: InsightsEngine.Theme?
    @State private var selectedPoint: InsightsEngine.MoodPoint?

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
                            onSelect: { theme in themeFilter = theme }
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
                ThemeFilteredEntriesView(theme: theme)
                    .environment(\.managedObjectContext, viewContext)
            }
            .sheet(item: $selectedPoint) { point in
                PointDetailSheet(point: point)
                    .environment(\.managedObjectContext, viewContext)
                    .presentationDetents([.medium, .large])
            }
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
        await MainActor.run {
            loadToken = token
            isLoadingCharts = true
            isLoadingThemes = true
        }

        async let pointsTask = engine.moodSeries(in: interval, bucket: range.chartBucket)
        async let themesTask = engine.themes(in: interval)
        async let statsTask = engine.writingStats()
        async let cellsTask = fetchDailyCells(in: interval)

        let (points, loadedThemes, loadedStats, loadedCells) = await (pointsTask, themesTask, statsTask, cellsTask)

        await MainActor.run {
            // 只在 token 还是最新时才把结果写进 UI，避免"被挤下的老 reload 把过期数据盖上"。
            // 被挤下的老 reload 走到这里 guard 失败后**直接 return**，不触碰 loading flag：
            // 后继 reload 在它自己的开头 MainActor.run 已经把 loadToken 刷新 + isLoading 重置 true，
            // 由它自己的结尾负责清 false。老 reload 若在这里抢先清 false，新 reload 还没返回，
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
    }

    private func fetchDailyCells(in range: DateInterval) async -> [DailyCell] {
        // 热力图展示最近 140 天，覆盖范围比 TimeRange 更广以保持视觉稳定
        let today = Date()
        let start = Calendar.current.date(byAdding: .day, value: -140, to: today) ?? range.start
        let fetchRange = DateInterval(start: start, end: today)
        return await PersistenceController.shared.container.performBackgroundTask { context in
            let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
            request.predicate = NSPredicate(
                format: "date >= %@ AND date <= %@",
                fetchRange.start as NSDate,
                fetchRange.end as NSDate
            )
            // 只读需要的字段，节省内存
            request.propertiesToFetch = ["date", "moodValue", "wordCount"]
            request.returnsObjectsAsFaults = false
            guard let entries = try? context.fetch(request) else { return [] }
            let calendar = Calendar.current
            var grouped: [Date: (moodSum: Double, count: Int, words: Int)] = [:]
            grouped.reserveCapacity(entries.count)
            for entry in entries {
                guard let date = entry.date else { continue }
                let day = calendar.startOfDay(for: date)
                var row = grouped[day] ?? (0, 0, 0)
                row.moodSum += entry.moodValue
                row.count += 1
                row.words += Int(entry.wordCount)
                grouped[day] = row
            }
            return grouped.map { (day, row) in
                DailyCell(date: day, mood: row.moodSum / Double(row.count), wordCount: row.words)
            }
        }
    }
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
    @State private var entries: [DiaryEntry] = []

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
            }
            .onAppear(perform: fetch)
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
        let f = DateFormatter()
        f.dateStyle = .medium
        return f.string(from: point.date)
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
