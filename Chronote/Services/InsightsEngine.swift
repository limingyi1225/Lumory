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
        case day, week, month
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
        let entryIds: [UUID]
        let trend: [Double]  // 最近 N 个 bucket 的 avg mood，供 sparkline
        var id: String { name }
    }

    struct AnswerChunk: Equatable {
        enum Kind: Equatable { case text, citation }
        let kind: Kind
        let text: String
        let citedEntryIds: [UUID]
        init(text: String) { self.kind = .text; self.text = text; self.citedEntryIds = [] }
        init(citations ids: [UUID]) { self.kind = .citation; self.text = ""; self.citedEntryIds = ids }
    }

    // MARK: Dependencies

    private let persistence: PersistenceController
    private let ai: AIServiceProtocol

    static let shared = InsightsEngine(
        persistence: .shared,
        ai: OpenAIService(apiKey: "")
    )

    init(persistence: PersistenceController, ai: AIServiceProtocol) {
        self.persistence = persistence
        self.ai = ai
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
            let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)]
            request.propertiesToFetch = ["date", "moodValue", "wordCount"]
            request.returnsObjectsAsFaults = false
            guard let entries = try? context.fetch(request), !entries.isEmpty else {
                return WritingStats(totalEntries: 0, currentStreak: 0, longestStreak: 0, totalWords: 0, avgMood: 0.5)
            }

            // 单次遍历：总数、字数、情绪和、唯一日期
            var totalWords = 0
            var moodSum = 0.0
            var uniqueDaysDesc: [Date] = []
            uniqueDaysDesc.reserveCapacity(entries.count)
            for entry in entries {
                totalWords += Int(entry.wordCount)
                moodSum += entry.moodValue
                if let date = entry.date {
                    let day = calendar.startOfDay(for: date)
                    if uniqueDaysDesc.last != day { uniqueDaysDesc.append(day) }
                }
            }
            let total = entries.count
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

    func themes(in range: DateInterval, limit: Int = 5, trendBuckets: Int = 6) async -> [Theme] {
        let entries = await fetchEntryData(in: range)
        return Self.aggregateThemes(entries: entries, range: range, limit: limit, trendBuckets: trendBuckets)
    }

    /// 纯函数版本，便于单元测试。
    static func aggregateThemes(entries: [DiaryEntryData], range: DateInterval, limit: Int = 5, trendBuckets: Int = 6) -> [Theme] {
        guard !entries.isEmpty else { return [] }
        guard trendBuckets > 0 else { return [] }

        // 统计每个主题的出现条目；过滤掉元描述词（历史数据里可能还存着"情绪"等）。
        // 跨日记做 case-insensitive 合并：Abby / abby / ABBY → 同一个 bucket，
        // 展示名保留**首次出现**的原文大小写（按 entry date ASC 排序，First-seen 稳定）。
        var bucketMap: [String: (displayName: String, items: [DiaryEntryData])] = [:]
        let sortedEntries = entries.sorted { $0.date < $1.date }
        for entry in sortedEntries {
            for theme in entry.themes where !theme.isEmpty && !isBannedTheme(theme) {
                let key = theme.lowercased()
                if var existing = bucketMap[key] {
                    existing.items.append(entry)
                    bucketMap[key] = existing
                } else {
                    bucketMap[key] = (theme, [entry])
                }
            }
        }

        // 计算 trend：按时间等分成 trendBuckets 份，每份取平均心情
        let safeBucketSize = max(range.duration / Double(trendBuckets), 1)
        func trendFor(_ items: [DiaryEntryData]) -> [Double] {
            var sums = [Double](repeating: 0, count: trendBuckets)
            var counts = [Int](repeating: 0, count: trendBuckets)
            for entry in items {
                let offset = entry.date.timeIntervalSince(range.start)
                let idx = min(trendBuckets - 1, max(0, Int(offset / safeBucketSize)))
                sums[idx] += entry.moodValue
                counts[idx] += 1
            }
            return zip(sums, counts).map { $1 > 0 ? $0 / Double($1) : 0.5 }
        }

        let calendar = Calendar.current
        return bucketMap.values
            .map { bucket -> Theme in
                let items = bucket.items
                let uniqueDays = Set(items.map { calendar.startOfDay(for: $0.date) }).count
                return Theme(
                    name: bucket.displayName,
                    count: items.count,
                    uniqueDays: uniqueDays,
                    avgMood: items.reduce(0.0) { $0 + $1.moodValue } / Double(items.count),
                    entryIds: items.map { $0.id },
                    trend: trendFor(items)
                )
            }
            // 先按出现的"天数"排序——反复出现的人物/项目优先；tie-break 用条目总数
            .sorted {
                if $0.uniqueDays != $1.uniqueDays { return $0.uniqueDays > $1.uniqueDays }
                return $0.count > $1.count
            }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - 4. Streaming narrative

    func streamNarrative(in range: DateInterval) -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task {
                let entries = await self.fetchEntryData(in: range)
                guard !entries.isEmpty else {
                    continuation.yield(NSLocalizedString("这段时间还没有日记。", comment: "Empty narrative"))
                    continuation.finish()
                    return
                }
                for await chunk in self.ai.streamReport(entries: entries) {
                    if Task.isCancelled { break }
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
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
                for await chunk in self.ai.ask(question: question, context: selected) {
                    if Task.isCancelled { break }
                    continuation.yield(AnswerChunk(text: chunk))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 6. Semantic search

    func semanticSearch(_ query: String, topK: Int = 20) async -> [DiaryEntryData] {
        let qVec = await ai.embed(text: query)
        return await retrieve(query: query, queryVector: qVec, topK: topK)
    }

    // MARK: - 7. 近 N 条（给 prompt suggestion 做 grounding 用）

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

    /// 返回情绪最高、最低的那一天（带 summary），供 suggestion grounding 使用。
    /// 没数据时两个字段都可能为 nil。
    /// 当所有条目 mood 都相同（比如全是默认 0.5），返回 (nil, nil) ——UI 显示"同一条 = 最高 + 最低"
    /// 是无意义的；让上游知道"没有显著差异"比给它俩同一个值更好。
    func moodExtremes(in range: DateInterval) async -> (high: DiaryEntryData?, low: DiaryEntryData?) {
        let entries = await fetchEntryData(in: range)
        guard !entries.isEmpty else { return (nil, nil) }
        // 按 summary 不空优先（空 summary 对 grounding 没用）
        let withSummary = entries.filter { !$0.summary.isEmpty }
        let pool = withSummary.isEmpty ? entries : withSummary
        let high = pool.max { $0.moodValue < $1.moodValue }
        let low = pool.min { $0.moodValue < $1.moodValue }
        // 如果 mood 值相同，说明没有显著波动——返回 nil，让下游判定"数据不足"
        if let h = high, let l = low, h.moodValue == l.moodValue {
            return (nil, nil)
        }
        return (high, low)
    }

    // MARK: - Private

    private func fetchEntryData(in range: DateInterval) async -> [DiaryEntryData] {
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
                    embedding: entry.embeddingVector,
                    wordCount: Int(entry.wordCount)
                )
            }
        }
    }

    private func retrieve(query: String, queryVector: [Float]?, topK: Int) async -> [DiaryEntryData] {
        let all = await persistence.container.performBackgroundTask { context -> [DiaryEntryData] in
            let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
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
                    embedding: entry.embeddingVector,
                    wordCount: Int(entry.wordCount)
                )
            }
        }

        return Self.rankRetrieval(all: all, queryVector: queryVector, topK: topK)
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

        // **最低**给"最近但没索引"留 slot（≥ topK/3，且不小于 2），保证 backfill 没跑完时
        // 新写的日记也能被 AI 读到。但这只是下限——如果 embedded 条目不够，剩下的空位
        // 继续由 recency 填，保证总量尽量接近 topK。
        let minRecencyReserve: Int = withoutVectors.isEmpty
            ? 0
            : min(max(2, topK / 3), withoutVectors.count)

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
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        let n = vDSP_Length(a.count)
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, n)
        var aNorm: Float = 0
        vDSP_svesq(a, 1, &aNorm, n)
        var bNorm: Float = 0
        vDSP_svesq(b, 1, &bNorm, n)
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
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        case .month:
            return calendar.dateInterval(of: .month, for: date)?.start ?? date
        }
    }
}
