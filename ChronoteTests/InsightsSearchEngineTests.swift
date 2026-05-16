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

    @discardableResult
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
