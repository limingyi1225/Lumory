//
//  InsightsResultCacheTests.swift
//  ChronoteTests
//
//  P1 回归测:`InsightsResultCache` 是 Insights sheet 的 SWR 缓存,
//  `EntryWipeOrchestrator.performBulkWipeCleanup` / `performSingleDeleteCleanup`
//  都依赖它的 `clear()` API 派生缓存(详见 CLAUDE.md "EntryWipeOrchestrator" 段)。
//
//  这台 @MainActor singleton 一旦坏:
//    - snapshot/update/clear 任意分支挂掉 → Insights sheet 重开看到旧聚合 / 不刷新
//    - clear() 漏一行 → 用户清空数据后再开 Insights 看到引用已删 entry 的旧聚合
//    - 多 range 串扰 → .month 数据写到 .year 桶 → 范围切换显示错误
//  → 都是用户可感的 data integrity 问题。
//
//  测试每条都先 reset singleton(`clear()`),避免上一个测试残留污染。
//

import Testing
import Foundation
@testable import Lumory

@MainActor
struct InsightsResultCacheTests {
    /// 每个测试前 reset singleton 状态。
    private func reset() {
        InsightsResultCache.shared.clear()
    }

    // MARK: - Fixture

    /// 构造一个最小可识别的 Snapshot。`marker` 用 `stats.totalEntries` 携带,
    /// 比较时只看这个字段(Snapshot 整体不是 Equatable)。
    private func makeSnapshot(marker: Int) -> InsightsResultCache.Snapshot {
        let stats = InsightsEngine.WritingStats(
            totalEntries: marker,
            currentStreak: 0,
            longestStreak: 0,
            totalWords: 0,
            avgMood: 0.5
        )
        return InsightsResultCache.Snapshot(
            moodPoints: [],
            themes: [],
            stats: stats,
            dailyCells: [],
            facts: []
        )
    }

    // MARK: - snapshot(for:)

    @Test func snapshot_missingRange_returnsNil() {
        reset()
        let cache = InsightsResultCache.shared
        #expect(cache.snapshot(for: .month) == nil)
        #expect(cache.snapshot(for: .quarter) == nil)
        #expect(cache.snapshot(for: .year) == nil)
        #expect(cache.snapshot(for: .all) == nil)
    }

    // MARK: - update(_:for:)

    @Test func update_storesAndRetrievesPerRange() {
        reset()
        let cache = InsightsResultCache.shared
        let snap = makeSnapshot(marker: 42)
        cache.update(snap, for: .month)
        let got = cache.snapshot(for: .month)
        #expect(got != nil)
        #expect(got?.stats.totalEntries == 42)
    }

    @Test func update_differentRanges_dontInterfere() {
        reset()
        let cache = InsightsResultCache.shared
        let monthSnap = makeSnapshot(marker: 1)
        let yearSnap = makeSnapshot(marker: 99)
        cache.update(monthSnap, for: .month)
        cache.update(yearSnap, for: .year)
        #expect(cache.snapshot(for: .month)?.stats.totalEntries == 1)
        #expect(cache.snapshot(for: .year)?.stats.totalEntries == 99)
        // 未写过的 range 应该仍然 nil。
        #expect(cache.snapshot(for: .quarter) == nil)
        #expect(cache.snapshot(for: .all) == nil)
    }

    @Test func update_overwritesPreviousValueForSameRange() {
        reset()
        let cache = InsightsResultCache.shared
        cache.update(makeSnapshot(marker: 1), for: .month)
        cache.update(makeSnapshot(marker: 2), for: .month)
        #expect(cache.snapshot(for: .month)?.stats.totalEntries == 2)
    }

    @Test func update_allFourRanges_storedIndependently() {
        reset()
        let cache = InsightsResultCache.shared
        cache.update(makeSnapshot(marker: 10), for: .month)
        cache.update(makeSnapshot(marker: 20), for: .quarter)
        cache.update(makeSnapshot(marker: 30), for: .year)
        cache.update(makeSnapshot(marker: 40), for: .all)
        #expect(cache.snapshot(for: .month)?.stats.totalEntries == 10)
        #expect(cache.snapshot(for: .quarter)?.stats.totalEntries == 20)
        #expect(cache.snapshot(for: .year)?.stats.totalEntries == 30)
        #expect(cache.snapshot(for: .all)?.stats.totalEntries == 40)
    }

    // MARK: - clear()

    @Test func clear_emptiesAllRanges() {
        reset()
        let cache = InsightsResultCache.shared
        cache.update(makeSnapshot(marker: 1), for: .month)
        cache.update(makeSnapshot(marker: 2), for: .quarter)
        cache.update(makeSnapshot(marker: 3), for: .year)
        cache.update(makeSnapshot(marker: 4), for: .all)
        // 预检:写入成功。
        #expect(cache.snapshot(for: .month) != nil)
        #expect(cache.snapshot(for: .all) != nil)

        cache.clear()

        // 全部 range 都应该是 nil。
        #expect(cache.snapshot(for: .month) == nil)
        #expect(cache.snapshot(for: .quarter) == nil)
        #expect(cache.snapshot(for: .year) == nil)
        #expect(cache.snapshot(for: .all) == nil)
    }

    @Test func clear_onEmptyCache_isNoOp() {
        reset()
        let cache = InsightsResultCache.shared
        // 调一次 clear 在空 cache 上,不应崩溃。
        cache.clear()
        cache.clear()
        #expect(cache.snapshot(for: .month) == nil)
    }

    @Test func clear_thenUpdate_worksNormally() {
        reset()
        let cache = InsightsResultCache.shared
        cache.update(makeSnapshot(marker: 1), for: .month)
        cache.clear()
        // clear 后再写应该正常工作(不残留状态)。
        cache.update(makeSnapshot(marker: 5), for: .month)
        #expect(cache.snapshot(for: .month)?.stats.totalEntries == 5)
    }
}
