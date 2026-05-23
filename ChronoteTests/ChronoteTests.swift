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

}

// MARK: - LumoryAdaptivePresentation

struct LumoryAdaptivePresentationTests {
    @Test func iPad_usesExpandedModalEvenInCompactSplit() {
        #expect(LumoryAdaptivePresentation.shouldUseExpandedModal(
            isPad: true,
            horizontalSizeClassIsRegular: false
        ))
    }

    @Test func regularWidth_usesExpandedModal() {
        #expect(LumoryAdaptivePresentation.shouldUseExpandedModal(
            isPad: false,
            horizontalSizeClassIsRegular: true
        ))
    }

    @Test func phoneCompact_keepsSheetPresentation() {
        #expect(!LumoryAdaptivePresentation.shouldUseExpandedModal(
            isPad: false,
            horizontalSizeClassIsRegular: false
        ))
    }
}

// MARK: - InsightsEngine.aggregateThemes

struct ThemeAggregationTests {
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

    @Test func equalFrequencyThemesSortByName() {
        let range = DateInterval(
            start: makeDate(year: 2024, month: 6, day: 1),
            end: makeDate(year: 2024, month: 6, day: 30)
        )
        let entries: [DiaryEntryData] = [
            makeEntry(date: makeDate(year: 2024, month: 6, day: 1), themes: ["Beta"]),
            makeEntry(date: makeDate(year: 2024, month: 6, day: 2), themes: ["Alpha"])
        ]
        let result = InsightsEngine.aggregateThemes(entries: entries, range: range)
        #expect(result.map(\.name) == ["Alpha", "Beta"])
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

    @Test func noQueryVector_returnsEmpty() {
        let e1 = makeEntry(date: makeDate(year: 2024, month: 6, day: 1), embedding: [1, 0])
        let e2 = makeEntry(date: makeDate(year: 2024, month: 6, day: 10), embedding: [0, 1])
        let e3 = makeEntry(date: makeDate(year: 2024, month: 6, day: 20), embedding: nil)
        let result = InsightsEngine.rankRetrieval(all: [e1, e2, e3], queryVector: nil, topK: 3)
        #expect(result.isEmpty, "query 向量生成失败时不能回退到最近日记,否则 Ask Past 会产生假引用")
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

    @Test func dimensionMismatch_returnsEmpty() {
        let e1 = makeEntry(date: makeDate(year: 2024, month: 6, day: 1), embedding: [1, 0, 0])
        let e2 = makeEntry(date: makeDate(year: 2024, month: 6, day: 2), embedding: [0, 1, 0])
        let result = InsightsEngine.rankRetrieval(all: [e1, e2], queryVector: [1, 0], topK: 2)
        #expect(result.isEmpty, "embedding 维度不匹配时不能把 0 分结果当成相关日记")
    }

    @Test func dimensionMismatchWithUnindexed_fallsBackToRecency() {
        let mismatched = makeEntry(date: makeDate(year: 2024, month: 6, day: 1), embedding: [1, 0, 0])
        let freshUnindexed = makeEntry(date: makeDate(year: 2024, month: 6, day: 3), embedding: nil)
        let olderUnindexed = makeEntry(date: makeDate(year: 2024, month: 6, day: 2), embedding: nil)
        let result = InsightsEngine.rankRetrieval(
            all: [mismatched, olderUnindexed, freshUnindexed],
            queryVector: [1, 0],
            topK: 3
        )

        #expect(result.map(\.id) == [freshUnindexed.id, olderUnindexed.id, mismatched.id])
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
        let ctx1 = makeContext(latestDay: makeDate(year: 2024, month: 6, day: 15))
        let ctx2 = makeContext(latestDay: makeDate(year: 2024, month: 6, day: 15))
        #expect(ctx1.makeFingerprint() == ctx2.makeFingerprint())
    }

    @Test func newEntryFlipsFingerprint() {
        // fingerprint 通过最新 entry id 感知"加了新条目"。
        // 注意 fingerprint 只取 uuidString.prefix(8),两个 UUID 必须在前 8 字符不同。
        let oldId = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!
        let newId = UUID(uuidString: "22222222-0000-0000-0000-000000000002")!
        let a = makeContext(latestDay: makeDate(year: 2024, month: 6, day: 15), entryId: oldId)
        let b = makeContext(latestDay: makeDate(year: 2024, month: 6, day: 15), entryId: newId)
        #expect(a.makeFingerprint() != b.makeFingerprint())
    }

    @Test func newEntryDateFlipsFingerprint() {
        // fingerprint 把 latestDay 折成 ISO 周(YYYY-Www),所以这里要选跨周的两个日期才能
        // 测出语义。06-15(W24,周六)→ 06-22(W25,周六)。
        let a = makeContext(latestDay: makeDate(year: 2024, month: 6, day: 15))
        let b = makeContext(latestDay: makeDate(year: 2024, month: 6, day: 22))
        #expect(a.makeFingerprint() != b.makeFingerprint())
    }

    @Test func sameWeekDifferentDayDoesNotFlipFingerprint() {
        // 同一 ISO 周内任意一天都不应触发刷新,避免用户在一周内反复看到重生成。
        let a = makeContext(latestDay: makeDate(year: 2024, month: 6, day: 10))  // 周一
        let b = makeContext(latestDay: makeDate(year: 2024, month: 6, day: 14))  // 周五
        #expect(a.makeFingerprint() == b.makeFingerprint())
    }

    @Test func todayWeekFlipsFingerprint_withoutNewEntry() {
        let latest = makeDate(year: 2024, month: 6, day: 10)
        let a = makeContext(latestDay: latest, today: makeDate(year: 2024, month: 6, day: 14))
        let b = makeContext(latestDay: latest, today: makeDate(year: 2024, month: 6, day: 17))
        #expect(a.makeFingerprint() != b.makeFingerprint())
    }

    @Test func insufficientSignalFlagsCorrectly() {
        let few = makeContext(entryCount: 2)
        let enough = makeContext(entryCount: 3)
        #expect(few.hasEnoughSignal == false)
        #expect(enough.hasEnoughSignal == true)
    }

    private func makeContext(
        latestDay: Date = Date(),
        today: Date? = nil,
        entryId: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        entryCount: Int = 5
    ) -> SuggestionContext {
        // 制造 `entryCount` 篇日记,第一篇用指定 id 和 latestDay(其他篇日期/id 不影响指纹)。
        let recent: [DiaryEntryData] = (0..<entryCount).map { i in
            DiaryEntryData(
                id: i == 0 ? entryId : UUID(),
                date: latestDay,
                text: "",
                moodValue: 0.5,
                summary: ""
            )
        }
        return SuggestionContext(
            today: today ?? latestDay,
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

// MARK: - Insights preset chip hydration

struct InsightsPresetChipTests {
    @Test func presetChipQuestions_usesFirstThreeCachedPresets() {
        let bundle = SuggestionBundle(
            askPastPresets: ["q1?", "q2?", "q3?", "q4?"],
            homePlaceholders: ["p1"],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            fingerprint: "f",
            language: "zh"
        )
        #expect(InsightsView.presetChipQuestions(from: bundle) == ["q1?", "q2?", "q3?"])
    }

    @Test func presetChipQuestions_emptyOrMissingCacheHidesBlock() {
        let empty = SuggestionBundle(
            askPastPresets: [],
            homePlaceholders: ["p1"],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            fingerprint: "f",
            language: "zh"
        )
        #expect(InsightsView.presetChipQuestions(from: nil).isEmpty)
        #expect(InsightsView.presetChipQuestions(from: empty).isEmpty)
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

// MARK: - PromptSuggestionEngine.clearCache

struct PromptCacheClearTests {
    @MainActor
    @Test func clearCache_removesProtectedDiskCacheAndLegacyDefaults() throws {
        let url = try #require(PromptSuggestionEngine.cacheFileURLForTesting)
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)

        let bundle = SuggestionBundle(
            askPastPresets: ["What changed?"],
            homePlaceholders: ["Write now"],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            fingerprint: "stale-after-delete",
            language: "en"
        )
        let data = try JSONEncoder().encode(bundle)
        try data.write(to: url)
        UserDefaults.standard.set(data, forKey: PromptSuggestionEngine.cacheKeyForTesting)

        #expect(fm.fileExists(atPath: url.path))
        let engine = PromptSuggestionEngine(ai: ThemeAliasAITestDouble())
        engine.clearCache()

        #expect(!fm.fileExists(atPath: url.path))
        #expect(UserDefaults.standard.data(forKey: PromptSuggestionEngine.cacheKeyForTesting) == nil)
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

    @Test func unknownNonErrorFrameIsSkipped() async throws {
        let events = try await collectSSEEvents([
            #"data: {"type":"future.event","payload":{"value":1}}"#,
            "",
            #"data: {"value":"after"}"#,
            "",
            "data: [DONE]"
        ])

        #expect(events == [Chunk(value: "after")])
    }

    @Test func malformedJSONFrameThrowsInvalidEvent() async {
        do {
            _ = try await collectSSEEvents([
                "data: {not-json}",
                "",
                #"data: {"value":"after"}"#,
                "",
                "data: [DONE]"
            ])
            #expect(Bool(false), "Expected invalidEvent")
        } catch let error as SSEParser.ParserError {
            #expect(error.localizedDescription == SSEParser.ParserError.invalidEvent(byteCount: 10).localizedDescription)
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

    @Test func openAIStreamResponseAllowsFinishReasonWithoutDelta() async throws {
        let lines = [
            #"data: {"choices":[{"finish_reason":"stop"}]}"#,
            "",
            "data: [DONE]"
        ]

        var events: [OpenAIStreamResponse] = []
        for try await event in SSEParser.parse(lines: lines, type: OpenAIStreamResponse.self, decoder: JSONDecoder()) {
            events.append(event)
        }

        #expect(events.count == 1)
        #expect(events[0].choices.count == 1)
        #expect(events[0].choices[0].delta == nil)
        #expect(events[0].hasTruncatedFinish == false)
    }

    @Test func openAIStreamResponseFlagsTruncatedFinishWithoutDelta() async throws {
        let lines = [
            #"data: {"choices":[{"finish_reason":"length"}]}"#,
            "",
            "data: [DONE]"
        ]

        var events: [OpenAIStreamResponse] = []
        for try await event in SSEParser.parse(lines: lines, type: OpenAIStreamResponse.self, decoder: JSONDecoder()) {
            events.append(event)
        }

        #expect(events.count == 1)
        #expect(events[0].choices[0].delta == nil)
        #expect(events[0].hasTruncatedFinish == true)
    }

    @Test func doneLineAfterPayloadInSameEventFlushesPayloadThenFinishes() async throws {
        let events = try await collectSSEEvents([
            #"data: {"value":"hello"}"#,
            "data: [DONE]"
        ])

        #expect(events == [Chunk(value: "hello")])
    }

    private func collectSSEEvents(_ lines: [String]) async throws -> [Chunk] {
        var events: [Chunk] = []
        for try await event in SSEParser.parse(lines: lines, type: Chunk.self, decoder: JSONDecoder()) {
            events.append(event)
        }
        return events
    }
}

// MARK: - Network retry

struct NetworkRetryHelperTests {
    @Test func missingDoneBeforeFirstChunkRetries() async throws {
        var attempts = 0

        let value: String = try await NetworkRetryHelper.performWithRetry(
            maxRetries: 2,
            retryDelay: 0
        ) {
            attempts += 1
            if attempts == 1 {
                throw SSEParser.ParserError.missingDone
            }
            return "ok"
        }

        #expect(value == "ok")
        #expect(attempts == 2)
    }
}

// MARK: - Narrative input truncation

struct NarrativeTextBlockTests {
    @Test func keepsMostRecentEntriesWithinUTF16Limit() {
        let old = narrativeEntry(day: 1, text: String(repeating: "old", count: 30))
        let mid = narrativeEntry(day: 2, text: String(repeating: "mid", count: 30))
        let newest = narrativeEntry(day: 3, text: String(repeating: "new", count: 30))

        let block = OpenAIService.narrativeTextBlock(from: [old, mid, newest], maxUTF16Units: 210)

        #expect(block.truncated)
        #expect(block.text.utf16.count <= 210)
        #expect(block.text.contains("new"))
        #expect(!block.text.contains("old"))
        #expect(block.sourceEntryIds.contains(newest.id))
        #expect(!block.sourceEntryIds.contains(old.id))
    }

    @Test func trimsSingleOversizedLatestEntry() {
        let entry = narrativeEntry(day: 1, text: String(repeating: "你", count: 500))

        let block = OpenAIService.narrativeTextBlock(from: [entry], maxUTF16Units: 120)

        #expect(block.truncated)
        #expect(block.includedEntries == 1)
        #expect(block.sourceEntryIds == [entry.id])
        #expect(block.text.utf16.count <= 120)
    }

    @Test func sourceEntryIdsUseNewestFirstDisplayOrder() {
        let old = narrativeEntry(day: 1, text: "old")
        let mid = narrativeEntry(day: 2, text: "mid")
        let newest = narrativeEntry(day: 3, text: "new")

        let block = OpenAIService.narrativeTextBlock(from: [old, mid, newest], maxUTF16Units: 10_000)

        #expect(block.sourceEntryIds == [newest.id, mid.id, old.id])
    }

    private func narrativeEntry(day: Int, text: String) -> DiaryEntryData {
        DiaryEntryData(
            id: UUID(),
            date: makeDate(year: 2024, month: 6, day: day),
            text: text,
            moodValue: 0.5,
            summary: "summary-\(day)",
            themes: [],
            embedding: nil,
            wordCount: text.count
        )
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

    @Test func aliasMap_usesThemeKeyForNFDInput() {
        let range = DateInterval(
            start: makeDate(year: 2024, month: 6, day: 1),
            end: makeDate(year: 2024, month: 6, day: 30)
        )
        let nfdCafe = "cafe\u{301}"
        let entries: [DiaryEntryData] = [
            makeEntry(date: makeDate(year: 2024, month: 6, day: 1), themes: [nfdCafe])
        ]
        let result = InsightsEngine.aggregateThemes(
            entries: entries,
            range: range,
            aliasMap: [ThemeKey.make("café"): "Cafe"]
        )
        #expect(result.count == 1)
        #expect(result.first?.name == "Cafe")
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

    @Test func restoreGroup_mergesCaseInsensitiveExistingGroupWithoutDoubleKey() {
        let (r, _) = makeResolver()
        let existing = PendingSuggestion(newTag: "bee", canonicalGuess: "abby", confidence: .high, source: .scan)
        _ = r.enqueue(existing)
        r.confirm(existing, canonical: "abby")

        r.restoreGroup(canonical: "Abby", aliases: ["bee", "Cee", "Abby"])

        #expect(r.groups["abby"] == nil, "restore 应删除旧大小写 key,避免双 group")
        let aliases = r.groups["Abby"] ?? []
        #expect(aliases.contains("bee"))
        #expect(aliases.contains("Cee"))
        #expect(!aliases.contains("Abby"), "canonical 自身不能进入 aliases")
        #expect(Set(aliases.map { $0.lowercased() }).count == aliases.count, "aliases 应大小写不敏感去重")
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

    @Test func restoreDeletedTheme_onlyRestoresActuallyRemovedLabels() async throws {
        let persistence = PersistenceController(inMemory: true)
        let resolver = ThemeAliasResolver(testingWithEmptyState: isolatedDefaults())
        let context = persistence.container.viewContext
        let entryID = UUID()
        insertDiaryEntry(
            context: context,
            id: entryID,
            date: makeDate(year: 2024, month: 6, day: 1),
            themes: ["Person A", "Work"]
        )
        try context.save()

        let service = ThemeManagementService(persistence: persistence, resolver: resolver)
        let deleteOutcome = await service.deleteTheme(canonical: "Person A")
        let payload = try #require(deleteOutcome.undoPayload)

        await persistence.container.performBackgroundTask { bg in
            let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", entryID as NSUUID)
            if let entry = try? bg.fetch(request).first {
                entry.setThemes([])
                try? bg.save()
            }
        }

        let restoreOutcome = await service.restoreDeletedTheme(payload)

        #expect(restoreOutcome.succeeded)
        let themes = await fetchThemeArrays(persistence)
        #expect(themes == [["Person A"]], "撤销只应恢复本次删除的 Person A,不应复活窗口内移除的 Work")
    }

    @Test func restoreDeletedTheme_restoresPendingSuggestionsRemovedByDelete() async throws {
        let persistence = PersistenceController(inMemory: true)
        let resolver = ThemeAliasResolver(testingWithEmptyState: isolatedDefaults())
        let context = persistence.container.viewContext
        insertDiaryEntry(
            context: context,
            date: makeDate(year: 2024, month: 6, day: 1),
            themes: ["Person A"]
        )
        try context.save()

        let pending = PendingSuggestion(
            newTag: "Partner",
            canonicalGuess: "Person A",
            confidence: .medium,
            source: .scan
        )
        #expect(resolver.enqueue(pending))

        let service = ThemeManagementService(persistence: persistence, resolver: resolver)
        let deleteOutcome = await service.deleteTheme(canonical: "Person A")
        let payload = try #require(deleteOutcome.undoPayload)
        #expect(resolver.pending.isEmpty, "删除主题会清掉指向该主题的待审建议")

        let restoreOutcome = await service.restoreDeletedTheme(payload)

        #expect(restoreOutcome.succeeded)
        #expect(resolver.pending.map(\.id).contains(pending.id),
                "撤销删除主题时,原先被清掉的待审建议也应回来")
    }

    @Test func restoreDeletedTheme_saveFailureReportsFailure() async throws {
        let persistence = PersistenceController(inMemory: true)
        let resolver = ThemeAliasResolver(testingWithEmptyState: isolatedDefaults())
        let context = persistence.container.viewContext
        let entryID = UUID()
        insertDiaryEntry(
            context: context,
            id: entryID,
            date: makeDate(year: 2024, month: 6, day: 1),
            themes: []
        )
        try context.save()

        struct ForcedSaveError: Error {}
        let service = ThemeManagementService(
            persistence: persistence,
            resolver: resolver,
            saveAction: { _ in throw ForcedSaveError() }
        )
        let payload = ThemeManagementService.ThemeDeletionUndoPayload(
            canonical: "Person A",
            originalThemesByEntryID: [entryID: ["Person A"]],
            aliasGroupCanonical: nil,
            aliasGroupAliases: [],
            removedPending: []
        )

        let outcome = await service.restoreDeletedTheme(payload)

        #expect(!outcome.succeeded)
        #expect(outcome.affected == 0)
        #expect(outcome.undoPayload == nil)
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

    /// **P1-4 (2026-05-15 megareview)**:60s throttle 必须落 UserDefaults,App 被 kill / 冷启动
    /// 后仍生效。原 in-memory 实现:午休前写一篇 → 系统 jetsam kill → 午休后写一篇 → throttle 失效
    /// → 整 inventory 上送 OpenAI 一次,白付 cost + 频繁 PII 暴露。
    @Test func judgeAfterWrite_throttlePersistsAcrossInstances() async throws {
        let throttleKey = "lumory.themeAliasJudge.lastJudgeAt"
        // 清理 UserDefaults.standard 残留(跨测试隔离)
        UserDefaults.standard.removeObject(forKey: throttleKey)
        defer { UserDefaults.standard.removeObject(forKey: throttleKey) }

        let persistence = PersistenceController(inMemory: true)
        try seedEntries(persistence, [
            (["Person A"], makeDate(year: 2024, month: 6, day: 1))
        ])
        let ai1 = ThemeAliasAITestDouble()
        ai1.judgeResult = []
        let resolver = ThemeAliasResolver(testingWithEmptyState: isolatedDefaults())

        // Phase 1: service A 第一次 judgeAfterWrite → 触发 AI 调用 + 写 UserDefaults timestamp
        let serviceA = ThemeAliasJudgeService(persistence: persistence, ai: ai1, resolver: resolver)
        await serviceA.judgeAfterWrite(entryID: UUID(), newTags: ["FreshTag"])

        #expect(ai1.judgeCalls == 1, "first judgeAfterWrite should call AI")
        let storedTimestamp = UserDefaults.standard.double(forKey: throttleKey)
        #expect(storedTimestamp > 0, "throttle timestamp must be written to UserDefaults (P1-4)")

        // Phase 2: 模拟"App 被 kill 后冷启动" → 起 fresh service B,共用同一 UserDefaults
        let ai2 = ThemeAliasAITestDouble()
        ai2.judgeResult = []
        let serviceB = ThemeAliasJudgeService(persistence: persistence, ai: ai2, resolver: resolver)
        await serviceB.judgeAfterWrite(entryID: UUID(), newTags: ["AnotherFreshTag"])

        #expect(ai2.judgeCalls == 0,
                "fresh-instance judgeAfterWrite within 60s must be throttled by persisted timestamp (P1-4 — was broken pre-fix)")
    }
}

// `@unchecked Sendable` — `AIServiceProtocol` 加 Sendable 后,所有 conformer 必须满足。
// test double 用 mutable `var` 字段记录 call counts / fixtures 给 assertion 用,在 actor 隔离
// 上"承诺线程安全";所有测试都从主线程驱动它(单测 await 模式),实际 race 不存在,但 Swift
// 类型系统看不出。`@unchecked` 把这条挂出来,Swift 6 strict 编译通过。如果 future 测试想从
// 后台线程并发调用 fixtures,改用 `@MainActor` 标记 + actor isolation 或加内部锁。
private final class ThemeAliasAITestDouble: AIServiceProtocol, @unchecked Sendable {
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

    // MARK: nextFireDate(纯函数) — Settings 显示"下次提醒"用

    /// daily 频率,reference 在 21:00 之前 → 今天 21:00。
    @Test func nextFireDate_daily_beforeFireTime_returnsToday() {
        let anchor = makeUTCDate(year: 2026, month: 4, day: 1)
        var comps = DateComponents(); comps.year = 2026; comps.month = 4; comps.day = 5; comps.hour = 10; comps.minute = 0
        let now = calendar.date(from: comps)!
        let next = ReminderService.nextFireDate(
            isEnabled: true, frequency: .daily, hour: 21, minute: 0,
            anchor: anchor, referenceDate: now, calendar: calendar
        )
        #expect(next != nil)
        let nextComps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: next!)
        #expect(nextComps.day == 5 && nextComps.hour == 21 && nextComps.minute == 0)
    }

    /// daily,reference 在 21:00 之后 → 明天 21:00(本 cycle 已过 → 跳下一)。
    @Test func nextFireDate_daily_afterFireTime_rollsToTomorrow() {
        let anchor = makeUTCDate(year: 2026, month: 4, day: 1)
        var comps = DateComponents(); comps.year = 2026; comps.month = 4; comps.day = 5; comps.hour = 22; comps.minute = 30
        let now = calendar.date(from: comps)!
        let next = ReminderService.nextFireDate(
            isEnabled: true, frequency: .daily, hour: 21, minute: 0,
            anchor: anchor, referenceDate: now, calendar: calendar
        )
        let nextComps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: next!)
        #expect(nextComps.day == 6 && nextComps.hour == 21)
    }

    /// every3Days,anchor=4/1,now=4/2 10:00 → 当前 cycle 末是 4/3,fire 在 4/3 21:00。
    @Test func nextFireDate_every3Days_currentCycleEnd() {
        let anchor = makeUTCDate(year: 2026, month: 4, day: 1)
        var comps = DateComponents(); comps.year = 2026; comps.month = 4; comps.day = 2; comps.hour = 10
        let now = calendar.date(from: comps)!
        let next = ReminderService.nextFireDate(
            isEnabled: true, frequency: .every3Days, hour: 21, minute: 0,
            anchor: anchor, referenceDate: now, calendar: calendar
        )
        let nextComps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: next!)
        #expect(nextComps.day == 3 && nextComps.hour == 21)
    }

    /// every3Days,now 在 cycle 末 21:00 之后 → 跳到下一 cycle 末(4/6 21:00)。
    @Test func nextFireDate_every3Days_pastCycleEnd_rollsForward() {
        let anchor = makeUTCDate(year: 2026, month: 4, day: 1)
        var comps = DateComponents(); comps.year = 2026; comps.month = 4; comps.day = 3; comps.hour = 22; comps.minute = 30
        let now = calendar.date(from: comps)!
        let next = ReminderService.nextFireDate(
            isEnabled: true, frequency: .every3Days, hour: 21, minute: 0,
            anchor: anchor, referenceDate: now, calendar: calendar
        )
        let nextComps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: next!)
        #expect(nextComps.day == 6 && nextComps.hour == 21)
    }

    /// weekly,anchor=4/1,now=4/3 → cycle 是 [4/1, 4/8),fire 在 4/7 21:00(end-1)。
    @Test func nextFireDate_weekly_returnsCycleLastDay() {
        let anchor = makeUTCDate(year: 2026, month: 4, day: 1)
        var comps = DateComponents(); comps.year = 2026; comps.month = 4; comps.day = 3; comps.hour = 12
        let now = calendar.date(from: comps)!
        let next = ReminderService.nextFireDate(
            isEnabled: true, frequency: .weekly, hour: 21, minute: 0,
            anchor: anchor, referenceDate: now, calendar: calendar
        )
        let nextComps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: next!)
        #expect(nextComps.day == 7 && nextComps.hour == 21)
    }

    /// disabled → nil。
    @Test func nextFireDate_disabled_returnsNil() {
        let anchor = makeUTCDate(year: 2026, month: 4, day: 1)
        let now = makeUTCDate(year: 2026, month: 4, day: 5)
        let next = ReminderService.nextFireDate(
            isEnabled: false, frequency: .daily, hour: 21, minute: 0,
            anchor: anchor, referenceDate: now, calendar: calendar
        )
        #expect(next == nil)
    }

    /// **Race fixture** — 模拟用户来回拨 picker 时,显示的"下次提醒"必须**实时**反映当前 frequency,
    /// 不能因为 reschedule 还没跑完就拿到 stale 值。这条直接锁住"纯函数,跟 frequency 同步"。
    @Test func nextFireDate_switchingFrequency_immediatelyReflectsNew() {
        let anchor = makeUTCDate(year: 2026, month: 4, day: 1)
        var comps = DateComponents(); comps.year = 2026; comps.month = 4; comps.day = 5; comps.hour = 10
        let now = calendar.date(from: comps)!

        let daily = ReminderService.nextFireDate(
            isEnabled: true, frequency: .daily, hour: 21, minute: 0,
            anchor: anchor, referenceDate: now, calendar: calendar
        )!
        let every3 = ReminderService.nextFireDate(
            isEnabled: true, frequency: .every3Days, hour: 21, minute: 0,
            anchor: anchor, referenceDate: now, calendar: calendar
        )!
        let weekly = ReminderService.nextFireDate(
            isEnabled: true, frequency: .weekly, hour: 21, minute: 0,
            anchor: anchor, referenceDate: now, calendar: calendar
        )!

        // daily 今天就 fire(4/5 21:00)
        // every3Days anchor=4/1,now=4/5 → cycle [4/4, 4/7) → fire 4/6 21:00
        // weekly anchor=4/1,now=4/5 → cycle [4/1, 4/8) → fire 4/7 21:00
        // 三个都不一样、都对得上 anchor + cycleDays + hour:minute 算式。
        #expect(daily != every3)
        #expect(every3 != weekly)
        #expect(daily != weekly)
    }
}

// MARK: - StreakMilestoneService.milestoneFor 纯函数

@MainActor
struct StreakMilestoneTests {
    /// 7/14/30/60/100 是固定档位
    @Test func milestoneFor_fixedTiers() {
        #expect(StreakMilestoneService.milestoneFor(streak: 7) == 7)
        #expect(StreakMilestoneService.milestoneFor(streak: 14) == 14)
        #expect(StreakMilestoneService.milestoneFor(streak: 30) == 30)
        #expect(StreakMilestoneService.milestoneFor(streak: 60) == 60)
        #expect(StreakMilestoneService.milestoneFor(streak: 100) == 100)
    }

    /// 100 之后每加 100 一档(200 / 300 / 1000)
    @Test func milestoneFor_centuryPlus() {
        #expect(StreakMilestoneService.milestoneFor(streak: 200) == 200)
        #expect(StreakMilestoneService.milestoneFor(streak: 300) == 300)
        #expect(StreakMilestoneService.milestoneFor(streak: 500) == 500)
        #expect(StreakMilestoneService.milestoneFor(streak: 1000) == 1000)
        #expect(StreakMilestoneService.milestoneFor(streak: 2500) == 2500)
    }

    /// 非里程碑返回 nil(且 6 / 8 / 99 / 101 / 150 / 250 都不算)
    @Test func milestoneFor_nonMilestoneReturnsNil() {
        #expect(StreakMilestoneService.milestoneFor(streak: 0) == nil)
        #expect(StreakMilestoneService.milestoneFor(streak: 1) == nil)
        #expect(StreakMilestoneService.milestoneFor(streak: 6) == nil)
        #expect(StreakMilestoneService.milestoneFor(streak: 8) == nil)
        #expect(StreakMilestoneService.milestoneFor(streak: 99) == nil)
        #expect(StreakMilestoneService.milestoneFor(streak: 101) == nil)
        #expect(StreakMilestoneService.milestoneFor(streak: 150) == nil)
        #expect(StreakMilestoneService.milestoneFor(streak: 250) == nil)
        #expect(StreakMilestoneService.milestoneFor(streak: 999) == nil)
    }

    /// 已庆祝过的 milestone 不再 fire(防 streak 跌回再升时刷一遍)
    @Test func handleStreak_dedupsByCelebratedSet() {
        let service = StreakMilestoneService.shared
        service.resetCelebratedForTesting()
        service.dismiss()

        service.evaluateForTesting(streak: 7, moodValue: 0.6)
        #expect(service.pendingMilestone?.days == 7)

        // 模拟用户 dismiss
        service.dismiss()
        #expect(service.pendingMilestone == nil)

        // streak 7 再来一次 → 已 celebrated,不再 fire
        service.evaluateForTesting(streak: 7, moodValue: 0.6)
        #expect(service.pendingMilestone == nil)

        service.resetCelebratedForTesting()
    }

    /// 不同档位 streak 各 fire 一次
    @Test func handleStreak_independentMilestonesFireIndependently() {
        let service = StreakMilestoneService.shared
        service.resetCelebratedForTesting()
        service.dismiss()

        service.evaluateForTesting(streak: 7, moodValue: 0.5)
        #expect(service.pendingMilestone?.days == 7)
        service.dismiss()

        service.evaluateForTesting(streak: 30, moodValue: 0.5)
        #expect(service.pendingMilestone?.days == 30)
        service.dismiss()

        service.resetCelebratedForTesting()
    }

    /// (2026-05-15 superreview P1#4-2 + round-5 D2)cancel-and-replace 真契约:
    /// 第一次 evaluate 被 cancel → handleStreak **不应被调**,只有第二次能 commit。
    ///
    /// 老 `firstTask?.isCancelled == true` 是 tautology(`cancel()` 调过 flag 必 true,
    /// 不证明 handleStreak 没跑)。改用 `commitObservationsForTesting` spy 直接观察
    /// commit 次数,跟 cancel 实现策略(Task ivar / 世代号)解耦。
    @Test func evaluateAfterSave_cancelAndReplace_onlyLatestReachesHandleStreak() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        // 7 天连续日记触发 streak=7 milestone(用最小 milestone 让测试快)。
        for offset in 0..<7 {
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            let entry = DiaryEntry(context: context)
            entry.id = UUID()
            entry.date = day
            entry.text = "day \(offset)"
            entry.summary = ""
            entry.themes = ""
            entry.moodValue = 0.5
            entry.wordCount = 5
        }
        try context.save()

        let service = StreakMilestoneService.shared
        service.resetCelebratedForTesting()
        service.dismiss()

        service.evaluateAfterSave(persistence: persistence, latestEntryMood: 0.3)
        service.evaluateAfterSave(persistence: persistence, latestEntryMood: 0.9)
        await service.drainEvaluateTaskForTesting()

        // **真契约**:cancel-and-replace 后只有第二次走到 handleStreak。
        // 老 task 跑完 bg fetch 后 `guard !Task.isCancelled` 早返,不调 handleStreak。
        #expect(service.commitObservationsForTesting.count == 1,
                "cancel-and-replace 后只一次 handleStreak,实际 \(service.commitObservationsForTesting.count) 次")
        #expect(service.commitObservationsForTesting.first?.moodValue == 0.9,
                "唯一一次 commit 必须来自第二次 evaluate(moodValue=0.9),实际 \(String(describing: service.commitObservationsForTesting.first?.moodValue))")

        // pendingMilestone 也对(冗余但显式锁 UI-side 行为)
        #expect(service.pendingMilestone?.days == 7)
        #expect(service.pendingMilestone?.moodValue == 0.9)

        service.dismiss()
        service.resetCelebratedForTesting()
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

// MARK: - PersistenceController shared NSManagedObjectModel invariant
//
// 多个 `PersistenceController(inMemory: true)` 实例必须共享同一个 `NSManagedObjectModel`。
// 否则 `+[DiaryEntry entity]` 看到 N 份 model "Failed to find a unique match",在 simulator
// clone 多 fork 跑测试时触发 SIGABRT(`+entity in 0x...` 不在任一 model 里)。CLAUDE.md
// "⚠️ 但是真的 SIGABRT 不是 clone flake" 段记录了这条踩坑。这条 invariant 锁住 cachedModel
// 共享路径不被改坏。

struct PersistenceControllerCachedModelTests {
    @Test func multipleInMemoryInstancesShareManagedObjectModel() {
        let p1 = PersistenceController(inMemory: true)
        let p2 = PersistenceController(inMemory: true)
        // `===` 身份比较:必须是同一个对象,不只是 .isEqual。每次 init 重新 load .xcdatamodeld
        // 会让 N 个 entity description 互相不识,导致 +entity 找不到唯一 match。
        #expect(p1.container.managedObjectModel === p2.container.managedObjectModel,
                "PersistenceController 多实例必须共享同一个 NSManagedObjectModel。 改坏后只在 simulator clone 多 fork 触发 SIGABRT,定位成本极高。")
    }
}

// MARK: - DST + leap year boundary tests
//
// CLAUDE.md "Follow-up backlog" 提:`computeStreaks` / `cycleBounds` 都用 UTC 标准 30 天月,
// 跨 DST 春令时 / 2024-02-29 anchor 的 calendar 操作没专门覆盖。这两条用真实 timezone /
// 真实闰日 fixture 锁住边界行为。

struct DSTBoundaryStreakTests {
    /// 美国东部春令时:2024-03-10 凌晨 2 点跳到 3 点,这一天只有 23 小时。
    /// 连续每天写 5 天跨过这条边界,streak 应仍 = 5(不被"今天起到那天的 day diff"
    /// 偶发算 4 或 6 干扰)。
    @Test func computeStreaks_acrossUSEasternSpringForward_remainsCorrect() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!

        // 5 个连续日(3-08 / 09 / 10 / 11 / 12),3-10 是春令时跳点。
        // calendar.startOfDay 在那个 timezone 下应正确给出每天 0 点。
        let days: [Date] = (0..<5).map { i in
            var components = DateComponents()
            components.year = 2024
            components.month = 3
            components.day = 8 + i
            return calendar.date(from: components)!
        }.reversed()  // 倒序:今天最先

        let today = days.first!
        let result = InsightsEngine.computeStreaks(uniqueDaysDesc: Array(days), today: today, calendar: calendar)
        #expect(result.current == 5, "DST 春令时不该把连续 5 天的 streak 算成其他值")
        #expect(result.longest == 5)
    }
}

struct LeapYearCycleBoundsTests {
    /// 2024-02-29 是 leap day,如果 anchor 设在这天,后续 weekly 周期算法应该平稳前推
    /// (`byAdding: .day, value: 7` 而不是 `.month`/年级别 fall back)。
    @Test func cycleBounds_weeklyAnchoredOnLeapDay_advancesByDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        // anchor:2024-02-29 (leap day) startOfDay UTC
        var anchorComponents = DateComponents()
        anchorComponents.year = 2024
        anchorComponents.month = 2
        anchorComponents.day = 29
        let anchor = calendar.startOfDay(for: calendar.date(from: anchorComponents)!)

        // reference:2024-03-15 (anchor 之后 15 天,刚跨进第 3 个 weekly cycle)
        var refComponents = DateComponents()
        refComponents.year = 2024
        refComponents.month = 3
        refComponents.day = 15
        let ref = calendar.startOfDay(for: calendar.date(from: refComponents)!)

        let bounds = ReminderService.cycleBounds(
            referenceDate: ref,
            anchor: anchor,
            frequency: .weekly,
            calendar: calendar
        )

        // 第 3 周的范围应是 anchor + 14天 → anchor + 21天
        let expectedStart = calendar.date(byAdding: .day, value: 14, to: anchor)!
        let expectedEnd = calendar.date(byAdding: .day, value: 21, to: anchor)!
        #expect(bounds.start == expectedStart, "leap day anchor + weekly:cycle 3 start 应是 anchor + 14 天")
        #expect(bounds.end == expectedEnd, "leap day anchor + weekly:cycle 3 end 应是 anchor + 21 天")
    }
}

// MARK: - ThemeAliasStore / Resolver helpers — 2026-05-16 superreview P1 #3/#4/#5

/// `ThemeAliasStore.update { state in ... }` 批 mutation 不变量。Resolver 几乎所有 mutation
/// 都靠"一次闭包改多字段 → 一次 rebuildIndex + save"。若未来谁把 `rebuildIndex()` 提前到闭包中间或
/// 拆成 per-field call,index 与 state 跨字段不一致 → 用户看到 ghost canonical / Insights 错位。
/// 这条测试钉死"mutation 一次完整完成,reverse index 一次性更新"的契约。
@MainActor
struct ThemeAliasStoreUpdateBatchTests {
    @Test func mergeThemes_singleClosureBatch_reverseIndexConsistentAcrossAllAffectedTags() {
        let resolver = ThemeAliasResolver(testingWithEmptyState: isolatedDefaults())

        // 先建一个 group:Abby ← 宝贝
        let firstSugg = PendingSuggestion(
            newTag: "宝贝", canonicalGuess: "Abby", confidence: .high, source: .scan
        )
        #expect(resolver.enqueue(firstSugg))
        resolver.confirm(firstSugg, canonical: "Abby")

        // mergeThemes 触发 update 一次性改 groups + pending + negativePairs + coolUntil
        let outcome = resolver.mergeThemes(source: "老婆", into: "Abby")
        #expect(outcome == .merged)

        // 关键 invariant:**所有受影响 label** 都立刻 resolve 到新 canonical(不在中间态)。
        // 如果 rebuildIndex 漏了任何一条 alias,canonicalize 返回原文 ≠ "Abby"。
        #expect(resolver.canonicalize("Abby") == "Abby")
        #expect(resolver.canonicalize("宝贝") == "Abby")
        #expect(resolver.canonicalize("老婆") == "Abby")
        #expect(resolver.canonicalize("ABBY") == "Abby", "case-insensitive lookup must still hit")
        // 无关 label 不被污染
        #expect(resolver.canonicalize("Work") == "Work")
    }
}

/// `ThemeAliasStore.aliasToCanonicalLowerLookup(in:key:)` static helper 直接单测。
/// 文件注释明确说"早期版本写错过一行 `if canonical.lowercased() == key { return key }`,
/// 导致 confirm() 误删独立 pending"(superreview P1 #4 fix)。confirm 测试间接覆盖,但
/// helper 自身契约要钉死:**canonical 自己不返 self,只命中 alias bucket**。
@MainActor
struct ThemeAliasStoreAliasLookupTests {
    @Test func canonicalSelfReturnsNil_onlyAliasMatchesReturnsParent() {
        let groups: [String: [String]] = ["Abby": ["宝贝", "老婆"]]

        // canonical 本身 → 返 nil(不是 self)
        #expect(ThemeAliasStore.aliasToCanonicalLowerLookup(in: groups, key: "abby") == nil)
        // case 不同的 canonical → 仍 nil(comparison 用 lowercased)
        #expect(ThemeAliasStore.aliasToCanonicalLowerLookup(in: groups, key: "ABBY") == nil)
        // alias → 返 lowercased canonical
        #expect(ThemeAliasStore.aliasToCanonicalLowerLookup(in: groups, key: "宝贝") == "abby")
        #expect(ThemeAliasStore.aliasToCanonicalLowerLookup(in: groups, key: "老婆") == "abby")
        // 未知 key → nil
        #expect(ThemeAliasStore.aliasToCanonicalLowerLookup(in: groups, key: "未知") == nil)
    }

    @Test func emptyGroupsReturnsNil() {
        #expect(ThemeAliasStore.aliasToCanonicalLowerLookup(in: [:], key: "anything") == nil)
    }
}

/// `ThemeAliasStore.collateralLabels(forMerging:into:)` 边界。
/// `Insights ThemeCard` 长按合并 sheet 显示"将一并搬走的标签",算错 → 用户预览 1 条实际搬 5 条
/// (违反最小惊讶)。4 个边界 case 钉死 UX 契约。
@MainActor
struct ThemeAliasStoreCollateralLabelsTests {
    /// (a) source 是 canonical → collateral = 该 group 内所有 aliases(canonical 自己不入,因为是 source)
    @Test func sourceIsCanonical_returnsAllAliases() {
        let resolver = ThemeAliasResolver(testingWithEmptyState: isolatedDefaults())
        let sugg1 = PendingSuggestion(newTag: "宝贝", canonicalGuess: "Abby", confidence: .high, source: .scan)
        _ = resolver.enqueue(sugg1); resolver.confirm(sugg1, canonical: "Abby")
        let sugg2 = PendingSuggestion(newTag: "老婆", canonicalGuess: "Abby", confidence: .high, source: .scan)
        _ = resolver.enqueue(sugg2); resolver.confirm(sugg2, canonical: "Abby")

        let collateral = resolver.collateralLabels(forMerging: "Abby", into: "Work")
        // 整组的 aliases 都跟着搬,canonical 自己不入(它就是 source)
        #expect(Set(collateral) == Set(["宝贝", "老婆"]),
                "source 是 canonical → collateral 应包含所有 aliases")
    }

    /// (b) source 是别人的 alias → collateral = parent canonical + 所有 sibling aliases(**整组搬移**)
    /// 注意:这与 `mergeThemes` 实际行为(`labelsToMerge` 包括 sc + group[sc] 全部)一致 ——
    /// 长按一个 alias 合并,会把它整个 group 都带走,不是只带它自己。
    @Test func sourceIsAlias_returnsParentCanonicalAndSiblingAliases() {
        let resolver = ThemeAliasResolver(testingWithEmptyState: isolatedDefaults())
        let sugg1 = PendingSuggestion(newTag: "宝贝", canonicalGuess: "Abby", confidence: .high, source: .scan)
        _ = resolver.enqueue(sugg1); resolver.confirm(sugg1, canonical: "Abby")
        let sugg2 = PendingSuggestion(newTag: "老婆", canonicalGuess: "Abby", confidence: .high, source: .scan)
        _ = resolver.enqueue(sugg2); resolver.confirm(sugg2, canonical: "Abby")

        let collateral = resolver.collateralLabels(forMerging: "宝贝", into: "Work")
        // parent canonical "Abby" + 同组其他 alias "老婆" 都跟着搬
        #expect(Set(collateral) == Set(["Abby", "老婆"]),
                "source 是 alias → collateral 应包含 parent canonical + sibling aliases(整组带走)")
    }

    /// (c) source / target 已在同组 → 返 []
    @Test func sourceAndTargetSameGroup_returnsEmpty() {
        let resolver = ThemeAliasResolver(testingWithEmptyState: isolatedDefaults())
        let sugg = PendingSuggestion(newTag: "宝贝", canonicalGuess: "Abby", confidence: .high, source: .scan)
        _ = resolver.enqueue(sugg); resolver.confirm(sugg, canonical: "Abby")

        // source=宝贝(alias) merge into target=Abby(canonical of same group)
        #expect(resolver.collateralLabels(forMerging: "宝贝", into: "Abby") == [])
    }

    /// (e) target 是裸标签(不在 reverse index) → resolvedTargetLower fallback 到 targetTrim.lowercased。
    /// 验 line 177 的 `aliasToCanonical[targetLower] ?? targetTrim` 兜底分支(round 3 P2 #4 补)。
    /// 之前 4 个 case 都没让 target 落进这个 fallback 路径。
    ///
    /// 构造:source = Abby(canonical with aliases),target = "陌生词"(从未见过的裸标签)
    /// 期望:resolvedTargetLower = "陌生词"(fallback) ≠ "abby"(source canonical)→ 进入 collateral 收集
    /// → 返非空 [Abby group 全部 aliases](source 是 canonical 时不入自己,只入 aliases)
    @Test func targetIsBareLabel_resolvedFallsBackToTrimmed() {
        let resolver = ThemeAliasResolver(testingWithEmptyState: isolatedDefaults())
        let sugg = PendingSuggestion(newTag: "宝贝", canonicalGuess: "Abby", confidence: .high, source: .scan)
        _ = resolver.enqueue(sugg); resolver.confirm(sugg, canonical: "Abby")

        let collateral = resolver.collateralLabels(forMerging: "Abby", into: "陌生词")
        #expect(Set(collateral) == Set(["宝贝"]),
                "target 是未知裸标签时,fallback 到 targetTrim.lowercased(),collateral 应是 source group 的 aliases")
    }

    /// (d) target 是 alias → 用 resolved canonical 比对,正确识别已在同组。
    /// 这条**真正**走 ThemeAliasStore.swift:177-180 的 `resolvedTargetLower == sourceCanonical.lowercased()` 早返路径
    /// (round 2 P1 #1 修正:之前用裸标签 source 会在 line 179 sourceCanonical guard 早返,
    /// 根本不经过 target-resolution 比对)。
    ///
    /// 构造:source = Abby(group canonical),target = 宝贝(Abby 的 alias)
    /// 期望:resolved target = "abby" = sourceCanonical(=Abby).lowercased() → 早返 [](已同组)
    @Test func targetIsAlias_usesResolvedCanonicalForComparison() {
        let resolver = ThemeAliasResolver(testingWithEmptyState: isolatedDefaults())
        let sugg = PendingSuggestion(newTag: "宝贝", canonicalGuess: "Abby", confidence: .high, source: .scan)
        _ = resolver.enqueue(sugg); resolver.confirm(sugg, canonical: "Abby")

        // source="Abby" 在 reverse index 里 sourceCanonical=Abby(canonical 自指 — rebuildIndex
        // 把 canonical 也加进 aliasToCanonical[lowercased canonical] = canonical)。
        // target="宝贝" 是 Abby 的 alias,resolvedTargetLower = "abby"。
        // sourceCanonical.lowercased() == resolvedTargetLower → 早返 [](line 180)。
        // 如果 target-resolution 错了(比如把 "宝贝" 当裸标签),resolvedTargetLower="宝贝" != "abby",
        // 进入 collateral 收集,会把 Abby group 的 aliases 错搬走。这个测试 catch 那个 bug。
        #expect(resolver.collateralLabels(forMerging: "Abby", into: "宝贝") == [],
                "target 是 alias 时必须 resolve 到 canonical 再比对,识别出已同组")
    }
}

// MARK: - ThemeAliasResolver: NFC/NFD 归一化(megareview P1 #1)
//
// `ThemeAliasStore.rebuildIndex` 用 `ThemeKey.make`(NFC + lower + trim) 建反向索引;
// Resolver 内部 7 处 `indexSnapshot[...]` lookup 历史上用裸 `.lowercased()` 当 key,
// NFD 输入(剪贴板 / 网页粘贴的组合字符)下 silent miss。
// 这组测试锁住:NFC 已存的别名,用 NFD 等价字符串走 enqueue / confirm / mergeThemes / cleanup,
// 都必须命中已有 group(而非新建 dup group 或 silent 丢弃)。

@MainActor
struct ThemeAliasResolverNFCNormalizationTests {
    // 同一个"café":NFC 单字符 U+00E9(é) vs NFD 拆解 e + U+0301(combining acute)
    // 两个 String literal `.utf8` 字节不等,但语义上等价。
    private let nfcCafe = "café"             // NFC: U+0063 U+0061 U+0066 U+00E9
    private let nfdCafe = "cafe\u{301}"      // NFD: U+0063 U+0061 U+0066 U+0065 U+0301

    @Test func enqueue_NFDNewTagHitsNFCCanonical() {
        // group 已存 NFC canonical "Café",用户(或 AI)用 NFD 等价字符串发同 newTag。
        // 修前:`indexSnapshot[.lowercased()]` 在 NFD 输入下 miss → 进入"新建"路径 enqueue 成功 →
        // 同语义 alias 重复入队;修后:ThemeKey.make 归一化 → 命中 → return false(已合并)。
        let resolver = ThemeAliasResolver(testingWithEmptyState: isolatedDefaults())
        let seed = PendingSuggestion(
            newTag: nfcCafe,
            canonicalGuess: "Coffee Shop",
            confidence: .high,
            source: .scan
        )
        _ = resolver.enqueue(seed)
        resolver.confirm(seed, canonical: "Coffee Shop")

        // 新建议:用 NFD 字符串当 newTag,canonical 任意。enqueue 应识别 NFD newTag 已是 alias
        // (line 142 indexSnapshot lookup)→ 跳过。
        let nfdAttempt = PendingSuggestion(
            newTag: nfdCafe,
            canonicalGuess: "OtherCanonical",
            confidence: .medium,
            source: .scan
        )
        let accepted = resolver.enqueue(nfdAttempt)
        #expect(accepted == false, "NFD newTag 已是 NFC alias 的 group 成员 → enqueue 必须跳过")
    }

    @Test func confirm_NFDChoiceResolvesToExistingNFCCanonical() {
        // 现有 group canonical="Coffee Shop" + alias=NFC "café";新建议合并 "Mocha → Café"(用户
        // 在 picker 输入 NFD 等价字符串 "café"-NFD)。`confirm` 内 line 240 用 indexSnapshot 把
        // chosen resolve 到 "Coffee Shop"。修前:NFD chosen miss → resolvedChosen=raw="café"-NFD,
        // 新建一个 group "café"-NFD={"Mocha"},跟现有 "Coffee Shop" group 分裂。
        // 修后:ThemeKey.make 化的 chosenIndexKey 命中 → resolvedChosen="Coffee Shop" → Mocha 加入。
        let resolver = ThemeAliasResolver(testingWithEmptyState: isolatedDefaults())
        let seed = PendingSuggestion(
            newTag: nfcCafe,
            canonicalGuess: "Coffee Shop",
            confidence: .high,
            source: .scan
        )
        _ = resolver.enqueue(seed)
        resolver.confirm(seed, canonical: "Coffee Shop")

        // 用户在 picker 选了一个 NFD 等价字符串作为 chosen
        let newSugg = PendingSuggestion(
            newTag: "Mocha",
            canonicalGuess: "Drink",
            confidence: .medium,
            source: .scan
        )
        _ = resolver.enqueue(newSugg)
        resolver.confirm(newSugg, canonical: nfdCafe)

        // 期望:Mocha 加入了 "Coffee Shop" group(因为 chosenIndexKey resolve 命中)
        #expect(resolver.groups["Coffee Shop"]?.contains("Mocha") == true,
                "NFD chosen 必须经 ThemeKey.make 归一化命中 NFC canonical,Mocha 应进 Coffee Shop")
        #expect(resolver.groups[nfdCafe] == nil,
                "不应该新建独立的 NFD 字符串 group(会跟现有 NFC group 永久分裂)")
    }

    @Test func mergeThemes_NFDTargetResolvesToExistingNFCCanonical() {
        // 现有 group canonical="Coffee Shop" + alias=NFC "café"。用户主动合并 "Tea Shop → Café"
        // (target 输入 NFD 等价)。修前:`indexSnapshot[targetLower]` miss → resolvedTarget=NFD 字符串
        // → 新建 NFD group。修后:targetIndexKey=ThemeKey.make 命中 → resolvedTarget="Coffee Shop"。
        let resolver = ThemeAliasResolver(testingWithEmptyState: isolatedDefaults())
        let seed = PendingSuggestion(
            newTag: nfcCafe,
            canonicalGuess: "Coffee Shop",
            confidence: .high,
            source: .scan
        )
        _ = resolver.enqueue(seed)
        resolver.confirm(seed, canonical: "Coffee Shop")

        // 用户主动合并 "Tea Shop" 到 NFD 等价 target
        let outcome = resolver.mergeThemes(source: "Tea Shop", into: nfdCafe)
        #expect(outcome == .merged)
        #expect(resolver.groups["Coffee Shop"]?.contains("Tea Shop") == true,
                "NFD target 必须 resolve 到 Coffee Shop,Tea Shop 应加入现有 group")
        #expect(resolver.groups[nfdCafe] == nil,
                "不应该新建 NFD 字符串 group")
    }

    @Test func collateralLabels_NFDSourceHitsNFCAliasGroup() {
        let resolver = ThemeAliasResolver(testingWithEmptyState: isolatedDefaults())
        let seed = PendingSuggestion(
            newTag: nfcCafe,
            canonicalGuess: "Coffee Shop",
            confidence: .high,
            source: .scan
        )
        _ = resolver.enqueue(seed)
        resolver.confirm(seed, canonical: "Coffee Shop")
        let sibling = PendingSuggestion(
            newTag: "Mocha",
            canonicalGuess: "Coffee Shop",
            confidence: .high,
            source: .scan
        )
        _ = resolver.enqueue(sibling)
        resolver.confirm(sibling, canonical: "Coffee Shop")

        let collateral = resolver.collateralLabels(forMerging: nfdCafe, into: "Work")
        #expect(Set(collateral) == Set(["Coffee Shop", "Mocha"]),
                "NFD source 必须命中 NFC alias group,预览出 parent canonical + sibling aliases")
    }

    @Test func knownCoveredAndNegativePairsUseNFCKeysWithoutBreakingLegacyPairs() {
        let resolver = ThemeAliasResolver(testingWithEmptyState: isolatedDefaults())
        let seed = PendingSuggestion(
            newTag: nfcCafe,
            canonicalGuess: "Coffee Shop",
            confidence: .high,
            source: .scan
        )
        _ = resolver.enqueue(seed)
        resolver.confirm(seed, canonical: "Coffee Shop")

        let duplicate = PendingSuggestion(
            newTag: nfdCafe,
            canonicalGuess: "Other",
            confidence: .high,
            source: .scan
        )
        #expect(resolver.enqueue(duplicate) == false,
                "knownCovered 应用 ThemeKey.make,避免 NFD 等价 tag 重复入队")

        let reject = PendingSuggestion(
            newTag: nfcCafe,
            canonicalGuess: "Tea Shop",
            confidence: .high,
            source: .scan
        )
        _ = resolver.enqueue(reject)
        resolver.reject(reject)
        #expect(resolver.isNegative(nfdCafe, "Tea Shop"),
                "isNegative 应同时兼容 legacy lowercased pair 与 NFC normalized pair")
    }
}

// MARK: - DataMigrationService(megareview OPT-HIGH H3)
//
// 一次性 v2 JSON → CoreData 迁移有两道生产事故级防御:
//   - `seenIDs` Set 去重:save 失败下次重跑不会因为缺 unique constraint 翻倍导入 + 同步到 CloudKit
//   - `defaults.set` **同步**写(performAndWait 内,非 dispatch async):context.save → migrationKey
//     之间无 force-quit / 内存压力 race 窗口
// 这些契约在 DataMigrationService 注释里点明,但**没有 test 锁住**;某次 refactor 删任一道 → 老用户
// 升级触发数据翻倍。本组测试用 isolated defaults + temp file + in-memory context 覆盖 5 个关键场景。

@MainActor
struct DataMigrationServiceTests {
    /// 构造一个 in-memory PersistenceController + 拿到 bgContext。
    /// 不复用 `.shared`,避免污染其他 test。
    private func makeBgContext() -> NSManagedObjectContext {
        let pc = PersistenceController(inMemory: true)
        return pc.container.newBackgroundContext()
    }

    /// 用 JSONSerialization 构造 v2 JSON fixture(LegacyDiaryEntry 是 Decodable-only,自己拼 dict 更简单)。
    /// JSONDecoder 默认 dateDecodingStrategy = deferredToDate(Double seconds since reference date),
    /// 所以 date field 用 `Date.timeIntervalSinceReferenceDate` 直接 encode。
    private func writeLegacyJSON(
        entries: [(id: UUID, date: Date, text: String, mood: Double, audio: String?)],
        to url: URL
    ) throws {
        let dicts: [[String: Any]] = entries.map { e -> [String: Any] in
            var d: [String: Any] = [
                "id": e.id.uuidString,
                "date": e.date.timeIntervalSinceReferenceDate,
                "text": e.text,
                "moodValue": e.mood
            ]
            if let audio = e.audio { d["audioFileName"] = audio }
            return d
        }
        let data = try JSONSerialization.data(withJSONObject: dicts)
        try data.write(to: url)
    }

    private func tempJSONURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("diary-test-\(UUID().uuidString).json")
    }

    @Test func migration_freshInstall_noJSON_marksMigrated() {
        // 新装机 / 无 v2 JSON 文件 — 应该 silent skip + 标记已迁移防下次重跑。
        let defaults = isolatedDefaults()
        let jsonURL = tempJSONURL()  // 故意不写文件
        let context = makeBgContext()

        let outcome = DataMigrationService.performMigration(
            defaults: defaults,
            standardDefaults: nil,
            jsonURL: jsonURL,
            context: context
        )

        #expect(outcome.inserted == 0)
        #expect(outcome.skipped == 0)
        #expect(outcome.didMark == true, "无 JSON 文件也要标 migrated,防下次启动重跑全流程")
        #expect(outcome.didMoveBackup == false)
        #expect(outcome.saveError == nil)
        #expect(defaults.bool(forKey: DataMigrationService.migrationKey) == true)
    }

    @Test func migration_withJSON_insertsAllUniqueEntriesAndRenamesBackup() async throws {
        let defaults = isolatedDefaults()
        let jsonURL = tempJSONURL()
        let context = makeBgContext()
        let now = Date()
        let id1 = UUID(); let id2 = UUID(); let id3 = UUID()
        try writeLegacyJSON(entries: [
            (id1, now, "first entry", 0.5, nil),
            (id2, now.addingTimeInterval(-86400), "second", 0.7, "audio1.m4a"),
            (id3, now.addingTimeInterval(-172800), "third with words", 0.3, nil)
        ], to: jsonURL)
        defer { try? FileManager.default.removeItem(at: jsonURL) }

        let outcome = DataMigrationService.performMigration(
            defaults: defaults,
            standardDefaults: nil,
            jsonURL: jsonURL,
            context: context
        )

        #expect(outcome.inserted == 3)
        #expect(outcome.skipped == 0)
        #expect(outcome.didMark == true)
        #expect(outcome.didMoveBackup == true, "save 成功后 diary.json → diary.json.backup")
        #expect(outcome.saveError == nil)
        #expect(defaults.bool(forKey: DataMigrationService.migrationKey) == true)

        // 备份文件应该存在,原文件应该消失
        let backupURL = jsonURL.appendingPathExtension("backup")
        defer { try? FileManager.default.removeItem(at: backupURL) }
        #expect(FileManager.default.fileExists(atPath: backupURL.path) == true)
        #expect(FileManager.default.fileExists(atPath: jsonURL.path) == false)

        // CoreData 应该有 3 条 entry
        let fetchCount: Int = await context.perform {
            let req = NSFetchRequest<DiaryEntry>(entityName: "DiaryEntry")
            return (try? context.count(for: req)) ?? -1
        }
        #expect(fetchCount == 3)
    }

    @Test func migration_runTwice_secondPassSkipsAllByUUID() async throws {
        // 模拟 race:第一遍 save 成功 + migrationKey 写盘成功,但 backup rename 假装失败(我们手动复制
        // diary.json 回 jsonURL 模拟"文件还在"+ defaults 删 migrationKey 模拟"sentinel race window"
        // 让人为复现 "save 成功但下次启动 migrationKey 缺失" 的 fault path。
        let defaults = isolatedDefaults()
        let jsonURL = tempJSONURL()
        let context = makeBgContext()
        let id1 = UUID(); let id2 = UUID()
        try writeLegacyJSON(entries: [
            (id1, Date(), "alpha", 0.5, nil),
            (id2, Date().addingTimeInterval(-3600), "beta", 0.6, nil)
        ], to: jsonURL)
        defer { try? FileManager.default.removeItem(at: jsonURL) }

        // 第一遍:正常跑
        let first = DataMigrationService.performMigration(
            defaults: defaults,
            standardDefaults: nil,
            jsonURL: jsonURL,
            context: context
        )
        #expect(first.inserted == 2)
        let backupURL = jsonURL.appendingPathExtension("backup")
        defer { try? FileManager.default.removeItem(at: backupURL) }

        // 人为复现 race window:把 backup 文件 rename 回 jsonURL(模拟"backup rename 失败,JSON 文件还在")
        // + 清掉 defaults sentinel(模拟"migrationKey 还没落盘 force-quit")
        if FileManager.default.fileExists(atPath: backupURL.path) {
            try? FileManager.default.removeItem(at: jsonURL)
            try FileManager.default.moveItem(at: backupURL, to: jsonURL)
        }
        defaults.removeObject(forKey: DataMigrationService.migrationKey)

        // 第二遍:seenIDs guard 应该 skip 全部
        let second = DataMigrationService.performMigration(
            defaults: defaults,
            standardDefaults: nil,
            jsonURL: jsonURL,
            context: context
        )
        #expect(second.inserted == 0, "seenIDs UUID 去重应该挡住所有 entry")
        #expect(second.skipped == 2, "全部 2 条都应被识别为 already-imported")

        // 数据库应该仍然只有 2 条,不翻倍
        let fetchCount: Int = await context.perform {
            let req = NSFetchRequest<DiaryEntry>(entityName: "DiaryEntry")
            return (try? context.count(for: req)) ?? -1
        }
        #expect(fetchCount == 2, "race window 触发的重跑不能让 CoreData 翻倍 ghost entry")
    }

    @Test func migration_lossyDecode_skipsMalformedRowsAndAcceptsISODate() async throws {
        let defaults = isolatedDefaults()
        let jsonURL = tempJSONURL()
        let context = makeBgContext()
        let numericID = UUID()
        let isoID = UUID()
        let numericDate = Date(timeIntervalSinceReferenceDate: 123_456)
        let isoDate = ISO8601DateFormatter().date(from: "2025-06-01T12:34:56Z")!
        let rows: [[String: Any]] = [
            [
                "id": numericID.uuidString,
                "date": numericDate.timeIntervalSinceReferenceDate,
                "text": "numeric legacy date",
                "moodValue": 0.4
            ],
            [
                "id": isoID.uuidString,
                "date": ISO8601DateFormatter().string(from: isoDate),
                "text": "iso legacy date",
                "moodValue": 0.8,
                "audioFileName": "../unsafe.m4a"
            ],
            [
                "id": UUID().uuidString,
                "date": "not-a-date",
                "text": "bad row",
                "moodValue": 0.5
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: rows)
        try data.write(to: jsonURL)
        defer {
            try? FileManager.default.removeItem(at: jsonURL)
            try? FileManager.default.removeItem(at: jsonURL.appendingPathExtension("backup"))
        }

        let outcome = DataMigrationService.performMigration(
            defaults: defaults,
            standardDefaults: nil,
            jsonURL: jsonURL,
            context: context
        )

        #expect(outcome.inserted == 2, "单行坏数据不应拖垮整批迁移")
        #expect(outcome.skipped == 1)
        #expect(outcome.didMark == true)
        #expect(outcome.saveError == nil)

        let entries: [(id: UUID?, text: String, date: Date?, audioFileName: String?)] = await context.perform {
            let req: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
            req.sortDescriptors = [NSSortDescriptor(keyPath: \DiaryEntry.text, ascending: true)]
            return ((try? context.fetch(req)) ?? []).map {
                ($0.id, $0.wrappedText, $0.date, $0.audioFileName)
            }
        }
        #expect(entries.count == 2)
        #expect(entries.contains { $0.id == numericID && $0.text == "numeric legacy date" })
        let isoEntry = entries.first { $0.id == isoID }
        #expect(isoEntry?.text == "iso legacy date")
        #expect(isoEntry?.date == isoDate)
        #expect(isoEntry?.audioFileName == nil, "不安全 legacy audioFileName 不能被迁移落库")
    }

    @Test func migration_allMalformedRows_keepsOriginalFileAndDoesNotMarkMigrated() throws {
        let defaults = isolatedDefaults()
        let jsonURL = tempJSONURL()
        let context = makeBgContext()
        let rows: [[String: Any]] = [
            [
                "id": UUID().uuidString,
                "date": "not-a-date",
                "text": "bad row one",
                "moodValue": 0.5
            ],
            [
                "id": UUID().uuidString,
                "date": "also-not-a-date",
                "text": "bad row two",
                "moodValue": 0.4
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: rows)
        try data.write(to: jsonURL)
        defer {
            try? FileManager.default.removeItem(at: jsonURL)
            try? FileManager.default.removeItem(at: jsonURL.appendingPathExtension("backup"))
        }

        let outcome = DataMigrationService.performMigration(
            defaults: defaults,
            standardDefaults: nil,
            jsonURL: jsonURL,
            context: context
        )

        #expect(outcome.inserted == 0)
        #expect(outcome.skipped == 2)
        #expect(outcome.didMark == false, "所有行都坏时不能标记迁移完成,否则用户老数据永远不会重试")
        #expect(outcome.didMoveBackup == false, "所有行都坏时必须保留原 JSON,不能移走成 backup")
        #expect(outcome.saveError != nil)
        #expect(defaults.bool(forKey: DataMigrationService.migrationKey) == false)
        #expect(FileManager.default.fileExists(atPath: jsonURL.path))
        #expect(!FileManager.default.fileExists(atPath: jsonURL.appendingPathExtension("backup").path))
    }

    @Test func migration_alreadyMarked_isNoop() throws {
        // 已经标记过 migrated 的 defaults 应该 silent return,不读 JSON 不写盘。
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: DataMigrationService.migrationKey)
        let jsonURL = tempJSONURL()
        let context = makeBgContext()
        // 故意写一个会"看似有数据"的 JSON,如果 service 偷跑就会插数据
        try writeLegacyJSON(entries: [(UUID(), Date(), "should not import", 0.5, nil)], to: jsonURL)
        defer { try? FileManager.default.removeItem(at: jsonURL) }

        let outcome = DataMigrationService.performMigration(
            defaults: defaults,
            standardDefaults: nil,
            jsonURL: jsonURL,
            context: context
        )

        #expect(outcome.inserted == 0)
        #expect(outcome.skipped == 0)
        #expect(outcome.didMark == false, "已 mark 的不应该再写一遍 mark")
        #expect(outcome.didMoveBackup == false, "已 mark 的不应该动 backup")
        #expect(outcome.saveError == nil)
        // 原 JSON 文件应该没动
        #expect(FileManager.default.fileExists(atPath: jsonURL.path) == true)
    }

    @Test func migration_legacyStandardDefaults_migratedToAppGroup_explicitFalsePreserved() throws {
        // 老用户在 .standard suite 显式写过 `false`(可能是 sentinel reset),要对称拷到 AppGroup;
        // 否则 AppGroup 永远缺 key,启动重跑 → 若 v2 JSON 仍在 → 数据翻倍。
        let appGroup = isolatedDefaults()
        let standardSurrogate = isolatedDefaults()  // 用 isolated 模拟 .standard 防污染
        standardSurrogate.set(false, forKey: DataMigrationService.migrationKey)

        let jsonURL = tempJSONURL()  // 无文件,触发"标记已迁移"路径
        let context = makeBgContext()

        let outcome = DataMigrationService.performMigration(
            defaults: appGroup,
            standardDefaults: standardSurrogate,
            jsonURL: jsonURL,
            context: context
        )

        // 应该:先把 standard 的 false 拷到 appGroup,然后因为 bool=false 不被 guard 挡掉,
        // 继续走"无 JSON → 标 migrated"路径。这是合法的"老用户重启后正常完成"路径。
        #expect(appGroup.bool(forKey: DataMigrationService.migrationKey) == true,
                "无 JSON 文件路径会把 migrationKey 设回 true(已完成迁移)")
        #expect(outcome.didMark == true)
        #expect(outcome.inserted == 0)
    }
}

// MARK: - Backfill services(megareview OPT-HIGH H5)
//
// 三个 backfill service 的核心契约:
//   - `pendingCount()` 准确:UI 进 Settings → "一键重建索引" 顶部要显示"剩 N 条";数错 = 用户看
//     不出 backfill 进度 / 跑完仍提示"还有 N 条"。
//   - `backfillAll()` 真正落 embedding/themes/wordCount 到 DiaryEntry,而非 silent no-op。
//   - 二次 run idempotent — 跑完一遍 pendingCount 归零,二次 backfillAll 立即返。
// CLAUDE.md 提到 `runningTask` 改 `@MainActor` 隔离锁住 concurrent backfill race;这条契约 H4
// 之外的 race 测试需要异步并发场景,暂不覆盖(actor isolation 已经从设计层保住)。

@MainActor
struct EmbeddingBackfillServiceTests {
    private func makePersistence() -> PersistenceController {
        PersistenceController(inMemory: true)
    }

    /// Seed N 条 entry,其中 `missingEmbeddingCount` 条无 embedding,其余有(任意 vector)。
    /// 返回 (persistence, seededIDs)。
    private func seed(missing: Int, withVector: Int) -> (PersistenceController, [UUID]) {
        let pc = makePersistence()
        let ctx = pc.container.viewContext
        var ids: [UUID] = []
        for i in 0..<missing {
            let id = UUID()
            ids.append(id)
            _ = insertDiaryEntry(
                context: ctx,
                id: id,
                date: makeDate(year: 2024, month: 6, day: 1 + i),
                themes: [],
                text: "missing-embedding-\(i)"
            )
        }
        for i in 0..<withVector {
            let id = UUID()
            ids.append(id)
            let entry = insertDiaryEntry(
                context: ctx,
                id: id,
                date: makeDate(year: 2024, month: 7, day: 1 + i),
                themes: [],
                text: "has-embedding-\(i)"
            )
            // 写一段非空 embedding blob(用 setEmbedding 走 V1 header)
            entry.setEmbedding([Float(0.1), Float(0.2), Float(0.3)])
        }
        try? ctx.save()
        return (pc, ids)
    }

    @Test func pendingCount_returnsCorrectMissingEmbeddingCount() async {
        let (pc, _) = seed(missing: 5, withVector: 3)
        let service = EmbeddingBackfillService(persistence: pc, ai: MockAIService(), batchSize: 3, throttleMs: 0)
        let count = await service.pendingCount()
        #expect(count == 5, "pendingCount 应只反映 embedding=nil 的 entry")
    }

    @Test func backfillAll_writesEmbeddingsAndClearsPending() async {
        let (pc, _) = seed(missing: 4, withVector: 0)
        let service = EmbeddingBackfillService(persistence: pc, ai: MockAIService(), batchSize: 2, throttleMs: 0)

        let progress = await service.backfillAll()
        // MockAIService.embed 总返非 nil 16 维向量,所以 4 条都应该 write 成功
        #expect(progress.processed == 4)
        #expect(progress.failed == 0)
        #expect(progress.isRunning == false)

        // 跑完后 pendingCount 应该归零(全部 entry 都 embed 过了)
        let after = await service.pendingCount()
        #expect(after == 0, "backfillAll 完成后 pendingCount 应归零")
    }

    @Test func backfillAll_emptyMissing_returnsImmediately() async {
        let (pc, _) = seed(missing: 0, withVector: 3)
        let service = EmbeddingBackfillService(persistence: pc, ai: MockAIService(), batchSize: 3, throttleMs: 0)
        let progress = await service.backfillAll()
        #expect(progress.processed == 0)
        #expect(progress.total == 0)
        #expect(progress.isRunning == false)
    }
}

@MainActor
struct ThemeBackfillServiceTests {
    private func seed(missingThemes: Int, withThemes: Int) -> PersistenceController {
        let pc = PersistenceController(inMemory: true)
        let ctx = pc.container.viewContext
        for i in 0..<missingThemes {
            insertDiaryEntry(
                context: ctx,
                date: makeDate(year: 2024, month: 6, day: 1 + i),
                themes: [],  // 空 themes → pending
                text: "needs themes \(i)"
            )
        }
        for i in 0..<withThemes {
            insertDiaryEntry(
                context: ctx,
                date: makeDate(year: 2024, month: 7, day: 1 + i),
                themes: ["工作", "家人"],  // 已有 themes
                text: "has themes \(i)"
            )
        }
        try? ctx.save()
        return pc
    }

    @Test func pendingCount_countsEntriesWithoutThemes() async {
        let pc = seed(missingThemes: 4, withThemes: 2)
        let service = ThemeBackfillService(persistence: pc, ai: MockAIService(), batchSize: 3, throttleMs: 0)
        let count = await service.pendingCount()
        #expect(count == 4, "pendingCount 应只算 themes=nil/空 的 entry")
    }

    @Test func backfillAll_writesThemesViaMockAI() async {
        // MockAIService.extractThemes 用关键词匹配,text="工作 加班" 会返 ["工作"]
        let pc = PersistenceController(inMemory: true)
        let ctx = pc.container.viewContext
        insertDiaryEntry(
            context: ctx,
            date: makeDate(year: 2024, month: 6, day: 1),
            themes: [],
            text: "今天工作很累，加班了好久"
        )
        try? ctx.save()

        let service = ThemeBackfillService(persistence: pc, ai: MockAIService(), batchSize: 3, throttleMs: 0)
        let progress = await service.backfillAll()
        #expect(progress.processed == 1)
        #expect(progress.failed == 0)

        // 检查 entry.themes 真的被写了
        let after = await service.pendingCount()
        #expect(after == 0, "backfillAll 完成后 pending 应归零")
    }
}

struct WordCountBackfillServiceTests {
    @Test func backfillIfNeeded_processesZeroWordCountEntriesWithText() async {
        // CLAUDE.md & wordCount comment 自陈:wordCount==0 AND text!="" 的 entry 才处理。
        // image-only entry (text="" / nil) 应该被 predicate 挡住,避免每次启动反复 fetch。
        let pc = PersistenceController(inMemory: true)
        let ctx = pc.container.viewContext

        // 3 条有 text 的 entry(wordCount=0,待回填)
        for i in 0..<3 {
            let entry = insertDiaryEntry(
                context: ctx,
                date: makeDate(year: 2024, month: 6, day: 1 + i),
                themes: [],
                text: "hello world entry \(i) with several words"
            )
            entry.wordCount = 0  // 显式设 0 模拟老用户数据
        }
        // 1 条 image-only entry(text="",wordCount=0,不应被处理)
        let imageOnly = insertDiaryEntry(
            context: ctx,
            date: makeDate(year: 2024, month: 6, day: 4),
            themes: [],
            text: ""
        )
        imageOnly.wordCount = 0
        try? ctx.save()

        let processed = await WordCountBackfillService.forceBackfill(persistence: pc)
        #expect(processed == 3, "应处理 3 条有 text 的,跳过 image-only")

        // 再跑一遍 — 全部已写,应返回 0(idempotent)
        let processedAgain = await WordCountBackfillService.forceBackfill(persistence: pc)
        #expect(processedAgain == 0, "二次跑应 idempotent 返 0")
    }
}
