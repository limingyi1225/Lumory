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

    struct MoodPoint: Identifiable, Equatable {
        let date: Date
        let mood: Double   // 0.0 ~ 1.0
        let entryCount: Int
        var id: Date { date }
    }

    enum Bucket: Equatable {
        case day
    }

    struct WritingStats: Equatable {
        let totalEntries: Int
        let currentStreak: Int
        let longestStreak: Int
        let totalWords: Int
        let avgMood: Double
    }

    struct Theme: Identifiable, Equatable {
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

    struct AnswerChunk: Equatable {
        enum Kind: Equatable { case text, citation, truncated, failed }
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

    static let shared = InsightsEngine(
        persistence: .shared,
        ai: OpenAIService.shared
    )

    init(persistence: PersistenceController, ai: AIServiceProtocol) {
        self.persistence = persistence
        self.ai = ai
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

    // MARK: - 5a. Semantic search(F1)
    //
    // 跟 `ask` 同走两阶段检索 + cosine 排名,但**只返 NSManagedObjectID**,UI 自行 materialize 成
    // `DiaryEntry`(SwiftUI cell 直接吃 NSManagedObject,不用先转 DiaryEntryData)。跟 `retrieve()`
    // 不同的是这里**不**给"未索引保留槽":搜索用户想要的是按相关度排,新写的未索引日记夹在中间会
    // confusion;改成把 `indexCoverage` 透出来,UI 在覆盖率 < 95% 时显示"索引不完整"banner +
    // 引导用户去 Settings 一键重建。
    //
    // 失败路径:
    //   - query 空 → 空结果,coverage=1.0
    //   - 网络错(embed 返 nil)→ ids=空,coverage 仍正确(给 UI fallback 到关键词搜索的机会)
    //   - 全语料 0 embedding → ids=空,coverage=0
    //
    // 性能:1500 维 × 1000-2000 entries cosine ≈ 30-80ms 后台 actor;主线程零阻塞。
    // 调用方在 `.searchable` submit 时触发(用户按 return 键),不需要 typing debounce。

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
    /// 调用方自行 fallback)。
    func searchSemantic(query: String, topK: Int = 20) async -> SemanticSearchResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SemanticSearchResult(ids: [], indexCoverage: 1.0, totalCount: 0, queryEmbedded: false)
        }

        let qVec = await ai.embed(text: trimmed)
        let queryEmbedded = qVec != nil

        return await persistence.container.performBackgroundTask { context -> SemanticSearchResult in
            // Phase A: 轻量扫(只 prefetch embedding + date,不 hydrate text 等大字段)
            // 复用 retrieve() 同款策略,见 `InsightsEngine.swift` 那条注释。
            let scanRequest: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
            scanRequest.sortDescriptors = [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)]
            scanRequest.returnsObjectsAsFaults = true
            scanRequest.includesPropertyValues = true
            scanRequest.propertiesToFetch = ["embedding", "date"]
            guard let scanned = try? context.fetch(scanRequest), !scanned.isEmpty else {
                return SemanticSearchResult(ids: [], indexCoverage: 1.0, totalCount: 0, queryEmbedded: queryEmbedded)
            }
            let totalCount = scanned.count
            guard topK > 0 else {
                return SemanticSearchResult(ids: [], indexCoverage: 0.0, totalCount: totalCount, queryEmbedded: queryEmbedded)
            }

            // 无 query 向量 → 直接返空(让 UI 决定 fallback 策略,不偷偷返"最近 K 条"假装是相关结果)
            guard let qVec = qVec else {
                let withVecCount = scanned.filter { $0.embedding != nil }.count
                let coverage = Double(withVecCount) / Double(max(1, totalCount))
                return SemanticSearchResult(ids: [], indexCoverage: coverage, totalCount: totalCount, queryEmbedded: false)
            }

            // 跟 retrieve() 同款 bounded heap(insertion sort),内存 O(K) 而非 O(N)。
            var topHeap: [(id: NSManagedObjectID, score: Float)] = []
            topHeap.reserveCapacity(topK)
            var withoutVecCount = 0
            var maxScore: Float = -.infinity
            for entry in scanned {
                guard let vec = entry.embeddingVector else {
                    withoutVecCount += 1
                    continue
                }
                let score = Self.cosineSimilarity(qVec, vec)
                if score > maxScore { maxScore = score }
                if topHeap.count < topK {
                    let insertAt = topHeap.firstIndex(where: { $0.score < score }) ?? topHeap.count
                    topHeap.insert((entry.objectID, score), at: insertAt)
                } else if let last = topHeap.last, score > last.score {
                    topHeap.removeLast()
                    let insertAt = topHeap.firstIndex(where: { $0.score < score }) ?? topHeap.count
                    topHeap.insert((entry.objectID, score), at: insertAt)
                }
            }

            let withVecCount = totalCount - withoutVecCount
            let coverage = Double(withVecCount) / Double(max(1, totalCount))

            // **P1 fix (2026-05-15 megareview, refined by 2026-05-15 superreview P2)**:
            // `cosineSimilarity` 在维度不匹配时返 0(legacy embedding 用旧 dim 写过,
            // index 仍有 embedding 字段但跟当前 query dim 不对齐)。全 0 score 时 bounded heap
            // 仍然填满前 K 条按日期降序的 entry,返回成"语义最相关"假象。
            //
            // 用 `abs()` —— query 跟所有 entry 都语义对立时 cosine 可能负且 max 仍接近 0
            // (例:query="开心快乐" + 全是负面 entry → 所有 entry 都 cosine ≈ -0.x,maxScore 是
            // 接近 -1 的值)。但 dim-mismatch 的 0 是真的接近 0,不是负值。**用 abs 抓 "全维度
            // 错配返 0" 这个特征**,既能挡 dim-mismatch 又不误伤"全负相关"的合法语义场景。
            // 真实空相关性场景由前面的 `withoutVecCount == totalCount` 路径覆盖。
            if withVecCount > 0 && abs(maxScore) < 1e-6 {
                Log.warning("[InsightsEngine] searchSemantic: max cosine ≈ 0 across \(withVecCount) embeddings — dimension mismatch likely; returning empty", category: .ai)
                return SemanticSearchResult(
                    ids: [],
                    indexCoverage: 0.0,
                    totalCount: totalCount,
                    queryEmbedded: true
                )
            }

            // 注意:**不**保留 unindexed 槽位 — 搜索是按相关度排,不是 AI grounding。
            // 覆盖率不足时 UI 显示 banner 让用户主动去 Settings 重建。
            return SemanticSearchResult(
                ids: topHeap.map { $0.id },
                indexCoverage: coverage,
                totalCount: totalCount,
                queryEmbedded: true
            )
        }
    }

    // MARK: - 5. Ask Your Past (RAG)

    func ask(_ question: String, topK: Int = 8) -> AsyncStream<AnswerChunk> {
        AsyncStream { continuation in
            let task = Task {
                guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continuation.finish()
                    return
                }

                let qVec = await self.ai.embed(text: question)
                let selected = await self.retrieve(query: question, queryVector: qVec, topK: topK)

                if !selected.isEmpty {
                    continuation.yield(AnswerChunk(citations: selected.map { $0.id }))
                }
                // 升级消费:走 askEvents,把 .truncated 单独冒泡给 UI
                for await event in self.ai.askEvents(question: question, context: selected) {
                    if Task.isCancelled { break }
                    switch event {
                    case .chunk(let text):
                        continuation.yield(AnswerChunk(text: text))
                    case .truncated(let reason):
                        continuation.yield(AnswerChunk(truncatedReason: reason))
                    case .failed(let error):
                        // **区分 truncated 和 failed**:truncated 是"断在中间,已有部分内容";
                        // failed 是"一点内容都没产出"(离线 / 401 / 5xx)。合并成 truncated 会让
                        // AskPastView 只显示空 bubble + 通用 banner,用户看不到具体错误。
                        continuation.yield(AnswerChunk(failureReason: error.localizedDescription))
                    case .done:
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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

    private func retrieve(query: String, queryVector: [Float]?, topK: Int) async -> [DiaryEntryData] {
        // **两阶段检索**(Fix #20):
        //  Phase A —— 轻量扫:只 prefetch `embedding` + `date`,**不**触发 text/summary/themes/imagesData
        //             的 fault。1000 条 × 6KB embedding ≈ 6MB,vs 旧实现 15-30MB 全量物化。
        //             用 bounded top-K 数组(insertion sort)代替 O(N log N) 全排序,峰值内存 O(K) 而非 O(N)。
        //  Phase B —— 物化:拿 top-K objectIDs 回填完整 DiaryEntryData。每个 objectID 通过 fault 取数,
        //             成本和原方案的 mapping 一致,但只对 K 条。
        //
        // 无 query 向量 / 全无 embedding 走时间倒序兜底(语义见 rankRetrieval 注释),这条路径在 Phase A 内完成。
        return await persistence.container.performBackgroundTask { context -> [DiaryEntryData] in
            // Phase A: lightweight scan
            let scanRequest: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
            scanRequest.sortDescriptors = [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)]
            // returnsObjectsAsFaults=true + propertiesToFetch=[embedding, date] →
            // 仅这两列进 row cache,其它属性保持 fault,scan 阶段不会去读 text 列。
            scanRequest.returnsObjectsAsFaults = true
            scanRequest.includesPropertyValues = true
            scanRequest.propertiesToFetch = ["embedding", "date"]
            guard let scanned = try? context.fetch(scanRequest), !scanned.isEmpty else { return [] }
            guard topK > 0 else { return [] }

            // 兜底路径:无 query 向量 → 直接取最近 topK,Phase B 时材料化
            guard let qVec = queryVector else {
                let ids = scanned.prefix(topK).map { $0.objectID }
                return Self.materialize(objectIDs: Array(ids), in: context)
            }

            // 收集 (objectID, score),用 bounded min-heap 维护当前 top-K(K 通常 8-20):
            // 用 sorted insertion 模拟 —— `topHeap` 始终按 score 降序;新候选 < heap 末尾(最小值)直接丢,
            // 否则 insertion-sort 进去并把溢出末尾踢掉。K=20 时每次 insertion 最差 20 次比较。
            var topHeap: [(id: NSManagedObjectID, score: Float)] = []
            topHeap.reserveCapacity(topK)
            // 同步收集"无 embedding"的 objectID + date,以便最后做"未索引语料保留槽"逻辑(对齐 rankRetrieval 行为)。
            var withoutVecIDs: [(id: NSManagedObjectID, date: Date)] = []
            withoutVecIDs.reserveCapacity(scanned.count)

            for entry in scanned {
                guard let vec = entry.embeddingVector else {
                    withoutVecIDs.append((entry.objectID, entry.date ?? .distantPast))
                    continue
                }
                let score = Self.cosineSimilarity(qVec, vec)
                if topHeap.count < topK {
                    // 插入并保持降序
                    let insertAt = topHeap.firstIndex(where: { $0.score < score }) ?? topHeap.count
                    topHeap.insert((entry.objectID, score), at: insertAt)
                } else if let last = topHeap.last, score > last.score {
                    // 比当前最小分还高 —— 替换尾部,insertion-sort 到正确位置
                    topHeap.removeLast()
                    let insertAt = topHeap.firstIndex(where: { $0.score < score }) ?? topHeap.count
                    topHeap.insert((entry.objectID, score), at: insertAt)
                }
            }

            // 全语料无 embedding → 走时间兜底(scanned 已按 date desc)
            guard !topHeap.isEmpty else {
                let ids = scanned.prefix(topK).map { $0.objectID }
                return Self.materialize(objectIDs: Array(ids), in: context)
            }

            // 计算"未索引保留槽":覆盖率不到 95% 或有 5 分钟内新条目时,留 max(2, topK/3) 给最近未索引。
            // 与 rankRetrieval 的策略一致,只是这里直接对 objectID 操作,不必回填 DiaryEntryData。
            let totalCount = scanned.count
            let withVecCount = totalCount - withoutVecIDs.count
            let indexCoverage = Double(withVecCount) / Double(max(1, totalCount))
            let now = Date()
            let hasFreshUnindexed = withoutVecIDs.contains { now.timeIntervalSince($0.date) < 300 }
            let minRecencyReserve: Int
            if !withoutVecIDs.isEmpty, indexCoverage < 0.95 || hasFreshUnindexed {
                minRecencyReserve = min(max(2, topK / 3), withoutVecIDs.count)
            } else {
                minRecencyReserve = 0
            }

            let maxSemanticSlots = max(0, topK - minRecencyReserve)
            let semanticIDs = topHeap.prefix(maxSemanticSlots).map { $0.id }
            let remainingSlots = max(0, topK - semanticIDs.count)
            // withoutVecIDs 来自按 date desc 的 scanned,所以它本身已按 date desc
            let recentUnindexed = withoutVecIDs.prefix(min(remainingSlots, withoutVecIDs.count)).map { $0.id }

            let finalIDs = Array(semanticIDs) + Array(recentUnindexed)

            // Phase B: 物化
            return Self.materialize(objectIDs: finalIDs, in: context)
        }
    }

    /// 把一批 objectID 物化成 `DiaryEntryData`。每个 `context.object(with:)` 是 cheap fault,
    /// 第一次访问其属性才会 round-trip 到 row cache。这里遍历完成后所有属性都被读过一次,
    /// 跨 context 边界返回值类型是安全的。
    /// `includeEmbedding=false`(默认):跳过 `embeddingVector` 解包,省 K × 6KB Float32 拷贝
    /// (retrieve Phase B 给 ask path 用,消费方只读 id / 文本字段,embedding 拷出来就丢)。
    private static func materialize(
        objectIDs: [NSManagedObjectID],
        in context: NSManagedObjectContext,
        includeEmbedding: Bool = false
    ) -> [DiaryEntryData] {
        objectIDs.compactMap { id in
            guard let entry = try? context.existingObject(with: id) as? DiaryEntry else { return nil }
            return DiaryEntryData(
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

    /// 纯函数版检索排名（方便单测）：
    ///  - 无 query 向量 → 按时间倒序返回 topK
    ///  - 全语料都没 embedding → 同上
    ///  - 有部分 embedded、部分没 embedded：**不能只看 embedded 那一半**，
    ///    否则 backfill 没跑完时 Ask Past / 语义搜索只看到索引过的语料子集，
    ///    对剩下的历史日记装聋作哑。现在预留 `topK` 的 1/3（夹在 2-5 之间）
    ///    给"最近但没建索引"的条目，让 AI 至少能看到新鲜未索引语料。
    static func rankRetrieval(
        all: [DiaryEntryData],
        queryVector: [Float]?,
        topK: Int
    ) -> [DiaryEntryData] {
        guard topK > 0, !all.isEmpty else { return [] }

        // 无 query 向量：时间倒序兜底
        guard let qVec = queryVector else {
            return Array(all.sorted { $0.date > $1.date }.prefix(topK))
        }

        let withVectors = all.filter { $0.embedding != nil }
        let withoutVectors = all.filter { $0.embedding == nil }

        // 全语料没 embedding：等于无 query 向量走兜底
        guard !withVectors.isEmpty else {
            return Array(all.sorted { $0.date > $1.date }.prefix(topK))
        }

        // 语义排名
        let scoredEmbedded: [DiaryEntryData] = withVectors
            .map { ($0, InsightsEngine.cosineSimilarity(qVec, $0.embedding ?? [])) }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }

        // 只有两种情况才给最近未索引条目留保留槽:
        //   (a) 索引覆盖率不到 95% —— backfill 还没跑完,尾部未索引日记仍占相当比例
        //   (b) 5 分钟内有新写但未索引的条目 —— 用户刚写完马上问"刚才那条"的窗口
        // 其它情况(覆盖率 ≥ 95% 且无新鲜未索引)完全交给语义排名,避免把不相关的老条目塞进 context。
        let indexCoverage = Double(withVectors.count) / Double(max(1, all.count))
        let now = Date()
        let hasFreshUnindexed = withoutVectors.contains { now.timeIntervalSince($0.date) < 300 }
        let minRecencyReserve: Int
        if !withoutVectors.isEmpty, indexCoverage < 0.95 || hasFreshUnindexed {
            minRecencyReserve = min(max(2, topK / 3), withoutVectors.count)
        } else {
            minRecencyReserve = 0
        }

        let maxSemanticSlots = max(0, topK - minRecencyReserve)
        let topSemantic = Array(scoredEmbedded.prefix(maxSemanticSlots))

        let remainingSlots = max(0, topK - topSemantic.count)
        let recentNonIndexed = Array(
            withoutVectors
                .sorted { $0.date > $1.date }
                .prefix(min(remainingSlots, withoutVectors.count))
        )
        return topSemantic + recentNonIndexed
    }

    // MARK: - Math helpers

    /// 余弦相似度。长度不等时返回 0（而不是截断比较），避免误导。空向量返回 0。
    static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return 0 }
        let count = vDSP_Length(lhs.count)
        var dot: Float = 0
        vDSP_dotpr(lhs, 1, rhs, 1, &dot, count)
        var aNorm: Float = 0
        vDSP_svesq(lhs, 1, &aNorm, count)
        var bNorm: Float = 0
        vDSP_svesq(rhs, 1, &bNorm, count)
        let denom = sqrt(aNorm) * sqrt(bNorm)
        guard denom > 0 else { return 0 }
        return dot / denom
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
