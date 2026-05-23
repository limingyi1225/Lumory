//
//  EntryCreationServiceTests.swift
//  ChronoteTests
//
//  Phase 2 unit tests for `EntryCreationService` — Lumory 写日记落库 / AI writeback / 派生副作用
//  的 service-level 契约。
//
//  **隔离策略**:
//  - 每个 test 自起 `PersistenceController(inMemory: true)`(`cachedModel` 静态共享 NSManagedObjectModel
//    防 Core Data ambiguity SIGABRT — CLAUDE.md 锁死)。
//  - `aliasJudge` 走 `@MainActor` spy class(@Sendable 闭包不能 capture local var,Codex 建议)。
//  - `requestReminderReschedule` 注入 `{}`,防 `ReminderService.fetchLastEntryDate()` 偷调
//    `PersistenceController.shared.container`(CLAUDE.md 锁死)。
//  - `MockAIService()` 走 AIService.swift 内置实现:summarize 取 prefix(50),extractThemes 关键词匹配,
//    embed 返 16-D 归一化伪向量。
//
//  **不测的事**(已留 backlog):
    //  - Reminder reschedule 副作用:UN center 不 mock,默认闭包注入成 no-op 即可,不验证 schedule 调度。
//  - StreakMilestone 副作用:`evaluateAfterSave` 内部跑 detached Task 算 streak,异步且 fire-and-forget。
//

import Testing
import Foundation
import CoreData
@testable import Lumory

// MARK: - Spy

/// `@MainActor` actor / class spy 记录 alias judge 调用 — Codex 提示 `@Sendable` 闭包对 local var
/// capture 卡严,要走 actor / class。这里用 `@MainActor final class` + 同步 record(test 全程
/// 在 main 上)。
@MainActor
final class AliasJudgeSpy {
    private(set) var calls: [(UUID, [String])] = []
    func record(id: UUID, tags: [String]) {
        calls.append((id, tags))
    }
}

private struct ThemeFailingAIService: AIServiceProtocol {
    private let base = MockAIService()

    func summarize(text: String) async -> String? { await base.summarize(text: text) }
    func analyzeMood(text: String) async -> Double { await base.analyzeMood(text: text) }
    func extractThemes(text: String) async -> [String] { [] }
    func extractThemesOutcome(text: String) async -> ThemeExtractionOutcome { .failed }
    func embed(text: String) async -> [Float]? { await base.embed(text: text) }
    func judgeThemeAliases(newTags: [String], inventory: [ThemeAliasJudgeCandidate]) async -> [ThemeAliasJudgeMatch] { [] }
    func scanThemeAliasGroups(candidates: [ThemeAliasJudgeCandidate]) async throws -> [ThemeAliasJudgeGroup] { [] }
    func askEvents(question: String, context entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
        AsyncStream { $0.finish() }
    }
    func streamReportEvents(entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
        AsyncStream { $0.finish() }
    }
    func composeSuggestions(context: SuggestionContext) async -> SuggestionBundle? { nil }
    func parseImportedDiaries(rawText: String) async throws -> [ParsedDiaryEntry] { [] }
}

// MARK: - Tests

@MainActor
struct EntryCreationServiceTests {

    @Test func textOnly_happyPath_savesEntryWithFields() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let ai = MockAIService()

        let result = await EntryCreationService.create(
            .init(text: "Today was happy", audioFileName: nil, images: [], moodValue: 0.85),
            in: persistence,
            viewContext: context,
            ai: ai,
            aliasJudge: { _, _ in },
            requestReminderReschedule: {}
        )

        guard case .saved(let entryID) = result else {
            Issue.record("expected .saved, got \(result)")
            return
        }

        // Fetch back and verify fields。`text/mood/date/wordCount` 全部走过 service 主线程写入。
        let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", entryID as NSUUID)
        let entries = try context.fetch(request)
        try #require(entries.count == 1)
        let entry = entries[0]
        #expect(entry.wrappedText == "Today was happy")
        #expect(entry.moodValue == 0.85)
        #expect(entry.wordCount > 0, "recomputeWordCount should have populated wordCount")
        #expect(entry.summary == nil, "summary 暂时 nil(AI writeback fire-and-forget,test 不 await)")
        #expect(entry.audioFileName == nil)
        #expect((entry.imageFileNames ?? "").isEmpty)
    }

    @Test func create_withDateOverride_savesSelectedDate() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let calendar = Calendar(identifier: .gregorian)
        let selectedDate = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 1, hour: 20, minute: 30)))

        let result = await EntryCreationService.create(
            .init(text: "Backfilled entry", audioFileName: nil, images: [], moodValue: 0.7, date: selectedDate),
            in: persistence,
            viewContext: context,
            ai: MockAIService(),
            aliasJudge: { _, _ in },
            requestReminderReschedule: {}
        )

        guard case .saved(let entryID) = result else {
            Issue.record("expected .saved, got \(result)")
            return
        }

        let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", entryID as NSUUID)
        let entry = try #require(try context.fetch(request).first)
        #expect(entry.date == selectedDate)
    }

    @Test func whitespaceText_isTrimmedBeforeSave() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let result = await EntryCreationService.create(
            .init(text: "  \n\t  ", audioFileName: nil, images: [], moodValue: 0.5),
            in: persistence,
            viewContext: context,
            ai: MockAIService(),
            aliasJudge: { _, _ in },
            requestReminderReschedule: {}
        )

        guard case .saved(let entryID) = result else {
            Issue.record("expected .saved, got \(result)")
            return
        }

        let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", entryID as NSUUID)
        let entry = try #require(try context.fetch(request).first)
        #expect(entry.wrappedText.isEmpty)
        #expect(entry.wordCount == 0)
    }

    @Test func imageAndAudio_persistsAttachmentMetadata() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let ai = MockAIService()

        // 一张占位图(5x5 黑色 PNG-ish bytes;NSKeyedArchiver 不验证 PNG 格式,任何 Data 都能编)。
        let image1 = Data(repeating: 0xAB, count: 64)
        let image2 = Data(repeating: 0xCD, count: 128)
        let audioFileName = "test_audio_\(UUID().uuidString).m4a"

        defer {
            // image 落盘到 Documents/LumoryImages,test tearDown 清。
            // audio 没真实本地文件 → persistAudioOffMain iCloud 移动路径不会触发,无需清。
            let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LumoryImages")
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: docsURL.path) {
                for name in entries where name.hasPrefix("img_") {
                    try? FileManager.default.removeItem(at: docsURL.appendingPathComponent(name))
                }
            }
        }

        let result = await EntryCreationService.create(
            .init(text: "with attachments", audioFileName: audioFileName, images: [image1, image2], moodValue: 0.5),
            in: persistence,
            viewContext: context,
            ai: ai,
            aliasJudge: { _, _ in },
            requestReminderReschedule: {}
        )

        guard case .saved(let entryID) = result else {
            Issue.record("expected .saved, got \(result)")
            return
        }

        let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", entryID as NSUUID)
        let entries = try context.fetch(request)
        try #require(entries.count == 1)
        let entry = entries[0]

        // audio:本地文件不存在时不应把 fileName 落库,否则日记会指向一个永远无法播放的音频。
        #expect(entry.audioFileName == nil)

        // images:imageFileNames 应有 2 个 CSV 项(`img_<entryID>_0.jpg`, `_1.jpg`),imagesData
        // NSKeyedArchiver blob 非空。
        let csv = entry.imageFileNames ?? ""
        let parts = csv.split(separator: ",").map(String.init)
        #expect(parts.count == 2, "expect 2 image filenames, got: \(csv)")
        #expect(parts.allSatisfy { $0.hasPrefix("img_") && $0.hasSuffix(".jpg") })
        #expect((entry.imagesData?.count ?? 0) > 0, "imagesData should be non-empty NSKeyedArchiver blob")
    }

    @Test func create_saveFailureDeletesInsertedEntryAndReturnsFailure() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let ai = MockAIService()
        struct ForcedSaveError: Error {}

        let result = await EntryCreationService.create(
            .init(text: "will fail", audioFileName: nil, images: [], moodValue: 0.5),
            in: persistence,
            viewContext: context,
            ai: ai,
            saveAction: { _ in throw ForcedSaveError() },
            aliasJudge: { _, _ in },
            requestReminderReschedule: {}
        )

        guard case .failed = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }

        #expect(context.insertedObjects.isEmpty, "save 失败后 inserted DiaryEntry 必须从 context 移除")
        let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
        let entries = try context.fetch(request)
        #expect(entries.isEmpty, "save 失败不应留下 ghost entry")
    }

    @Test func create_saveFailureCleansPersistedImageAndAudioFiles() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let ai = MockAIService()
        struct ForcedSaveError: Error {}

        let fm = FileManager.default
        let imageDir = try LumoryAttachmentPaths.ensureLocalDirectory(for: .image)
        let imageFilesBefore = Set((try? fm.contentsOfDirectory(atPath: imageDir.path)) ?? [])
        let audioName = "test_audio_failure_\(UUID().uuidString).m4a"
        let audioURL = LumoryAttachmentPaths.legacyURL(fileName: audioName)
        try Data(repeating: 0xA1, count: 16).write(to: audioURL)
        defer {
            _ = try? LumoryAttachmentPaths.deleteAllCopies(fileName: audioName, kind: .audio)
            if let files = try? fm.contentsOfDirectory(atPath: imageDir.path) {
                for file in files where !imageFilesBefore.contains(file) {
                    try? fm.removeItem(at: imageDir.appendingPathComponent(file))
                }
            }
        }

        let result = await EntryCreationService.create(
            .init(text: "will fail with attachments", audioFileName: audioName, images: [Data(repeating: 0xBC, count: 64)], moodValue: 0.5),
            in: persistence,
            viewContext: context,
            ai: ai,
            saveAction: { _ in throw ForcedSaveError() },
            aliasJudge: { _, _ in },
            requestReminderReschedule: {}
        )

        guard case .failed = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
        #expect(
            LumoryAttachmentPaths.existingAudioURL(fileName: audioName) != nil,
            "save 失败后 audio 要保留给 HomeView 回滚恢复,不能删掉用户刚录好的内容"
        )
        let imageFilesAfter = Set((try? fm.contentsOfDirectory(atPath: imageDir.path)) ?? [])
        #expect(imageFilesAfter == imageFilesBefore, "save 失败后新写入的 image 文件应被清理")
    }

    @Test func updateMood_missingEntry_returnsFalse() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let ok = EntryCreationService.updateMood(
            entryID: UUID(),
            moodValue: 0.9,
            viewContext: context
        )

        #expect(ok == false, "entry 已不存在时不能静默当成功,否则 HomeView 不会提示保存失败")
    }

    @Test func performAIWriteback_staleText_skipsCommitAndAliasJudge() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let ai = MockAIService()
        let spy = AliasJudgeSpy()

        // Seed:走 `create` 落一条 v1 entry。
        let result = await EntryCreationService.create(
            .init(text: "v1 工作很忙", audioFileName: nil, images: [], moodValue: 0.5),
            in: persistence,
            viewContext: context,
            ai: ai,
            aliasJudge: { id, tags in spy.record(id: id, tags: tags) },
            requestReminderReschedule: {}
        )
        guard case .saved(let entryID) = result else {
            Issue.record("seed expected .saved, got \(result)")
            return
        }

        // 模拟用户在 AI 请求返回前编辑了 entry → text 变 v2。
        let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", entryID as NSUUID)
        let seeded = try context.fetch(request)
        try #require(seeded.count == 1)
        seeded[0].text = "v2 这是修改后的内容"
        try context.save()

        // 用 v1 文本做 snapshot 调 writeback —— 模拟 AI 返回时 entry 已经是 v2。
        let didCommit = await EntryCreationService.performAIWriteback(
            entryID: entryID,
            textSnapshot: "v1 工作很忙",
            in: context,
            ai: ai,
            aliasJudge: { id, tags in spy.record(id: id, tags: tags) }
        )

        #expect(didCommit == false, "stale-write guard 必须丢弃 v1 结果")

        // entry.summary 应仍是 nil(没写回),entry.text 仍是 v2(没被覆盖)。
        let after = try context.fetch(request)
        try #require(after.count == 1)
        #expect(after[0].wrappedText == "v2 这是修改后的内容")
        #expect(after[0].summary == nil, "stale 路径不应写 summary,否则 alias / Insights 引用 ghost 数据")

        // alias judge 不应被调 —— 关键契约,防 ghost 别名建议(参考 codex review)。
        #expect(spy.calls.isEmpty, "stale 路径必须跳过 aliasJudge,否则用户看到基于 v1 的 alias 建议")
    }

    /// 双 reviewer(coredata-migration-reviewer + codex)都独立 flag 的 gap:entry 在 AI 请求返回前
    /// 已被删除 → `performAIWriteback` 内 fetch 拿不到 entry → 必须 no-op return false 且**不**调
    /// aliasJudge。跟 stale-text guard 是同家族但走 `entry == nil` 早返路径,值得显式锁住契约。
    @Test func performAIWriteback_entryDeleted_returnsNoOp_andSkipsAliasJudge() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let ai = MockAIService()
        let spy = AliasJudgeSpy()

        // Seed:落一条 entry。
        let textSnapshot = "今天工作很忙"
        let result = await EntryCreationService.create(
            .init(text: textSnapshot, audioFileName: nil, images: [], moodValue: 0.5),
            in: persistence,
            viewContext: context,
            ai: ai,
            aliasJudge: { _, _ in },
            requestReminderReschedule: {}
        )
        guard case .saved(let entryID) = result else {
            Issue.record("seed expected .saved, got \(result)")
            return
        }

        // 模拟用户立即删了这条 entry(走 viewContext.delete + save 的真实路径)。
        let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", entryID as NSUUID)
        let seeded = try context.fetch(request)
        try #require(seeded.count == 1)
        context.delete(seeded[0])
        try context.save()

        // 现在调 writeback,fetch 拿不到 → 走 `return false` 早返路径,不应触碰 aliasJudge。
        let didCommit = await EntryCreationService.performAIWriteback(
            entryID: entryID,
            textSnapshot: textSnapshot,
            in: context,
            ai: ai,
            aliasJudge: { id, tags in spy.record(id: id, tags: tags) }
        )

        #expect(didCommit == false, "entry 已删 → writeback 必须 return false 不抛")
        #expect(spy.calls.isEmpty, "entry 已删 → 不能调 aliasJudge(没有 entry 再让 alias 建议挂上)")
    }

    /// Codex 独立 flag 的 gap:`create` 收 attachments-only(empty text)时,**fire-and-forget AI
    /// writeback Task 不应被 spawn**(`if !input.text.isEmpty { Task { ... } }` 早返)。锁住这条
    /// 契约 — 防 future 把 guard 误删后 service 给空文本调 AI summarize / extractThemes 浪费 token。
    @Test func create_attachmentsOnly_emptyText_skipsAIWriteback() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let ai = MockAIService()
        let spy = AliasJudgeSpy()

        let image = Data(repeating: 0xEE, count: 32)
        defer {
            let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LumoryImages")
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: docsURL.path) {
                for name in entries where name.hasPrefix("img_") {
                    try? FileManager.default.removeItem(at: docsURL.appendingPathComponent(name))
                }
            }
        }

        let result = await EntryCreationService.create(
            .init(text: "", audioFileName: nil, images: [image], moodValue: 0.5),
            in: persistence,
            viewContext: context,
            ai: ai,
            aliasJudge: { id, tags in spy.record(id: id, tags: tags) },
            requestReminderReschedule: {}
        )
        guard case .saved(let entryID) = result else {
            Issue.record("expected .saved for attachments-only, got \(result)")
            return
        }

        // 给任何被错误 spawn 的 Task 一次跑的机会 — 如果 guard 误失效,这次 yield 后 spy 就会被填。
        for _ in 0..<3 { await Task.yield() }

        let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", entryID as NSUUID)
        let entries = try context.fetch(request)
        try #require(entries.count == 1)
        let entry = entries[0]

        // 主线断言:attachment 落库正常,但 summary 仍 nil(AI Task 没被 spawn → 没人写)。
        #expect(entry.summary == nil, "empty text 不应触发 AI writeback,summary 应保持 nil")
        #expect(entry.themeArray.isEmpty, "empty text 不应触发 extractThemes,themes 应空")
        #expect(spy.calls.isEmpty, "empty text 路径绝不应调 aliasJudge")

        // 顺带验证 attachment metadata 仍写了。
        let csv = entry.imageFileNames ?? ""
        #expect(!csv.isEmpty, "attachment-only 路径仍应落 imageFileNames")
        #expect((entry.imagesData?.count ?? 0) > 0, "attachment-only 路径仍应落 imagesData blob")
    }

    @Test func performAIWriteback_freshText_commitsAndCallsAliasJudge() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let ai = MockAIService()
        let spy = AliasJudgeSpy()

        // text 含 MockAIService.extractThemes 能命中的关键词("工作"/"健康"),保证 themes 非空触发 alias judge。
        let textSnapshot = "今天工作很忙,健康也要注意"

        let result = await EntryCreationService.create(
            .init(text: textSnapshot, audioFileName: nil, images: [], moodValue: 0.6),
            in: persistence,
            viewContext: context,
            ai: ai,
            aliasJudge: { id, tags in spy.record(id: id, tags: tags) },
            requestReminderReschedule: {}
        )
        guard case .saved(let entryID) = result else {
            Issue.record("seed expected .saved, got \(result)")
            return
        }

        // 直接调 writeback 用相同文本,模拟 AI 及时返回(非 stale)。
        let didCommit = await EntryCreationService.performAIWriteback(
            entryID: entryID,
            textSnapshot: textSnapshot,
            in: context,
            ai: ai,
            aliasJudge: { id, tags in spy.record(id: id, tags: tags) }
        )

        #expect(didCommit == true, "fresh 路径应写盘成功")

        let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", entryID as NSUUID)
        let after = try context.fetch(request)
        try #require(after.count == 1)
        let entry = after[0]
        #expect(entry.summary != nil, "summary should be written by AI")
        #expect(!entry.themeArray.isEmpty, "MockAIService 关键词命中应有 themes(如 工作 / 健康)")
        #expect(entry.embeddingVector != nil, "embedding vector should be written")

        // alias judge 至少一次被调(可能不止一次:`create` 的 fire-and-forget 也会调一次,然后 explicit
        // `performAIWriteback` 又调一次)。**最少**一次的契约是:fresh + non-empty themes 必须触发。
        #expect(!spy.calls.isEmpty, "fresh 路径 + non-empty themes 必须触发 aliasJudge")
        #expect(spy.calls.allSatisfy { $0.0 == entryID })
    }

    @Test func performAIWriteback_themeFailurePreservesExistingThemes() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let ai = ThemeFailingAIService()
        let spy = AliasJudgeSpy()

        let entry = DiaryEntry(context: context)
        let entryID = UUID()
        entry.id = entryID
        entry.date = Date()
        entry.text = "今天工作很多,但主题抽取会失败"
        entry.moodValue = 0.5
        entry.setThemes(["旧主题"])
        try context.save()

        let didCommit = await EntryCreationService.performAIWriteback(
            entryID: entryID,
            textSnapshot: entry.wrappedText,
            in: context,
            ai: ai,
            aliasJudge: { id, tags in spy.record(id: id, tags: tags) }
        )

        #expect(didCommit == true, "summary / embedding 成功时仍应写回,不能因 theme 失败整条放弃")
        #expect(entry.themeArray == ["旧主题"], "theme 抽取失败时必须保留旧 themes,不能清空")
        #expect(entry.summary != nil)
        #expect(entry.embeddingVector != nil)
        #expect(spy.calls.isEmpty, "theme 未实际写入时不应触发 aliasJudge")
    }
}
