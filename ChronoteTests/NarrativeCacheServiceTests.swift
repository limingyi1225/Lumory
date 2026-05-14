//
//  NarrativeCacheServiceTests.swift
//  ChronoteTests
//
//  wave14 NarrativeSummaryCard cache 行为单测。
//
//  覆盖:
//  - latest(for:in:) 按 rangeKind 找最新一条 v2,忽略 v1 老 record
//  - latest 在多 range 共存时只返指定 rangeKind 的
//  - isStale 3 个 stale 触发条件(nil cache / 新日记后写 / entryCount 变化)+ fresh 路径
//  - **2026-05-10**: age-based freshness window 整套删除(用户没写日记不该凭空重生)
//

import Testing
import Foundation
import CoreData
@testable import Lumory

@MainActor
struct NarrativeCacheServiceTests {
    init() {
        NarrativeCacheService.resetInvalidationForTesting()
    }

    // MARK: - latest

    @Test func latest_returnsNil_whenNoNarrative() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        #expect(NarrativeCacheService.latest(for: .month, in: context) == nil)
    }

    @Test func latest_returnsLatestByCreatedAt() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        // 先写一条旧 narrative (.month, v2)
        let older = try AIConversation.insertNarrative(
            in: context,
            title: "old",
            payload: AIConversation.NarrativePayload(
                rangeStart: Date(timeIntervalSinceNow: -2_592_000),
                rangeEnd: Date(),
                body: "OLD",
                isIncomplete: false,
                truncatedReason: nil,
                rangeKind: TimeRange.month.rawValue,
                entryCount: 5,
                sourceLatestEntryDate: Date(timeIntervalSinceNow: -3600),
                generatedAt: Date(timeIntervalSinceNow: -120)
            ),
            citedEntryIds: []
        )
        older.createdAt = Date(timeIntervalSinceNow: -120)

        // 后写一条新的 (.month, v2) — 应被 latest 选中
        let newer = try AIConversation.insertNarrative(
            in: context,
            title: "new",
            payload: AIConversation.NarrativePayload(
                rangeStart: Date(timeIntervalSinceNow: -2_592_000),
                rangeEnd: Date(),
                body: "NEW",
                isIncomplete: false,
                truncatedReason: nil,
                rangeKind: TimeRange.month.rawValue,
                entryCount: 6,
                sourceLatestEntryDate: Date(),
                generatedAt: Date()
            ),
            citedEntryIds: []
        )
        newer.createdAt = Date()
        try context.save()

        let result = try #require(NarrativeCacheService.latest(for: .month, in: context))
        #expect(result.payload.body == "NEW")
        #expect(result.payload.entryCount == 6)
    }

    @Test func latest_filtersV1Records() async throws {
        // v1 record(rangeKind=nil)不参与 cache hit;v2 同 rangeKind 的应被选中。
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        // v1: rangeKind == nil(老 callsite,无 v2 字段)
        let v1 = try AIConversation.insertNarrative(
            in: context,
            title: "v1 old",
            payload: AIConversation.NarrativePayload(
                rangeStart: Date(timeIntervalSinceNow: -2_592_000),
                rangeEnd: Date(),
                body: "V1",
                isIncomplete: false,
                truncatedReason: nil
                // rangeKind / entryCount / ... 默认 nil
            ),
            citedEntryIds: []
        )
        v1.createdAt = Date()  // 比 v2 还新,但应被忽略

        // v2: 老一点但带 rangeKind
        let v2 = try AIConversation.insertNarrative(
            in: context,
            title: "v2",
            payload: AIConversation.NarrativePayload(
                rangeStart: Date(timeIntervalSinceNow: -2_592_000),
                rangeEnd: Date(),
                body: "V2",
                isIncomplete: false,
                truncatedReason: nil,
                rangeKind: TimeRange.month.rawValue,
                entryCount: 4,
                sourceLatestEntryDate: nil,
                generatedAt: Date(timeIntervalSinceNow: -300)
            ),
            citedEntryIds: []
        )
        v2.createdAt = Date(timeIntervalSinceNow: -300)
        try context.save()

        // payloadVersion 在 insertNarrative 内根据 rangeKind 自动设置:v1=1, v2=2
        #expect(v1.payloadVersion == 1, "rangeKind=nil 必须落 v1")
        #expect(v2.payloadVersion == 2, "rangeKind 非空必须落 v2")

        let result = try #require(NarrativeCacheService.latest(for: .month, in: context))
        #expect(result.payload.body == "V2",
                "v1 record 必须忽略,即便 createdAt 更新")
    }

    @Test func latest_filtersByRangeKind() async throws {
        // .month / .year 两种 v2 record 共存,各自查各自的。
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        for kind in [TimeRange.month, TimeRange.year] {
            _ = try AIConversation.insertNarrative(
                in: context,
                title: kind.rawValue,
                payload: AIConversation.NarrativePayload(
                    rangeStart: Date(timeIntervalSinceNow: -86400),
                    rangeEnd: Date(),
                    body: kind.rawValue.uppercased(),
                    isIncomplete: false,
                    truncatedReason: nil,
                    rangeKind: kind.rawValue,
                    entryCount: 3,
                    sourceLatestEntryDate: nil,
                    generatedAt: Date()
                ),
                citedEntryIds: []
            )
        }
        try context.save()

        let monthResult = try #require(NarrativeCacheService.latest(for: .month, in: context))
        #expect(monthResult.payload.body == "MONTH")

        let yearResult = try #require(NarrativeCacheService.latest(for: .year, in: context))
        #expect(yearResult.payload.body == "YEAR")
    }

    @Test func latest_returnsV3HeadlinePayload() async throws {
        // v3 payload 带 headline。latest 必须 decode 并返回 headline,不能因为 v2+ fetch
        // predicate / fetchLimit 优化漏掉新 schema。
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        _ = try AIConversation.insertNarrative(
            in: context,
            title: "v3",
            payload: AIConversation.NarrativePayload(
                rangeStart: Date(timeIntervalSinceNow: -2_592_000),
                rangeEnd: Date(),
                body: "BODY",
                isIncomplete: false,
                truncatedReason: nil,
                rangeKind: TimeRange.month.rawValue,
                entryCount: 5,
                sourceLatestEntryDate: Date(timeIntervalSinceNow: -3600),
                generatedAt: Date(),
                headline: "HEAD"
            ),
            citedEntryIds: []
        )
        try context.save()

        let result = try #require(NarrativeCacheService.latest(for: .month, in: context))
        #expect(result.payload.headline == "HEAD")
        #expect(result.payload.body == "BODY")
    }

    @Test func latest_scansPastNewest32RowsForOlderRange() async throws {
        // rangeKind 在 JSON payload 内,不能只取最新 32 条再过滤。连续生成 .month 后,
        // 稍旧的 .year cache 仍应被找到。
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let yearCreatedAt = Date(timeIntervalSinceNow: -3_600)
        let year = try AIConversation.insertNarrative(
            in: context,
            title: "year",
            payload: AIConversation.NarrativePayload(
                rangeStart: Date(timeIntervalSinceNow: -31_536_000),
                rangeEnd: Date(),
                body: "YEAR",
                isIncomplete: false,
                truncatedReason: nil,
                rangeKind: TimeRange.year.rawValue,
                entryCount: 40,
                sourceLatestEntryDate: Date(timeIntervalSinceNow: -7_200),
                generatedAt: yearCreatedAt,
                headline: "YEAR HEAD"
            ),
            citedEntryIds: []
        )
        year.createdAt = yearCreatedAt

        for idx in 0..<40 {
            let month = try AIConversation.insertNarrative(
                in: context,
                title: "month \(idx)",
                payload: AIConversation.NarrativePayload(
                    rangeStart: Date(timeIntervalSinceNow: -2_592_000),
                    rangeEnd: Date(),
                    body: "MONTH \(idx)",
                    isIncomplete: false,
                    truncatedReason: nil,
                    rangeKind: TimeRange.month.rawValue,
                    entryCount: 5,
                    sourceLatestEntryDate: Date(timeIntervalSinceNow: -600),
                    generatedAt: Date()
                ),
                citedEntryIds: []
            )
            month.createdAt = Date(timeIntervalSinceNow: Double(idx))
        }
        try context.save()

        let result = try #require(NarrativeCacheService.latest(for: .year, in: context))
        #expect(result.payload.body == "YEAR")
    }

    @Test func latest_skipsRowsOlderThanEntryInvalidation() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        defer { NarrativeCacheService.resetInvalidationForTesting() }

        let staleCreatedAt = Date(timeIntervalSinceNow: -60)
        let stale = try AIConversation.insertNarrative(
            in: context,
            title: "stale",
            payload: AIConversation.NarrativePayload(
                rangeStart: Date(timeIntervalSinceNow: -2_592_000),
                rangeEnd: Date(),
                body: "STALE",
                isIncomplete: false,
                truncatedReason: nil,
                rangeKind: TimeRange.month.rawValue,
                entryCount: 5,
                sourceLatestEntryDate: nil,
                generatedAt: staleCreatedAt,
                headline: "STALE"
            ),
            citedEntryIds: []
        )
        stale.createdAt = staleCreatedAt
        try context.save()

        NarrativeCacheService.markInvalidatedForEntryChange(at: Date())

        #expect(
            NarrativeCacheService.latest(for: .month, in: context) == nil,
            "entry edit/delete invalidation 后,旧 AIConversation 仍保留但不能再当 narrative cache"
        )
    }

    // MARK: - isStale

    @Test func isStale_nilCache_returnsTrue() async throws {
        let stale = NarrativeCacheService.isStale(
            payload: nil, createdAt: nil,
            mostRecentEntryDate: Date(),
            currentEntryCount: 5
        )
        #expect(stale, "无 cache 必须 stale")
    }

    @Test func isStale_freshCache_returnsFalse() async throws {
        let now = Date()
        let payload = AIConversation.NarrativePayload(
            rangeStart: Date(timeIntervalSinceNow: -2_592_000),
            rangeEnd: now,
            body: "fresh",
            isIncomplete: false,
            truncatedReason: nil,
            rangeKind: TimeRange.month.rawValue,
            entryCount: 5,
            sourceLatestEntryDate: Date(timeIntervalSinceNow: -3600),
            generatedAt: now,
            headline: "fresh"
        )
        let stale = NarrativeCacheService.isStale(
            payload: payload,
            createdAt: now,
            mostRecentEntryDate: Date(timeIntervalSinceNow: -3600),
            currentEntryCount: 5
        )
        #expect(!stale)
    }

    @Test func isStale_entryNewerThanCache_returnsTrue() async throws {
        // 用户在生成 narrative 后又写了一条 → mostRecentEntryDate > createdAt → stale。
        let cacheCreated = Date(timeIntervalSinceNow: -3600)
        let newerEntry = Date()
        let payload = AIConversation.NarrativePayload(
            rangeStart: Date(timeIntervalSinceNow: -2_592_000),
            rangeEnd: Date(),
            body: "x",
            isIncomplete: false,
            truncatedReason: nil,
            rangeKind: TimeRange.month.rawValue,
            entryCount: 5,
            sourceLatestEntryDate: Date(timeIntervalSinceNow: -7200),
            generatedAt: cacheCreated,
            headline: "old"
        )
        let stale = NarrativeCacheService.isStale(
            payload: payload,
            createdAt: cacheCreated,
            mostRecentEntryDate: newerEntry,
            currentEntryCount: 5
        )
        #expect(stale)
    }

    @Test func isStale_cacheOlderThanWindow_returnsFalse() async throws {
        // **2026-05-10 修复**:删 age-based freshness window 后,即便 cache 30h+ 老
        // (远超原 .month 24h 窗口),只要内容信号没变(没新日记 + entryCount 不变)
        // 就**不**stale。这是用户体验诉求 — 没写日记不该凭空重生 LLM 输出。
        let cacheCreated = Date(timeIntervalSinceNow: -30 * 3600)
        let payload = AIConversation.NarrativePayload(
            rangeStart: Date(timeIntervalSinceNow: -2_592_000),
            rangeEnd: Date(),
            body: "x",
            isIncomplete: false,
            truncatedReason: nil,
            rangeKind: TimeRange.month.rawValue,
            entryCount: 5,
            sourceLatestEntryDate: cacheCreated,
            generatedAt: cacheCreated,
            headline: "old"
        )
        let stale = NarrativeCacheService.isStale(
            payload: payload,
            createdAt: cacheCreated,
            mostRecentEntryDate: cacheCreated,
            currentEntryCount: 5
        )
        #expect(!stale, "没新日记 + entryCount 不变,即便 cache 老也不应 stale")
    }

    @Test func isStale_entryCountChanged_returnsTrue() async throws {
        // 用户删了一篇日记 → mostRecentEntryDate 可能不变,但 entryCount 从 5 → 4。仍 stale。
        let now = Date()
        let payload = AIConversation.NarrativePayload(
            rangeStart: Date(timeIntervalSinceNow: -2_592_000),
            rangeEnd: now,
            body: "x",
            isIncomplete: false,
            truncatedReason: nil,
            rangeKind: TimeRange.month.rawValue,
            entryCount: 5,    // 生成时是 5
            sourceLatestEntryDate: Date(timeIntervalSinceNow: -3600),
            generatedAt: now,
            headline: "old"
        )
        let stale = NarrativeCacheService.isStale(
            payload: payload,
            createdAt: now,
            mostRecentEntryDate: Date(timeIntervalSinceNow: -3600),
            currentEntryCount: 4   // 现在是 4
        )
        #expect(stale, "entryCount 不一致(用户删了日记)必须 stale")
    }

    @Test func isStale_missingHeadline_returnsTrue() async throws {
        let now = Date()
        let payload = AIConversation.NarrativePayload(
            rangeStart: Date(timeIntervalSinceNow: -2_592_000),
            rangeEnd: now,
            body: "old v2",
            isIncomplete: false,
            truncatedReason: nil,
            rangeKind: TimeRange.month.rawValue,
            entryCount: 5,
            sourceLatestEntryDate: Date(timeIntervalSinceNow: -3600),
            generatedAt: now
        )
        let stale = NarrativeCacheService.isStale(
            payload: payload,
            createdAt: now,
            mostRecentEntryDate: Date(timeIntervalSinceNow: -3600),
            currentEntryCount: 5
        )
        #expect(stale, "v2 old cache without headline should be regenerated")
    }

    @Test func isStale_incompletePayload_returnsTrue() async throws {
        let now = Date()
        let payload = AIConversation.NarrativePayload(
            rangeStart: Date(timeIntervalSinceNow: -2_592_000),
            rangeEnd: now,
            body: "partial",
            isIncomplete: true,
            truncatedReason: "truncated",
            rangeKind: TimeRange.month.rawValue,
            entryCount: 5,
            sourceLatestEntryDate: Date(timeIntervalSinceNow: -3600),
            generatedAt: now,
            headline: "partial"
        )
        let stale = NarrativeCacheService.isStale(
            payload: payload,
            createdAt: now,
            mostRecentEntryDate: Date(timeIntervalSinceNow: -3600),
            currentEntryCount: 5
        )
        #expect(stale, "incomplete cache should be retried")
    }

    // freshnessWindow 函数已删(2026-05-10),不再有 age-based stale 判定。
}
