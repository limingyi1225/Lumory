//
//  EntryWipeOrchestratorTests.swift
//  ChronoteTests
//
//  P0 回归测:`EntryWipeOrchestrator` 的 4 vs 5 件清理状态机。
//
//  CLAUDE.md 反复 callout 这是删 entry 后的"唯一防漏机制"——漏一件就会有 banner /
//  通知 body / 别名管理页 / Insights / 主屏 widget 引用已删 entry 的 ghost 数据。
//  这套测试锁住对外可观察的契约:
//
//  - **bulk(5 件)**:`Reminder reschedule + ThemeAlias resetForBulkEntryWipe +
//    Prompt clearCache + Insights clear + Widget clear`。其中 Reminder 副作用难观察(UN
//    center 不 mock,见末尾跳过说明),其余 4 件全部覆盖。**关键不变量**:`negativePairs`
//    保留(用户主观偏好,与 entry 存在与否无关 —— CLAUDE.md 明文)。
//  - **single(4 件)**:`Reminder reschedule + Prompt clearCache + Insights clear +
//    alias 孤儿清理 + Widget invalidateCaches`,**不**主动 `clear()` widget snapshot 文件
//    (依赖 NSManagedObjectContextDidSave 观察者已 schedule 一次 requestRefresh,CLAUDE.md
//    明文 "依赖 save 观察者从 CoreData 重抓")。本测试断言 widget snapshot 文件**不变**。
//
//  **隔离**:依赖三个 `@MainActor` singleton(`InsightsResultCache.shared` /
//  `PromptSuggestionEngine.shared` / `ThemeAliasResolver.shared`)+ 一个 `actor`
//  singleton(`WidgetSnapshotService.shared`)。XCTest 默认串行 + 每个 test 在 `setUp`
//  调对应 `clear()` reset state。`WidgetSnapshotStore.overrideURL` 走 temp dir,与
//  `WidgetSnapshotTests` 同 idiom,完全旁路真实 App Group 容器。
//
//  **不修改 production 代码**。某条断言因 dependency 缺乏 testing seam 无法断言到内部
//  状态(reminder reschedule、alias 孤儿清理),改成 smoke test "调用不抛 / 不死锁",
//  在注释里写明 backlog。
//

import XCTest
@testable import Lumory

@MainActor
final class EntryWipeOrchestratorTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EntryWipeOrchestratorTests-\(UUID().uuidString)"
        )
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        WidgetSnapshotStore.overrideURL = tempDir.appendingPathComponent("snapshot.json")

        // Reset shared state — singleton 在跨 test 间会污染。
        InsightsResultCache.shared.clear()
        PromptSuggestionEngine.shared.clearCache()
        // ThemeAliasResolver:`resetForBulkEntryWipe` 清 groups/pending/coolUntil 但保留 negativePairs
        // (这正是被测的契约!)。测试 setup 要彻底归零 → 先 `resetNegativePairs()` 再
        // `resetForBulkEntryWipe()`,避免跨测试残留 negativePair 污染下一个用例。
        ThemeAliasResolver.shared.resetNegativePairs()
        ThemeAliasResolver.shared.resetForBulkEntryWipe()
        // Widget snapshot:测试自行用 overrideURL,actor 内 in-memory 状态可用 invalidateCaches 重置。
        await WidgetSnapshotService.shared.invalidateCaches()
    }

    override func tearDown() async throws {
        WidgetSnapshotStore.overrideURL = nil
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil

        // 跨测试避免污染下一个测试 / 真实 App 状态。
        InsightsResultCache.shared.clear()
        PromptSuggestionEngine.shared.clearCache()
        ThemeAliasResolver.shared.resetNegativePairs()
        ThemeAliasResolver.shared.resetForBulkEntryWipe()
        await WidgetSnapshotService.shared.invalidateCaches()
        try await super.tearDown()
    }

    // MARK: - Bulk wipe path (5 件清理)

    func testBulkWipe_clearsWidgetSnapshot_writesEmptyFile() async {
        // Seed:写一份非空 snapshot 到 override URL。
        let populated = WidgetSnapshot(
            generatedAt: Date(),
            currentStreak: 9,
            longestStreak: 30,
            lastEntryDate: Date(),
            lastEntryMood: 0.7,
            prompt: "你最近最常想起谁?"
        )
        try? WidgetSnapshotStore.write(populated)
        XCTAssertEqual(WidgetSnapshotStore.read()?.currentStreak, 9, "seed precondition")

        await EntryWipeOrchestrator.performBulkWipeCleanup()

        let cleared = WidgetSnapshotStore.read()
        XCTAssertNotNil(cleared, "bulk wipe 写 empty snapshot 而非删文件 —— widget 能稳定渲染 fallback")
        XCTAssertEqual(cleared?.currentStreak, 0, "bulk wipe 后 widget 显示零 streak")
        XCTAssertEqual(cleared?.longestStreak, 0)
        XCTAssertNil(cleared?.lastEntryDate)
        XCTAssertNil(cleared?.lastEntryMood)
        XCTAssertNil(cleared?.prompt, "prompt 必须清空 —— 旧 placeholder 可能引用已删主题")
    }

    func testBulkWipe_resetsAliasGroupsAndPending_butPreservesNegativePairs() async {
        // Seed:走 enqueue + confirm 真实路径建一个 group(直接改 @Published private(set) 不行)。
        // 同时 reject 另一对,把 pair 写入 negativePairs。
        let toMerge = PendingSuggestion(
            newTag: "宝贝",
            canonicalGuess: "Abby",
            confidence: .high,
            sampleEntryIds: [],
            source: .scan
        )
        let added = ThemeAliasResolver.shared.enqueue(toMerge)
        XCTAssertTrue(added, "enqueue should accept fresh pair")
        ThemeAliasResolver.shared.confirm(toMerge, canonical: "Abby")
        XCTAssertFalse(ThemeAliasResolver.shared.groups.isEmpty, "groups seed precondition")

        let toReject = PendingSuggestion(
            newTag: "外婆",
            canonicalGuess: "妈妈",
            confidence: .medium,
            sampleEntryIds: [],
            source: .scan
        )
        XCTAssertTrue(ThemeAliasResolver.shared.enqueue(toReject), "enqueue reject seed")
        ThemeAliasResolver.shared.reject(toReject)
        XCTAssertFalse(ThemeAliasResolver.shared.negativePairs.isEmpty, "negativePairs seed precondition")
        let negativePairsBefore = ThemeAliasResolver.shared.negativePairs

        // 再 enqueue 一条让 pending 非空 — 验证 pending 被清。
        let extra = PendingSuggestion(
            newTag: "老板",
            canonicalGuess: "公司",
            confidence: .medium,
            sampleEntryIds: [],
            source: .scan
        )
        XCTAssertTrue(ThemeAliasResolver.shared.enqueue(extra))
        XCTAssertFalse(ThemeAliasResolver.shared.pending.isEmpty, "pending seed precondition")

        await EntryWipeOrchestrator.performBulkWipeCleanup()

        XCTAssertTrue(
            ThemeAliasResolver.shared.groups.isEmpty,
            "bulk wipe 必须清 groups —— 已删 entry 的别名映射没意义了"
        )
        XCTAssertTrue(
            ThemeAliasResolver.shared.pending.isEmpty,
            "bulk wipe 必须清 pending —— 待审建议引用的 entry 都没了"
        )
        XCTAssertEqual(
            ThemeAliasResolver.shared.negativePairs,
            negativePairsBefore,
            "negativePairs 必须保留 —— CLAUDE.md 明文 '用户主观判断与 entry 存在与否无关'"
        )
    }

    func testBulkWipe_clearsInsightsResultCache() async {
        // Seed:塞一份非空 snapshot 进 .month bucket。
        let snap = InsightsResultCache.Snapshot(
            moodPoints: [
                InsightsEngine.MoodPoint(date: Date(), mood: 0.7, entryCount: 3)
            ],
            themes: [],
            stats: InsightsEngine.WritingStats(
                totalEntries: 5,
                currentStreak: 2,
                longestStreak: 7,
                totalWords: 1200,
                avgMood: 0.6
            ),
            dailyCells: [],
            facts: []
        )
        InsightsResultCache.shared.update(snap, for: .month)
        XCTAssertNotNil(InsightsResultCache.shared.snapshot(for: .month), "seed precondition")

        await EntryWipeOrchestrator.performBulkWipeCleanup()

        XCTAssertNil(
            InsightsResultCache.shared.snapshot(for: .month),
            "bulk wipe 必须清 InsightsResultCache —— SWR 缓存会引用已删 entry,re-open Insights 看到 ghost"
        )
        for range in TimeRange.allCases {
            XCTAssertNil(
                InsightsResultCache.shared.snapshot(for: range),
                "InsightsResultCache.clear() 清所有 bucket,不只 .month"
            )
        }
    }

    func testBulkWipe_clearsPromptSuggestionCache() async {
        // Seed:写一份 SuggestionBundle 到 PromptSuggestionEngine 的持久化文件,然后强制 reload
        // 把它带进 in-memory `current`。直接写 `current` 不行(@Published private(set))。
        let bundle = SuggestionBundle(
            askPastPresets: ["三个月前的我和现在有什么不同?"],
            homePlaceholders: ["今天最让你停下脚步的瞬间是什么?"],
            generatedAt: Date(),
            fingerprint: "test-fingerprint",
            language: "zh"
        )
        // 直接写 protected file,然后通过新建一个 engine 实例 hydrate(测试 PromptSuggestionEngine
        // 的 cache 文件公开 seam)。但 EntryWipeOrchestrator 操作的是 `.shared`,所以走 indirect:
        // 用 cacheFileURLForTesting 写文件,然后 shared 实例已经在 init 里 load 过 —— hydrate 不到。
        // 取折中:断言 `clearCache` 调用产生的可观察效果 = `current` 是 nil + cache 文件被删除。
        // setup 已 clearCache,这里只验"调 EntryWipeOrchestrator 后仍然 nil + 文件不存在"——
        // 也就是说,即使我们没法 seed `current` 为非 nil,我们能 seed 文件为存在,验证 bulk 路径
        // 把文件也清掉(clearCache 实现里调 removeCacheFile)。
        #if DEBUG
        if let url = PromptSuggestionEngine.cacheFileURLForTesting {
            let data = try? JSONEncoder().encode(bundle)
            try? data?.write(to: url, options: .atomic)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "seed precondition: cache file should exist after manual write"
            )

            await EntryWipeOrchestrator.performBulkWipeCleanup()

            XCTAssertFalse(
                FileManager.default.fileExists(atPath: url.path),
                "bulk wipe 必须删 PromptSuggestion cache 文件 —— 否则下次启动 hydrate 出已删主题的 placeholder"
            )
        } else {
            // Debug seam 不可用 → 退化成 smoke test:调用不抛 + current 仍 nil。
            await EntryWipeOrchestrator.performBulkWipeCleanup()
        }
        #else
        // Release build:只能验对外可观察的 `current` —— setup 已清,bulk 后仍 nil。
        await EntryWipeOrchestrator.performBulkWipeCleanup()
        #endif

        XCTAssertNil(
            PromptSuggestionEngine.shared.current,
            "bulk wipe 后 PromptSuggestionEngine.current 必须 nil"
        )
    }

    // MARK: - Single delete path (4 件清理 + 不动 widget snapshot 文件)

    func testSingleDelete_doesNotClearWidgetSnapshotFile() async {
        // Seed:写一份非空 snapshot。
        let snapshotDate = Date()
        let populated = WidgetSnapshot(
            generatedAt: snapshotDate,
            currentStreak: 12,
            longestStreak: 40,
            lastEntryDate: snapshotDate,
            lastEntryMood: 0.55,
            prompt: "今晚想给三年后的自己留一句什么?"
        )
        try? WidgetSnapshotStore.write(populated)
        let beforeStreak = WidgetSnapshotStore.read()?.currentStreak
        let beforePrompt = WidgetSnapshotStore.read()?.prompt
        XCTAssertEqual(beforeStreak, 12, "seed precondition")

        EntryWipeOrchestrator.performSingleDeleteCleanup()
        // Single delete 内部跑 fire-and-forget Task 跑 alias cleanup + widget invalidateCaches。
        // 让 RunLoop 转一次让 unstructured Task 至少进入 await 阶段(我们只断言文件不变,不依赖 Task 完成)。
        await Task.yield()

        let afterSnap = WidgetSnapshotStore.read()
        XCTAssertNotNil(afterSnap, "single delete **不**主动 clear widget snapshot 文件")
        XCTAssertEqual(
            afterSnap?.currentStreak,
            beforeStreak,
            "CLAUDE.md 明文:single delete 依赖 NSManagedObjectContextDidSave 观察者已 schedule 一次 requestRefresh,**不**主动 clear。文件应保持不变直到 save 观察者重写"
        )
        XCTAssertEqual(
            afterSnap?.prompt,
            beforePrompt,
            "single delete 不动盘上 prompt"
        )
    }

    func testSingleDelete_clearsInsightsResultCache() async {
        // Seed 跟 bulk 用例同样模式。
        let snap = InsightsResultCache.Snapshot(
            moodPoints: [],
            themes: [],
            stats: InsightsEngine.WritingStats(
                totalEntries: 1,
                currentStreak: 1,
                longestStreak: 1,
                totalWords: 100,
                avgMood: 0.5
            ),
            dailyCells: [],
            facts: []
        )
        InsightsResultCache.shared.update(snap, for: .month)
        InsightsResultCache.shared.update(snap, for: .quarter)
        XCTAssertNotNil(InsightsResultCache.shared.snapshot(for: .month))
        XCTAssertNotNil(InsightsResultCache.shared.snapshot(for: .quarter))

        EntryWipeOrchestrator.performSingleDeleteCleanup()

        XCTAssertNil(
            InsightsResultCache.shared.snapshot(for: .month),
            "single delete **必须**清 Insights cache —— megareview BUG-P1 #1 修复:之前漏清 → SWR 显示 ghost"
        )
        XCTAssertNil(
            InsightsResultCache.shared.snapshot(for: .quarter),
            "InsightsResultCache.clear() 清所有 bucket"
        )
    }

    func testSingleDelete_clearsPromptSuggestionCache() async {
        #if DEBUG
        // 同 bulk 用例的限制:对 `current` 的可观察 seam 是 file existence。
        if let url = PromptSuggestionEngine.cacheFileURLForTesting {
            let bundle = SuggestionBundle(
                askPastPresets: ["你最近重复犯的错是什么?"],
                homePlaceholders: ["今天和上周比有什么变化?"],
                generatedAt: Date(),
                fingerprint: "single-delete-fixture",
                language: "zh"
            )
            let data = try? JSONEncoder().encode(bundle)
            try? data?.write(to: url, options: .atomic)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "seed precondition")

            EntryWipeOrchestrator.performSingleDeleteCleanup()

            XCTAssertFalse(
                FileManager.default.fileExists(atPath: url.path),
                "single delete **必须**清 PromptSuggestion cache —— 否则 placeholder 引用已删主题(megareview BUG-P1 #1)"
            )
        } else {
            EntryWipeOrchestrator.performSingleDeleteCleanup()
        }
        #else
        EntryWipeOrchestrator.performSingleDeleteCleanup()
        #endif

        XCTAssertNil(
            PromptSuggestionEngine.shared.current,
            "single delete 后 PromptSuggestionEngine.current 必须 nil"
        )
    }

    // MARK: - Smoke / 不可观察依赖

    /// `ReminderService.shared.requestReschedule()` 副作用是 schedule UN center 通知,跨进程
    /// 系统 daemon,无法在单测内观察。`ThemeAliasResolver.cleanupOrphanedPending()` 是 fire-and-forget
    /// Task 跑后台 fetch,有自身的 fetch-failure / generation guard,**不**依赖 Task.isCancelled。
    /// `WidgetSnapshotService.invalidateCaches()` 清的是 actor 内 in-memory `cachedPrompt` —
    /// 那个属性 actor-isolated 且没有 testing accessor。
    ///
    /// 这三件不能直接断言到内部状态。本测试退化成 smoke:调用不抛、不死锁、能完成。
    /// 真要观察需要在 production 加 testing seam(reschedule generation counter / cleanup completion
    /// signal / cachedPrompt accessor),与 "不修改 production 代码" 的约束冲突 → 留 backlog。
    func testSingleDelete_smokeTest_completesWithoutThrowingOrDeadlocking() async {
        EntryWipeOrchestrator.performSingleDeleteCleanup()
        // 让 unstructured Tasks(alias cleanup + widget invalidateCaches)进入 await 阶段。
        await Task.yield()
        await Task.yield()
        // 不死锁就算过。
    }

    func testBulkWipe_smokeTest_completesAndAwaits() async {
        // bulk path 全 await,如果 await Widget.clear() 死锁这条会卡住直到 XCTest timeout。
        await EntryWipeOrchestrator.performBulkWipeCleanup()
    }
}
