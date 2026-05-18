//
//  CoreDataImportServiceTests.swift
//  ChronoteTests
//
//  **Scope**:锁住 `CoreDataImportService.importEntries` wrapper 的 rethrow + isImporting
//  状态复位 + 多种 dedup 路径(NFC/NFD / 同 day+text / chunk 成功)。**仅 wrapper 行为**。
//
//   - 解析失败(network / parse / etc) → 重抛 DiaryImportError + isImporting/Progress 复位
//   - parsed.isEmpty → 返 .empty(没识别到日记是合法情况,不算 error)
//   - 同 day + 同 text → 第二条被 fingerprint 去重(skipped)
//   - NFD 文本被规范化成 NFC → 两条本质同一篇,去重生效
//   - 整批 import 成功 → 每条都进 viewContext + counts 对得上
//
//  **未覆盖**(CLAUDE.md backlog 仍开着,**不要据此勾掉那条**):
//  `Chronote/Services/OpenAI/OpenAIService+Import.swift` 的 `parseImportedDiaries` parser
//  本体错误路径(malformed JSON / 部分截断 / 5xx HTML)。本文件用 `ImportTestDouble` 直接注入
//  parser 抛错,**绕过了真 parser**。要勾掉 backlog 那条,需要单独加 URLProtocol mock + 真
//  错误响应 fixtures 测 `OpenAIService+Import`。
//

import XCTest
import CoreData
@testable import Lumory

/// 可配置的 AI 测试 double — 让单测控制 parseImportedDiaries 的返值 / 抛错。
/// MockAIService 默认 parseImportedDiaries 返 [],不够灵活测各种场景。
@MainActor
// `@unchecked Sendable` — `AIServiceProtocol: Sendable` 要求 conformer 满足。test double 用
// mutable `var` 字段记录 call count / fixtures,实际所有测试都从主线程驱动(单测 await 模式),
// race 不存在但 Swift 类型系统看不出。`@unchecked` 把这条挂出来。
private final class ImportTestDouble: AIServiceProtocol, @unchecked Sendable {
    var parseResult: [ParsedDiaryEntry] = []
    var parseError: Error?
    var parseCallCount = 0

    // 四件套 mock 行为 — 走 prefix / 简单 keyword 匹配,跟 MockAIService 同 idiom。
    nonisolated func summarize(text: String) async -> String? {
        String(text.prefix(50))
    }
    nonisolated func analyzeMood(text: String) async -> Double { 0.5 }
    nonisolated func extractThemes(text: String) async -> [String] { ["import"] }
    nonisolated func embed(text: String) async -> [Float]? { Array(repeating: 0.1, count: 16) }
    nonisolated func judgeThemeAliases(newTags: [String], inventory: [ThemeAliasJudgeCandidate]) async -> [ThemeAliasJudgeMatch] { [] }
    nonisolated func scanThemeAliasGroups(candidates: [ThemeAliasJudgeCandidate]) async throws -> [ThemeAliasJudgeGroup] { [] }
    nonisolated func askEvents(question: String, context entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
        AsyncStream { $0.finish() }
    }
    nonisolated func streamReportEvents(entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
        AsyncStream { $0.finish() }
    }
    nonisolated func composeSuggestions(context: SuggestionContext) async -> SuggestionBundle? { nil }

    func parseImportedDiaries(rawText: String) async throws -> [ParsedDiaryEntry] {
        parseCallCount += 1
        if let parseError {
            throw parseError
        }
        return parseResult
    }
}

@MainActor
final class CoreDataImportServiceTests: XCTestCase {

    // MARK: - Error path

    /// `parseImportedDiaries` 抛 network error → importEntries 重抛 + state 复位。
    /// 老 bug:把任何 throw 都吞成 "succeeded=0",用户看不到真错。CLAUDE.md backlog 标的点。
    func testImportEntries_parseNetworkError_rethrowsAndResetsState() async {
        let persistence = PersistenceController(inMemory: true)
        let ai = ImportTestDouble()
        ai.parseError = DiaryImportError.network(URLError(.notConnectedToInternet))
        let service = CoreDataImportService(aiService: ai)

        do {
            _ = try await service.importEntries(from: "some text", context: persistence.container.viewContext)
            XCTFail("expected throw, got success")
        } catch let error as DiaryImportError {
            // DiaryImportError 不是 Equatable(.network 有 associated Error)→ 用 pattern match
            if case .network = error {
                // ✓
            } else {
                XCTFail("expected .network, got \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }

        XCTAssertFalse(service.isImporting, "isImporting must be reset after error")
        XCTAssertEqual(service.importProgress, 0.0, "importProgress must be reset to 0")
    }

    /// 空 rawText 通过 MockAIService 默认抛 .emptyInput — ImportTestDouble 不抛,这里测的是 importEntries
    /// 在解析返 [] 时返回 .empty 不抛(parsed empty 是合法,不是 error)。
    func testImportEntries_parseReturnsEmpty_returnsEmptyResult() async throws {
        let persistence = PersistenceController(inMemory: true)
        let ai = ImportTestDouble()
        ai.parseResult = []  // parse 不抛,返空
        let service = CoreDataImportService(aiService: ai)

        let result = try await service.importEntries(from: "ambiguous text", context: persistence.container.viewContext)

        XCTAssertEqual(result, CoreDataImportService.ImportResult.empty,
                       "parse 返 [] 是合法(用户粘贴里没识别到日记),应返 .empty,不抛")
        XCTAssertFalse(service.isImporting)
        XCTAssertEqual(service.importProgress, 0.0)
    }

    // MARK: - Happy path

    /// 一批不重复的日记 → succeeded 计数对,失败 0,跳过 0,viewContext 内有对应行。
    func testImportEntries_uniqueEntries_allSucceed() async throws {
        let persistence = PersistenceController(inMemory: true)
        let ctx = persistence.container.viewContext

        let day1 = makeDate(year: 2025, month: 1, day: 1)
        let day2 = makeDate(year: 2025, month: 1, day: 2)
        let day3 = makeDate(year: 2025, month: 1, day: 3)
        let ai = ImportTestDouble()
        ai.parseResult = [
            ParsedDiaryEntry(date: day1, text: "first day"),
            ParsedDiaryEntry(date: day2, text: "second day"),
            ParsedDiaryEntry(date: day3, text: "third day")
        ]
        let service = CoreDataImportService(aiService: ai)

        let result = try await service.importEntries(from: "doesn't matter (mocked)", context: ctx)

        XCTAssertEqual(result.succeeded, 3)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.skipped, 0)

        let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
        let entries = try ctx.fetch(request)
        XCTAssertEqual(entries.count, 3, "3 unique entries must land in CoreData")
        XCTAssertEqual(Set(entries.map { $0.text ?? "" }), ["first day", "second day", "third day"])
    }

    // MARK: - Fingerprint dedup

    /// 同 day + 同 text → 第二条被 skipped 计数(fingerprint dedup)。
    func testImportEntries_sameDayAndText_secondIsSkipped() async throws {
        let persistence = PersistenceController(inMemory: true)
        let ctx = persistence.container.viewContext

        let day = makeDate(year: 2025, month: 1, day: 5)
        let ai = ImportTestDouble()
        ai.parseResult = [
            ParsedDiaryEntry(date: day, text: "today was good"),
            ParsedDiaryEntry(date: day, text: "today was good")  // 一模一样
        ]
        let service = CoreDataImportService(aiService: ai)

        let result = try await service.importEntries(from: "raw", context: ctx)

        XCTAssertEqual(result.succeeded, 1, "only first entry should be saved")
        XCTAssertEqual(result.skipped, 1, "second (duplicate) must be skipped, not failed")
        XCTAssertEqual(result.failed, 0)

        let entries = try ctx.fetch(NSFetchRequest<DiaryEntry>(entityName: "DiaryEntry"))
        XCTAssertEqual(entries.count, 1)
    }

    /// NFD vs NFC 文本(同一文字不同编码)→ NFC 规范化后视为同一篇,第二条 skipped。
    /// 老 bug:用户从两个源粘贴同一日记,一处 NFD 一处 NFC,fingerprint 不同 → 重复入库。
    func testImportEntries_sameDayNFCvsNFD_treatedAsDuplicate() async throws {
        let persistence = PersistenceController(inMemory: true)
        let ctx = persistence.container.viewContext

        let day = makeDate(year: 2025, month: 2, day: 14)
        // 显式构造 NFC / NFD,而不是依赖源文件存的"café"被编辑器存成哪种形式。
        let nfcText = "caf\u{00E9}"  // 单 codepoint é (U+00E9)
        let nfdText = "cafe\u{0301}"  // 'e' + 组合重音 (U+0301)
        // **Precondition**:Swift String `==` 用 canonical equivalence → NFC == NFD 在 Swift 层。
        // 但**底层 UTF-8 bytes 不同**(NFC `é` 2 bytes,NFD `e` + combining 总 3 bytes)。
        // fingerprint 之前若直接拿 raw text 算 hash,两条会落不同 bucket。
        XCTAssertNotEqual(Array(nfcText.utf8), Array(nfdText.utf8),
                          "precondition: NFC / NFD raw UTF-8 bytes 不同(Swift 层 == 是 canonical equal)")

        let ai = ImportTestDouble()
        ai.parseResult = [
            ParsedDiaryEntry(date: day, text: nfcText),
            ParsedDiaryEntry(date: day, text: nfdText)
        ]
        let service = CoreDataImportService(aiService: ai)

        let result = try await service.importEntries(from: "raw", context: ctx)

        XCTAssertEqual(result.succeeded, 1, "first (NFC) entry saved")
        XCTAssertEqual(result.skipped, 1,
                       "second (NFD same text same day) must be skipped — fingerprint normalizes via precomposedStringWithCanonicalMapping")
    }

    /// 案例已入库 + 用户再次 import 同一篇 → fingerprint 命中已有数据,skipped。
    func testImportEntries_existingDBEntry_isSkippedOnRepeatImport() async throws {
        let persistence = PersistenceController(inMemory: true)
        let ctx = persistence.container.viewContext

        // Seed:先手动插入一条
        let day = makeDate(year: 2025, month: 3, day: 1)
        let seeded = DiaryEntry(context: ctx)
        seeded.id = UUID()
        seeded.date = day
        seeded.text = "already here"
        try ctx.save()

        // Import 同一 (day, text)
        let ai = ImportTestDouble()
        ai.parseResult = [
            ParsedDiaryEntry(date: day, text: "already here")
        ]
        let service = CoreDataImportService(aiService: ai)

        let result = try await service.importEntries(from: "raw", context: ctx)

        XCTAssertEqual(result.succeeded, 0)
        XCTAssertEqual(result.skipped, 1, "already-seeded entry should be detected by fingerprint and skipped")
        XCTAssertEqual(result.failed, 0)

        // 数据库里仍然只有那一条 seeded(没多出 dup)
        let entries = try ctx.fetch(NSFetchRequest<DiaryEntry>(entityName: "DiaryEntry"))
        XCTAssertEqual(entries.count, 1)
    }

    // MARK: - Helpers

    /// 跨 test 通用 date factory(同 ChronoteTests.swift 里的 makeDate 同 idiom)。
    private func makeDate(year: Int, month: Int, day: Int) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12
        return Calendar(identifier: .gregorian).date(from: comps)!
    }
}
