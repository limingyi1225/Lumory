import Foundation
import CoreData
import Accelerate

// MARK: - InsightsEngine
//
// Phase 0 · 地基。统一 AI × 统计调用入口，所有 Dashboard / Ask-Your-Past / 写作伙伴
// 共享同一个上下文和检索路径，避免各视图层重复造轮子。
//
// 本文件只放 *纯逻辑* 和 *Core Data 聚合*；对 AI 的调用全部经由 `AIServiceProtocol`。
//
// 设计原则：
//  1. 读取 Core Data 时始终用后台 context (`performBackgroundTask`)，避免阻塞主线程。
//  2. 结果以值类型返回；不向外暴露 NSManagedObject，避免跨线程访问。
//  3. AI 相关结果尽可能以 AsyncStream 流式返回，让 UI 逐字显示。
//  4. 所有聚合的"纯函数"核心暴露为 `static func`，便于单元测试。

final class InsightsEngine {
    // MARK: Public value types

    struct MoodPoint: Identifiable, Equatable, Sendable {
        let date: Date
        let mood: Double   // 0.0 ~ 1.0
        let entryCount: Int
        var id: Date { date }
    }

    enum Bucket: Equatable, Sendable {
        case day
    }

    struct WritingStats: Equatable, Sendable {
        let totalEntries: Int
        let currentStreak: Int
        let longestStreak: Int
        let totalWords: Int
        let avgMood: Double
    }

    struct Theme: Identifiable, Equatable, Sendable {
        let name: String
        let count: Int           // 出现过的日记条目数
        let uniqueDays: Int      // 出现在多少个不同的日子——衡量"反复出现"而不是"突发频繁"
        let avgMood: Double
        /// 情绪两极:用 0.45 / 0.55 阈值切分而非中位数——中位数永远 50/50,
        /// 反映不出"8 篇开心 + 2 篇难过"这种比例,UI 也就没法按比例渲染色斑面积。
        /// 极端为空时用 avgMood 兜底。
        let moodLow: Double
        let moodHigh: Double
        /// 用于 UI 决定两个色斑的相对面积。`lowCount + highCount + 中性数 == count`。
        let lowCount: Int
        let highCount: Int
        let entryIds: [UUID]
        var id: String { name }
    }

    struct AnswerChunk: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case text, citation, truncated, failed }
        let kind: Kind
        let text: String
        let citedEntryIds: [UUID]
        init(text: String) { self.kind = .text; self.text = text; self.citedEntryIds = [] }
        init(citations ids: [UUID]) { self.kind = .citation; self.text = ""; self.citedEntryIds = ids }
        /// 流中断(已有部分内容) —— `text` 是 localized 原因说明,UI 应显示警示条,
        /// 不要把它当正文 append 到 message body。用户可以重新生成。
        init(truncatedReason reason: String) { self.kind = .truncated; self.text = reason; self.citedEntryIds = [] }
        /// 流彻底失败(没产出任何内容) —— `text` 是 error.localizedDescription,
        /// UI 应展示为"可操作错误"(显示出原文,而不是通用截断提示),让用户知道是网络还是认证。
        init(failureReason reason: String) { self.kind = .failed; self.text = reason; self.citedEntryIds = [] }
    }

    // MARK: Dependencies

    private let persistence: PersistenceController
    private let ai: AIServiceProtocol
    // **Search + RAG 子系统**(2026-05-16 round 3 拆出独立 file InsightsSearchEngine.swift):
    // 同 `persistence` + `ai` 注入,跟主 engine 同生命周期。callsite 通过下方
    // `searchSemantic(...)` / `ask(...)` facade forward 透明转发,**测试零改动**
    // —— `InsightsEngine(persistence:ai:)` 注入的 mock 自动流到 SearchEngine。
    private let searchEngine: InsightsSearchEngine

    static let shared = InsightsEngine(
        persistence: .shared,
        ai: OpenAIService.shared
    )

    init(persistence: PersistenceController, ai: AIServiceProtocol) {
        self.persistence = persistence
        self.ai = ai
        self.searchEngine = InsightsSearchEngine(persistence: persistence, ai: ai)
    }

    // MARK: - 0. Range counters (浓缩卡 staleness 用)
    //
    // **不能凑现有 `writingStats().totalEntries`**(那是全局,不带 range);**也不能用
    // `dailyCells`** —— `InsightsView.fetchDailyCells` 为 heatmap 扩到 22 周窗口
    // (`lookbackDays=161`),既无序也超出 range。所以单写两个轻量 helper:
    //
    // - `entryCount(in:)` 走 NSDictionaryResultType + countFetch(不实例化 NSManagedObject)
    // - `mostRecentEntryDate(in:)` 走 fetchLimit=1 + sortDescriptor descending

    /// 该 range 内日记总数。NarrativeSummaryCard 判 stale + entryCount<3 disable。
    func entryCount(in range: DateInterval) async -> Int {
        await persistence.container.performBackgroundTask { context -> Int in
            let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
            request.predicate = NSPredicate(
                format: "date >= %@ AND date <= %@",
                range.start as NSDate, range.end as NSDate
            )
            return (try? context.count(for: request)) ?? 0
        }
    }

    /// 该 range 内最新一篇日记的 date。判 cache 是否被新日记 invalidate。
    /// nil = range 内无日记。
    func mostRecentEntryDate(in range: DateInterval) async -> Date? {
        await persistence.container.performBackgroundTask { context -> Date? in
            let request: NSFetchRequest<NSDictionary> = NSFetchRequest<NSDictionary>(entityName: "DiaryEntry")
            request.resultType = .dictionaryResultType
            request.predicate = NSPredicate(
                format: "date >= %@ AND date <= %@",
                range.start as NSDate, range.end as NSDate
            )
            request.propertiesToFetch = ["date"]
            request.sortDescriptors = [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)]
            request.fetchLimit = 1
            guard let rows = try? context.fetch(request),
                  let row = rows.first,
                  let date = row["date"] as? Date else { return nil }
            return date
        }
    }

    // MARK: - 1. Mood series (纯本地聚合)

    /// 按 bucket 聚合情绪曲线。空 bucket 会被跳过。
    func moodSeries(in range: DateInterval, bucket: Bucket) async -> [MoodPoint] {
        let entries = await fetchEntryData(in: range)
        return Self.aggregateMoodSeries(entries: entries, bucket: bucket)
    }

    /// 纯函数版本，便于单元测试。
    static func aggregateMoodSeries(entries: [DiaryEntryData], bucket: Bucket) -> [MoodPoint] {
        guard !entries.isEmpty else { return [] }
        let calendar = Calendar.current
        var grouped: [Date: (sum: Double, count: Int)] = [:]
        grouped.reserveCapacity(entries.count)
        for entry in entries {
            let key = startOfBucket(entry.date, bucket: bucket, calendar: calendar)
            var bucketData = grouped[key] ?? (0, 0)
            bucketData.sum += entry.moodValue
            bucketData.count += 1
            grouped[key] = bucketData
        }
        return grouped
            .map { MoodPoint(date: $0.key, mood: $0.value.sum / Double($0.value.count), entryCount: $0.value.count) }
            .sorted { $0.date < $1.date }
    }

    // MARK: - 2. Writing stats (streak / totals)

    func writingStats() async -> WritingStats {
        // **外部预算 today**：`performBackgroundTask` 内部的 `Date()` 在 DST 切换 /
        // 时区漂移的边界秒内可能落在不同的自然日，导致 streak 漏算一天。
        // 在调用者所在线程先快照 "now / today"，传进 background 做纯计算，时间锚定得很死。
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return await persistence.container.performBackgroundTask { context -> WritingStats in
            let request = NSFetchRequest<NSDictionary>(entityName: "DiaryEntry")
            request.resultType = .dictionaryResultType
            request.sortDescriptors = [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)]
            request.propertiesToFetch = ["date", "moodValue", "wordCount"]
            guard let dicts = try? context.fetch(request), !dicts.isEmpty else {
                return WritingStats(totalEntries: 0, currentStreak: 0, longestStreak: 0, totalWords: 0, avgMood: 0.5)
            }

            // 单次遍历：总数、字数、情绪和、唯一日期
            var totalWords = 0
            var moodSum = 0.0
            var uniqueDaysDesc: [Date] = []
            uniqueDaysDesc.reserveCapacity(dicts.count)
            for dict in dicts {
                totalWords += (dict["wordCount"] as? NSNumber)?.intValue ?? 0
                moodSum += (dict["moodValue"] as? NSNumber)?.doubleValue ?? 0.5
                if let date = dict["date"] as? Date {
                    let day = calendar.startOfDay(for: date)
                    if uniqueDaysDesc.last != day { uniqueDaysDesc.append(day) }
                }
            }
            let total = dicts.count
            let avg = moodSum / Double(total)
            let (currentStreak, longestStreak) = Self.computeStreaks(uniqueDaysDesc: uniqueDaysDesc, today: today, calendar: calendar)

            return WritingStats(
                totalEntries: total,
                currentStreak: currentStreak,
                longestStreak: longestStreak,
                totalWords: totalWords,
                avgMood: avg
            )
        }
    }

    /// 纯函数版本：输入按日期降序去重的日子数组，返回 (当前连续, 最长连续)。
    static func computeStreaks(uniqueDaysDesc: [Date], today: Date, calendar: Calendar = .current) -> (current: Int, longest: Int) {
        guard let first = uniqueDaysDesc.first else { return (0, 0) }

        var current = 0
        let diff = calendar.dateComponents([.day], from: first, to: today).day ?? 0
        // 今天或昨天写过都算当前连续中
        if diff <= 1 {
            current = 1
            for i in 1..<uniqueDaysDesc.count {
                let gap = calendar.dateComponents([.day], from: uniqueDaysDesc[i], to: uniqueDaysDesc[i-1]).day ?? 0
                if gap == 1 { current += 1 } else { break }
            }
        }

        // 最长连续：单次线性扫描
        var longest = 0
        var run = 0
        for i in 0..<uniqueDaysDesc.count {
            if i == 0 {
                run = 1
            } else {
                let gap = calendar.dateComponents([.day], from: uniqueDaysDesc[i], to: uniqueDaysDesc[i-1]).day ?? 0
                run = (gap == 1) ? run + 1 : 1
            }
            if run > longest { longest = run }
        }
        return (current, longest)
    }

    // MARK: - 3. Themes

    func themes(in range: DateInterval, limit: Int = 5) async -> [Theme] {
        async let aliasMapAsync = MainActor.run { ThemeAliasResolver.shared.snapshotIndex() }
        let entries = await fetchEntryData(in: range)
        let aliasMap = await aliasMapAsync
        return Self.aggregateThemes(entries: entries, range: range, limit: limit, aliasMap: aliasMap)
    }

    /// 纯函数版本，便于单元测试。
    /// `aliasMap`: lowercased(alias) → canonical(原文大小写)。空 dict 等价于无别名。
    /// 把别名折成 canonical 后再 bucket —— "Abby" / "宝贝" 会落到同一个 Theme(显示名是 canonical)。
    /// `range` 当前未使用(2026-05-16 删 sparkline 后失去 caller),保留参数避免动 12 处测试 callsite。
    static func aggregateThemes(
        entries: [DiaryEntryData],
        range _: DateInterval,
        limit: Int = 5,
        aliasMap: [String: String] = [:]
    ) -> [Theme] {
        guard !entries.isEmpty else { return [] }

        // 统计每个主题的出现条目；过滤掉元描述词（历史数据里可能还存着"情绪"等）。
        // 跨日记做 case-insensitive 合并：Abby / abby / ABBY → 同一个 bucket。
        // 命中 aliasMap 时把别名映射成 canonical(显示名也用 canonical);
        // 不在 map 里的 tag 走原 first-seen 逻辑(按 entry date ASC,稳定)。
        var bucketMap: [String: (displayName: String, items: [DiaryEntryData])] = [:]
        let sortedEntries = entries.sorted { $0.date < $1.date }
        for entry in sortedEntries {
            // 同一篇 entry 内,如果 themes 包含多个映射到同一 canonical 的 tag(比如 ["Abby","宝贝"]),
            // 不能往同一 bucket 重复 append 同一 entry —— 否则 count/uniqueDays 翻倍。
            var contributedKeys = Set<String>()
            for theme in entry.themes where !theme.isEmpty && !isBannedTheme(theme) {
                let themeKey = ThemeKey.make(theme)
                let canonical = aliasMap[themeKey] ?? theme
                let key = ThemeKey.make(canonical)
                guard contributedKeys.insert(key).inserted else { continue }
                if var existing = bucketMap[key] {
                    existing.items.append(entry)
                    bucketMap[key] = existing
                } else {
                    // displayName 优先用 canonical(map 命中) / 否则当前 tag 原文
                    let displayName = aliasMap[themeKey] ?? theme
                    bucketMap[key] = (displayName, [entry])
                }
            }
        }

        let calendar = Calendar.current
        return bucketMap.values
            .map { bucket -> Theme in
                let items = bucket.items
                let uniqueDays = Set(items.map { calendar.startOfDay(for: $0.date) }).count
                let moods = items.map { $0.moodValue }
                let avg = moods.reduce(0, +) / Double(moods.count)
                // 阈值 0.45 / 0.55 跟 Color.moodSpectrum 的"中性带"边界对齐——
                // 不在两极的条目算中性,既不参与 high 池也不参与 low 池。
                let lowMoods = moods.filter { $0 < 0.45 }
                let highMoods = moods.filter { $0 > 0.55 }
                let moodLow = lowMoods.isEmpty ? avg : lowMoods.reduce(0, +) / Double(lowMoods.count)
                let moodHigh = highMoods.isEmpty ? avg : highMoods.reduce(0, +) / Double(highMoods.count)
                return Theme(
                    name: bucket.displayName,
                    count: items.count,
                    uniqueDays: uniqueDays,
                    avgMood: avg,
                    moodLow: moodLow,
                    moodHigh: moodHigh,
                    lowCount: lowMoods.count,
                    highCount: highMoods.count,
                    entryIds: items.map { $0.id }
                )
            }
            // 先按出现的"天数"排序——反复出现的人物/项目优先；tie-break 用条目总数
            .sorted {
                if $0.uniqueDays != $1.uniqueDays { return $0.uniqueDays > $1.uniqueDays }
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - 4. Streaming narrative

    /// 事件流 —— 消费方能感知 `.truncated` / `.failed` 做 UI banner。
    @available(iOS 15.0, macOS 12.0, *)
    func streamNarrativeEvents(in range: DateInterval) -> AsyncStream<StreamEvent> {
        AsyncStream { continuation in
            let task = Task {
                let entries = await self.fetchEntryData(in: range)
                guard !entries.isEmpty else {
                    continuation.finish()
                    return
                }
                for await event in self.ai.streamReportEvents(entries: entries) {
                    if Task.isCancelled { break }
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 5a. Semantic search(F1)— facade forwarder
    //
    // 实现 + 完整设计文档(两阶段检索 / 失败路径 / 性能特征 / 索引覆盖率语义)在
    // [InsightsSearchEngine.swift](InsightsSearchEngine.swift)。`SemanticSearchResult`
    // 留这里因为它是嵌套类型 + 跨 view 层(`HomeView+Search.swift`)消费,搬走会拖一片
    // caller。改 search 行为改 InsightsSearchEngine.swift,改 result 字段改这里。

    /// 返回类型:跨 actor 边界,所有字段 Sendable。
    struct SemanticSearchResult: Sendable {
        /// 按相关度降序的 entry objectIDs(最多 topK 条)。空 = 没结果(可能因为 embed 失败或 0 索引覆盖)。
        let ids: [NSManagedObjectID]
        /// 已建索引日记数 / 总日记数。`< 0.95` UI 应该提示"索引不完整"。空库时为 1.0。
        let indexCoverage: Double
        /// 数据库里日记总数(给 UI 算"没在结果里的占比")。
        let totalCount: Int
        /// query embed 是否成功。false → 网络/认证问题,UI 应该 fallback 关键词搜索 / 显示重试。
        let queryEmbedded: Bool
    }

    /// F1 语义搜索入口。AI service 要返回 query 向量(embed 失败时 `queryEmbedded=false`,
    /// 调用方自行 fallback)。**实现迁到 [InsightsSearchEngine](InsightsSearchEngine.swift),本方法是 facade forwarder**。
    func searchSemantic(query: String, topK: Int = 20) async -> SemanticSearchResult {
        await searchEngine.searchSemantic(query: query, topK: topK)
    }

    // MARK: - 5. Ask Your Past (RAG)

    /// **实现迁到 [InsightsSearchEngine](InsightsSearchEngine.swift),本方法是 facade forwarder**。
    func ask(_ question: String, topK: Int = 8) -> AsyncStream<AnswerChunk> {
        searchEngine.ask(question, topK: topK)
    }

    // MARK: - 6. 近 N 条（给 prompt suggestion 做 grounding 用）

    /// 返回最近 `limit` 条日记，按时间倒序。每条的 `text` 会被截到 `textCharCap` 字符以内，
    /// 避免塞给 LLM 的 context 膨胀。
    func recentEntries(limit: Int = 3, textCharCap: Int = 200) async -> [DiaryEntryData] {
        await persistence.container.performBackgroundTask { context -> [DiaryEntryData] in
            let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)]
            request.fetchLimit = limit
            request.returnsObjectsAsFaults = false
            guard let entries = try? context.fetch(request) else { return [] }
            return entries.map { entry in
                let rawText = entry.text ?? ""
                let truncated = rawText.count > textCharCap
                    ? String(rawText.prefix(textCharCap))
                    : rawText
                return DiaryEntryData(
                    id: entry.id ?? UUID(),
                    date: entry.date ?? Date(),
                    text: truncated,
                    moodValue: entry.moodValue,
                    summary: entry.summary ?? "",
                    themes: entry.themeArray,
                    embedding: nil,   // grounding 不需要向量
                    wordCount: Int(entry.wordCount)
                )
            }
        }
    }

    // MARK: - Private

    private func fetchEntryData(in range: DateInterval, includeEmbedding: Bool = false) async -> [DiaryEntryData] {
        await persistence.container.performBackgroundTask { context -> [DiaryEntryData] in
            let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
            request.predicate = NSPredicate(format: "date >= %@ AND date <= %@",
                                            range.start as NSDate, range.end as NSDate)
            request.sortDescriptors = [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: true)]
            request.returnsObjectsAsFaults = false
            guard let entries = try? context.fetch(request) else { return [] }
            return entries.map { entry in
                DiaryEntryData(
                    id: entry.id ?? UUID(),
                    date: entry.date ?? Date(),
                    text: entry.text ?? "",
                    moodValue: entry.moodValue,
                    summary: entry.summary ?? "",
                    themes: entry.themeArray,
                    embedding: includeEmbedding ? entry.embeddingVector : nil,
                    wordCount: Int(entry.wordCount)
                )
            }
        }
    }

    // MARK: - Static forwarding wrappers (test-facing API)
    //
    // **2026-05-16 round 3**:Search/RAG 实现迁到 [InsightsSearchEngine](InsightsSearchEngine.swift),
    // 但 `ChronoteTests/ChronoteTests.swift` 有 **15 处** 静态调用
    // (`InsightsEngine.cosineSimilarity` ×6 + `InsightsEngine.rankRetrieval` ×9)。
    // 不留 wrapper → 15 测试编不过。wrapper 是一行 forwarder,无 runtime 开销。

    /// 余弦相似度。长度不等时返回 0(而不是截断比较),避免误导。空向量返回 0。
    /// **Forwarder**:实现在 `InsightsSearchEngine.cosineSimilarity`。
    static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        InsightsSearchEngine.cosineSimilarity(lhs, rhs)
    }

    /// 纯函数版检索排名(方便单测)。**Forwarder**:实现在 `InsightsSearchEngine.rankRetrieval`。
    static func rankRetrieval(
        all: [DiaryEntryData],
        queryVector: [Float]?,
        topK: Int
    ) -> [DiaryEntryData] {
        InsightsSearchEngine.rankRetrieval(all: all, queryVector: queryVector, topK: topK)
    }

    /// 元描述标签：情绪/心情/感受 之类。历史数据里可能已经写进 themes CSV，显示时统一过滤。
    /// 新写入的日记由 `OpenAIService.extractThemes` 的 banned 列表在 AI 那一层就挡掉。
    static func isBannedTheme(_ raw: String) -> Bool {
        Self.bannedThemeSet.contains(raw.lowercased())
    }

    private static let bannedThemeSet: Set<String> = [
        "情绪", "心情", "感受", "反思", "日常", "记录", "生活",
        "思考", "想法", "感想", "焦虑", "开心", "难过", "疲惫",
        "情感", "心得", "感悟",
        "emotion", "emotions", "feeling", "feelings", "mood", "moods",
        "reflection", "daily", "journal", "journaling", "thought",
        "thoughts", "anxiety", "happy", "sad", "tired", "life", "general",
        "vibe", "vibes"
    ]

    static func startOfBucket(_ date: Date, bucket: Bucket, calendar: Calendar) -> Date {
        switch bucket {
        case .day:
            return calendar.startOfDay(for: date)
        }
    }
}
