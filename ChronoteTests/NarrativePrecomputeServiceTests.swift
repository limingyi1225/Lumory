//
//  NarrativePrecomputeServiceTests.swift
//  ChronoteTests
//
//  wave14 写日记后 60s debounce 后台重生 .month 浓缩的逻辑契约测试。
//
//  覆盖:
//  - entryCount < 3 → noop(不写盘)
//  - 当前 cache 已 fresh → noop(不重复生成)
//  - cache stale + entryCount >= 3 → 跑流式 + 写 v2 narrative,带 rangeKind / entryCount /
//    sourceLatestEntryDate 字段
//  - debounce — 60s 内多次请求只跑一次(注入短 debounce 验证)
//  - stream failed → 失败静默,不写盘
//
//  **不覆盖**:
//  - 真实 OpenAI 流式调用(走 MockAIService.streamReportEvents 默认实现)
//  - EntryCreationService 触发点(那是 `Task.detached` fire-and-forget,生产路径,
//    通过 DiaryEntry 流量测可间接验证)
//

import Testing
import Foundation
import CoreData
@testable import Lumory

@MainActor
struct NarrativePrecomputeServiceTests {
    init() {
        NarrativeCacheService.resetInvalidationForTesting()
    }

    // MARK: - Helpers

    private func seedEntries(count: Int, in persistence: PersistenceController) throws {
        let context = persistence.container.viewContext
        for idx in 0..<count {
            let entry = DiaryEntry(context: context)
            entry.id = UUID()
            // 倒着编日期,确保都在 .month range (最近 30 天) 内
            entry.date = Date(timeIntervalSinceNow: -Double(idx * 3600))
            entry.text = "Entry \(idx) about work and family."
            entry.moodValue = 0.5
            entry.themes = "工作,家人"
            entry.wordCount = 8
        }
        try context.save()
    }

    private func makeService(
        persistence: PersistenceController,
        debounce: Duration = .milliseconds(50)
    ) -> NarrativePrecomputeService {
        let engine = InsightsEngine(persistence: persistence, ai: MockAIService())
        return NarrativePrecomputeService(
            persistence: persistence,
            engine: engine,
            debounce: debounce
        )
    }

    private func narrativeCount(in persistence: PersistenceController) throws -> Int {
        let context = persistence.container.viewContext
        // refresh viewContext 看到 bg context 写的内容
        context.refreshAllObjects()
        let req = NSFetchRequest<AIConversation>(entityName: "AIConversation")
        req.predicate = NSPredicate(format: "kind == %@", AIConversation.Kind.narrative.rawValue)
        return try context.count(for: req)
    }

    // MARK: - Tests

    @Test func skipsWhenEntryCountTooFew() async throws {
        let persistence = PersistenceController(inMemory: true)
        try seedEntries(count: 2, in: persistence)  // < 3
        let service = makeService(persistence: persistence)

        await service.requestRefreshIfNeeded(for: .month)
        await service.drainPendingForTesting()

        let count = try narrativeCount(in: persistence)
        #expect(count == 0, "<3 篇日记必须 noop,不写盘")
    }

    @Test func writesV3NarrativeWithHeadline() async throws {
        // wave15 — Mock streamReportEvents 输出 [HEADLINE]/[BODY] marker,
        // splitter 应该 split 出 headline + body,写盘 payloadVersion=3。
        let persistence = PersistenceController(inMemory: true)
        try seedEntries(count: 5, in: persistence)
        let service = makeService(persistence: persistence)

        await service.requestRefreshIfNeeded(for: .month)
        await service.drainPendingForTesting()

        let count = try narrativeCount(in: persistence)
        #expect(count == 1, "应写一条新 narrative")

        // 验证 v3 字段都填了
        let context = persistence.container.viewContext
        let req = NSFetchRequest<AIConversation>(entityName: "AIConversation")
        req.predicate = NSPredicate(format: "kind == %@", AIConversation.Kind.narrative.rawValue)
        let conv = try #require(try context.fetch(req).first)
        #expect(conv.payloadVersion == 3, "headline 非空必须落 v3")
        let payload = try #require(conv.narrativePayload)
        #expect(payload.rangeKind == TimeRange.month.rawValue)
        #expect(payload.entryCount == 5)
        #expect(payload.sourceLatestEntryDate != nil)
        #expect(payload.generatedAt != nil)
        #expect(!payload.body.isEmpty)
        #expect(payload.headline != nil, "Mock 输出含 [HEADLINE] marker,split 后应有 headline")
        #expect(payload.headline?.isEmpty == false)
        let entryRequest = NSFetchRequest<NSDictionary>(entityName: "DiaryEntry")
        entryRequest.resultType = .dictionaryResultType
        entryRequest.propertiesToFetch = ["id", "date"]
        entryRequest.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        let expectedSourceIds = try context.fetch(entryRequest).compactMap { $0["id"] as? UUID }
        #expect(conv.citedEntryUUIDs == expectedSourceIds, "narrative citation 必须保存 prompt 实际纳入的 entry ids")
    }

    @Test func refreshesFinalMetricsWhenEntryIsAddedDuringStream() async throws {
        let persistence = PersistenceController(inMemory: true)
        try seedEntries(count: 5, in: persistence)
        let ai = EntryMutatingNarrativeAIService(persistence: persistence)
        let engine = InsightsEngine(persistence: persistence, ai: ai)
        let service = NarrativePrecomputeService(
            persistence: persistence,
            engine: engine,
            debounce: .milliseconds(50)
        )

        await service.requestRefreshIfNeeded(for: .month)
        await service.drainPendingForTesting()

        let context = persistence.container.viewContext
        context.refreshAllObjects()
        let req = NSFetchRequest<AIConversation>(entityName: "AIConversation")
        req.predicate = NSPredicate(format: "kind == %@", AIConversation.Kind.narrative.rawValue)
        let conv = try #require(try context.fetch(req).first)
        let payload = try #require(conv.narrativePayload)
        #expect(payload.entryCount == 6, "stream 期间新增 entry 后,payload metrics 必须用最终 count")
        #expect(payload.sourceLatestEntryDate != nil, "stream 后最终 mostRecent 必须写入 payload")
    }

    @Test func skipsWhenCacheFresh() async throws {
        let persistence = PersistenceController(inMemory: true)
        try seedEntries(count: 5, in: persistence)
        let context = persistence.container.viewContext

        // 预写一条 fresh v3 cache(刚刚生成 + entryCount 一致 + headline 已存在)。
        // 旧 v2 cache 会被 isStale 视为 stale,用于自动升级到 headline schema。
        let now = Date()
        // mostRecent 是 entry 0 的 date(timeIntervalSinceNow: 0),所以用稍微之前的 date
        // 让 cache.createdAt > mostRecent。
        let mostRecent = Date(timeIntervalSinceNow: -3600)
        _ = try AIConversation.insertNarrative(
            in: context,
            title: "fresh cache",
            payload: AIConversation.NarrativePayload(
                rangeStart: Date(timeIntervalSinceNow: -2_592_000),
                rangeEnd: now,
                body: "OLD",
                isIncomplete: false,
                truncatedReason: nil,
                rangeKind: TimeRange.month.rawValue,
                entryCount: 5,
                sourceLatestEntryDate: mostRecent,
                generatedAt: now,
                headline: "fresh"
            ),
            citedEntryIds: []
        )
        try context.save()

        // 但 isStale 还是会判 stale,因为 mostRecentEntryDate(取自 seedEntries 最新一条)
        // 是 Date(timeIntervalSinceNow: 0) > cache.createdAt = now(细微差但仍可能 stale)。
        // 为了确保 fresh,把 cache 的 createdAt 显式设到 entry 之后 + entryCount 一致。
        // 实际我们 seed 的最新 entry.date 也是 ~Date()。让 cache 更新到 Date()+1s。
        let req = NSFetchRequest<AIConversation>(entityName: "AIConversation")
        let conv = try context.fetch(req).first!
        conv.createdAt = Date(timeIntervalSinceNow: 5)  // 比所有 entry 都新
        try context.save()

        let service = makeService(persistence: persistence)
        await service.requestRefreshIfNeeded(for: .month)
        await service.drainPendingForTesting()

        let count = try narrativeCount(in: persistence)
        #expect(count == 1, "fresh cache 必须 noop,不重复写")
    }

    @Test func skipsWhenStreamFails() async throws {
        // codex review fix:.failed 路径必须不写盘 + 静默吞失败,不让僵尸记录污染 cache。
        let persistence = PersistenceController(inMemory: true)
        try seedEntries(count: 5, in: persistence)
        let engine = InsightsEngine(persistence: persistence, ai: FailingNarrativeAIService())
        let service = NarrativePrecomputeService(
            persistence: persistence,
            engine: engine,
            debounce: .milliseconds(50)
        )

        await service.requestRefreshIfNeeded(for: .month)
        await service.drainPendingForTesting()

        let count = try narrativeCount(in: persistence)
        #expect(count == 0, "stream .failed 必须 noop 不写盘")
    }

    @Test func debouncesMultipleRequests() async throws {
        let persistence = PersistenceController(inMemory: true)
        try seedEntries(count: 5, in: persistence)
        // 用足够长的 debounce 让第一次请求被第二次 cancel
        let service = makeService(persistence: persistence, debounce: .milliseconds(200))

        // 50ms 间隔触发 3 次,只有最后一次的 200ms 倒计时不被 cancel
        await service.requestRefreshIfNeeded(for: .month)
        try await Task.sleep(for: .milliseconds(50))
        await service.requestRefreshIfNeeded(for: .month)
        try await Task.sleep(for: .milliseconds(50))
        await service.requestRefreshIfNeeded(for: .month)
        await service.drainPendingForTesting()

        let count = try narrativeCount(in: persistence)
        #expect(count == 1, "60s debounce 内多次调应该只生成 1 条")
    }

    /// **P0 test gap (2026-05-13 superreview)**:`.truncated` 事件端到端进 NarrativePrecomputeService
    /// 消费侧后,是否正确 set isIncomplete=true / truncatedReason 写盘。CLAUDE.md follow-up backlog
    /// 已记缺口,新加 precompute service 是新消费者也漏 — 现在补齐。
    @Test func persistsIncompleteFlagAndReasonOnTruncated() async throws {
        let persistence = PersistenceController(inMemory: true)
        try seedEntries(count: 5, in: persistence)
        let engine = InsightsEngine(persistence: persistence, ai: TruncatedNarrativeAIService())
        let service = NarrativePrecomputeService(
            persistence: persistence,
            engine: engine,
            debounce: .milliseconds(50)
        )

        await service.requestRefreshIfNeeded(for: .month)
        await service.drainPendingForTesting()

        let context = persistence.container.viewContext
        context.refreshAllObjects()
        let req = NSFetchRequest<AIConversation>(entityName: "AIConversation")
        req.predicate = NSPredicate(format: "kind == %@", AIConversation.Kind.narrative.rawValue)
        let conv = try #require(try context.fetch(req).first)
        let payload = try #require(conv.narrativePayload)
        #expect(payload.isIncomplete == true, ".truncated event 必须把 isIncomplete 翻 true")
        #expect(payload.truncatedReason == "max_tokens", ".truncated reason 必须透传到 payload")
        #expect(!payload.body.isEmpty, "truncated 前已有部分 body 必须落盘")
    }

    @Test func localRawOutputLimitPersistsIncompleteFlag() async throws {
        let persistence = PersistenceController(inMemory: true)
        try seedEntries(count: 5, in: persistence)
        let engine = InsightsEngine(persistence: persistence, ai: LongNarrativeAIService())
        let service = NarrativePrecomputeService(
            persistence: persistence,
            engine: engine,
            debounce: .milliseconds(50)
        )

        await service.requestRefreshIfNeeded(for: .month)
        await service.drainPendingForTesting()

        let context = persistence.container.viewContext
        context.refreshAllObjects()
        let req = NSFetchRequest<AIConversation>(entityName: "AIConversation")
        req.predicate = NSPredicate(format: "kind == %@", AIConversation.Kind.narrative.rawValue)
        let conv = try #require(try context.fetch(req).first)
        let payload = try #require(conv.narrativePayload)
        #expect(payload.isIncomplete == true, "本地 64KB cap 命中时不能把半截 narrative 写成完整")
        #expect(payload.truncatedReason == NarrativeStreamLimits.localTruncationReason)
        #expect(payload.body.count < 70_000, "payload 应只保留 cap 内前缀")
    }

    /// **P1 test gap (2026-05-13 superreview)**:`lastFailureAtByRange[range]` 5min backoff
    /// 路径完全没测。第一次 fail 后 5min 内再调,必须 noop(不再进 stream)。
    @Test func failureBackoff_skipsSecondRequestWithin5Minutes() async throws {
        let persistence = PersistenceController(inMemory: true)
        try seedEntries(count: 5, in: persistence)
        let ai = StreamCountingAIService(inner: FailingNarrativeAIService())
        let engine = InsightsEngine(persistence: persistence, ai: ai)
        let service = NarrativePrecomputeService(
            persistence: persistence,
            engine: engine,
            debounce: .milliseconds(50)
        )

        await service.requestRefreshIfNeeded(for: .month)
        await service.drainPendingForTesting()
        let firstCallCount = ai.streamCallCount
        #expect(firstCallCount == 1, "第一次必须真正调 stream")

        // 第二次调:5min backoff 期内,必须不再 reach streamReportEvents。
        await service.requestRefreshIfNeeded(for: .month)
        await service.drainPendingForTesting()
        #expect(ai.streamCallCount == firstCallCount,
                "5min failureBackoff 内必须 noop,不重复烧 API")
    }

    @Test func cancelPendingAndBumpGeneration_preventsInFlightPersist() async throws {
        let persistence = PersistenceController(inMemory: true)
        try seedEntries(count: 5, in: persistence)
        let engine = InsightsEngine(persistence: persistence, ai: SlowNarrativeAIService())
        let service = NarrativePrecomputeService(
            persistence: persistence,
            engine: engine,
            debounce: .milliseconds(1)
        )

        await service.requestRefreshIfNeeded(for: .month)
        try await Task.sleep(for: .milliseconds(50))
        await service.cancelPendingAndBumpGeneration()

        let count = try narrativeCount(in: persistence)
        #expect(count == 0, "cancel + generation bump must prevent in-flight narrative from persisting")
    }
}

// MARK: - Failure-injecting AIService(给 .failed 路径测试用)
//
// MockAIService 是 production fixture,不能改它默认行为引入 failure 模式。这里 composition
// 模式 wrap 一个 base mock,只 override streamReportEvents 返 .failed,其他 method 透传。

private struct FailingNarrativeAIService: AIServiceProtocol {
    private let base = MockAIService()

    func summarize(text: String) async -> String? {
        await base.summarize(text: text)
    }
    func analyzeMood(text: String) async -> Double {
        await base.analyzeMood(text: text)
    }
    func extractThemes(text: String) async -> [String] {
        await base.extractThemes(text: text)
    }
    func judgeThemeAliases(
        newTags: [String],
        inventory: [ThemeAliasJudgeCandidate]
    ) async -> [ThemeAliasJudgeMatch] {
        await base.judgeThemeAliases(newTags: newTags, inventory: inventory)
    }
    func scanThemeAliasGroups(
        candidates: [ThemeAliasJudgeCandidate]
    ) async throws -> [ThemeAliasJudgeGroup] {
        try await base.scanThemeAliasGroups(candidates: candidates)
    }
    func embed(text: String) async -> [Float]? {
        await base.embed(text: text)
    }
    func askEvents(question: String, context entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
        base.askEvents(question: question, context: entries)
    }
    func composeSuggestions(context: SuggestionContext) async -> SuggestionBundle? {
        await base.composeSuggestions(context: context)
    }
    func parseImportedDiaries(rawText: String) async throws -> [ParsedDiaryEntry] {
        try await base.parseImportedDiaries(rawText: rawText)
    }

    /// **唯一覆盖** —— 模拟 narrative 流彻底失败(零内容产出)。
    func streamReportEvents(entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
        AsyncStream { continuation in
            continuation.yield(.failed(NSError(
                domain: "TestStreamFailed",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Simulated stream failure"]
            )))
            continuation.finish()
        }
    }
}

private struct SlowNarrativeAIService: AIServiceProtocol {
    private let base = MockAIService()

    func summarize(text: String) async -> String? { await base.summarize(text: text) }
    func analyzeMood(text: String) async -> Double { await base.analyzeMood(text: text) }
    func extractThemes(text: String) async -> [String] { await base.extractThemes(text: text) }
    func judgeThemeAliases(
        newTags: [String],
        inventory: [ThemeAliasJudgeCandidate]
    ) async -> [ThemeAliasJudgeMatch] {
        await base.judgeThemeAliases(newTags: newTags, inventory: inventory)
    }
    func scanThemeAliasGroups(
        candidates: [ThemeAliasJudgeCandidate]
    ) async throws -> [ThemeAliasJudgeGroup] {
        try await base.scanThemeAliasGroups(candidates: candidates)
    }
    func embed(text: String) async -> [Float]? { await base.embed(text: text) }
    func askEvents(question: String, context entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
        base.askEvents(question: question, context: entries)
    }
    func composeSuggestions(context: SuggestionContext) async -> SuggestionBundle? {
        await base.composeSuggestions(context: context)
    }
    func parseImportedDiaries(rawText: String) async throws -> [ParsedDiaryEntry] {
        try await base.parseImportedDiaries(rawText: rawText)
    }

    func streamReportEvents(entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
        AsyncStream { continuation in
            let task = Task {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }
                continuation.yield(.chunk("[HEADLINE]\n晚风把日子放轻\n[BODY]\nbody after delay"))
                continuation.yield(.done)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private final class EntryMutatingNarrativeAIService: AIServiceProtocol, @unchecked Sendable {
    private let base = MockAIService()
    private let persistence: PersistenceController

    init(persistence: PersistenceController) {
        self.persistence = persistence
    }

    func summarize(text: String) async -> String? { await base.summarize(text: text) }
    func analyzeMood(text: String) async -> Double { await base.analyzeMood(text: text) }
    func extractThemes(text: String) async -> [String] { await base.extractThemes(text: text) }
    func judgeThemeAliases(
        newTags: [String],
        inventory: [ThemeAliasJudgeCandidate]
    ) async -> [ThemeAliasJudgeMatch] {
        await base.judgeThemeAliases(newTags: newTags, inventory: inventory)
    }
    func scanThemeAliasGroups(
        candidates: [ThemeAliasJudgeCandidate]
    ) async throws -> [ThemeAliasJudgeGroup] {
        try await base.scanThemeAliasGroups(candidates: candidates)
    }
    func embed(text: String) async -> [Float]? { await base.embed(text: text) }
    func askEvents(question: String, context entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
        base.askEvents(question: question, context: entries)
    }
    func composeSuggestions(context: SuggestionContext) async -> SuggestionBundle? {
        await base.composeSuggestions(context: context)
    }
    func parseImportedDiaries(rawText: String) async throws -> [ParsedDiaryEntry] {
        try await base.parseImportedDiaries(rawText: rawText)
    }

    func streamReportEvents(entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
        AsyncStream { continuation in
            let task = Task {
                await persistence.container.performBackgroundTask { context in
                    let entry = DiaryEntry(context: context)
                    entry.id = UUID()
                    entry.date = Date()
                    entry.text = "Entry written while narrative stream is running."
                    entry.moodValue = 0.5
                    entry.themes = "工作"
                    entry.wordCount = 8
                    try? context.save()
                }
                continuation.yield(.chunk("[HEADLINE]\n晚风把日子放轻\n[BODY]\nbody after mid-stream write"))
                continuation.yield(.done)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// 模拟 stream 中段被截断:先 yield 一段 chunk,再 yield `.truncated`,再 `.done`。
/// 用于验证客户端 .truncated → isIncomplete=true / truncatedReason 端到端通路。
private struct TruncatedNarrativeAIService: AIServiceProtocol {
    private let base = MockAIService()

    func summarize(text: String) async -> String? { await base.summarize(text: text) }
    func analyzeMood(text: String) async -> Double { await base.analyzeMood(text: text) }
    func extractThemes(text: String) async -> [String] { await base.extractThemes(text: text) }
    func judgeThemeAliases(
        newTags: [String],
        inventory: [ThemeAliasJudgeCandidate]
    ) async -> [ThemeAliasJudgeMatch] {
        await base.judgeThemeAliases(newTags: newTags, inventory: inventory)
    }
    func scanThemeAliasGroups(
        candidates: [ThemeAliasJudgeCandidate]
    ) async throws -> [ThemeAliasJudgeGroup] {
        try await base.scanThemeAliasGroups(candidates: candidates)
    }
    func embed(text: String) async -> [Float]? { await base.embed(text: text) }
    func askEvents(question: String, context entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
        base.askEvents(question: question, context: entries)
    }
    func composeSuggestions(context: SuggestionContext) async -> SuggestionBundle? {
        await base.composeSuggestions(context: context)
    }
    func parseImportedDiaries(rawText: String) async throws -> [ParsedDiaryEntry] {
        try await base.parseImportedDiaries(rawText: rawText)
    }

    func streamReportEvents(entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
        AsyncStream { continuation in
            continuation.yield(.chunk("[HEADLINE]\n晚风把日子放轻\n[BODY]\n半截正文"))
            continuation.yield(.truncated(reason: "max_tokens"))
            continuation.yield(.done)
            continuation.finish()
        }
    }
}

/// 模拟模型输出超过本地 rawOutput cap,但服务端没有发 `.truncated`。
private struct LongNarrativeAIService: AIServiceProtocol {
    private let base = MockAIService()

    func summarize(text: String) async -> String? { await base.summarize(text: text) }
    func analyzeMood(text: String) async -> Double { await base.analyzeMood(text: text) }
    func extractThemes(text: String) async -> [String] { await base.extractThemes(text: text) }
    func judgeThemeAliases(
        newTags: [String],
        inventory: [ThemeAliasJudgeCandidate]
    ) async -> [ThemeAliasJudgeMatch] {
        await base.judgeThemeAliases(newTags: newTags, inventory: inventory)
    }
    func scanThemeAliasGroups(
        candidates: [ThemeAliasJudgeCandidate]
    ) async throws -> [ThemeAliasJudgeGroup] {
        try await base.scanThemeAliasGroups(candidates: candidates)
    }
    func embed(text: String) async -> [Float]? { await base.embed(text: text) }
    func askEvents(question: String, context entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
        base.askEvents(question: question, context: entries)
    }
    func composeSuggestions(context: SuggestionContext) async -> SuggestionBundle? {
        await base.composeSuggestions(context: context)
    }
    func parseImportedDiaries(rawText: String) async throws -> [ParsedDiaryEntry] {
        try await base.parseImportedDiaries(rawText: rawText)
    }

    func streamReportEvents(entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
        AsyncStream { continuation in
            continuation.yield(.chunk("[HEADLINE]\n很长的一段回顾\n[BODY]\n"))
            continuation.yield(.chunk(String(repeating: "字", count: 70_000)))
            continuation.yield(.done)
            continuation.finish()
        }
    }
}

/// Wrapper 计 `streamReportEvents` 调用次数,验证 failureBackoff 路径下后续调用真的 noop。
private final class StreamCountingAIService: AIServiceProtocol, @unchecked Sendable {
    private let inner: any AIServiceProtocol
    private(set) var streamCallCount: Int = 0

    init(inner: any AIServiceProtocol) { self.inner = inner }

    func summarize(text: String) async -> String? { await inner.summarize(text: text) }
    func analyzeMood(text: String) async -> Double { await inner.analyzeMood(text: text) }
    func extractThemes(text: String) async -> [String] { await inner.extractThemes(text: text) }
    func judgeThemeAliases(
        newTags: [String],
        inventory: [ThemeAliasJudgeCandidate]
    ) async -> [ThemeAliasJudgeMatch] {
        await inner.judgeThemeAliases(newTags: newTags, inventory: inventory)
    }
    func scanThemeAliasGroups(
        candidates: [ThemeAliasJudgeCandidate]
    ) async throws -> [ThemeAliasJudgeGroup] {
        try await inner.scanThemeAliasGroups(candidates: candidates)
    }
    func embed(text: String) async -> [Float]? { await inner.embed(text: text) }
    func askEvents(question: String, context entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
        inner.askEvents(question: question, context: entries)
    }
    func composeSuggestions(context: SuggestionContext) async -> SuggestionBundle? {
        await inner.composeSuggestions(context: context)
    }
    func parseImportedDiaries(rawText: String) async throws -> [ParsedDiaryEntry] {
        try await inner.parseImportedDiaries(rawText: rawText)
    }

    func streamReportEvents(entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
        streamCallCount += 1
        return inner.streamReportEvents(entries: entries)
    }
}
