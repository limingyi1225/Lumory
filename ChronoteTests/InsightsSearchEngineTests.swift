//
//  InsightsSearchEngineTests.swift
//  ChronoteTests
//
//  2026-05-16 round 3 — Search/RAG 拆分到独立 `InsightsSearchEngine.swift`。本测试覆盖:
//   (A) `InsightsEngine.ask(_:)` facade 拆完后仍能完整 stream `.citation` + `.text`,
//       AsyncStream 自然结束。**不**预期 `.done` chunk —— `AnswerChunk.Kind` 只有 4 case
//       (`.text / .citation / .truncated / .failed`),`StreamEvent.done` 在 ask 里只是
//       `break` 然后 `continuation.finish()`,消费侧表现为 `for await` 退出。
//   (B) `InsightsSearchEngine` 单独 init 也 work,验 instance API 不通过 facade 路径。
//
//  **必须 `@MainActor struct`** — 需要操作 `PersistenceController.container.viewContext`
//  seed 日记 entry(参考 `InsightsEngineSearchSemanticTests:21` 同款 idiom)。
//  没 seed entry → retrieve 返空 → ask 不会 yield `.citation`,(A) 断言会过早 fail。
//

import Testing
import Foundation
import CoreData
@testable import Lumory

@MainActor
struct InsightsSearchEngineTests {

    // MARK: - Helpers

    /// 16 维伪向量,匹配 `MockAIService.embed` 编码空间,query 和 entries 在同一空间 cosine
    /// 才有意义。直接复用 `InsightsEngineSearchSemanticTests.mockEmbed` 的实现风格。
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

    private func vector(cosine: Float) -> [Float] {
        var vector = [Float](repeating: 0, count: 16)
        let clamped = min(max(cosine, -1), 1)
        vector[0] = clamped
        vector[1] = sqrt(max(0, 1 - clamped * clamped))
        return vector
    }

    @discardableResult
    private func makeEntry(
        in context: NSManagedObjectContext,
        text: String,
        date: Date,
        withEmbedding: Bool,
        embedding: [Float]? = nil
    ) -> DiaryEntry {
        let entry = DiaryEntry(context: context)
        entry.id = UUID()
        entry.date = date
        entry.text = text
        entry.summary = text
        entry.themes = ""
        entry.moodValue = 0.5
        entry.wordCount = Int32(text.count)
        if let embedding {
            entry.setEmbedding(embedding)
        } else if withEmbedding {
            entry.setEmbedding(mockEmbed(text))
        }
        return entry
    }

    private struct NilEmbedAI: AIServiceProtocol {
        func summarize(text: String) async -> String? { nil }
        func analyzeMood(text: String) async -> Double { 0.5 }
        func extractThemes(text: String) async -> [String] { [] }
        func embed(text: String) async -> [Float]? { nil }
        func askEvents(question: String, context entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
            AsyncStream { continuation in
                continuation.yield(.chunk("should not be called"))
                continuation.finish()
            }
        }
        func streamReportEvents(entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
            AsyncStream { $0.finish() }
        }
        func parseImportedDiaries(rawText: String) async throws -> [ParsedDiaryEntry] { [] }
        func judgeThemeAliases(newTags: [String], inventory: [ThemeAliasJudgeCandidate]) async -> [ThemeAliasJudgeMatch] { [] }
        func scanThemeAliasGroups(candidates: [ThemeAliasJudgeCandidate]) async throws -> [ThemeAliasJudgeGroup] { [] }
        func composeSuggestions(context: SuggestionContext) async -> SuggestionBundle? { nil }
    }

    private struct DimMismatchAskAI: AIServiceProtocol {
        func summarize(text: String) async -> String? { nil }
        func analyzeMood(text: String) async -> Double { 0.5 }
        func extractThemes(text: String) async -> [String] { [] }
        func embed(text: String) async -> [Float]? { [Float](repeating: 0.5, count: 8) }
        func askEvents(question: String, context entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
            AsyncStream { continuation in
                continuation.yield(.chunk(entries.map(\.text).joined(separator: " | ")))
                continuation.yield(.done)
                continuation.finish()
            }
        }
        func streamReportEvents(entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
            AsyncStream { $0.finish() }
        }
        func parseImportedDiaries(rawText: String) async throws -> [ParsedDiaryEntry] { [] }
        func judgeThemeAliases(newTags: [String], inventory: [ThemeAliasJudgeCandidate]) async -> [ThemeAliasJudgeMatch] { [] }
        func scanThemeAliasGroups(candidates: [ThemeAliasJudgeCandidate]) async throws -> [ThemeAliasJudgeGroup] { [] }
        func composeSuggestions(context: SuggestionContext) async -> SuggestionBundle? { nil }
    }

    private struct ContextEchoAI: AIServiceProtocol {
        func summarize(text: String) async -> String? { nil }
        func analyzeMood(text: String) async -> Double { 0.5 }
        func extractThemes(text: String) async -> [String] { [] }
        func embed(text: String) async -> [Float]? {
            var vector = [Float](repeating: 0, count: 16)
            vector[0] = 1
            return vector
        }
        func askEvents(question: String, context entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
            AsyncStream { continuation in
                continuation.yield(.chunk(entries.map(\.text).joined(separator: " | ")))
                continuation.yield(.done)
                continuation.finish()
            }
        }
        func streamReportEvents(entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
            AsyncStream { $0.finish() }
        }
        func parseImportedDiaries(rawText: String) async throws -> [ParsedDiaryEntry] { [] }
        func judgeThemeAliases(newTags: [String], inventory: [ThemeAliasJudgeCandidate]) async -> [ThemeAliasJudgeMatch] { [] }
        func scanThemeAliasGroups(candidates: [ThemeAliasJudgeCandidate]) async throws -> [ThemeAliasJudgeGroup] { [] }
        func composeSuggestions(context: SuggestionContext) async -> SuggestionBundle? { nil }
    }

    // MARK: - (A) facade `ask` 拆完仍能 stream citation + text

    /// `InsightsEngine.ask(_:)` 经 SearchEngine facade forward 后,**整链路必须连得上**:
    ///   1. `searchEngine.ask` 内 `await self.retrieve(...)` 拿到 selected 非空 → yield `.citation`
    ///   2. `self.ai.askEvents(...)` 走 MockAIService → yield 1 条 `.text` "Mock 回答:..."
    ///   3. MockAIService yield `.done` → ask 里 `break` → continuation.finish → 流自然结束
    ///
    /// 任一处搬错(`Self.cosineSimilarity` 漏改、嵌套 type 引用错、persistence 注入丢)→
    /// retrieve 返空 → `.citation` 不出现 → `sawCitation` false → fail。
    /// 这个测试覆盖面比单纯 `searchSemantic` 大很多。
    @Test func ask_facade_streamsCitationThenTextChunks() async {
        let persistence = PersistenceController(inMemory: true)

        // seed:1 条带 embedding 的 entry。retrieve 用 cosine 选 top-K,有这条才会 yield citation。
        let ctx = persistence.container.viewContext
        makeEntry(in: ctx, text: "今天去公园散步,看花开了", date: Date(), withEmbedding: true)
        try? ctx.save()

        let engine = InsightsEngine(persistence: persistence, ai: MockAIService())

        var sawCitation = false
        var sawText = false
        var chunkCount = 0
        for await chunk in engine.ask("公园", topK: 3) {
            chunkCount += 1
            switch chunk.kind {
            case .citation:
                sawCitation = true
                #expect(!chunk.citedEntryIds.isEmpty, "citation chunk 必须带 entry id")
            case .text:
                sawText = true
                #expect(!chunk.text.isEmpty, "text chunk 不能为空")
            case .truncated, .failed:
                Issue.record("MockAIService 正常路径不该 yield \(chunk.kind)")
            }
        }
        // for-await 循环退出 = AsyncStream 自然 finish(StreamEvent.done → break → continuation.finish)
        #expect(sawCitation, "seed 了 entry,应至少 1 条 .citation")
        #expect(sawText, "MockAIService.askEvents 至少 yield 1 条 .text chunk")
        #expect(chunkCount >= 2, "至少 1 个 citation + 1 个 text,共 ≥ 2 chunks(实际 = \(chunkCount))")
    }

    @Test func ask_facade_limitsCitationsToPromptContext() async {
        let persistence = PersistenceController(inMemory: true)
        let ctx = persistence.container.viewContext
        let now = Date()
        for i in 0..<12 {
            makeEntry(
                in: ctx,
                text: "entry \(i) 公园 散步",
                date: now.addingTimeInterval(TimeInterval(-i * 60)),
                withEmbedding: true
            )
        }
        try? ctx.save()

        let engine = InsightsEngine(persistence: persistence, ai: MockAIService())

        var citationCount = 0
        var answerText = ""
        for await chunk in engine.ask("公园", topK: 11) {
            switch chunk.kind {
            case .citation:
                citationCount = chunk.citedEntryIds.count
            case .text:
                answerText += chunk.text
            case .truncated, .failed:
                Issue.record("MockAIService 正常路径不该 yield \(chunk.kind)")
            }
        }

        #expect((3...8).contains(citationCount), "Ask Past 应动态裁剪到 3-8 条 context,实际: \(citationCount)")
        #expect(answerText.contains("基于 \(citationCount) 条日记"), "Mock 回答应证明 citation 数量等于 askEvents 实际 context,实际: \(answerText)")
    }

    @Test func ask_excludesFutureDatedEntriesFromContext() async {
        let persistence = PersistenceController(inMemory: true)
        let ctx = persistence.container.viewContext
        let now = Date()
        makeEntry(
            in: ctx,
            text: "past context should be visible",
            date: now.addingTimeInterval(-60),
            withEmbedding: true,
            embedding: vector(cosine: 0.95)
        )
        makeEntry(
            in: ctx,
            text: "future context must stay hidden",
            date: now.addingTimeInterval(86_400),
            withEmbedding: true,
            embedding: vector(cosine: 1.0)
        )
        try? ctx.save()

        let engine = InsightsEngine(persistence: persistence, ai: ContextEchoAI())
        var answerText = ""
        for await chunk in engine.ask("context", topK: 3) {
            if case .text = chunk.kind {
                answerText += chunk.text
            }
        }

        #expect(answerText.contains("past context should be visible"))
        #expect(!answerText.contains("future context must stay hidden"))
    }

    @Test func searchSemantic_excludesFutureDatedEntries() async {
        let persistence = PersistenceController(inMemory: true)
        let ctx = persistence.container.viewContext
        let now = Date()
        let past = makeEntry(
            in: ctx,
            text: "past semantic result",
            date: now.addingTimeInterval(-60),
            withEmbedding: true,
            embedding: vector(cosine: 0.95)
        )
        let future = makeEntry(
            in: ctx,
            text: "future semantic result",
            date: now.addingTimeInterval(86_400),
            withEmbedding: true,
            embedding: vector(cosine: 1.0)
        )
        try? ctx.save()

        let searchEngine = InsightsSearchEngine(persistence: persistence, ai: ContextEchoAI())
        let result = await searchEngine.searchSemantic(query: "semantic", topK: 5)

        #expect(result.ids.contains(past.objectID))
        #expect(!result.ids.contains(future.objectID))
    }

    @Test func recentEntries_excludesFutureDatedEntries() async {
        let persistence = PersistenceController(inMemory: true)
        let ctx = persistence.container.viewContext
        let now = Date()
        makeEntry(in: ctx, text: "past recent entry", date: now.addingTimeInterval(-60), withEmbedding: false)
        makeEntry(in: ctx, text: "future recent entry", date: now.addingTimeInterval(86_400), withEmbedding: false)
        try? ctx.save()

        let engine = InsightsEngine(persistence: persistence, ai: MockAIService())
        let entries = await engine.recentEntries(limit: 5, textCharCap: 200)

        #expect(entries.map(\.text).contains("past recent entry"))
        #expect(!entries.map(\.text).contains("future recent entry"))
    }

    @Test func narrativeInput_excludesFutureDatedEntriesEvenWhenRangeEndsInFuture() async {
        let persistence = PersistenceController(inMemory: true)
        let ctx = persistence.container.viewContext
        let now = Date()
        makeEntry(in: ctx, text: "past narrative entry", date: now.addingTimeInterval(-60), withEmbedding: false)
        makeEntry(in: ctx, text: "future narrative entry", date: now.addingTimeInterval(86_400), withEmbedding: false)
        try? ctx.save()

        let engine = InsightsEngine(persistence: persistence, ai: MockAIService())
        let input = await engine.narrativeInput(
            in: DateInterval(start: now.addingTimeInterval(-3_600), end: now.addingTimeInterval(172_800))
        )

        let texts = input.entries.map(\.text)
        #expect(texts.contains("past narrative entry"))
        #expect(!texts.contains("future narrative entry"))
    }

    @Test func ask_facade_dynamicallyTrimsWeakSemanticCandidates() async {
        let persistence = PersistenceController(inMemory: true)
        let ctx = persistence.container.viewContext
        let now = Date()
        let scores: [Float] = [1.0, 0.98, 0.95, 0.70, 0.60, 0.50, 0.40, 0.30]
        for (index, score) in scores.enumerated() {
            makeEntry(
                in: ctx,
                text: index < 3 ? "close semantic \(index)" : "weak semantic \(index)",
                date: now.addingTimeInterval(TimeInterval(-index * 60)),
                withEmbedding: true,
                embedding: vector(cosine: score)
            )
        }
        try? ctx.save()

        let engine = InsightsEngine(persistence: persistence, ai: ContextEchoAI())

        var citationCount = 0
        var answerText = ""
        for await chunk in engine.ask("公园", topK: 11) {
            switch chunk.kind {
            case .citation:
                citationCount = chunk.citedEntryIds.count
            case .text:
                answerText += chunk.text
            case .truncated, .failed:
                Issue.record("ContextEchoAI 正常路径不该 yield \(chunk.kind)")
            }
        }

        #expect(citationCount == 3, "只有前三条分数接近 top score,弱相关候选不应为凑满 8 而进入 context")
        #expect(answerText.contains("close semantic 0"))
        #expect(answerText.contains("close semantic 1"))
        #expect(answerText.contains("close semantic 2"))
        #expect(!answerText.contains("weak semantic 3"))
    }

    @Test func ask_facade_preservesRecentUnindexedInsideContextBudget() async {
        let persistence = PersistenceController(inMemory: true)
        let ctx = persistence.container.viewContext
        let now = Date()
        for i in 0..<12 {
            makeEntry(
                in: ctx,
                text: "semantic indexed \(i) 公园 散步",
                date: now.addingTimeInterval(TimeInterval(-(i + 10) * 60)),
                withEmbedding: true
            )
        }
        makeEntry(in: ctx, text: "fresh unindexed one", date: now, withEmbedding: false)
        makeEntry(in: ctx, text: "fresh unindexed two", date: now.addingTimeInterval(-30), withEmbedding: false)
        try? ctx.save()

        let engine = InsightsEngine(persistence: persistence, ai: ContextEchoAI())

        var citationCount = 0
        var answerText = ""
        for await chunk in engine.ask("公园", topK: 11) {
            switch chunk.kind {
            case .citation:
                citationCount = chunk.citedEntryIds.count
            case .text:
                answerText += chunk.text
            case .truncated, .failed:
                Issue.record("ContextEchoAI 正常路径不该 yield \(chunk.kind)")
            }
        }

        #expect((3...8).contains(citationCount), "Ask Past context 应动态控制在 3-8 条,实际: \(citationCount)")
        #expect(answerText.contains("fresh unindexed one"))
        #expect(answerText.contains("fresh unindexed two"))
    }

    @Test func ask_facade_embedFailureYieldsFailureOnly() async {
        let persistence = PersistenceController(inMemory: true)
        let ctx = persistence.container.viewContext
        makeEntry(in: ctx, text: "今天去公园散步", date: Date(), withEmbedding: true)
        try? ctx.save()

        let engine = InsightsEngine(persistence: persistence, ai: NilEmbedAI())

        var chunks: [InsightsEngine.AnswerChunk] = []
        for await chunk in engine.ask("公园", topK: 3) {
            chunks.append(chunk)
        }

        #expect(chunks.count == 1)
        #expect(chunks.first?.kind == .failed)
        #expect(chunks.first?.citedEntryIds.isEmpty == true)
        #expect(chunks.first?.text.isEmpty == false)
    }

    @Test func ask_facade_dimensionMismatchYieldsFailureWithoutCitations() async {
        let persistence = PersistenceController(inMemory: true)
        let ctx = persistence.container.viewContext
        makeEntry(in: ctx, text: "今天去公园散步", date: Date(), withEmbedding: true)
        try? ctx.save()

        let engine = InsightsEngine(persistence: persistence, ai: DimMismatchAskAI())

        var chunks: [InsightsEngine.AnswerChunk] = []
        for await chunk in engine.ask("公园", topK: 3) {
            chunks.append(chunk)
        }

        #expect(chunks.count == 1)
        #expect(chunks.first?.kind == .failed)
        #expect(chunks.first?.citedEntryIds.isEmpty == true)
    }

    @Test func ask_facade_dimensionMismatchKeepsRecentUnindexedFallback() async {
        let persistence = PersistenceController(inMemory: true)
        let ctx = persistence.container.viewContext
        makeEntry(
            in: ctx,
            text: "old mismatched indexed entry",
            date: Date().addingTimeInterval(-3600),
            withEmbedding: true
        )
        makeEntry(in: ctx, text: "fresh unindexed fallback", date: Date(), withEmbedding: false)
        try? ctx.save()

        let engine = InsightsEngine(persistence: persistence, ai: DimMismatchAskAI())

        var sawCitation = false
        var answerText = ""
        for await chunk in engine.ask("公园", topK: 3) {
            switch chunk.kind {
            case .citation:
                sawCitation = true
                #expect(!chunk.citedEntryIds.isEmpty)
            case .text:
                answerText += chunk.text
            case .truncated:
                Issue.record("DimMismatchAskAI 正常路径不该 yield truncated")
            case .failed:
                Issue.record("有 recent unindexed 条目时不应直接失败")
            }
        }

        #expect(sawCitation)
        #expect(answerText.contains("fresh unindexed fallback"))
    }

    /// query 空白 → ask 立刻 finish,不应 yield 任何 chunk。验证 facade 的 trim guard 没丢。
    @Test func ask_facade_emptyQuery_finishesImmediately() async {
        let persistence = PersistenceController(inMemory: true)
        let ctx = persistence.container.viewContext
        makeEntry(in: ctx, text: "有内容的日记", date: Date(), withEmbedding: true)
        try? ctx.save()

        let engine = InsightsEngine(persistence: persistence, ai: MockAIService())

        var chunkCount = 0
        for await _ in engine.ask("   \n\t ", topK: 3) {
            chunkCount += 1
        }
        #expect(chunkCount == 0, "空白 query 应 immediate finish,无 chunk(实际 = \(chunkCount))")
    }

    // MARK: - (B) SearchEngine 单独 init 也 work(不通过 facade)

    /// 直接 `InsightsSearchEngine(persistence:ai:)` init,绕开 `InsightsEngine`,
    /// 验语义搜索 unit-level 自包含。如果搬过去后 SearchEngine 反向依赖 InsightsEngine 静态 wrapper,
    /// 这个测试也能挂 —— 因为 InsightsSearchEngine.rankRetrieval 内部用的是 `Self.cosineSimilarity`,
    /// 应该 self-contained,不绕回 InsightsEngine。
    @Test func ownInstance_searchSemantic_returnsExpectedIDs() async {
        let persistence = PersistenceController(inMemory: true)
        let ctx = persistence.container.viewContext

        makeEntry(in: ctx, text: "alpha bravo charlie", date: Date(), withEmbedding: true)
        makeEntry(in: ctx, text: "delta echo foxtrot", date: Date().addingTimeInterval(-86400), withEmbedding: true)
        makeEntry(in: ctx, text: "golf hotel india", date: Date().addingTimeInterval(-172800), withEmbedding: true)
        try? ctx.save()

        let searchEngine = InsightsSearchEngine(persistence: persistence, ai: MockAIService())
        let result = await searchEngine.searchSemantic(query: "alpha", topK: 3)

        #expect(result.queryEmbedded, "MockAIService.embed 总成功")
        #expect(result.totalCount == 3, "应扫到 3 条 entry,实际 \(result.totalCount)")
        #expect(!result.ids.isEmpty, "3 条都有 embedding,topK=3 → ids 非空")
        #expect(result.indexCoverage == 1.0, "全部建索引,coverage=1.0")
    }

    // MARK: - (C) Static helper forwarding wrapper(锁住 InsightsEngine 的兼容性 API)

    /// `InsightsEngine.cosineSimilarity` / `.rankRetrieval` 静态 wrapper 必须仍然存在
    /// (ChronoteTests.swift 有 15 处静态调用依赖它们)。这条 smoke 只验"调通",
    /// 详细行为由 ChronoteTests.swift 里 cosineSim ×6 / rankRetrieval ×9 个 case 覆盖。
    @Test func staticWrappers_routeThroughSearchEngine() {
        let a: [Float] = [1, 0]
        #expect(InsightsEngine.cosineSimilarity(a, a) == InsightsSearchEngine.cosineSimilarity(a, a),
                "InsightsEngine.cosineSim wrapper 应直接 forward 到 InsightsSearchEngine.cosineSim")

        let empty = InsightsEngine.rankRetrieval(all: [], queryVector: nil, topK: 5)
        #expect(empty.isEmpty, "rankRetrieval wrapper 行为应跟 SearchEngine 实现一致(空入空出)")
    }
}
