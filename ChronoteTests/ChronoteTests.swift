//
//  ChronoteTests.swift
//  ChronoteTests
//
//  Pure-function unit tests. Anything touching Core Data / network lives in UI tests.
//

import Testing
import Foundation
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
            InsightsEngine.Theme(name: "work", count: 10, uniqueDays: 5, avgMood: 0.3, entryIds: [], trend: Array(repeating: 0.3, count: 6)),
            InsightsEngine.Theme(name: "family", count: 8, uniqueDays: 4, avgMood: 0.9, entryIds: [], trend: Array(repeating: 0.9, count: 6))
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
        let a = makeContext(totalEntries: 10, themeNames: ["Abby"], latestDay: makeDate(year: 2024, month: 6, day: 15))
        let b = makeContext(totalEntries: 11, themeNames: ["Abby"], latestDay: makeDate(year: 2024, month: 6, day: 15))
        #expect(a.makeFingerprint() != b.makeFingerprint())
    }

    @Test func newEntryDateFlipsFingerprint() {
        let a = makeContext(totalEntries: 10, themeNames: ["Abby"], latestDay: makeDate(year: 2024, month: 6, day: 15))
        let b = makeContext(totalEntries: 10, themeNames: ["Abby"], latestDay: makeDate(year: 2024, month: 6, day: 16))
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

    private func makeContext(totalEntries: Int, themeNames: [String], latestDay: Date) -> SuggestionContext {
        let themes = themeNames.enumerated().map { i, name in
            InsightsEngine.Theme(
                name: name,
                count: 5 - i,
                uniqueDays: 5 - i,
                avgMood: 0.5,
                entryIds: [],
                trend: Array(repeating: 0.5, count: 6)
            )
        }
        let recent = [
            DiaryEntryData(id: UUID(), date: latestDay, text: "", moodValue: 0.5, summary: "")
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
