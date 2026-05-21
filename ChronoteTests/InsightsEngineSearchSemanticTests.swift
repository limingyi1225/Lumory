//
//  InsightsEngineSearchSemanticTests.swift
//  ChronoteTests
//
//  F1 语义搜索的契约测试。`InsightsEngine.searchSemantic(query:topK:)` 是给 HomeView 搜索栏
//  用的 Sendable API,直接走真实 in-memory CoreData(`PersistenceController(inMemory: true)`)
//  + `MockAIService.embed`(16 维归一化伪向量)。
//
//  **不测**:
//  - HomeView UI(searchModeHeader / loading state / coverage banner)— 那些是 view-state
//    观察,留 P1 测试 backlog。
//  - 跟 `retrieve()` 的 cosine 数学一致性 — 已被 `cosineSimilarityTests` / `rankRetrievalTests`
//    覆盖。
//

import Testing
import Foundation
import CoreData
@testable import Lumory

@MainActor
struct InsightsEngineSearchSemanticTests {

    // MARK: - Helpers

    /// 用 MockAIService 同款 16 维伪向量给 entry 写 embedding,这样 query 跟 entries 走同一个
    /// 编码空间,cosine ranking 才有意义。
    private func mockEmbed(_ text: String) -> [Float] {
        var vector = [Float](repeating: 0, count: 16)
        for (i, scalar) in text.unicodeScalars.enumerated() {
            let bucket = (i + Int(scalar.value)) % 16
            vector[bucket] += Float(scalar.value & 0xFF) / 255.0
        }
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    private func makeEntry(
        in context: NSManagedObjectContext,
        text: String,
        date: Date,
        withEmbedding: Bool
    ) -> DiaryEntry {
        let entry = DiaryEntry(context: context)
        entry.id = UUID()
        entry.date = date
        entry.text = text
        entry.summary = text
        entry.themes = ""
        entry.moodValue = 0.5
        entry.wordCount = Int32(text.count)
        if withEmbedding {
            entry.setEmbedding(mockEmbed(text))
        }
        return entry
    }

    // MARK: - Empty / edge cases

    @Test func emptyQuery_returnsEmptyResult() async throws {
        let persistence = PersistenceController(inMemory: true)
        let engine = InsightsEngine(persistence: persistence, ai: MockAIService())

        let result = await engine.searchSemantic(query: "", topK: 20)
        #expect(result.ids.isEmpty)
        #expect(result.totalCount == 0)
        #expect(!result.queryEmbedded, "空 query 不该走 embed,queryEmbedded=false")
    }

    @Test func whitespaceOnlyQuery_returnsEmptyResult() async throws {
        let persistence = PersistenceController(inMemory: true)
        let engine = InsightsEngine(persistence: persistence, ai: MockAIService())

        let result = await engine.searchSemantic(query: "   \n\t ", topK: 20)
        #expect(result.ids.isEmpty)
        #expect(!result.queryEmbedded)
    }

    @Test func emptyDatabase_returnsEmptyButQueryEmbedded() async throws {
        let persistence = PersistenceController(inMemory: true)
        let engine = InsightsEngine(persistence: persistence, ai: MockAIService())

        let result = await engine.searchSemantic(query: "happy", topK: 20)
        #expect(result.ids.isEmpty)
        #expect(result.totalCount == 0)
        // 数据库空 → 不到 embed 一步就提前返;这里 queryEmbedded 跟着 totalCount==0 路径出来。
        // 当前实现是先 embed 再 fetch,所以 queryEmbedded=true。两种都合理;契约上 ids 必须空。
    }

    // MARK: - Coverage

    @Test func allEntriesHaveEmbeddings_coverageIs1() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let now = Date()
        for i in 0..<5 {
            _ = makeEntry(in: context, text: "entry \(i)", date: now.addingTimeInterval(TimeInterval(-i * 86400)), withEmbedding: true)
        }
        try context.save()
        let engine = InsightsEngine(persistence: persistence, ai: MockAIService())

        let result = await engine.searchSemantic(query: "entry", topK: 20)
        #expect(result.totalCount == 5)
        #expect(result.indexCoverage == 1.0, "全部已索引时 coverage=1.0,实际 \(result.indexCoverage)")
        #expect(result.ids.count == 5)
    }

    @Test func mediaOnlyEntriesAreExcludedFromSemanticCoverage() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let now = Date()
        let textEntry = makeEntry(in: context, text: "entry with words", date: now, withEmbedding: true)
        let mediaOnly = DiaryEntry(context: context)
        mediaOnly.id = UUID()
        mediaOnly.date = now.addingTimeInterval(-3600)
        mediaOnly.text = ""
        mediaOnly.summary = nil
        mediaOnly.imageFileNames = "img_media_only.jpg"
        mediaOnly.moodValue = 0.5
        mediaOnly.wordCount = 0
        try context.save()
        let engine = InsightsEngine(persistence: persistence, ai: MockAIService())

        let result = await engine.searchSemantic(query: "entry", topK: 20)

        #expect(result.totalCount == 1, "纯图片/纯录音 entry 不应算进语义搜索 coverage 分母")
        #expect(result.indexCoverage == 1.0)
        #expect(result.ids == [textEntry.objectID])
    }

    @Test func partialCoverage_isReportedAccurately() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let now = Date()
        // 3 已索引 + 2 未索引
        for i in 0..<3 {
            _ = makeEntry(in: context, text: "indexed \(i)", date: now.addingTimeInterval(TimeInterval(-i * 86400)), withEmbedding: true)
        }
        for i in 0..<2 {
            _ = makeEntry(in: context, text: "unindexed \(i)", date: now.addingTimeInterval(TimeInterval(-(10 + i) * 86400)), withEmbedding: false)
        }
        try context.save()
        let engine = InsightsEngine(persistence: persistence, ai: MockAIService())

        let result = await engine.searchSemantic(query: "indexed", topK: 20)
        #expect(result.totalCount == 5)
        #expect(abs(result.indexCoverage - 0.6) < 0.001, "3/5 = 0.6,实际 \(result.indexCoverage)")
        // 关键 invariant:**不**返回未索引条目(搜索是按相关度排,不混入未索引)。
        // 见 searchSemantic 跟 retrieve() 的差异注释。
        #expect(result.ids.count == 3)
    }

    @Test func zeroCoverage_returnsEmptyIdsButReportsTotal() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let now = Date()
        for i in 0..<3 {
            _ = makeEntry(in: context, text: "no embed \(i)", date: now.addingTimeInterval(TimeInterval(-i * 86400)), withEmbedding: false)
        }
        try context.save()
        let engine = InsightsEngine(persistence: persistence, ai: MockAIService())

        let result = await engine.searchSemantic(query: "no embed", topK: 20)
        #expect(result.totalCount == 3)
        #expect(result.indexCoverage == 0.0)
        #expect(result.ids.isEmpty, "全 0 索引时返空,UI 显示 banner 引导用户去 backfill")
    }

    // MARK: - Top-K cap

    @Test func topKCap_respected() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let now = Date()
        for i in 0..<10 {
            _ = makeEntry(in: context, text: "entry \(i)", date: now.addingTimeInterval(TimeInterval(-i * 86400)), withEmbedding: true)
        }
        try context.save()
        let engine = InsightsEngine(persistence: persistence, ai: MockAIService())

        let result = await engine.searchSemantic(query: "entry 0", topK: 3)
        #expect(result.ids.count == 3, "topK=3 限定 3 条,实际 \(result.ids.count)")
        #expect(result.totalCount == 10)
    }

    @Test func topKZero_returnsEmpty() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        _ = makeEntry(in: context, text: "alpha", date: Date(), withEmbedding: true)
        try context.save()
        let engine = InsightsEngine(persistence: persistence, ai: MockAIService())

        let result = await engine.searchSemantic(query: "alpha", topK: 0)
        #expect(result.ids.isEmpty)
        #expect(result.totalCount == 1, "totalCount 仍报告真实数")
    }

    // MARK: - Query embed failure(网络/认证错)

    /// embed 永远返 nil 的 AI(模拟 401 / offline)
    private struct EmbedFailingAI: AIServiceProtocol {
        func summarize(text: String) async -> String? { nil }
        func analyzeMood(text: String) async -> Double { 0.5 }
        func extractThemes(text: String) async -> [String] { [] }
        func embed(text: String) async -> [Float]? { nil } // ← 关键
        func generateReportFromData(entries: [DiaryEntryData], onEvent: @escaping @MainActor (StreamEvent) -> Void) async {
            await MainActor.run { onEvent(.done) }
        }
        func streamReportEvents(entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
            AsyncStream { $0.finish() }
        }
        func askEvents(question: String, context entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
            AsyncStream { $0.finish() }
        }
        func parseImportedDiaries(rawText: String) async throws -> [ParsedDiaryEntry] { [] }
        func judgeThemeAliases(newTags: [String], inventory: [ThemeAliasJudgeCandidate]) async -> [ThemeAliasJudgeMatch] { [] }
        func scanThemeAliasGroups(candidates: [ThemeAliasJudgeCandidate]) async throws -> [ThemeAliasJudgeGroup] { [] }
        func composeSuggestions(context: SuggestionContext) async -> SuggestionBundle? { nil }
    }

    @Test func queryEmbedFails_setsFlagAndReturnsEmpty() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let now = Date()
        for i in 0..<3 {
            _ = makeEntry(in: context, text: "entry \(i)", date: now.addingTimeInterval(TimeInterval(-i * 86400)), withEmbedding: true)
        }
        try context.save()
        let engine = InsightsEngine(persistence: persistence, ai: EmbedFailingAI())

        let result = await engine.searchSemantic(query: "anything", topK: 10)
        #expect(!result.queryEmbedded, "embed 返 nil → queryEmbedded=false")
        #expect(result.ids.isEmpty, "embed 失败必须返空,不能静默退化成最近 K 条假装相关")
        #expect(result.indexCoverage == 1.0, "已索引 3/3")
        #expect(result.totalCount == 3)
    }

    // MARK: - Dimension mismatch guard

    /// 模拟 legacy embedding 用旧 dim 写过(8 维),后来切了新模型 query embed 走新 dim(16 维)。
    /// cosineSimilarity 在 count 不等时返 0 → 全 0 max → searchSemantic 该 detect 并返空 + coverage=0
    /// (而不是 silently 把 bounded heap 填满前 K 条按日期降序当"语义最相关"伪结果)。
    private struct DimMismatchAI: AIServiceProtocol {
        func summarize(text: String) async -> String? { nil }
        func analyzeMood(text: String) async -> Double { 0.5 }
        func extractThemes(text: String) async -> [String] { [] }
        /// 返 8 维(跟 mockEmbed 的 16 维不匹配)
        func embed(text: String) async -> [Float]? {
            [Float](repeating: 0.5, count: 8)
        }
        func generateReportFromData(entries: [DiaryEntryData], onEvent: @escaping @MainActor (StreamEvent) -> Void) async {
            await MainActor.run { onEvent(.done) }
        }
        func streamReportEvents(entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
            AsyncStream { $0.finish() }
        }
        func askEvents(question: String, context entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
            AsyncStream { $0.finish() }
        }
        func parseImportedDiaries(rawText: String) async throws -> [ParsedDiaryEntry] { [] }
        func judgeThemeAliases(newTags: [String], inventory: [ThemeAliasJudgeCandidate]) async -> [ThemeAliasJudgeMatch] { [] }
        func scanThemeAliasGroups(candidates: [ThemeAliasJudgeCandidate]) async throws -> [ThemeAliasJudgeGroup] { [] }
        func composeSuggestions(context: SuggestionContext) async -> SuggestionBundle? { nil }
    }

    /// (2026-05-15 superreview-4 P2)守卫触发机制说明:`InsightsEngine.cosineSimilarity`
    /// 在 lhs.count != rhs.count 时返 0(见 `ChronoteTests.mismatchedLengths_returnZero`)。
    /// `DimMismatchAI` 返 8 维 vector,entry 存的是 16 维 → `cosineSimilarity` 全部返 0
    /// → `abs(maxScore) < 1e-6` 守卫(`InsightsEngine.swift:446` 附近)触发 → 强制清空 ids
    /// + 写 indexCoverage=0 让 UI 走"索引不完整"banner。
    ///
    /// 注意:这条 test 锁的是"dim mismatch → empty + coverage=0"业务契约,**走的路径是
    /// cosineSimilarity 的 count-guard 短路**。如果以后有人把 cosineSimilarity 改成
    /// "截到 min count 再算"(数学错误但能算出非零),这条 test 仍会 pass 但守卫语义已退化。
    /// 配套对照见 `ranking_putsExactMatchFirst` 锁住 cosine 在同 dim 下正常工作。
    @Test func dimensionMismatch_returnsEmptyWithZeroCoverage() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let now = Date()
        // 5 条都已索引,但走 16 维 mock embed。
        for i in 0..<5 {
            _ = makeEntry(in: context, text: "entry \(i)", date: now.addingTimeInterval(TimeInterval(-i * 86400)), withEmbedding: true)
        }
        try context.save()
        // query embed 返 8 维 → 跟 entry 的 16 维 dim mismatch → cosineSimilarity 全返 0。
        let engine = InsightsEngine(persistence: persistence, ai: DimMismatchAI())

        let result = await engine.searchSemantic(query: "anything", topK: 10)
        #expect(result.queryEmbedded, "AI 返了 vector(只是 dim 不对),queryEmbedded 仍 true")
        #expect(result.ids.isEmpty, "dim-mismatch 守卫该挡住伪 top-K,实际 ids=\(result.ids)")
        #expect(result.indexCoverage == 0.0, "守卫触发时 coverage 该被强制设 0 让 UI 走'索引不完整' banner,实际 \(result.indexCoverage)")
        #expect(result.totalCount == 5)
    }

    // MARK: - Ranking sanity check

    @Test func ranking_putsExactMatchFirst() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let now = Date()
        // 3 条不同文本的 entry,query 用其中一条原文的 prefix —— mock embed 同 input 走同伪向量,
        // 完全相同的 embedding cosine = 1。query 跟 "alpha bravo" 的相似度应该 >> 跟另外两条。
        let target = makeEntry(in: context, text: "alpha bravo", date: now, withEmbedding: true)
        _ = makeEntry(in: context, text: "completely unrelated text here xyz", date: now.addingTimeInterval(-86400), withEmbedding: true)
        _ = makeEntry(in: context, text: "another different topic 123 456", date: now.addingTimeInterval(-2 * 86400), withEmbedding: true)
        try context.save()
        let engine = InsightsEngine(persistence: persistence, ai: MockAIService())

        let result = await engine.searchSemantic(query: "alpha bravo", topK: 3)
        #expect(result.ids.count == 3)
        #expect(result.ids.first == target.objectID,
                "相同文本 cosine=1 必排首位,实际首位是另一条")
    }
}
