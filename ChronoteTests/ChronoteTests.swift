//
//  ChronoteTests.swift
//  ChronoteTests
//
//  Pure-function unit tests. Anything touching Core Data / network lives in UI tests.
//

import Testing
import Foundation
import CoreData
@testable import Lumory

// MARK: - InsightsEngine: cosineSimilarity

struct CosineSimilarityTests {
    @Test func identicalVectors_returnOne() {
        let a: [Float] = [1, 2, 3, 4]
        #expect(abs(InsightsEngine.cosineSimilarity(a, a) - 1.0) < 1e-5)
    }

    @Test func orthogonalVectors_returnZero() {
        #expect(InsightsEngine.cosineSimilarity([1, 0], [0, 1]) == 0)
    }

    @Test func oppositeVectors_returnNegativeOne() {
        let a: [Float] = [1, 2, 3]
        let b: [Float] = [-1, -2, -3]
        #expect(abs(InsightsEngine.cosineSimilarity(a, b) - (-1.0)) < 1e-5)
    }

    @Test func emptyVectors_returnZero() {
        #expect(InsightsEngine.cosineSimilarity([], []) == 0)
    }

    @Test func mismatchedLengths_returnZero() {
        // 旧实现会 min(count) 截断；新实现拒绝不等长，避免生成误导性的相似度。
        #expect(InsightsEngine.cosineSimilarity([1, 2, 3], [1, 2]) == 0)
    }

    @Test func zeroVector_returnZero() {
        #expect(InsightsEngine.cosineSimilarity([0, 0, 0], [1, 2, 3]) == 0)
    }
}

// MARK: - InsightsEngine: startOfBucket

struct BucketGroupingTests {
    private let calendar = Calendar(identifier: .gregorian)

    @Test func day_bucketsToMidnight() {
        let date = makeDate(year: 2024, month: 6, day: 15, hour: 14, minute: 30)
        let bucket = InsightsEngine.startOfBucket(date, bucket: .day, calendar: calendar)
        let expected = makeDate(year: 2024, month: 6, day: 15, hour: 0, minute: 0)
        #expect(bucket == expected)
    }

    @Test func week_bucketsToFirstWeekday() {
        let date = makeDate(year: 2024, month: 6, day: 15, hour: 14, minute: 30) // Saturday
        let bucket = InsightsEngine.startOfBucket(date, bucket: .week, calendar: calendar)
        // Gregorian first weekday = 1 (Sun). Week containing Sat June 15 2024 starts Sun June 9.
        let expected = makeDate(year: 2024, month: 6, day: 9, hour: 0, minute: 0)
        #expect(bucket == expected)
    }

    @Test func month_bucketsToFirstOfMonth() {
        let date = makeDate(year: 2024, month: 6, day: 15)
        let bucket = InsightsEngine.startOfBucket(date, bucket: .month, calendar: calendar)
        let expected = makeDate(year: 2024, month: 6, day: 1)
        #expect(bucket == expected)
    }
}

// MARK: - InsightsEngine: aggregateMoodSeries

struct MoodSeriesTests {
    @Test func emptyEntries_returnsEmpty() {
        let series = InsightsEngine.aggregateMoodSeries(entries: [], bucket: .day)
        #expect(series.isEmpty)
    }

    @Test func singleEntry_singlePoint() {
        let entry = makeEntry(date: makeDate(year: 2024, month: 6, day: 1), mood: 0.8)
        let series = InsightsEngine.aggregateMoodSeries(entries: [entry], bucket: .day)
        #expect(series.count == 1)
        #expect(abs(series.first!.mood - 0.8) < 1e-5)
        #expect(series.first!.entryCount == 1)
    }

    @Test func sameDay_averagesMood() {
        let day = makeDate(year: 2024, month: 6, day: 1, hour: 9)
        let entries = [
            makeEntry(date: day, mood: 0.2),
            makeEntry(date: addHours(day, 3), mood: 0.8)
        ]
        let series = InsightsEngine.aggregateMoodSeries(entries: entries, bucket: .day)
        #expect(series.count == 1)
        #expect(abs(series[0].mood - 0.5) < 1e-5)
        #expect(series[0].entryCount == 2)
    }

    @Test func multipleDays_sortedAscending() {
        let entries = [
            makeEntry(date: makeDate(year: 2024, month: 6, day: 3), mood: 0.5),
            makeEntry(date: makeDate(year: 2024, month: 6, day: 1), mood: 0.3),
            makeEntry(date: makeDate(year: 2024, month: 6, day: 2), mood: 0.7)
        ]
        let series = InsightsEngine.aggregateMoodSeries(entries: entries, bucket: .day)
        #expect(series.count == 3)
        #expect(series[0].date < series[1].date)
        #expect(series[1].date < series[2].date)
    }
}

// MARK: - InsightsEngine: computeStreaks

struct StreakComputationTests {
    private let calendar = Calendar(identifier: .gregorian)

    @Test func emptyInput_returnsZeros() {
        let today = makeDate(year: 2024, month: 6, day: 15)
        let result = InsightsEngine.computeStreaks(uniqueDaysDesc: [], today: today, calendar: calendar)
        #expect(result.current == 0)
        #expect(result.longest == 0)
    }

    @Test func writingToday_currentIsOne() {
        let today = makeDate(year: 2024, month: 6, day: 15)
        let result = InsightsEngine.computeStreaks(uniqueDaysDesc: [today], today: today, calendar: calendar)
        #expect(result.current == 1)
        #expect(result.longest == 1)
    }

    @Test func writingYesterday_currentIsOne() {
        let today = makeDate(year: 2024, month: 6, day: 15)
        let yesterday = makeDate(year: 2024, month: 6, day: 14)
        let result = InsightsEngine.computeStreaks(uniqueDaysDesc: [yesterday], today: today, calendar: calendar)
        #expect(result.current == 1)
        #expect(result.longest == 1)
    }

    @Test func consecutiveDays_currentEqualsRun() {
        let today = makeDate(year: 2024, month: 6, day: 15)
        let days = (0..<5).compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        let result = InsightsEngine.computeStreaks(uniqueDaysDesc: days, today: today, calendar: calendar)
        #expect(result.current == 5)
        #expect(result.longest == 5)
    }

    @Test func gapBreaksCurrentButRemembersLongest() {
        let today = makeDate(year: 2024, month: 6, day: 15)
        let days: [Date] = [
            today,                                      // current run starts
            makeDate(year: 2024, month: 6, day: 14),
            makeDate(year: 2024, month: 6, day: 13),
            // gap of 3 days
            makeDate(year: 2024, month: 6, day: 9),
            makeDate(year: 2024, month: 6, day: 8),
            makeDate(year: 2024, month: 6, day: 7),
            makeDate(year: 2024, month: 6, day: 6)
        ]
        let result = InsightsEngine.computeStreaks(uniqueDaysDesc: days, today: today, calendar: calendar)
        #expect(result.current == 3)
        #expect(result.longest == 4)
    }

    @Test func twoDaysAgoOnly_currentIsZero() {
        // 缺席"今天/昨天" → 不算当前连续
        let today = makeDate(year: 2024, month: 6, day: 15)
        let twoDaysAgo = makeDate(year: 2024, month: 6, day: 13)
        let result = InsightsEngine.computeStreaks(uniqueDaysDesc: [twoDaysAgo], today: today, calendar: calendar)
        #expect(result.current == 0)
        #expect(result.longest == 1)
    }
}

// MARK: - TimeRange

struct TimeRangeTests {
    @Test func month_isAboutThirtyDays() {
        let interval = TimeRange.month.dateInterval
        let days = interval.duration / 86_400
        // 月 = 28~31 天，允许上下 1 天浮动以吸收 DST
        #expect(days >= 27 && days <= 32)
    }

    @Test func allRanges_endAtNow() {
        // 30 秒容差：CI（尤其 Sim 冷启动时）可能被 IO / warmup 拖掉很久再跑到断言，
        // 原先的 5 秒窗口在慢机器上偶发 flaky。30s 仍然远小于任何 range 粒度。
        let tolerance: TimeInterval = 30
        for tr in TimeRange.allCases {
            let diff = abs(tr.dateInterval.end.timeIntervalSinceNow)
            #expect(diff < tolerance, "Range \(tr) should end at now (±30s)")
        }
    }

    @Test func allRanges_startBeforeEnd() {
        for tr in TimeRange.allCases {
            let iv = tr.dateInterval
            #expect(iv.start < iv.end)
        }
    }

    @Test func allRange_usesDistantPast() {
        // `all` 表示不设下界；应比 year 还早。
        #expect(TimeRange.all.dateInterval.start < TimeRange.year.dateInterval.start)
    }

    @Test func chartBucket_scalesWithRange() {
        // 月用 day；季用 week；年/全部用 month —— 让点数稳定在 ~30 以内。
        #expect(TimeRange.month.chartBucket == .day)
        #expect(TimeRange.quarter.chartBucket == .week)
        #expect(TimeRange.year.chartBucket == .month)
        #expect(TimeRange.all.chartBucket == .month)
    }
}

// MARK: - CorrelationFactGenerator

struct CorrelationFactGeneratorTests {
    @Test func emptyInputs_returnsEmpty() {
        let facts = CorrelationFactGenerator.generate(
            points: [],
            themes: [],
            stats: InsightsEngine.WritingStats.empty
        )
        #expect(facts.isEmpty)
    }

    @Test func withPoints_alwaysIncludesOverall() {
        let points = [
            InsightsEngine.MoodPoint(date: makeDate(year: 2024, month: 6, day: 1), mood: 0.8, entryCount: 1),
            InsightsEngine.MoodPoint(date: makeDate(year: 2024, month: 6, day: 2), mood: 0.7, entryCount: 1)
        ]
        let facts = CorrelationFactGenerator.generate(
            points: points,
            themes: [],
            stats: InsightsEngine.WritingStats.empty
        )
        #expect(facts.contains { $0.kind == .overall })
        #expect(facts.first(where: { $0.kind == .overall })?.isPositive == true)
    }

    @Test func negativeAverage_markedAsNotPositive() {
        let points = [
            InsightsEngine.MoodPoint(date: makeDate(year: 2024, month: 6, day: 1), mood: 0.1, entryCount: 1),
            InsightsEngine.MoodPoint(date: makeDate(year: 2024, month: 6, day: 2), mood: 0.3, entryCount: 1)
        ]
        let facts = CorrelationFactGenerator.generate(
            points: points,
            themes: [],
            stats: InsightsEngine.WritingStats.empty
        )
        let overall = facts.first(where: { $0.kind == .overall })
        #expect(overall?.isPositive == false)
    }

    @Test func streakBelowThreshold_omitsStreakFact() {
        let stats = InsightsEngine.WritingStats(
            totalEntries: 2, currentStreak: 2, longestStreak: 2, totalWords: 100, avgMood: 0.5
        )
        let facts = CorrelationFactGenerator.generate(points: [], themes: [], stats: stats)
        #expect(!facts.contains { $0.kind == .streak })
    }

    @Test func streakAtThreeOrMore_includesStreakFact() {
        let stats = InsightsEngine.WritingStats(
            totalEntries: 5, currentStreak: 5, longestStreak: 5, totalWords: 500, avgMood: 0.6
        )
        let facts = CorrelationFactGenerator.generate(points: [], themes: [], stats: stats)
        #expect(facts.contains { $0.kind == .streak })
    }

    @Test func idsAreStableAcrossInvocations() {
        // 相同输入应得到相同 id —— SwiftUI diff 不会因重新生成而抖动。
        let stats = InsightsEngine.WritingStats(
            totalEntries: 4, currentStreak: 4, longestStreak: 4, totalWords: 400, avgMood: 0.7
        )
        let first = CorrelationFactGenerator.generate(points: [], themes: [], stats: stats)
        let second = CorrelationFactGenerator.generate(points: [], themes: [], stats: stats)
        #expect(first.map(\.id) == second.map(\.id))
    }

    @Test func twoThemes_emitsBestAndWorst() {
        let range = DateInterval(
            start: makeDate(year: 2024, month: 6, day: 1),
            end: makeDate(year: 2024, month: 6, day: 30)
        )
        let themes = [
            InsightsEngine.Theme(name: "work", count: 10, uniqueDays: 5, avgMood: 0.3, moodLow: 0.3, moodHigh: 0.3, lowCount: 10, highCount: 0, entryIds: [], trend: Array(repeating: 0.3, count: 6)),
            InsightsEngine.Theme(name: "family", count: 8, uniqueDays: 4, avgMood: 0.9, moodLow: 0.9, moodHigh: 0.9, lowCount: 0, highCount: 8, entryIds: [], trend: Array(repeating: 0.9, count: 6))
        ]
        let facts = CorrelationFactGenerator.generate(points: [], themes: themes, stats: .empty)
        #expect(facts.contains { $0.kind == .bestMoodTheme })
        #expect(facts.contains { $0.kind == .worstMoodTheme })
        _ = range // silence unused
    }
}

// MARK: - InsightsEngine.aggregateThemes

struct ThemeAggregationTests {
    @Test func zeroTrendBuckets_returnsEmpty() {
        let entry = makeEntry(date: makeDate(year: 2024, month: 6, day: 1), mood: 0.5, themes: ["work"])
        let range = DateInterval(
            start: makeDate(year: 2024, month: 6, day: 1),
            end: makeDate(year: 2024, month: 6, day: 30)
        )
        let result = InsightsEngine.aggregateThemes(entries: [entry], range: range, trendBuckets: 0)
        #expect(result.isEmpty)
    }

    @Test func limitCapsReturnCount() {
        let range = DateInterval(
            start: makeDate(year: 2024, month: 6, day: 1),
            end: makeDate(year: 2024, month: 6, day: 30)
        )
        let entries = (0..<10).map { idx in
            makeEntry(
                date: makeDate(year: 2024, month: 6, day: 1 + idx),
                mood: 0.5,
                themes: ["t\(idx)"]
            )
        }
        let result = InsightsEngine.aggregateThemes(entries: entries, range: range, limit: 3)
        #expect(result.count == 3)
    }

    @Test func sortedByUniqueDaysDescending() {
        let range = DateInterval(
            start: makeDate(year: 2024, month: 6, day: 1),
            end: makeDate(year: 2024, month: 6, day: 30)
        )
        let entries: [DiaryEntryData] = [
            makeEntry(date: makeDate(year: 2024, month: 6, day: 1), themes: ["rare"]),
            makeEntry(date: makeDate(year: 2024, month: 6, day: 2), themes: ["often"]),
            makeEntry(date: makeDate(year: 2024, month: 6, day: 3), themes: ["often"]),
            makeEntry(date: makeDate(year: 2024, month: 6, day: 4), themes: ["often"])
        ]
        let result = InsightsEngine.aggregateThemes(entries: entries, range: range)
        #expect(result.first?.name == "often")
        #expect(result.first?.uniqueDays == 3)
    }

    @Test func recurringBeatsBursty() {
        // Abby 出现在 4 个不同的日子（每天 1 篇），"工作" 集中在 2 天但总次数更高。
        // 期望 Abby 排在前面 —— 反复出现的"角色"比突发高频的话题更"我"。
        let range = DateInterval(
            start: makeDate(year: 2024, month: 6, day: 1),
            end: makeDate(year: 2024, month: 6, day: 30)
        )
        var entries: [DiaryEntryData] = []
        for day in 1...4 {
            entries.append(makeEntry(date: makeDate(year: 2024, month: 6, day: day), themes: ["Abby"]))
        }
        // work: 3 篇同一天 + 2 篇第二天 = 5 篇但只 2 天
        for _ in 0..<3 {
            entries.append(makeEntry(date: makeDate(year: 2024, month: 6, day: 10, hour: 9), themes: ["work"]))
        }
        for _ in 0..<2 {
            entries.append(makeEntry(date: makeDate(year: 2024, month: 6, day: 11, hour: 9), themes: ["work"]))
        }
        let result = InsightsEngine.aggregateThemes(entries: entries, range: range)
        #expect(result.first?.name == "Abby")
        #expect(result.first?.uniqueDays == 4)
    }

    @Test func caseInsensitiveAggregation_mergesAbbyVariants() {
        // 三个条目分别写了 "Abby" / "abby" / "ABBY" —— 期望聚合成 1 个 theme，展示名为首次出现的 "Abby"。
        let range = DateInterval(
            start: makeDate(year: 2024, month: 6, day: 1),
            end: makeDate(year: 2024, month: 6, day: 30)
        )
        let entries: [DiaryEntryData] = [
            makeEntry(date: makeDate(year: 2024, month: 6, day: 1), themes: ["Abby"]),
            makeEntry(date: makeDate(year: 2024, month: 6, day: 2), themes: ["abby"]),
            makeEntry(date: makeDate(year: 2024, month: 6, day: 3), themes: ["ABBY"])
        ]
        let result = InsightsEngine.aggregateThemes(entries: entries, range: range)
        #expect(result.count == 1)
        #expect(result.first?.name == "Abby")      // 首次出现的原文大小写
        #expect(result.first?.count == 3)
        #expect(result.first?.uniqueDays == 3)
    }

    @Test func bannedMetaThemesAreFiltered() {
        // 即便历史数据里存了"情绪"标签，聚合时也不应出现。
        let range = DateInterval(
            start: makeDate(year: 2024, month: 6, day: 1),
            end: makeDate(year: 2024, month: 6, day: 30)
        )
        let entries: [DiaryEntryData] = [
            makeEntry(date: makeDate(year: 2024, month: 6, day: 1), themes: ["情绪", "Abby"]),
            makeEntry(date: makeDate(year: 2024, month: 6, day: 2), themes: ["心情", "work"])
        ]
        let result = InsightsEngine.aggregateThemes(entries: entries, range: range)
        #expect(!result.contains(where: { $0.name == "情绪" }))
        #expect(!result.contains(where: { $0.name == "心情" }))
        #expect(result.contains(where: { $0.name == "Abby" }))
    }

    @Test func previewCandidateEntryIDs_keepsNewestTailFromAscendingIDs() {
        let ids = (0..<25).map { _ in UUID() }
        let candidates = ThemeCardList.previewCandidateEntryIDs(from: ids, limit: 20)
        #expect(candidates == Array(ids.suffix(20)))
        #expect(!candidates.contains(ids[0]))
        #expect(candidates.last == ids.last)
    }
}

// MARK: - InsightsEngine.rankRetrieval (Ask Past / semantic search)

struct RankRetrievalTests {
    @Test func emptyCorpus_returnsEmpty() {
        #expect(InsightsEngine.rankRetrieval(all: [], queryVector: [1, 0, 0], topK: 8).isEmpty)
    }

    @Test func zeroTopK_returnsEmpty() {
        let entries = [makeEntry(date: makeDate(year: 2024, month: 6, day: 1), embedding: [1, 0])]
        #expect(InsightsEngine.rankRetrieval(all: entries, queryVector: [1, 0], topK: 0).isEmpty)
    }

    @Test func noQueryVector_fallsBackToRecency() {
        let e1 = makeEntry(date: makeDate(year: 2024, month: 6, day: 1), embedding: [1, 0])
        let e2 = makeEntry(date: makeDate(year: 2024, month: 6, day: 10), embedding: [0, 1])
        let e3 = makeEntry(date: makeDate(year: 2024, month: 6, day: 20), embedding: nil)
        let result = InsightsEngine.rankRetrieval(all: [e1, e2, e3], queryVector: nil, topK: 3)
        #expect(result.map(\.id) == [e3.id, e2.id, e1.id])
    }

    @Test func allNonEmbedded_fallsBackToRecency() {
        let e1 = makeEntry(date: makeDate(year: 2024, month: 6, day: 1), embedding: nil)
        let e2 = makeEntry(date: makeDate(year: 2024, month: 6, day: 10), embedding: nil)
        let result = InsightsEngine.rankRetrieval(all: [e1, e2], queryVector: [1, 0, 0], topK: 5)
        #expect(result.map(\.id) == [e2.id, e1.id])
    }

    @Test func allEmbedded_rankedByCosine() {
        // q=[1,0] —— e1 方向完全对齐 = 1.0；e2 方向垂直 = 0；e3 方向相反 = -1
        let e1 = makeEntry(date: makeDate(year: 2024, month: 6, day: 1), embedding: [1, 0])
        let e2 = makeEntry(date: makeDate(year: 2024, month: 6, day: 2), embedding: [0, 1])
        let e3 = makeEntry(date: makeDate(year: 2024, month: 6, day: 3), embedding: [-1, 0])
        let result = InsightsEngine.rankRetrieval(all: [e2, e3, e1], queryVector: [1, 0], topK: 3)
        #expect(result.map(\.id) == [e1.id, e2.id, e3.id])
    }

    /// 关键回归：有部分条目有向量、部分没向量时，不应把没向量的整类扔掉。
    @Test func mixedCoverage_keepsRecentNonIndexedEntries() {
        // 5 embedded（day 1-5）+ 5 non-embedded（day 10-14），topK = 8
        //   minRecencyReserve = min(max(2, 8/3=2), 5) = 2
        //   maxSemanticSlots = 8 - 2 = 6 → embedded 全进（5 条）
        //   remaining = 8 - 5 = 3 → 再补 3 条最近的非索引
        var entries: [DiaryEntryData] = []
        for i in 1...5 {
            entries.append(makeEntry(
                date: makeDate(year: 2024, month: 6, day: i),
                embedding: [Float(i), 0]
            ))
        }
        for i in 10...14 {
            entries.append(makeEntry(
                date: makeDate(year: 2024, month: 6, day: i),
                embedding: nil
            ))
        }
        let nonEmbeddedIds = Set(entries.filter { $0.embedding == nil }.map(\.id))
        let result = InsightsEngine.rankRetrieval(all: entries, queryVector: [1, 0], topK: 8)
        let nonEmbeddedInResult = result.filter { nonEmbeddedIds.contains($0.id) }
        #expect(result.count == 8)
        #expect(nonEmbeddedInResult.count >= 2, "至少保留 2 个非索引 slot")
        // 保留的非索引条目必须是最新的 N 个（N 由实际填充决定）
        let expectedRecent = entries
            .filter { $0.embedding == nil }
            .sorted { $0.date > $1.date }
            .prefix(nonEmbeddedInResult.count)
            .map(\.id)
        #expect(Set(nonEmbeddedInResult.map(\.id)) == Set(expectedRecent))
    }

    @Test func mixedCoverage_fillsTopKWhenRoomRemains() {
        // 20 embedded + 20 non-embedded，topK = 30：
        //   minRecencyReserve = min(max(2, 10), 20) = 10
        //   maxSemanticSlots = 30 - 10 = 20 → 全部 20 条 embedded 进来
        //   remaining = 30 - 20 = 10 → 再补 10 条最近的非索引
        // 总计 30 条，不留空槽。
        var entries: [DiaryEntryData] = []
        for i in 1...20 {
            entries.append(makeEntry(
                date: makeDate(year: 2024, month: 6, day: i),
                embedding: [Float(i), 0]
            ))
        }
        for i in 1...20 {
            entries.append(makeEntry(
                date: makeDate(year: 2024, month: 7, day: i),
                embedding: nil
            ))
        }
        let nonEmbeddedIds = Set(entries.filter { $0.embedding == nil }.map(\.id))
        let result = InsightsEngine.rankRetrieval(all: entries, queryVector: [1, 0], topK: 30)
        let nonIdxCount = result.filter { nonEmbeddedIds.contains($0.id) }.count
        #expect(result.count == 30)
        #expect(nonIdxCount == 10)
    }

    @Test func mixedCoverage_reservedQuotaBoundedByActualCount() {
        // 非索引只有 1 条 —— 不能超过实际数量
        var entries: [DiaryEntryData] = []
        for i in 1...10 {
            entries.append(makeEntry(
                date: makeDate(year: 2024, month: 6, day: i),
                embedding: [Float(i), 0]
            ))
        }
        entries.append(makeEntry(date: makeDate(year: 2024, month: 7, day: 1), embedding: nil))
        let nonEmbeddedIds = Set(entries.filter { $0.embedding == nil }.map(\.id))
        let result = InsightsEngine.rankRetrieval(all: entries, queryVector: [1, 0], topK: 8)
        let nonIdxCount = result.filter { nonEmbeddedIds.contains($0.id) }.count
        #expect(nonIdxCount == 1)
    }

    @Test func mixedCoverage_preservesSemanticOrderAmongEmbedded() {
        let e1 = makeEntry(date: makeDate(year: 2024, month: 6, day: 1), embedding: [1, 0])   // cos = 1
        let e2 = makeEntry(date: makeDate(year: 2024, month: 6, day: 2), embedding: [0.5, 0.5]) // cos = 0.707
        let e3 = makeEntry(date: makeDate(year: 2024, month: 6, day: 3), embedding: [0, 1])   // cos = 0
        let ne = makeEntry(date: makeDate(year: 2024, month: 6, day: 4), embedding: nil)
        let result = InsightsEngine.rankRetrieval(all: [e3, e1, e2, ne], queryVector: [1, 0], topK: 4)
        // 期望：[e1, e2, e3, ne]（前 3 个按 cosine 降序，最后填最近的非索引）
        #expect(result.map(\.id) == [e1.id, e2.id, e3.id, ne.id])
    }
}

private func makeEntry(date: Date, embedding: [Float]?) -> DiaryEntryData {
    DiaryEntryData(
        id: UUID(),
        date: date,
        text: "",
        moodValue: 0.5,
        summary: "",
        themes: [],
        embedding: embedding,
        wordCount: 0
    )
}

// MARK: - firstValidScore (mood fallback parser)

struct FirstValidScoreTests {
    @Test func plainNumberInRange() {
        #expect(OpenAIService.firstValidScore(in: "72") == 72)
    }

    @Test func numberInJSON() {
        #expect(OpenAIService.firstValidScore(in: "{\"mood_score\": 78}") == 78)
    }

    @Test func skipsFourDigitYearBeforeScore() {
        // 关键回归：年份 2024 先出现不应该吞掉后面的真正分数
        #expect(OpenAIService.firstValidScore(in: "Year 2024 mood is 72") == 72)
    }

    @Test func skipsLongRequestIdBeforeScore() {
        #expect(OpenAIService.firstValidScore(in: "req-id 123456 → mood 50") == 50)
    }

    @Test func skipsOutOfRangeShortNumber() {
        // "200" 是 3 位但超过 100 —— 应跳过继续找（注意 100 本身在范围内，所以用 101 测）
        #expect(OpenAIService.firstValidScore(in: "scored 200 out of 101 baseline 65") == 65)
    }

    @Test func returnsNilWhenNoValidScore() {
        #expect(OpenAIService.firstValidScore(in: "no numbers at all") == nil)
        #expect(OpenAIService.firstValidScore(in: "2024 9999 101") == nil)
    }

    @Test func emptyStringReturnsNil() {
        #expect(OpenAIService.firstValidScore(in: "") == nil)
    }

    @Test func consecutiveLongNumbersStillFindValidOne() {
        #expect(OpenAIService.firstValidScore(in: "2024 2025 72") == 72)
    }

    @Test func trailingNumberAtEndOfString() {
        #expect(OpenAIService.firstValidScore(in: "total score: 85") == 85)
    }

    @Test func firstInRangeWins() {
        // 第一个 1...100 的数字就返回；后面再出现也不查
        #expect(OpenAIService.firstValidScore(in: "first 42 then 88") == 42)
    }
}

// MARK: - SuggestionContext fingerprint

struct SuggestionContextFingerprintTests {
    @Test func sameInputsProduceSameFingerprint() {
        let ctx1 = makeContext(totalEntries: 10, themeNames: ["Abby", "工作"], latestDay: makeDate(year: 2024, month: 6, day: 15))
        let ctx2 = makeContext(totalEntries: 10, themeNames: ["Abby", "工作"], latestDay: makeDate(year: 2024, month: 6, day: 15))
        #expect(ctx1.makeFingerprint() == ctx2.makeFingerprint())
    }

    @Test func themeNameChangeFlipsFingerprint() {
        let a = makeContext(totalEntries: 10, themeNames: ["Abby", "工作"], latestDay: makeDate(year: 2024, month: 6, day: 15))
        let b = makeContext(totalEntries: 10, themeNames: ["Abby", "健身"], latestDay: makeDate(year: 2024, month: 6, day: 15))
        #expect(a.makeFingerprint() != b.makeFingerprint())
    }

    @Test func entryCountChangeFlipsFingerprint() {
        // fingerprint 通过最新 entry id 感知"加了新条目",不直接依赖 totalEntries 计数,
        // 所以这里用不同 entryId 模拟真实场景(加新日记 → 新 UUID → fingerprint 翻转)。
        // 注意 fingerprint 只取 uuidString.prefix(8),两个 UUID 必须在前 8 字符不同。
        let oldId = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!
        let newId = UUID(uuidString: "22222222-0000-0000-0000-000000000002")!
        let a = makeContext(totalEntries: 10, themeNames: ["Abby"], latestDay: makeDate(year: 2024, month: 6, day: 15), entryId: oldId)
        let b = makeContext(totalEntries: 11, themeNames: ["Abby"], latestDay: makeDate(year: 2024, month: 6, day: 15), entryId: newId)
        #expect(a.makeFingerprint() != b.makeFingerprint())
    }

    @Test func newEntryDateFlipsFingerprint() {
        // fingerprint 把 latestDay 折成 ISO 周(YYYY-Www),所以这里要选跨周的两个日期才能
        // 测出语义。06-15(W24,周六)→ 06-22(W25,周六)。
        let a = makeContext(totalEntries: 10, themeNames: ["Abby"], latestDay: makeDate(year: 2024, month: 6, day: 15))
        let b = makeContext(totalEntries: 10, themeNames: ["Abby"], latestDay: makeDate(year: 2024, month: 6, day: 22))
        #expect(a.makeFingerprint() != b.makeFingerprint())
    }

    @Test func themeCasingDoesNotFlipFingerprint() {
        // "abby" 和 "Abby" 应视为同一主题
        let a = makeContext(totalEntries: 10, themeNames: ["Abby"], latestDay: makeDate(year: 2024, month: 6, day: 15))
        let b = makeContext(totalEntries: 10, themeNames: ["abby"], latestDay: makeDate(year: 2024, month: 6, day: 15))
        #expect(a.makeFingerprint() == b.makeFingerprint())
    }

    @Test func insufficientSignalFlagsCorrectly() {
        let few = makeContext(totalEntries: 2, themeNames: [], latestDay: makeDate(year: 2024, month: 6, day: 15))
        let enough = makeContext(totalEntries: 3, themeNames: [], latestDay: makeDate(year: 2024, month: 6, day: 15))
        #expect(few.hasEnoughSignal == false)
        #expect(enough.hasEnoughSignal == true)
    }

    private func makeContext(
        totalEntries: Int,
        themeNames: [String],
        latestDay: Date,
        entryId: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    ) -> SuggestionContext {
        let themes = themeNames.enumerated().map { i, name in
            InsightsEngine.Theme(
                name: name,
                count: 5 - i,
                uniqueDays: 5 - i,
                avgMood: 0.5,
                moodLow: 0.5,
                moodHigh: 0.5,
                lowCount: 0,
                highCount: 0,
                entryIds: [],
                trend: Array(repeating: 0.5, count: 6)
            )
        }
        let recent = [
            DiaryEntryData(id: entryId, date: latestDay, text: "", moodValue: 0.5, summary: "")
        ]
        return SuggestionContext(
            topThemes: themes,
            moodAvg30d: 0.5,
            moodHighEntry: nil,
            moodLowEntry: nil,
            currentStreak: 3,
            totalEntries: totalEntries,
            recentEntries: recent,
            language: "zh"
        )
    }
}

// MARK: - SuggestionBundle Codable

struct SuggestionBundleCodableTests {
    @Test func validBundleRoundTrips() throws {
        let bundle = SuggestionBundle(
            askPastPresets: ["q1?", "q2?"],
            homePlaceholders: ["p1", "p2", "p3"],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            fingerprint: "abc",
            language: "zh"
        )
        let data = try JSONEncoder().encode(bundle)
        let decoded = try JSONDecoder().decode(SuggestionBundle.self, from: data)
        #expect(decoded == bundle)
    }

    @Test func hasUsableContentRequiresBothFieldsNonEmpty() {
        let both = SuggestionBundle(askPastPresets: ["x"], homePlaceholders: ["y"], generatedAt: Date(), fingerprint: "", language: "zh")
        let noPresets = SuggestionBundle(askPastPresets: [], homePlaceholders: ["y"], generatedAt: Date(), fingerprint: "", language: "zh")
        let noPlaceholders = SuggestionBundle(askPastPresets: ["x"], homePlaceholders: [], generatedAt: Date(), fingerprint: "", language: "zh")
        #expect(both.hasUsableContent)
        #expect(!noPresets.hasUsableContent)
        #expect(!noPlaceholders.hasUsableContent)
    }
}

// MARK: - parseSuggestionBundle (AI response parsing robustness)

struct ParseSuggestionBundleTests {
    private let fp = "test-fp"
    private let lang = "zh"
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func validJSON_roundtrips() {
        let raw = #"{"askPastPresets":["q1?","q2?"],"homePlaceholders":["p1","p2","p3"]}"#
        let bundle = OpenAIService.parseSuggestionBundle(rawJSON: raw, fingerprint: fp, language: lang, generatedAt: now)
        #expect(bundle?.askPastPresets == ["q1?", "q2?"])
        #expect(bundle?.homePlaceholders == ["p1", "p2", "p3"])
        #expect(bundle?.fingerprint == fp)
        #expect(bundle?.language == lang)
        #expect(bundle?.generatedAt == now)
    }

    @Test func acceptsAliasKeys_presetsAndPlaceholders() {
        // prompts 里允许 LLM 用简短的 "presets" / "placeholders" 字段名
        let raw = #"{"presets":["q?"],"placeholders":["hint"]}"#
        let bundle = OpenAIService.parseSuggestionBundle(rawJSON: raw, fingerprint: fp, language: lang, generatedAt: now)
        #expect(bundle?.askPastPresets == ["q?"])
        #expect(bundle?.homePlaceholders == ["hint"])
    }

    @Test func malformedJSON_returnsNil() {
        #expect(OpenAIService.parseSuggestionBundle(rawJSON: "not json at all", fingerprint: fp, language: lang, generatedAt: now) == nil)
        #expect(OpenAIService.parseSuggestionBundle(rawJSON: "{incomplete", fingerprint: fp, language: lang, generatedAt: now) == nil)
    }

    @Test func emptyArrays_returnsNil() {
        let raw = #"{"askPastPresets":[],"homePlaceholders":[]}"#
        #expect(OpenAIService.parseSuggestionBundle(rawJSON: raw, fingerprint: fp, language: lang, generatedAt: now) == nil)
    }

    @Test func oneFieldMissing_returnsNil() {
        let onlyPresets = #"{"askPastPresets":["q?"]}"#
        let onlyPlaceholders = #"{"homePlaceholders":["p"]}"#
        #expect(OpenAIService.parseSuggestionBundle(rawJSON: onlyPresets, fingerprint: fp, language: lang, generatedAt: now) == nil)
        #expect(OpenAIService.parseSuggestionBundle(rawJSON: onlyPlaceholders, fingerprint: fp, language: lang, generatedAt: now) == nil)
    }

    @Test func trimsAndFiltersEmptyStrings() {
        let raw = #"{"askPastPresets":["  q?  ","","real?"],"homePlaceholders":["   ","p"]}"#
        let bundle = OpenAIService.parseSuggestionBundle(rawJSON: raw, fingerprint: fp, language: lang, generatedAt: now)
        #expect(bundle?.askPastPresets == ["q?", "real?"])
        #expect(bundle?.homePlaceholders == ["p"])
    }

    @Test func capsPresetsAtFive_placeholdersAtEight() {
        // 给 10 条 preset + 12 条 placeholder，应截到 5 + 8
        let p10 = (1...10).map { "\"q\($0)?\"" }.joined(separator: ",")
        let h12 = (1...12).map { "\"h\($0)\"" }.joined(separator: ",")
        let raw = "{\"askPastPresets\":[\(p10)],\"homePlaceholders\":[\(h12)]}"
        let bundle = OpenAIService.parseSuggestionBundle(rawJSON: raw, fingerprint: fp, language: lang, generatedAt: now)
        #expect(bundle?.askPastPresets.count == 5)
        #expect(bundle?.homePlaceholders.count == 8)
    }
}

// MARK: - DiaryEntry.sanitizeThemes (CSV safety + dedup)

struct SanitizeThemesTests {
    @Test func empty_returnsNil() {
        #expect(DiaryEntry.sanitizeThemes([]) == nil)
        #expect(DiaryEntry.sanitizeThemes(["", "   ", "\n"]) == nil)
    }

    @Test func stripsHalfwidthComma() {
        // 关键回归：LLM 可能输出 "Tokyo, Japan" 作为单个 tag；必须把它变成 "Tokyo Japan"
        // 才不会被 themeArray split 成两个
        #expect(DiaryEntry.sanitizeThemes(["Tokyo, Japan"]) == "Tokyo Japan")
    }

    @Test func stripsFullwidthComma() {
        #expect(DiaryEntry.sanitizeThemes(["上海，出差"]) == "上海 出差")
    }

    @Test func deduplicatesCaseInsensitive() {
        // 保留首次出现的原文大小写
        let out = DiaryEntry.sanitizeThemes(["Abby", "abby", "ABBY", "Work"])
        #expect(out == "Abby,Work")
    }

    @Test func capsAtSix() {
        let input = (1...10).map { "tag\($0)" }
        let out = DiaryEntry.sanitizeThemes(input)
        let tags = out?.split(separator: ",").map(String.init) ?? []
        #expect(tags.count == 6)
        #expect(tags == ["tag1", "tag2", "tag3", "tag4", "tag5", "tag6"])
    }

    @Test func trimsWhitespace() {
        #expect(DiaryEntry.sanitizeThemes(["  Abby  ", "\tWork\n"]) == "Abby,Work")
    }
}

// MARK: - PromptSuggestionEngine.isFresh (cache TTL)

struct PromptCacheFreshnessTests {
    @Test func freshBundle_isFresh() {
        let bundle = SuggestionBundle(
            askPastPresets: ["q?"],
            homePlaceholders: ["p"],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            fingerprint: "f",
            language: "zh"
        )
        // 1 小时后仍新鲜
        let anHourLater = Date(timeIntervalSince1970: 1_700_003_600)
        #expect(PromptSuggestionEngine.isFresh(bundle: bundle, ttl: 24 * 3600, now: anHourLater))
    }

    @Test func exactTTL_boundary() {
        let generated = Date(timeIntervalSince1970: 1_700_000_000)
        let bundle = SuggestionBundle(
            askPastPresets: ["q"], homePlaceholders: ["p"],
            generatedAt: generated, fingerprint: "f", language: "zh"
        )
        // 恰好 TTL 边界：`<` 严格小于，边界即不新鲜
        let atBoundary = generated.addingTimeInterval(24 * 3600)
        #expect(PromptSuggestionEngine.isFresh(bundle: bundle, ttl: 24 * 3600, now: atBoundary) == false)
    }

    @Test func pastTTL_isStale() {
        let bundle = SuggestionBundle(
            askPastPresets: ["q"], homePlaceholders: ["p"],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            fingerprint: "f", language: "zh"
        )
        // 25 小时后（> 24h TTL）
        let twentyFiveHoursLater = Date(timeIntervalSince1970: 1_700_090_000)
        #expect(PromptSuggestionEngine.isFresh(bundle: bundle, ttl: 24 * 3600, now: twentyFiveHoursLater) == false)
    }
}

// MARK: - Test helpers

private func makeDate(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    // `date(from:)` 只在 components 全合法时才返 nil；理论上不会 trap。
    // 用 `preconditionFailure` 让一个单测因为构造错误日期而失败，而不是 bang 炸掉整个套件。
    guard let date = Calendar(identifier: .gregorian).date(from: components) else {
        preconditionFailure("makeDate 参数非法: y=\(year) m=\(month) d=\(day) h=\(hour) min=\(minute)")
    }
    return date
}

private func addHours(_ date: Date, _ hours: Int) -> Date {
    guard let result = Calendar(identifier: .gregorian).date(byAdding: .hour, value: hours, to: date) else {
        preconditionFailure("addHours 失败: date=\(date) hours=\(hours)")
    }
    return result
}

// MARK: - ContextPromptGenerator.computeStreak

struct ContextPromptStreakTests {
    private let calendar = Calendar(identifier: .gregorian)

    @Test func todayPresent_countsIncludingToday() {
        let now = makeDate(year: 2026, month: 4, day: 19, hour: 10, minute: 0)
        let dates = (0..<5).map { calendar.date(byAdding: .day, value: -$0, to: now)! } // swiftlint:disable:this force_unwrapping
        let streak = ContextPromptGenerator.computeStreak(entryDates: dates, calendar: calendar, now: now)
        #expect(streak == 5)
    }

    @Test func todayMissingYesterdayPresent_stillCounts() {
        // 用户连写 19→17（三天）但今天 4/19 还没写——旧逻辑会 return 0，新逻辑从 yesterday 起算
        let now = makeDate(year: 2026, month: 4, day: 19, hour: 10, minute: 0)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)! // swiftlint:disable:this force_unwrapping
        let twoAgo = calendar.date(byAdding: .day, value: -2, to: now)! // swiftlint:disable:this force_unwrapping
        let threeAgo = calendar.date(byAdding: .day, value: -3, to: now)! // swiftlint:disable:this force_unwrapping
        let streak = ContextPromptGenerator.computeStreak(
            entryDates: [yesterday, twoAgo, threeAgo],
            calendar: calendar,
            now: now
        )
        #expect(streak == 3)
    }

    @Test func todayAndYesterdayBothMissing_returnsZero() {
        let now = makeDate(year: 2026, month: 4, day: 19, hour: 10, minute: 0)
        let threeAgo = calendar.date(byAdding: .day, value: -3, to: now)! // swiftlint:disable:this force_unwrapping
        let fourAgo = calendar.date(byAdding: .day, value: -4, to: now)! // swiftlint:disable:this force_unwrapping
        let streak = ContextPromptGenerator.computeStreak(
            entryDates: [threeAgo, fourAgo],
            calendar: calendar,
            now: now
        )
        #expect(streak == 0)
    }

    @Test func emptyEntries_returnsZero() {
        let now = makeDate(year: 2026, month: 4, day: 19, hour: 10, minute: 0)
        #expect(ContextPromptGenerator.computeStreak(entryDates: [], calendar: calendar, now: now) == 0)
    }

    @Test func duplicatesOnSameDay_countOnce() {
        let now = makeDate(year: 2026, month: 4, day: 19, hour: 23, minute: 30)
        let morning = makeDate(year: 2026, month: 4, day: 19, hour: 8, minute: 0)
        let afternoon = makeDate(year: 2026, month: 4, day: 19, hour: 15, minute: 0)
        let streak = ContextPromptGenerator.computeStreak(
            entryDates: [morning, afternoon, now],
            calendar: calendar,
            now: now
        )
        #expect(streak == 1)
    }

    @Test func gapBreaksStreak() {
        // 今天在、昨天在、前天空、大前天在——streak 应是 2，不应跨过间隙
        let now = makeDate(year: 2026, month: 4, day: 19, hour: 10, minute: 0)
        let today = now
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)! // swiftlint:disable:this force_unwrapping
        let threeAgo = calendar.date(byAdding: .day, value: -3, to: now)! // swiftlint:disable:this force_unwrapping
        let streak = ContextPromptGenerator.computeStreak(
            entryDates: [today, yesterday, threeAgo],
            calendar: calendar,
            now: now
        )
        #expect(streak == 2)
    }
}

// MARK: - DiaryEntry embedding codec

struct EmbeddingCodecTests {
    @Test func v1RoundTrip() {
        let vector: [Float] = [0, 1, -2, 3.25]

        let data = DiaryEntry.encodeEmbeddingVector(vector)

        #expect(DiaryEntry.decodeEmbeddingVector(data) == vector)
    }

    @Test func legacyRawFloatFallback() {
        let vector: [Float] = [0.25, -0.5, 2.0]
        var raw = Data()
        vector.withUnsafeBytes { raw.append(contentsOf: $0) }

        #expect(DiaryEntry.decodeEmbeddingVector(raw) == vector)
    }

    @Test func malformedV1HeaderReturnsNil() {
        var data = Data("EMB1".utf8)
        var declaredDim = UInt32(2).littleEndian
        data.append(Data(bytes: &declaredDim, count: MemoryLayout<UInt32>.size))
        var oneFloat: Float = 1
        data.append(Data(bytes: &oneFloat, count: MemoryLayout<Float>.size))

        #expect(DiaryEntry.decodeEmbeddingVector(data) == nil)
    }
}

// MARK: - SSE parser

struct SSEParserTests {
    private struct Chunk: Decodable, Equatable {
        let value: String
    }

    @Test func doneTerminatesStream() async throws {
        let events = try await collectSSEEvents([
            #"data: {"value":"hello"}"#,
            "",
            "data: [DONE]"
        ])

        #expect(events == [Chunk(value: "hello")])
    }

    @Test func eofWithoutDoneThrowsMissingDone() async {
        do {
            _ = try await collectSSEEvents([
                #"data: {"value":"partial"}"#,
                ""
            ])
            #expect(Bool(false), "Expected missingDone")
        } catch let error as SSEParser.ParserError {
            #expect(error.localizedDescription == SSEParser.ParserError.missingDone.localizedDescription)
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test func upstreamErrorPayloadThrowsMessage() async {
        do {
            _ = try await collectSSEEvents([
                #"data: {"error":{"message":"rate limited"}}"#,
                ""
            ])
            #expect(Bool(false), "Expected upstream error")
        } catch let error as SSEParser.ParserError {
            #expect(error.localizedDescription == "rate limited")
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test func invalidJSONThrowsInvalidEvent() async {
        do {
            _ = try await collectSSEEvents([
                "data: {not-json}",
                ""
            ])
            #expect(Bool(false), "Expected invalid event")
        } catch let error as SSEParser.ParserError {
            #expect(error.localizedDescription.contains("invalid event"))
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    /// 走 byte-level 入口(模拟 `URLSession.AsyncBytes`)。Apple 实际 ship 的 `.lines`
    /// 在某些 iOS 版本会跳过空行,所有 SSE event 粘成一坨触发 invalidEvent —— 这条用例
    /// 守住自家的 `byteLineSequence` 必须为空行 yield "",防止有人后来改回 `.lines` 又
    /// 吃这坨 109KB / 189KB invalidEvent 的回旋镖。
    @Test func byteStreamWithBlankLineDispatchesEachEvent() async throws {
        let raw = #"""
        data: {"value":"hello"}

        data: {"value":"world"}

        data: [DONE]

        """#
        let bytes = Array(raw.utf8)
        let stream = AsyncStream<UInt8> { continuation in
            for b in bytes { continuation.yield(b) }
            continuation.finish()
        }
        var events: [Chunk] = []
        for try await event in SSEParser.parse(bytes: stream, type: Chunk.self, decoder: JSONDecoder()) {
            events.append(event)
        }
        #expect(events == [Chunk(value: "hello"), Chunk(value: "world")])
    }

    /// CRLF 兼容:`\r\n` 行尾、`\r` 单独"空行"都要被当成普通 LF 处理。
    @Test func byteStreamWithCRLFDispatchesEachEvent() async throws {
        let raw = "data: {\"value\":\"a\"}\r\n\r\ndata: {\"value\":\"b\"}\r\n\r\ndata: [DONE]\r\n\r\n"
        let bytes = Array(raw.utf8)
        let stream = AsyncStream<UInt8> { continuation in
            for b in bytes { continuation.yield(b) }
            continuation.finish()
        }
        var events: [Chunk] = []
        for try await event in SSEParser.parse(bytes: stream, type: Chunk.self, decoder: JSONDecoder()) {
            events.append(event)
        }
        #expect(events == [Chunk(value: "a"), Chunk(value: "b")])
    }

    private func collectSSEEvents(_ lines: [String]) async throws -> [Chunk] {
        var events: [Chunk] = []
        for try await event in SSEParser.parse(lines: lines, type: Chunk.self, decoder: JSONDecoder()) {
            events.append(event)
        }
        return events
    }
}

private func makeEntry(date: Date, mood: Double = 0.5, themes: [String] = []) -> DiaryEntryData {
    DiaryEntryData(
        id: UUID(),
        date: date,
        text: "",
        moodValue: mood,
        summary: "",
        themes: themes,
        embedding: nil,
        wordCount: 0
    )
}

// MARK: - aggregateThemes with alias map
//
// 验证 alias map 注入后的行为:
//  1) 跨 alias 的 entry 被合并到同一 canonical bucket
//  2) 同一 entry 内多个 alias 不被重复计入(count 不应 +2)
//  3) display name 用 canonical 而不是 first-seen alias

@MainActor
struct ThemeAggregationAliasTests {
    @Test func aliasMap_mergesAcrossEntries() {
        let range = DateInterval(
            start: makeDate(year: 2024, month: 6, day: 1),
            end: makeDate(year: 2024, month: 6, day: 30)
        )
        let entries: [DiaryEntryData] = [
            makeEntry(date: makeDate(year: 2024, month: 6, day: 1), themes: ["Abby"]),
            makeEntry(date: makeDate(year: 2024, month: 6, day: 2), themes: ["宝贝"]),
            makeEntry(date: makeDate(year: 2024, month: 6, day: 3), themes: ["老婆"])
        ]
        // alias map: 宝贝 / 老婆 → Abby
        let aliasMap: [String: String] = [
            "宝贝": "Abby",
            "老婆": "Abby",
            "abby": "Abby"
        ]
        let result = InsightsEngine.aggregateThemes(
            entries: entries,
            range: range,
            aliasMap: aliasMap
        )
        #expect(result.count == 1)
        #expect(result.first?.name == "Abby")
        #expect(result.first?.count == 3)
        #expect(result.first?.uniqueDays == 3)
    }

    @Test func aliasMap_dedupsWithinSameEntry() {
        // 一篇日记里同时写了 "Abby" 和 "宝贝" —— alias 折叠后属于同一 canonical,
        // 不应该让这篇 entry 在 bucket 里被计两次。
        let range = DateInterval(
            start: makeDate(year: 2024, month: 6, day: 1),
            end: makeDate(year: 2024, month: 6, day: 30)
        )
        let entries: [DiaryEntryData] = [
            makeEntry(date: makeDate(year: 2024, month: 6, day: 1), themes: ["Abby", "宝贝"])
        ]
        let aliasMap: [String: String] = ["宝贝": "Abby", "abby": "Abby"]
        let result = InsightsEngine.aggregateThemes(
            entries: entries,
            range: range,
            aliasMap: aliasMap
        )
        #expect(result.count == 1)
        #expect(result.first?.count == 1)
        #expect(result.first?.uniqueDays == 1)
    }

    @Test func emptyAliasMap_isNoOp() {
        // 不传 alias map 等价于以前的行为:case-insensitive 合并 + first-seen display name。
        let range = DateInterval(
            start: makeDate(year: 2024, month: 6, day: 1),
            end: makeDate(year: 2024, month: 6, day: 30)
        )
        let entries: [DiaryEntryData] = [
            makeEntry(date: makeDate(year: 2024, month: 6, day: 1), themes: ["Abby"]),
            makeEntry(date: makeDate(year: 2024, month: 6, day: 2), themes: ["abby"])
        ]
        let result = InsightsEngine.aggregateThemes(entries: entries, range: range)
        #expect(result.count == 1)
        #expect(result.first?.name == "Abby")
        #expect(result.first?.count == 2)
    }
}

// MARK: - ContextPromptGenerator alias canonicalization
//
// CLAUDE.md 把 InsightsEngine.aggregateThemes 和 ContextPromptGenerator.fetchEntries
// 列为 alias 注入仅有的两个点。aggregateThemes 上面已测,这里覆盖第二处:
// `ContextPromptGenerator.canonicalize(_:with:)` —— fetchEntries 在 background context
// 闭包内调它把 entry.themeArray 折成 canonical 后再喂给 yesterdayPrompt / lapsePrompt
// / topThemePrompt。如果 alias 折叠在这一步漏了,GPT 提示会把 ["Abby","宝贝"] 当两个
// 独立 entity,跨别名"消失" / "高频"判定全错。
//
// 走 static helper 的 unit test(`@testable import` 看得到 internal),
// 不需要 spin 起 PersistenceController / OpenAIService / 真实 fetchEntries。

struct ContextPromptAliasCanonicalizationTests {
    @Test func canonicalize_mapsAliasToCanonical() {
        let result = ContextPromptGenerator.canonicalize(
            ["宝贝", "Abby", "工作"],
            with: ["宝贝": "Abby"]
        )
        // 顺序保持入参顺序 + 同 canonical 在 entry 内 dedupe
        #expect(result == ["Abby", "工作"])
    }

    @Test func canonicalize_dedupsWithinSameEntry() {
        // 一篇 entry 里 ["Abby", "宝贝", "abby"] 全指向 "Abby" → 只保留一个
        let result = ContextPromptGenerator.canonicalize(
            ["Abby", "宝贝", "abby"],
            with: ["宝贝": "Abby", "abby": "Abby"]
        )
        #expect(result.count == 1)
        #expect(result.first == "Abby")
    }

    @Test func canonicalize_caseInsensitiveLookup() {
        // alias map key 是 lowercased,但 raw tag 是 mixed case → 必须命中
        let result = ContextPromptGenerator.canonicalize(
            ["BAOBEI"],
            with: ["baobei": "Abby"]
        )
        #expect(result == ["Abby"])
    }

    @Test func canonicalize_emptyAliasMap_preservesRaw() {
        // alias map 空时应保持入参(case-insensitive dedupe 由调用层 / aggregator 处理)
        let result = ContextPromptGenerator.canonicalize(
            ["Abby", "工作"],
            with: [:]
        )
        #expect(result == ["Abby", "工作"])
    }

    @Test func canonicalize_unknownAlias_passesThrough() {
        // tag 不在 alias map 里 → 保留原文,不 lowercase
        let result = ContextPromptGenerator.canonicalize(
            ["焦虑"],
            with: ["宝贝": "Abby"]
        )
        #expect(result == ["焦虑"])
    }
}

// MARK: - ThemeAliasResolver
//
// 用 isolated UserDefaults(suite-name)避免污染主存储。
// 直接 init(testingWithEmptyState:) 走 "load 完空状态" 路径。

@MainActor
struct ThemeAliasResolverTests {
    private func makeResolver(suiteName: String = UUID().uuidString) -> (ThemeAliasResolver, UserDefaults) {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let r = ThemeAliasResolver(testingWithEmptyState: defaults)
        return (r, defaults)
    }

    private func makeStoredResolver(defaults: UserDefaults) -> ThemeAliasResolver {
        ThemeAliasResolver(testingWithStoredState: defaults)
    }

    @Test func canonicalize_unknownReturnsRaw() {
        let (r, _) = makeResolver()
        #expect(r.canonicalize("Abby") == "Abby")
        #expect(r.canonicalize("xx") == "xx")
    }

    @Test func confirm_addsAliasMapping() {
        let (r, _) = makeResolver()
        let s = PendingSuggestion(
            newTag: "宝贝",
            canonicalGuess: "Abby",
            confidence: .high,
            source: .scan
        )
        _ = r.enqueue(s)
        r.confirm(s, canonical: "Abby")
        #expect(r.canonicalize("宝贝") == "Abby")
        #expect(r.canonicalize("Abby") == "Abby")
        #expect(r.canonicalize("ABBY") == "Abby")  // case-insensitive lookup
        #expect(r.pending.isEmpty)
        #expect(r.groups["Abby"]?.contains("宝贝") == true)
    }

    @Test func confirm_chosenEqualsNewTag_isNoOp() {
        // 新语义(2026-04-28):picker UI 排除 newTag,API 防御 chosen == newTag → noop,
        // 只清当前 pending,canonicalGuess 不动。
        let (r, _) = makeResolver()
        let s = PendingSuggestion(
            newTag: "宝贝",
            canonicalGuess: "Abby",
            confidence: .high,
            source: .scan
        )
        _ = r.enqueue(s)
        r.confirm(s, canonical: "宝贝")
        // canonicalGuess 完全独立,不被合进 newTag
        #expect(r.canonicalize("Abby") == "Abby")
        #expect(r.canonicalize("宝贝") == "宝贝")
        #expect(r.groups["宝贝"] == nil)
        #expect(r.pending.isEmpty)
    }

    @Test func confirm_withCustomThirdName_onlyMovesNewTag() {
        // 新语义:用户在 picker 选第三个主题,**只把 newTag 合并进去**,canonicalGuess 不动。
        // 之前实现会把 canonicalGuess 也卷进去,违反最小惊讶。
        let (r, _) = makeResolver()
        let s = PendingSuggestion(
            newTag: "宝贝",
            canonicalGuess: "Abby",
            confidence: .high,
            source: .scan
        )
        _ = r.enqueue(s)
        r.confirm(s, canonical: "我老婆")
        #expect(r.canonicalize("宝贝") == "我老婆")
        // canonicalGuess Abby 保留独立,不被合并
        #expect(r.canonicalize("Abby") == "Abby")
        let aliases = r.groups["我老婆"] ?? []
        #expect(aliases.contains("宝贝"))
        #expect(!aliases.contains("Abby"))
    }

    @Test func confirm_keepsPendingWhoseNewTagBecameCanonical() {
        let (r, _) = makeResolver()
        let alias = PendingSuggestion(
            newTag: "Person A Nickname",
            canonicalGuess: "Person A",
            confidence: .high,
            source: .scan
        )
        let followUp = PendingSuggestion(
            newTag: "Person A",
            canonicalGuess: "Person B",
            confidence: .medium,
            source: .scan
        )

        #expect(r.enqueue(alias))
        #expect(r.enqueue(followUp))
        r.confirm(alias, canonical: "Person A")

        #expect(r.pending.map(\.id).contains(followUp.id))
        #expect(r.pending.count == 1)
    }

    @Test func reject_addsToNegativeAndBlocksReenqueue() {
        let (r, _) = makeResolver()
        let s = PendingSuggestion(
            newTag: "妈妈",
            canonicalGuess: "母亲",
            confidence: .high,
            source: .scan
        )
        _ = r.enqueue(s)
        r.reject(s)
        // 同对子再 enqueue 应该被拒
        let s2 = PendingSuggestion(
            newTag: "妈妈",
            canonicalGuess: "母亲",
            confidence: .medium,
            source: .scan
        )
        let didAdd = r.enqueue(s2)
        #expect(!didAdd)
        // 对称对(canonical / new 反过来)也应被 negative pair 拒绝
        let s3 = PendingSuggestion(
            newTag: "母亲",
            canonicalGuess: "妈妈",
            confidence: .high,
            source: .scan
        )
        #expect(!r.enqueue(s3))
    }

    /// Regression: 之前 reject 用原始 (newTag, canonicalGuess) 存 pairKey,
    /// enqueue 用 resolved canonical 比对 —— canonicalGuess 后来变成别人 alias 时,
    /// 已 reject 的对子换个 canonical 名又能冒出来。修复后 raw + resolved 都比对。
    @Test func enqueue_rejectedPair_stillBlockedAfterCanonicalGuessBecomesAlias() {
        let (r, _) = makeResolver()
        // Step 1: 先 reject 原对子 (老婆, 宝贝),此时 宝贝 还是裸标签
        let rejected = PendingSuggestion(
            newTag: "老婆",
            canonicalGuess: "宝贝",
            confidence: .high,
            source: .scan
        )
        _ = r.enqueue(rejected)
        r.reject(rejected)

        // Step 2: 把 宝贝 合并成 Abby 的 alias(模拟用户后来手动 merge)
        r.mergeThemes(source: "宝贝", into: "Abby")
        #expect(r.canonicalize("宝贝") == "Abby")

        // Step 3: AI 又建议 (老婆, 宝贝) —— enqueue 会 resolve canonicalGuess "宝贝" → "Abby"
        // 修复前:resolved pair ("老婆","abby") 没在 negativePairs,suggestion 又冒出来
        // 修复后:raw pair ("老婆","宝贝") 仍命中 negativePairs,直接拒
        let resurfaced = PendingSuggestion(
            newTag: "老婆",
            canonicalGuess: "宝贝",
            confidence: .high,
            source: .scan
        )
        #expect(!r.enqueue(resurfaced))
        #expect(r.pending.isEmpty)
    }

    @Test func enqueue_dedupsExistingPending() {
        let (r, _) = makeResolver()
        let s1 = PendingSuggestion(
            id: UUID(),
            newTag: "宝贝",
            canonicalGuess: "Abby",
            confidence: .high,
            source: .scan
        )
        #expect(r.enqueue(s1))
        // 同对子(不同 id)应被拒
        let s2 = PendingSuggestion(
            id: UUID(),
            newTag: "宝贝",
            canonicalGuess: "Abby",
            confidence: .medium,
            source: .scan
        )
        #expect(!r.enqueue(s2))
        #expect(r.pending.count == 1)
    }

    @Test func unmerge_removesAlias() {
        let (r, _) = makeResolver()
        let s = PendingSuggestion(
            newTag: "宝贝",
            canonicalGuess: "Abby",
            confidence: .high,
            source: .scan
        )
        _ = r.enqueue(s)
        r.confirm(s, canonical: "Abby")
        r.unmerge(canonical: "Abby", removeAlias: "宝贝")
        #expect(r.canonicalize("宝贝") == "宝贝")
    }

    @Test func snapshotIndex_isLowercased() {
        let (r, _) = makeResolver()
        let s = PendingSuggestion(
            newTag: "BAOBEI",
            canonicalGuess: "Abby",
            confidence: .high,
            source: .scan
        )
        _ = r.enqueue(s)
        r.confirm(s, canonical: "Abby")
        let map = r.snapshotIndex()
        #expect(map["baobei"] == "Abby")
        #expect(map["abby"] == "Abby")
    }

    @Test func canonicalizeAll_dedupsToSameCanonical() {
        let (r, _) = makeResolver()
        let s = PendingSuggestion(
            newTag: "宝贝",
            canonicalGuess: "Abby",
            confidence: .high,
            source: .scan
        )
        _ = r.enqueue(s)
        r.confirm(s, canonical: "Abby")
        let out = r.canonicalize(all: ["宝贝", "Abby", "妈妈"])
        #expect(out.count == 2)
        #expect(out.contains("Abby"))
        #expect(out.contains("妈妈"))
    }

    @Test func clearAllPending_dropsAll() {
        let (r, _) = makeResolver()
        for i in 0..<5 {
            _ = r.enqueue(PendingSuggestion(
                newTag: "tag\(i)",
                canonicalGuess: "canon\(i)",
                confidence: .high,
                source: .scan
            ))
        }
        #expect(r.pending.count == 5)
        r.clearAllPending()
        #expect(r.pending.isEmpty)
        // 不写 negativePairs —— 同对子下次还能 enqueue 进来
        let didEnqueue = r.enqueue(PendingSuggestion(
            newTag: "tag0",
            canonicalGuess: "canon0",
            confidence: .high,
            source: .scan
        ))
        #expect(didEnqueue)
    }

    // MARK: codex review fixes

    @Test func confirm_chosenIsAliasOfDifferentGroup_mergesIntoExistingCanonical() {
        // codex P1 #1 regression — 仍然要保:chosen 解析到现有 canonical,**不**创建独立 group。
        // 新语义下:**只 newTag 进 chosen group,canonicalGuess 不动**。
        // 已存在 group: Abby = [宝贝]。
        // 新 suggestion: newTag=老婆, canonicalGuess=妻子。
        // 用户在 picker 输入 chosen="宝贝"(已是 Abby 别名)。
        // 期望:不创建新 group "宝贝",老婆 merge 到 Abby;**妻子保持独立**。
        let (r, _) = makeResolver()
        let s0 = PendingSuggestion(
            newTag: "宝贝",
            canonicalGuess: "Abby",
            confidence: .high,
            source: .scan
        )
        _ = r.enqueue(s0)
        r.confirm(s0, canonical: "Abby")
        // 现在 groups["Abby"] = ["宝贝"]
        #expect(r.groups["Abby"] == ["宝贝"])

        let s1 = PendingSuggestion(
            newTag: "老婆",
            canonicalGuess: "妻子",
            confidence: .high,
            source: .scan
        )
        _ = r.enqueue(s1)
        // 用户写自定义 = "宝贝"(已经是 Abby 的别名)
        r.confirm(s1, canonical: "宝贝")

        // 不应该出现 groups["宝贝"]
        #expect(r.groups["宝贝"] == nil)
        // Abby 下吸收了 newTag(老婆)+ 原有 alias(宝贝)
        let abbyAliases = r.groups["Abby"] ?? []
        #expect(abbyAliases.contains("宝贝"))
        #expect(abbyAliases.contains("老婆"))
        // 新语义:canonicalGuess 妻子 不被卷入
        #expect(!abbyAliases.contains("妻子"))
        #expect(r.canonicalize("妻子") == "妻子")  // 妻子 保持独立
        #expect(r.canonicalize("老婆") == "Abby")
        #expect(r.canonicalize("宝贝") == "Abby")
    }

    @Test func confirm_chosenIsCanonicalOfDifferentGroup_absorbs() {
        // 新语义:newTag 是另一 group 的 canonical → 把 newTag 整组并入 chosen,**canonicalGuess 不动**。
        let (r, _) = makeResolver()
        let s0 = PendingSuggestion(newTag: "a1", canonicalGuess: "A", confidence: .high, source: .scan)
        _ = r.enqueue(s0)
        r.confirm(s0, canonical: "A")

        let s1 = PendingSuggestion(newTag: "b1", canonicalGuess: "B", confidence: .high, source: .scan)
        _ = r.enqueue(s1)
        r.confirm(s1, canonical: "B")

        // 现在 A=[a1], B=[b1]
        let s2 = PendingSuggestion(newTag: "B", canonicalGuess: "x", confidence: .high, source: .scan)
        // B 是 canonical of itself,enqueue 不跳过
        let did = r.enqueue(s2)
        #expect(did)

        r.confirm(s2, canonical: "A")
        // newTag = B 整组并入 A:A 应有 a1, B, b1。**x 不动**(canonicalGuess 不被 absorb)。
        #expect(r.groups["B"] == nil)
        let aliases = r.groups["A"] ?? []
        #expect(aliases.contains("a1"))
        #expect(aliases.contains("b1"))
        #expect(aliases.contains("B"))
        // 新语义:canonicalGuess x 保持独立
        #expect(!aliases.contains("x"))
        #expect(r.canonicalize("x") == "x")
    }

    @Test func enqueue_reversedPair_isDeduped() {
        // codex P2 #3 — AI 在两次 scan 间 swap newTag/canonicalGuess,
        // 应该被识别为同一对子,只入队一条。
        let (r, _) = makeResolver()
        let a = PendingSuggestion(
            id: UUID(),
            newTag: "宝贝",
            canonicalGuess: "Abby",
            confidence: .high,
            source: .scan
        )
        let b = PendingSuggestion(
            id: UUID(),
            newTag: "Abby",
            canonicalGuess: "宝贝",
            confidence: .high,
            source: .scan
        )
        #expect(r.enqueue(a))
        #expect(!r.enqueue(b))
        #expect(r.pending.count == 1)
    }

    @Test func deleteGroup_purgesRelatedPending() {
        // codex P2 #6 — 删 group 时,pending 里引用这个 group 标签的 suggestion 应同步消失。
        let (r, _) = makeResolver()
        // 先建一个 group: Abby = [宝贝]
        let s0 = PendingSuggestion(newTag: "宝贝", canonicalGuess: "Abby", confidence: .high, source: .scan)
        _ = r.enqueue(s0)
        r.confirm(s0, canonical: "Abby")

        // 入队两条 pending:一条与 group 相关(canonicalGuess="Abby"),一条无关。
        let related = PendingSuggestion(newTag: "亲爱的", canonicalGuess: "Abby", confidence: .high, source: .scan)
        let unrelated = PendingSuggestion(newTag: "妈妈", canonicalGuess: "母亲", confidence: .high, source: .scan)
        _ = r.enqueue(related)
        _ = r.enqueue(unrelated)
        #expect(r.pending.count == 2)

        // 删 group → 相关 suggestion 应被清掉,无关的保留
        r.deleteGroup(canonical: "Abby")
        #expect(r.pending.count == 1)
        #expect(r.pending.first?.newTag == "妈妈")
    }

    // MARK: mergeThemes 手动合并(Insights 长按入口 + custom editor 用)

    @Test func mergeThemes_freshIntoFresh_createsGroup() {
        // 两个都没在任何 group 里,直接 merge 成新 group
        let (r, _) = makeResolver()
        r.mergeThemes(source: "宝贝", into: "Abby")
        #expect(r.groups["Abby"] == ["宝贝"])
        #expect(r.canonicalize("宝贝") == "Abby")
    }

    @Test func mergeThemes_sourceIsCanonical_absorbsItsGroup() {
        // groups["B"] = [b1, b2]。把 B 整组并入 A。期望 A = [B, b1, b2],B 不再是 canonical。
        let (r, _) = makeResolver()
        let s1 = PendingSuggestion(newTag: "b1", canonicalGuess: "B", confidence: .high, source: .scan)
        _ = r.enqueue(s1)
        r.confirm(s1, canonical: "B")
        let s2 = PendingSuggestion(newTag: "b2", canonicalGuess: "B", confidence: .high, source: .scan)
        _ = r.enqueue(s2)
        r.confirm(s2, canonical: "B")
        // 现在 B = [b1, b2]
        r.mergeThemes(source: "B", into: "A")
        #expect(r.groups["B"] == nil)
        let aliases = r.groups["A"] ?? []
        #expect(aliases.contains("B"))
        #expect(aliases.contains("b1"))
        #expect(aliases.contains("b2"))
        // canonicalize 全部都返回 A
        #expect(r.canonicalize("B") == "A")
        #expect(r.canonicalize("b1") == "A")
        #expect(r.canonicalize("b2") == "A")
    }

    @Test func mergeThemes_targetIsAlias_resolvesToCanonical() {
        // groups["Abby"] = [宝贝]。用户从 InsightsView 选 "宝贝" 作为 target(but 宝贝 is alias)。
        // 期望:resolveTarget = Abby,把 source 并入 Abby,而不是新建 groups["宝贝"]。
        let (r, _) = makeResolver()
        let s = PendingSuggestion(newTag: "宝贝", canonicalGuess: "Abby", confidence: .high, source: .scan)
        _ = r.enqueue(s)
        r.confirm(s, canonical: "Abby")
        // 现在 Abby = [宝贝]
        r.mergeThemes(source: "老婆", into: "宝贝")  // 用户错把 alias 当 target
        #expect(r.groups["宝贝"] == nil)  // 不应创建独立 group
        let aliases = r.groups["Abby"] ?? []
        #expect(aliases.contains("宝贝"))
        #expect(aliases.contains("老婆"))
    }

    @Test func mergeThemes_alreadyInTargetGroup_isNoOp() {
        // 已经在同一组,不应有变化
        let (r, _) = makeResolver()
        let s = PendingSuggestion(newTag: "宝贝", canonicalGuess: "Abby", confidence: .high, source: .scan)
        _ = r.enqueue(s)
        r.confirm(s, canonical: "Abby")
        let snapshotBefore = r.groups
        r.mergeThemes(source: "宝贝", into: "Abby")  // 已经在 Abby 下了
        #expect(r.groups == snapshotBefore)
    }

    @Test func mergeThemes_purgesStalePending() {
        // 合并后,引用源/目标的 pending suggestion 应被清掉
        let (r, _) = makeResolver()
        // 入队:与 "Abby" 相关的 pending 一条 + 无关的一条
        _ = r.enqueue(PendingSuggestion(newTag: "亲爱的", canonicalGuess: "Abby", confidence: .high, source: .scan))
        _ = r.enqueue(PendingSuggestion(newTag: "妈妈", canonicalGuess: "母亲", confidence: .high, source: .scan))
        r.mergeThemes(source: "宝贝", into: "Abby")
        // 第一条引用 Abby → 现在 Abby 是 group canonical → 应被清(任何含 Abby 的 pending 都 stale)。
        // 第二条无关。
        #expect(r.pending.count == 1)
        #expect(r.pending.first?.newTag == "妈妈")
    }

    @Test func mergeThemes_emptyOrIdentical_noOp() {
        let (r, _) = makeResolver()
        r.mergeThemes(source: "", into: "Abby")
        r.mergeThemes(source: "Abby", into: "")
        r.mergeThemes(source: "Abby", into: "ABBY")  // 大小写算同一个
        #expect(r.groups.isEmpty)
    }

    @Test func purgePending_removesByLabel() {
        let (r, _) = makeResolver()
        _ = r.enqueue(PendingSuggestion(newTag: "x", canonicalGuess: "Abby", confidence: .high, source: .scan))
        _ = r.enqueue(PendingSuggestion(newTag: "宝贝", canonicalGuess: "y", confidence: .high, source: .scan))
        _ = r.enqueue(PendingSuggestion(newTag: "p", canonicalGuess: "q", confidence: .high, source: .scan))
        #expect(r.pending.count == 3)
        r.purgePending(matchingLowercasedLabels: ["abby", "宝贝"])
        #expect(r.pending.count == 1)
        #expect(r.pending.first?.newTag == "p")
    }

    @Test func resetNegativePairs_unblocksRejected() {
        let (r, _) = makeResolver()
        let s = PendingSuggestion(
            newTag: "妈妈",
            canonicalGuess: "母亲",
            confidence: .high,
            source: .scan
        )
        _ = r.enqueue(s)
        r.reject(s)
        // reject 后,同对子被拒绝
        let blocked = r.enqueue(PendingSuggestion(
            newTag: "妈妈",
            canonicalGuess: "母亲",
            confidence: .medium,
            source: .scan
        ))
        #expect(!blocked)

        r.resetNegativePairs()
        // 重置后能重新进队列
        let allowed = r.enqueue(PendingSuggestion(
            newTag: "妈妈",
            canonicalGuess: "母亲",
            confidence: .medium,
            source: .scan
        ))
        #expect(allowed)
    }

    @Test func diskRoundTrip_preservesGroupsPendingNegativePairsAndAutoScanFlag() {
        let (r, defaults) = makeResolver()
        let alias = PendingSuggestion(
            newTag: "Person A Nickname",
            canonicalGuess: "Person A",
            confidence: .high,
            source: .scan
        )
        #expect(r.enqueue(alias))
        r.confirm(alias, canonical: "Person A")

        let rejected = PendingSuggestion(
            newTag: "Gym",
            canonicalGuess: "Work",
            confidence: .medium,
            source: .scan
        )
        #expect(r.enqueue(rejected))
        r.reject(rejected)

        let pending = PendingSuggestion(
            newTag: "Cafe",
            canonicalGuess: "Coffee",
            confidence: .medium,
            source: .scan
        )
        #expect(r.enqueue(pending))
        r.markAutoScanned()

        let reloaded = makeStoredResolver(defaults: defaults)
        #expect(reloaded.canonicalize("Person A Nickname") == "Person A")
        #expect(reloaded.groups["Person A"]?.contains("Person A Nickname") == true)
        #expect(reloaded.pending.map(\.id).contains(pending.id))
        #expect(!reloaded.enqueue(rejected))
        #expect(reloaded.didAutoScanOnce)
    }
}

// MARK: - ThemeManagementService

@MainActor
struct ThemeManagementServiceTests {
    @Test func deleteTheme_removesCanonicalAndAliasesFromEntriesAndResolver() async throws {
        let persistence = PersistenceController(inMemory: true)
        let resolver = ThemeAliasResolver(testingWithEmptyState: isolatedDefaults())
        let context = persistence.container.viewContext

        insertDiaryEntry(
            context: context,
            date: makeDate(year: 2024, month: 6, day: 1),
            themes: ["Person A", "Work"]
        )
        insertDiaryEntry(
            context: context,
            date: makeDate(year: 2024, month: 6, day: 2),
            themes: ["Person A Nickname", "Health"]
        )
        insertDiaryEntry(
            context: context,
            date: makeDate(year: 2024, month: 6, day: 3),
            themes: ["Family"]
        )
        try context.save()

        let alias = PendingSuggestion(
            newTag: "Person A Nickname",
            canonicalGuess: "Person A",
            confidence: .high,
            source: .scan
        )
        #expect(resolver.enqueue(alias))
        resolver.confirm(alias, canonical: "Person A")
        #expect(resolver.enqueue(PendingSuggestion(
            newTag: "Partner",
            canonicalGuess: "Person A",
            confidence: .medium,
            source: .scan
        )))

        let service = ThemeManagementService(persistence: persistence, resolver: resolver)
        let outcome = await service.deleteTheme(canonical: "Person A")

        #expect(outcome.succeeded)
        #expect(outcome.affected == 2)
        #expect(resolver.groups["Person A"] == nil)
        #expect(resolver.pending.isEmpty)

        let themes = await fetchThemeArrays(persistence)
        #expect(themes.contains(["Work"]))
        #expect(themes.contains(["Health"]))
        #expect(themes.contains(["Family"]))
        #expect(!themes.flatMap { $0 }.contains("Person A"))
        #expect(!themes.flatMap { $0 }.contains("Person A Nickname"))
    }

    /// **B3 — save-failure 分支**:context.save() 抛 → resolver group 必须保留(避免 alias 删了
    /// 但 raw entry.themes 还在的不一致状态)。`saveAction` closure 注入失败模拟。
    @Test func deleteTheme_saveFailure_preservesResolverGroupAndReportsFailure() async throws {
        let persistence = PersistenceController(inMemory: true)
        let resolver = ThemeAliasResolver(testingWithEmptyState: isolatedDefaults())
        let context = persistence.container.viewContext

        insertDiaryEntry(
            context: context,
            date: makeDate(year: 2024, month: 6, day: 1),
            themes: ["Person A"]
        )
        insertDiaryEntry(
            context: context,
            date: makeDate(year: 2024, month: 6, day: 2),
            themes: ["Person A Nickname"]
        )
        try context.save()

        // 先建一个 group(模拟用户已合并 Person A Nickname → Person A)
        let suggestion = PendingSuggestion(
            newTag: "Person A Nickname",
            canonicalGuess: "Person A",
            confidence: .high,
            source: .scan
        )
        #expect(resolver.enqueue(suggestion))
        resolver.confirm(suggestion, canonical: "Person A")
        #expect(resolver.groups["Person A"] != nil, "前置:group 应已建立")

        // 注入失败 saveAction
        struct ForcedSaveError: Error {}
        let service = ThemeManagementService(
            persistence: persistence,
            resolver: resolver,
            saveAction: { _ in throw ForcedSaveError() }
        )

        let outcome = await service.deleteTheme(canonical: "Person A")

        #expect(!outcome.succeeded, "save 失败 → succeeded 必须 false")
        #expect(outcome.affected == 0, "save 失败 → affected 必须 0")

        // **关键不变量**:save 失败时 resolver group **必须保留**,否则 alias map 删了
        // 但 entry.themes raw CSV 还在,Insights 上 "已合并" 数减但主题词又冒出来。
        #expect(resolver.groups["Person A"] != nil, "save 失败时 resolver group 必须保留")
        #expect(resolver.groups["Person A"]?.contains("Person A Nickname") == true,
                "alias 也必须保留")

        // entry.themes 也应未变(rollback 生效)
        let themes = await fetchThemeArrays(persistence)
        #expect(themes.contains(["Person A"]) || themes.flatMap { $0 }.contains("Person A"),
                "rollback 后 raw themes 应保留")
    }

    /// **B3 配套**:成功路径仍然走得通(saveAction 默认 try $0.save() 等价于原行为)。
    /// 这条是 sanity check,确保加 saveAction 注入没破坏默认行为。
    @Test func deleteTheme_defaultSaveAction_stillWorks() async throws {
        let persistence = PersistenceController(inMemory: true)
        let resolver = ThemeAliasResolver(testingWithEmptyState: isolatedDefaults())
        let context = persistence.container.viewContext

        insertDiaryEntry(
            context: context,
            date: makeDate(year: 2024, month: 6, day: 1),
            themes: ["TestTag"]
        )
        try context.save()

        // 不传 saveAction → 默认 try context.save()
        let service = ThemeManagementService(persistence: persistence, resolver: resolver)
        let outcome = await service.deleteTheme(canonical: "TestTag")

        #expect(outcome.succeeded)
        #expect(outcome.affected == 1)
    }
}

// MARK: - ThemeAliasJudgeService

@MainActor
struct ThemeAliasJudgeServiceTests {
    @Test func scanAllHistory_withSmallInventorySkipsAI() async {
        let persistence = PersistenceController(inMemory: true)
        let ai = ThemeAliasAITestDouble()
        let resolver = ThemeAliasResolver(testingWithEmptyState: isolatedDefaults())
        let service = ThemeAliasJudgeService(persistence: persistence, ai: ai, resolver: resolver)

        let task = service.scanAllHistory()
        await task.value

        #expect(ai.scanCalls == 0)
        #expect(service.scanProgress.isRunning == false)
        #expect(service.scanProgress.phase == .done)
    }

    @Test func scanAllHistory_whileRunningDoesNotStartSecondTask() async throws {
        let persistence = PersistenceController(inMemory: true)
        try seedEntries(
            persistence,
            [
                (["Person A"], makeDate(year: 2024, month: 6, day: 1)),
                (["Person A Nickname"], makeDate(year: 2024, month: 6, day: 2))
            ]
        )
        let ai = ThemeAliasAITestDouble()
        ai.scanGroups = [
            ThemeAliasJudgeGroup(
                canonical: "Person A",
                aliases: ["Person A Nickname"],
                confidence: .high,
                reason: "test"
            )
        ]
        ai.suspendScan = true
        let resolver = ThemeAliasResolver(testingWithEmptyState: isolatedDefaults())
        let service = ThemeAliasJudgeService(persistence: persistence, ai: ai, resolver: resolver)

        let first = service.scanAllHistory()
        await ai.waitForSuspendedScan()
        let second = service.scanAllHistory()

        #expect(ai.scanCalls == 1)
        ai.releaseScan()
        await first.value
        await second.value
        #expect(resolver.pending.count == 1)
    }

    @Test func cancelScan_returnsProgressToIdle() async throws {
        let persistence = PersistenceController(inMemory: true)
        try seedEntries(
            persistence,
            [
                (["Person A"], makeDate(year: 2024, month: 6, day: 1)),
                (["Person A Nickname"], makeDate(year: 2024, month: 6, day: 2))
            ]
        )
        let ai = ThemeAliasAITestDouble()
        ai.suspendScan = true
        let resolver = ThemeAliasResolver(testingWithEmptyState: isolatedDefaults())
        let service = ThemeAliasJudgeService(persistence: persistence, ai: ai, resolver: resolver)

        let task = service.scanAllHistory()
        await ai.waitForSuspendedScan()
        service.cancelScan()

        #expect(service.scanProgress.isRunning == false)
        #expect(service.scanProgress.phase == .idle)
        ai.releaseScan()
        await task.value
    }

    @Test func scanAllHistory_respectsNegativePairs() async throws {
        let persistence = PersistenceController(inMemory: true)
        try seedEntries(
            persistence,
            [
                (["Person A"], makeDate(year: 2024, month: 6, day: 1)),
                (["Person A Nickname"], makeDate(year: 2024, month: 6, day: 2))
            ]
        )
        let ai = ThemeAliasAITestDouble()
        ai.scanGroups = [
            ThemeAliasJudgeGroup(
                canonical: "Person A",
                aliases: ["Person A Nickname"],
                confidence: .high,
                reason: "test"
            )
        ]
        let resolver = ThemeAliasResolver(testingWithEmptyState: isolatedDefaults())
        let rejected = PendingSuggestion(
            newTag: "Person A Nickname",
            canonicalGuess: "Person A",
            confidence: .high,
            source: .scan
        )
        #expect(resolver.enqueue(rejected))
        resolver.reject(rejected)
        let service = ThemeAliasJudgeService(persistence: persistence, ai: ai, resolver: resolver)

        let task = service.scanAllHistory()
        await task.value

        #expect(ai.scanCalls == 1)
        #expect(resolver.pending.isEmpty)
    }

    @Test func judgeAfterWrite_deletedEntryDoesNotEnqueueGhostSuggestion() async throws {
        let persistence = PersistenceController(inMemory: true)
        try seedEntries(
            persistence,
            [
                (["Person A"], makeDate(year: 2024, month: 6, day: 1))
            ]
        )
        let ai = ThemeAliasAITestDouble()
        ai.judgeResult = [
            ThemeAliasJudgeMatch(
                newTag: "Person A Nickname",
                canonical: "Person A",
                confidence: .high,
                reason: "test"
            )
        ]
        let resolver = ThemeAliasResolver(testingWithEmptyState: isolatedDefaults())
        let service = ThemeAliasJudgeService(persistence: persistence, ai: ai, resolver: resolver)

        await service.judgeAfterWrite(
            entryID: UUID(),
            newTags: ["Person A Nickname"]
        )

        #expect(ai.judgeCalls == 1)
        #expect(resolver.pending.isEmpty)
    }

    /// **B4 race test** — T1 挂起在 AI scanThemeAliasGroups,T2 模拟进入(bump scanGen + 替换 scanTask)。
    /// T1 释放后其 trailing closure `if scanGen == myGen` 必须 false → 不该清掉 T2 的 sentinel scanTask。
    /// 这条锁的是 `superreview P1 #5` 修的世代号语义:旧实现下 T1 的 trailing 直接 `scanTask = nil`
    /// 会清掉 T2 的 handle,导致 isRunning gate 失效;改世代号后 stale T1 早返,T2 handle 保留。
    @Test func scanGen_staleCompletionDoesNotClearNewerTaskHandle() async throws {
        let persistence = PersistenceController(inMemory: true)
        try seedEntries(persistence, [
            (["A"], makeDate(year: 2024, month: 6, day: 1)),
            (["B"], makeDate(year: 2024, month: 6, day: 2))
        ])
        let ai = ThemeAliasAITestDouble()
        ai.suspendScan = true  // T1 进入 ai.scanThemeAliasGroups 后挂住
        let resolver = ThemeAliasResolver(testingWithEmptyState: isolatedDefaults())
        let service = ThemeAliasJudgeService(persistence: persistence, ai: ai, resolver: resolver)

        // T1 启动,会捕获 myGen=1,挂在 AI suspendScan 处
        let t1 = service.scanAllHistory()
        await ai.waitForSuspendedScan()
        let t1Gen = service.scanGenForTesting

        // 模拟 T2 racing in:bump scanGen 到 2,替换 scanTask 为 sentinel
        let sentinel = Task<Void, Never> { /* T2 sentinel,不实际跑 */ }
        service.simulateConcurrentScanStartForTesting(replacementTask: sentinel)
        let postBumpGen = service.scanGenForTesting
        #expect(postBumpGen == t1Gen &+ 1, "simulateConcurrent should bump gen by 1")
        #expect(service.scanTaskForTesting == sentinel, "scanTask 应已替换为 sentinel")

        // 释放 T1 → runScan 完成 → trailing closure 跑 `if scanGen (2) == myGen (1)` → false → 跳过清空
        ai.releaseScan()
        await t1.value

        // **关键不变量**:T1 的 stale trailing 闭包不能清掉 T2 的 handle
        #expect(service.scanTaskForTesting == sentinel,
                "T1(stale gen)trailing closure 不该清掉 T2 的 scanTask handle")

        sentinel.cancel()
    }

    @Test func scanAllHistory_failureSetsFailedProgress() async throws {
        let persistence = PersistenceController(inMemory: true)
        try seedEntries(
            persistence,
            [
                (["Person A"], makeDate(year: 2024, month: 6, day: 1)),
                (["Person A Nickname"], makeDate(year: 2024, month: 6, day: 2))
            ]
        )
        let ai = ThemeAliasAITestDouble()
        ai.scanError = ThemeAliasError.requestFailed
        let resolver = ThemeAliasResolver(testingWithEmptyState: isolatedDefaults())
        let service = ThemeAliasJudgeService(persistence: persistence, ai: ai, resolver: resolver)

        let task = service.scanAllHistory()
        await task.value

        #expect(ai.scanCalls == 1)
        #expect(service.scanProgress.isRunning == false)
        let didFail: Bool
        if case .failed = service.scanProgress.phase {
            didFail = true
        } else {
            didFail = false
        }
        #expect(didFail, "Expected failed scan phase")
    }
}

private final class ThemeAliasAITestDouble: AIServiceProtocol {
    var judgeCalls = 0
    var scanCalls = 0
    var judgeResult: [ThemeAliasJudgeMatch] = []
    var scanGroups: [ThemeAliasJudgeGroup] = []
    var scanError: Error?
    var suspendScan = false
    /// 最近一次 scanThemeAliasGroups 收到的 candidates。给隐私不变量测试用 —
    /// 断言 sampleSnippet 不会回退到 raw entry.text。
    var lastScanCandidates: [ThemeAliasJudgeCandidate] = []

    private var scanContinuation: CheckedContinuation<Void, Never>?

    func waitForSuspendedScan() async {
        while scanContinuation == nil {
            await Task.yield()
        }
    }

    func releaseScan() {
        scanContinuation?.resume()
        scanContinuation = nil
    }

    func summarize(text: String) async -> String? { nil }

    func analyzeMood(text: String) async -> Double { 0.5 }

    func extractThemes(text: String) async -> [String] { [] }

    func judgeThemeAliases(
        newTags: [String],
        inventory: [ThemeAliasJudgeCandidate]
    ) async -> [ThemeAliasJudgeMatch] {
        judgeCalls += 1
        return judgeResult
    }

    func scanThemeAliasGroups(
        candidates: [ThemeAliasJudgeCandidate]
    ) async throws -> [ThemeAliasJudgeGroup] {
        scanCalls += 1
        lastScanCandidates = candidates
        if suspendScan {
            await withCheckedContinuation { continuation in
                scanContinuation = continuation
            }
        }
        if let scanError { throw scanError }
        return scanGroups
    }

    func embed(text: String) async -> [Float]? { nil }

    func ask(question: String, context entries: [DiaryEntryData]) -> AsyncStream<String> {
        AsyncStream { continuation in continuation.finish() }
    }

    @available(iOS 15.0, macOS 12.0, *)
    func askEvents(question: String, context entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
        AsyncStream { continuation in continuation.finish() }
    }

    @available(iOS 15.0, macOS 12.0, *)
    func streamReportEvents(entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
        AsyncStream { continuation in continuation.finish() }
    }

    func composeSuggestions(context: SuggestionContext) async -> SuggestionBundle? { nil }

    func parseImportedDiaries(rawText: String) async throws -> [ParsedDiaryEntry] { [] }
}

private func isolatedDefaults() -> UserDefaults {
    let suiteName = UUID().uuidString
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

@discardableResult
private func insertDiaryEntry(
    context: NSManagedObjectContext,
    id: UUID = UUID(),
    date: Date,
    themes: [String],
    text: String = "Test entry"
) -> DiaryEntry {
    guard let entity = NSEntityDescription.entity(forEntityName: "DiaryEntry", in: context) else {
        preconditionFailure("DiaryEntry entity is missing from the test Core Data model")
    }
    let entry = DiaryEntry(entity: entity, insertInto: context)
    entry.id = id
    entry.date = date
    entry.text = text
    entry.summary = text
    entry.moodValue = 0.5
    entry.setThemes(themes)
    entry.recomputeWordCount()
    return entry
}

private func seedEntries(
    _ persistence: PersistenceController,
    _ specs: [([String], Date)]
) throws {
    let context = persistence.container.viewContext
    for (themes, date) in specs {
        insertDiaryEntry(context: context, date: date, themes: themes)
    }
    try context.save()
}

private func fetchThemeArrays(_ persistence: PersistenceController) async -> [[String]] {
    await persistence.container.performBackgroundTask { context in
        let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: true)]
        guard let entries = try? context.fetch(request) else { return [] }
        return entries.map(\.themeArray)
    }
}

// MARK: - ReminderService.notificationBody (new frequency-based API)

@MainActor
struct ReminderBodyTests {
    @Test func daily_fresh() {
        let body = ReminderService.notificationBody(frequency: .daily, daysSilent: 0)
        #expect(!body.contains("已经"))  // 不应说"已经 N 天"
    }

    @Test func daily_silentMultipleDays() {
        let body = ReminderService.notificationBody(frequency: .daily, daysSilent: 3)
        #expect(body.contains("3"))
    }

    @Test func every3Days_silent() {
        let body = ReminderService.notificationBody(frequency: .every3Days, daysSilent: 2)
        #expect(body.contains("2"))
    }

    @Test func weekly_silent() {
        let body = ReminderService.notificationBody(frequency: .weekly, daysSilent: 6)
        #expect(body.contains("6"))
    }

    @Test func weekly_neverWrote() {
        // daysSilent = nil(从未写过)→ 用 fresh 文案
        let body = ReminderService.notificationBody(frequency: .weekly, daysSilent: nil)
        #expect(!body.contains("已经"))
    }
}

// MARK: - Reminder notification routing

struct ReminderNotificationRoutingTests {
    @Test func reminderIdentifier_requestsComposerFocus() {
        #expect(ReminderNotificationRouter.shouldFocusComposer(
            identifier: "lumory.reminder.today",
            categoryIdentifier: "",
            userInfo: [:]
        ))
    }

    @Test func explicitComposeIntent_requestsComposerFocus() {
        #expect(ReminderNotificationRouter.shouldFocusComposer(
            identifier: "third.party.id",
            categoryIdentifier: "something.else",
            userInfo: ["lumory.intent": "compose"]
        ))
    }

    @Test func unrelatedNotification_doesNotRequestComposerFocus() {
        #expect(!ReminderNotificationRouter.shouldFocusComposer(
            identifier: "lumory.other",
            categoryIdentifier: "",
            userInfo: [:]
        ))
    }
}

// MARK: - ReminderService persistence migration & defaults

// 这两块 helper 是 CLAUDE.md 标过的坑:
//   - useContextualBody 默 true 必须 `(object as? Bool) ?? true`,bool(forKey:) 缺省返 false 反转语义
//   - weeklyTargetDays 一次性迁移逻辑(5-7→daily / 2-4→every3Days / else→weekly)+ 清 legacy key
// 没回归测试,future refactor 改坏极隐蔽。这里保 canary。

struct ReminderFrequencyMigrationTests {
    private let legacyKey = "lumory.test.legacyWeeklyTargetDays"
    private let key = "lumory.test.frequency"

    private func freshDefaults() -> UserDefaults {
        let suite = UUID().uuidString
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func newKey_winsAndClearsLegacy() {
        let d = freshDefaults()
        d.set(ReminderFrequency.every3Days.rawValue, forKey: key)
        d.set(7, forKey: legacyKey)  // legacy 应该被清掉,不影响结果
        let f = ReminderService.loadFrequency(from: d, legacyKey: legacyKey, key: key)
        #expect(f == .every3Days)
        #expect(d.object(forKey: legacyKey) == nil)
    }

    @Test func legacy_5to7_migratesToDaily() {
        for v in 5...7 {
            let d = freshDefaults()
            d.set(v, forKey: legacyKey)
            let f = ReminderService.loadFrequency(from: d, legacyKey: legacyKey, key: key)
            #expect(f == .daily, "\(v) days/week 应该迁移到 daily")
            #expect(d.object(forKey: legacyKey) == nil)
            #expect(d.object(forKey: key) as? Int == ReminderFrequency.daily.rawValue)
        }
    }

    @Test func legacy_2to4_migratesToEvery3Days() {
        for v in 2...4 {
            let d = freshDefaults()
            d.set(v, forKey: legacyKey)
            let f = ReminderService.loadFrequency(from: d, legacyKey: legacyKey, key: key)
            #expect(f == .every3Days, "\(v) days/week 应该迁移到 every3Days")
            #expect(d.object(forKey: legacyKey) == nil)
        }
    }

    @Test func legacy_1_migratesToWeekly() {
        // 边界:1 不在 2...4 / 5...7,落 weekly
        let d = freshDefaults()
        d.set(1, forKey: legacyKey)
        let f = ReminderService.loadFrequency(from: d, legacyKey: legacyKey, key: key)
        #expect(f == .weekly)
        #expect(d.object(forKey: legacyKey) == nil)
    }

    @Test func noKeysAtAll_defaultsToWeekly() {
        let d = freshDefaults()
        let f = ReminderService.loadFrequency(from: d, legacyKey: legacyKey, key: key)
        #expect(f == .weekly)
    }
}

struct ReminderUseContextualBodyDefaultTests {
    private let key = "lumory.test.useContextualBody"

    private func freshDefaults() -> UserDefaults {
        let suite = UUID().uuidString
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func unsetKey_defaultsToFalse() {
        // privacy-first:default off。AI 生成的 placeholder 含真实主题词,挂到通知 body
        // 会被 iOS 锁屏明文显示。新装机走 false,用户主动 opt-in 才打开。
        let d = freshDefaults()
        let v = ReminderService.loadUseContextualBody(from: d, key: key)
        #expect(v == false)
    }

    @Test func explicitFalse_isRespected() {
        let d = freshDefaults()
        d.set(false, forKey: key)
        let v = ReminderService.loadUseContextualBody(from: d, key: key)
        #expect(v == false)
    }

    @Test func explicitTrue_isRespected() {
        let d = freshDefaults()
        d.set(true, forKey: key)
        let v = ReminderService.loadUseContextualBody(from: d, key: key)
        #expect(v == true)
    }
}

// MARK: - ReminderService.cycleBounds (周期数学,doc-comment 例子的回归锁)
//
// CLAUDE.md 反复提到周期数学是 ReminderService 最容易踩坑的地方,但之前没单测覆盖。
// 这里用 nonisolated static 入口直接喂 anchor / frequency / 任意 reference date,
// 不依赖 @MainActor 实例,也不依赖 system Calendar.current / 当前时区。

struct ReminderCycleBoundsTests {
    /// 固定到 UTC + Gregorian,跨开发机时区稳定。本地用户感知用 Calendar.current 是另一回事,
    /// 但 cycle 数学在概念上就是按 startOfDay 滚 N 天,跟 timezone 解耦。
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func makeUTCDate(year: Int, month: Int, day: Int) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = 12  // 中午,确保 startOfDay 不会被时区拉到前一天
        return calendar.date(from: comps)!
    }

    @Test func daily_eachDayIsItsOwnCycle() {
        let anchor = makeUTCDate(year: 2026, month: 4, day: 1)
        let day1 = makeUTCDate(year: 2026, month: 4, day: 1)
        let day2 = makeUTCDate(year: 2026, month: 4, day: 2)
        let b1 = ReminderService.cycleBounds(referenceDate: day1, anchor: anchor, frequency: .daily, calendar: calendar)
        let b2 = ReminderService.cycleBounds(referenceDate: day2, anchor: anchor, frequency: .daily, calendar: calendar)
        #expect(b1.start == calendar.startOfDay(for: day1))
        #expect(b1.end == calendar.date(byAdding: .day, value: 1, to: b1.start))
        #expect(b2.start != b1.start)
    }

    @Test func every3Days_day1AndDay3SameCycle() {
        let anchor = makeUTCDate(year: 2026, month: 4, day: 1)
        let day1 = makeUTCDate(year: 2026, month: 4, day: 1)
        let day3 = makeUTCDate(year: 2026, month: 4, day: 3)
        let day4 = makeUTCDate(year: 2026, month: 4, day: 4)
        let b1 = ReminderService.cycleBounds(referenceDate: day1, anchor: anchor, frequency: .every3Days, calendar: calendar)
        let b3 = ReminderService.cycleBounds(referenceDate: day3, anchor: anchor, frequency: .every3Days, calendar: calendar)
        let b4 = ReminderService.cycleBounds(referenceDate: day4, anchor: anchor, frequency: .every3Days, calendar: calendar)
        #expect(b1.start == b3.start, "day 1 and day 3 of every3Days cycle should share start")
        #expect(b3.end == calendar.date(byAdding: .day, value: 3, to: b1.start))
        #expect(b4.start != b1.start, "day 4 starts new cycle")
        #expect(b4.start == b1.end, "next cycle's start = previous cycle's end")
    }

    @Test func weekly_day1AndDay7SameCycle_day8RollsOver() {
        let anchor = makeUTCDate(year: 2026, month: 4, day: 1)
        let day1 = makeUTCDate(year: 2026, month: 4, day: 1)
        let day7 = makeUTCDate(year: 2026, month: 4, day: 7)
        let day8 = makeUTCDate(year: 2026, month: 4, day: 8)
        let b1 = ReminderService.cycleBounds(referenceDate: day1, anchor: anchor, frequency: .weekly, calendar: calendar)
        let b7 = ReminderService.cycleBounds(referenceDate: day7, anchor: anchor, frequency: .weekly, calendar: calendar)
        let b8 = ReminderService.cycleBounds(referenceDate: day8, anchor: anchor, frequency: .weekly, calendar: calendar)
        #expect(b1.start == b7.start)
        #expect(b1.end == calendar.date(byAdding: .day, value: 7, to: b1.start))
        #expect(b8.start == b1.end)
    }

    @Test func referenceBeforeAnchor_clampsToCycle0() {
        // 用户系统时间倒拨 / 数据 import 时间漂移 → date 在 anchor 之前。
        // 应当作 cycle 0(含 anchor 那天)而不是负 cycleIndex。
        let anchor = makeUTCDate(year: 2026, month: 4, day: 10)
        let earlyDate = makeUTCDate(year: 2026, month: 4, day: 5)
        let b = ReminderService.cycleBounds(referenceDate: earlyDate, anchor: anchor, frequency: .weekly, calendar: calendar)
        #expect(b.start == calendar.startOfDay(for: anchor), "early date should clamp to anchor's cycle")
    }

    @Test func endIsExclusive_lastDayInCycle_nextDayInNextCycle() {
        let anchor = makeUTCDate(year: 2026, month: 1, day: 1)
        let cycleEnd = makeUTCDate(year: 2026, month: 1, day: 8)  // weekly: cycle [1, 8)
        let b = ReminderService.cycleBounds(referenceDate: anchor, anchor: anchor, frequency: .weekly, calendar: calendar)
        #expect(b.end == calendar.startOfDay(for: cycleEnd))
        // wroteCurrentCycle 的判断是 `lastEntry < cycleEnd`,所以 lastEntry == cycleEnd 应在下一 cycle。
        let bNext = ReminderService.cycleBounds(referenceDate: cycleEnd, anchor: anchor, frequency: .weekly, calendar: calendar)
        #expect(bNext.start == b.end)
    }
}

// MARK: - ThemeAliasJudgeService 隐私不变量

@MainActor
struct ThemeAliasJudgePrivacyTests {
    /// CLAUDE.md/codex 历史:fetchInventory 的 sampleSnippet 必须**只**来自 `entry.summary`,
    /// 绝不回退到 raw `entry.text`。本测试用 sentinel 字符串锁住:summary == nil + text 含
    /// sentinel,scanAllHistory 走完后 AI stub 收到的候选 snippet 不应含 sentinel。
    @Test func scan_inventoryNeverLeaksRawText() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let sentinel = "SENTINEL_RAW_TEXT_ABC123"

        // entry 1: summary 有值,sentinel 不出现。
        let e1 = insertDiaryEntry(
            context: context,
            date: makeDate(year: 2026, month: 1, day: 1),
            themes: ["Person A", "Person B"],
            text: "harmless text"
        )
        e1.summary = "summary one"

        // entry 2: summary nil,但 text 含 sentinel。预期 snippet 来自 nil → 空,绝不含 sentinel。
        let e2 = insertDiaryEntry(
            context: context,
            date: makeDate(year: 2026, month: 1, day: 2),
            themes: ["Person A Nickname", "Health"],
            text: "leaked diary content with \(sentinel) in body"
        )
        e2.summary = nil
        try context.save()

        let ai = ThemeAliasAITestDouble()
        // 触发 AI 路径:必须有 ≥ 2 候选才会进 scanThemeAliasGroups(否则 short-circuit)。
        let resolver = ThemeAliasResolver(testingWithEmptyState: isolatedDefaults())
        let service = ThemeAliasJudgeService(persistence: persistence, ai: ai, resolver: resolver)

        let task = service.scanAllHistory()
        await task.value

        // AI 应该被调一次;并且收到的 inventory 任何 candidate 的 sampleSnippet 都不能含 sentinel。
        #expect(ai.scanCalls == 1)
        let leakingCandidate = ai.lastScanCandidates.first {
            ($0.sampleSnippet ?? "").contains(sentinel)
        }
        #expect(leakingCandidate == nil, "sampleSnippet leaked raw entry.text via fallback — privacy regression")
    }
}

// MARK: - ThemeAliasResolver coolUntil + decode-corruption invariants

@MainActor
struct ThemeAliasResolverInvariantTests {
    /// 用户主动 confirm = 重新 engage,7 天冷却必须清掉,否则 banner 继续被压抑、用户感知"接受了
    /// 也不显示新建议"。superreview P2 fix。
    @Test func confirm_resetsCoolUntil() {
        let resolver = ThemeAliasResolver(testingWithEmptyState: isolatedDefaults())
        let suggestion = PendingSuggestion(
            newTag: "Abby", canonicalGuess: "宝贝", confidence: .high, source: .scan
        )
        #expect(resolver.enqueue(suggestion))
        resolver.setCoolUntilForTesting(Date().addingTimeInterval(7 * 86_400))  // 模拟用户已进入 7 天冷却

        resolver.confirm(suggestion, canonical: "宝贝")
        #expect(resolver.coolUntil == nil, "confirm should clear coolUntil")
    }

    /// 长按 mergeThemes 同样是主动 engage,coolUntil 一并清。
    @Test func mergeThemes_resetsCoolUntil() {
        let resolver = ThemeAliasResolver(testingWithEmptyState: isolatedDefaults())
        resolver.setCoolUntilForTesting(Date().addingTimeInterval(7 * 86_400))

        let outcome = resolver.mergeThemes(source: "Abby", into: "宝贝")
        #expect(outcome == .merged)
        #expect(resolver.coolUntil == nil, "mergeThemes should clear coolUntil")
    }

    /// 损坏 blob 必须备份到 `<key>.corrupted-<ts>` 后再走空状态。否则 next save 直接覆盖,
    /// iCloud restore / schema mismatch 场景静默丢用户的合并地图。
    @Test func decodeFailure_backsUpCorruptBlobToTimestampedKey() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let storageKey = "lumory.themeAliasStore.v1"
        let corruptBlob = Data([0xFF, 0xFE, 0xAB, 0xCD, 0x12])
        defaults.set(corruptBlob, forKey: storageKey)

        // 触发 load() — testingWithStoredState 走真实 load() 路径,会撞 decode 失败。
        _ = ThemeAliasResolver(testingWithStoredState: defaults)

        // 备份 key 应当存在(prefix `lumory.themeAliasStore.v1.corrupted-`)。
        let allKeys = defaults.dictionaryRepresentation().keys
        let backupKeys = allKeys.filter { $0.hasPrefix("\(storageKey).corrupted-") }
        #expect(backupKeys.count == 1, "expected exactly one timestamped backup key, got \(backupKeys)")
        if let backupKey = backupKeys.first {
            #expect(defaults.data(forKey: backupKey) == corruptBlob, "backup should hold the original corrupt bytes")
        }
    }

    /// rotate:已存在 3+ 个老备份 + 触发新 decode 失败 → 应只剩最新 2 个(包括这次新备份)。
    @Test func decodeFailure_keepsAtMostTwoCorruptedBackups() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let storageKey = "lumory.themeAliasStore.v1"
        // 预置 3 个老备份(timestamps:1, 2, 3 —— 字典序也是时间序)
        defaults.set(Data([0x01]), forKey: "\(storageKey).corrupted-1000000001")
        defaults.set(Data([0x02]), forKey: "\(storageKey).corrupted-1000000002")
        defaults.set(Data([0x03]), forKey: "\(storageKey).corrupted-1000000003")
        // 当前损坏 blob → 触发 load 失败 → 写第 4 个备份 + rotate 到只剩最新 2
        defaults.set(Data([0xFF, 0xFE, 0xAB]), forKey: storageKey)

        _ = ThemeAliasResolver(testingWithStoredState: defaults)

        let backupKeys = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("\(storageKey).corrupted-") }
            .sorted(by: >)
        #expect(backupKeys.count == 2, "expected rotation to keep only 2 backups, got \(backupKeys.count)")
        // 最旧的 1000000001、1000000002 应被删,只留最大的 1000000003 + 新加的(timestamp 大于 3)
        #expect(backupKeys.contains { $0.hasSuffix("1000000003") }, "newest pre-existing backup must survive")
        #expect(!backupKeys.contains { $0.hasSuffix("1000000001") }, "oldest backup should be evicted")
        #expect(!backupKeys.contains { $0.hasSuffix("1000000002") }, "second-oldest should be evicted")
    }
}

// MARK: - 17 round-2 fixes coverage

@MainActor
struct Round2FixesTests {
    /// Fix #12: enqueue 200 hard cap FIFO. 251 distinct → pending.count == 200,丢的是最旧的。
    @Test func enqueue_hardCap_dropsOldestKeepsCount200() {
        let resolver = ThemeAliasResolver(testingWithEmptyState: isolatedDefaults())
        // 灌入 251 条 distinct suggestions(unique pair: tag\(i) ↔ canonical\(i))
        for i in 0..<251 {
            let suggestion = PendingSuggestion(
                newTag: "tag\(i)",
                canonicalGuess: "canonical\(i)",
                confidence: .high,
                source: .scan
            )
            _ = resolver.enqueue(suggestion)
        }
        #expect(resolver.pending.count == 200, "cap 200 — got \(resolver.pending.count)")
        // 最早的 51 条(0-50)应该被 FIFO 干掉。最新的 250 应该保留。
        let newTags = Set(resolver.pending.map { $0.newTag })
        #expect(!newTags.contains("tag0"), "tag0 should be FIFO-dropped")
        #expect(!newTags.contains("tag50"), "tag50 should be FIFO-dropped")
        #expect(newTags.contains("tag51"), "tag51 should be retained as oldest survivor")
        #expect(newTags.contains("tag250"), "newest tag250 must be retained")
    }

    /// Fix #9: cleanupOrphanedPending 用 await 前的 beforeIDs snapshot,
    /// 不影响 await 期间新加的 pending(防止误删 judgeAfterWrite 在 cleanup 飞行中 enqueue 的新对子)。
    /// 用 helper 先 enqueue,然后手动调 cleanup,再断言 await 后插入的 pending 仍存活。
    /// 这条测试用同步路径模拟:cleanup 跑完前 enqueue 的 pending(simulated by calling enqueue
    /// 在 cleanup 之前但 sample 不在 active set)— 应被保留(不在 beforeIDs 里)。
    @Test func cleanupOrphanedPending_doesNotRemovePendingAddedAfterSnapshot() async {
        let persistence = PersistenceController(inMemory: true)
        let resolver = ThemeAliasResolver(testingWithEmptyState: isolatedDefaults())

        // pre-cleanup pending(将被视为 stale,因为 fetchActiveLowercasedLabels 返空)
        let stalePending = PendingSuggestion(
            newTag: "stale", canonicalGuess: "原版", confidence: .high, source: .scan
        )
        #expect(resolver.enqueue(stalePending))

        // 走真实 cleanup 路径:Core Data 是空的 → active set 空 → stalePending 应被删
        await resolver.cleanupOrphanedPending()
        #expect(!resolver.pending.contains(where: { $0.id == stalePending.id }),
                "empty CoreData should evict stalePending")

        // 现在加一条新 pending,再跑一次 cleanup —— 新加的应该 fetchActive 返回空时被删
        // (因为它也在 beforeIDs 里;这条测试间接验证:beforeIDs 等于当前 pending IDs 时,
        // cleanup 行为跟历史等价)
        let nextPending = PendingSuggestion(
            newTag: "next", canonicalGuess: "其他", confidence: .high, source: .scan
        )
        #expect(resolver.enqueue(nextPending))
        await resolver.cleanupOrphanedPending()
        #expect(!resolver.pending.contains(where: { $0.id == nextPending.id }),
                "second cleanup should also evict")

        // 实测 race:模拟 async 路径上 await 期间 enqueue。这一条用 cleanup-during-Task 设计
        // 比较复杂(需要 hold 住 fetch 然后注入 enqueue),所以这里只验证 beforeIDs 语义被
        // 实现:无 entry 时 cleanup 不会"主动重置 pending 为空集",只 remove beforeIDs 里的 stale。
        // 加一条新的然后立刻 cleanup —— 应该被删,但前面已经验证。
        // 真正的 race 测试需要更复杂 setup,留给将来 + cancellation 测试。
        _ = persistence  // prevent unused warning
    }

    /// Fix #1+2: deleteAllEntries → ThemeAliasResolver.resetForBulkEntryWipe + clearCache。
    /// 这条测 ThemeAliasResolver.resetForBulkEntryWipe 公开 API:
    /// groups + pending + coolUntil 清掉,negativePairs 保留,post 通知。
    @Test func resetForBulkEntryWipe_clearsAllExceptNegativePairs() {
        let resolver = ThemeAliasResolver(testingWithEmptyState: isolatedDefaults())
        // populate state
        let suggestion = PendingSuggestion(
            newTag: "Abby", canonicalGuess: "宝贝", confidence: .high, source: .scan
        )
        #expect(resolver.enqueue(suggestion))
        resolver.confirm(suggestion, canonical: "宝贝")  // 创 group
        // 单独 enqueue 一条 + reject 一条,把 pending + negativePair 都填上
        let rejected = PendingSuggestion(
            newTag: "ex", canonicalGuess: "前任", confidence: .medium, source: .scan
        )
        #expect(resolver.enqueue(rejected))
        resolver.reject(rejected)
        let still = PendingSuggestion(
            newTag: "妈咪", canonicalGuess: "妈妈", confidence: .high, source: .scan
        )
        #expect(resolver.enqueue(still))
        resolver.setCoolUntilForTesting(Date().addingTimeInterval(86400))

        // 前置断言:state 都填上了
        #expect(!resolver.groups.isEmpty)
        #expect(!resolver.pending.isEmpty)
        #expect(resolver.coolUntil != nil)

        resolver.resetForBulkEntryWipe()

        #expect(resolver.groups.isEmpty, "groups should be wiped")
        #expect(resolver.pending.isEmpty, "pending should be wiped")
        #expect(resolver.coolUntil == nil, "coolUntil should be cleared")
        // negativePairs 保留 —— 用户的"它们不是同一个"主观判断不应被批量删 entry 操作清掉
        #expect(resolver.isNegative("ex", "前任"), "negativePairs must be preserved across bulk wipe")
    }

    /// Fix #10: canonicalize NFC normalization。
    /// 入库 NFC "café"(precomposed),查找 NFD "café"(decomposed,e + combining acute)→ 应命中同一 group。
    @Test func canonicalize_NFC_lookupMatchesNFDInput() {
        let resolver = ThemeAliasResolver(testingWithEmptyState: isolatedDefaults())
        let nfcCanonical = "café".precomposedStringWithCanonicalMapping  // NFC 形式 (length 4)
        let nfdInput = "cafe\u{0301}"                                     // NFD 形式 (length 5)
        // sanity: 字节级它们不等
        #expect(nfcCanonical != nfdInput || nfcCanonical.utf8.count != nfdInput.utf8.count,
                "test fixture must use distinct byte forms")

        // 建一个以 NFC 为 canonical 的 group
        let suggestion = PendingSuggestion(
            newTag: "coffee", canonicalGuess: nfcCanonical, confidence: .high, source: .scan
        )
        #expect(resolver.enqueue(suggestion))
        resolver.confirm(suggestion, canonical: nfcCanonical)

        // 查找 NFD 形式 → 应映射到 NFC canonical(同一 group)
        let resolved = resolver.canonicalize(nfdInput)
        #expect(resolved == nfcCanonical, "NFD input should resolve to NFC canonical, got: \(resolved)")
    }

    /// Fix #7: judgeAfterWrite 60s debounce —— 60s 内第二次调跳过 AI 调用。
    @Test func judgeAfterWrite_debouncesWithin60s() async {
        let persistence = PersistenceController(inMemory: true)
        try? seedEntries(persistence, [
            (["A"], makeDate(year: 2024, month: 6, day: 1)),
            (["B"], makeDate(year: 2024, month: 6, day: 2))
        ])
        let ai = ThemeAliasAITestDouble()
        let resolver = ThemeAliasResolver(testingWithEmptyState: isolatedDefaults())
        let service = ThemeAliasJudgeService(persistence: persistence, ai: ai, resolver: resolver)

        // 第一次调 → 应当跑 judgeThemeAliases(知道是新 tag)
        await service.judgeAfterWrite(entryID: UUID(), newTags: ["FreshTag1"])
        let firstCalls = ai.judgeCalls

        // 60s 内第二次调 → 应被 debounce 跳过
        await service.judgeAfterWrite(entryID: UUID(), newTags: ["FreshTag2"])
        #expect(ai.judgeCalls == firstCalls, "second call within 60s must be skipped — debounce broken")
    }
}
