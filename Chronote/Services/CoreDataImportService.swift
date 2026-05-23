import Foundation
import CoreData
import SwiftUI

@MainActor
class CoreDataImportService: ObservableObject {
    struct ImportResult: Equatable {
        let succeeded: Int
        let failed: Int
        let skipped: Int

        static let empty = ImportResult(succeeded: 0, failed: 0, skipped: 0)
    }

    @Published var isImporting: Bool = false
    @Published var importProgress: Double = 0.0

    // 注入 AI 服务（后端代理处理认证）。默认用真实 OpenAIService；
    // 测试可传入 MockAIService 来跳过网络调用。
    private let aiService: AIServiceProtocol

    init(aiService: AIServiceProtocol = OpenAIService.shared) {
        self.aiService = aiService
    }

    /// 根据用户粘贴的原始文本批量导入日记到 Core Data
    /// 返回导入结果计数(成功 / 失败 / 跳过重复)供 UI 向用户反馈。
    /// **抛错语义**:解析层(网络 / 后端 / JSON)失败时抛 `DiaryImportError`,UI 应 catch
    /// 后展示真错误,而非把它当 "succeeded=0" 的 happy-path。
    /// 解析返回 `[]`(粘贴内容里没识别到日记)是合法情况,这里仍返回 `.empty`,UI 在
    /// `DiaryImportView` 里用专门的 "no entries detected" 文案区分。
    @discardableResult
    func importEntries(from rawText: String, context: NSManagedObjectContext) async throws -> ImportResult {
        Log.info("[CoreDataImportService] importEntries: rawText length = \(rawText.count)", category: .migration)
        isImporting = true
        importProgress = 0.0
        defer {
            isImporting = false
        }

        let parsed: [ParsedDiaryEntry]
        do {
            // 走注入的 AIService,Mock 在测试中可拦截。旧实现调静态 `DiaryImportService.parse`,
            // 完全绕过 DI;现已删除该 free function。
            parsed = try await aiService.parseImportedDiaries(rawText: rawText)
        } catch {
            Log.error("[CoreDataImportService] parse failed: \(error)", category: .migration)
            importProgress = 0.0
            throw error
        }
        Log.info("[CoreDataImportService] importEntries: parsed count = \(parsed.count)", category: .migration)

        guard !parsed.isEmpty else {
            Log.info("[CoreDataImportService] importEntries: parsed isEmpty (no entries detected in paste)", category: .migration)
            importProgress = 0.0
            return .empty
        }

        let total = parsed.count
        var succeeded = 0
        var failed = 0
        var skipped = 0
        var pendingEntries: [PreparedImportEntry] = []
        // **chunk save** — 每 chunkSize 条 save 一次,而不是全部 N 条结束后单次 save。
        // 单次 save 失败 = 整批 N×4 = 4N 个 AI call(~$1)钱白付。chunk=10 是经验值:
        // 失败时丢的最大 batch 是 10 条 = 40 AI call 的 cost,比一次性 200 强 5×。
        let chunkSize = 10
        var seenFingerprints = existingEntryFingerprints(in: context)
        for (index, entry) in parsed.enumerated() {
            defer {
                importProgress = Double(index + 1) / Double(total)
            }
            let date = entry.date
            let text = entry.text
            let fingerprint = Self.fingerprint(date: date, text: text)
            guard seenFingerprints.insert(fingerprint).inserted else {
                Log.info("[CoreDataImportService] 跳过重复导入条目: \(date)", category: .migration)
                skipped += 1
                continue
            }
            // 和 HomeView.addEntry 保持一致的四件套流水线：summary / mood / themes / embedding
            // 并行发 AI 请求，避免一条日记串行等 4 轮。wordCount 本地算，免费。
            async let summaryTask = aiService.summarize(text: text)
            async let moodTask = aiService.analyzeMood(text: text)
            async let themesTask = aiService.extractThemesOutcome(text: text)
            async let embeddingTask = aiService.embed(text: text)

            let (summary, moodValue, themeOutcome, embedding) =
                await (summaryTask, moodTask, themesTask, embeddingTask)
            let themes: [String]? = {
                guard case .success(let tags) = themeOutcome else {
                    Log.info("[CoreDataImportService] theme 抽取失败,本条导入不写 themes: \(date)", category: .migration)
                    return nil
                }
                return tags
            }()

            // 创建 Core Data 实体
            let preparedEntry = PreparedImportEntry(
                date: date,
                text: text,
                summary: summary,
                moodValue: moodValue,
                themes: themes,
                embedding: embedding
            )
            guard insertPreparedEntry(preparedEntry, into: context) else {
                failed += 1
                seenFingerprints.remove(fingerprint)
                continue
            }
            pendingEntries.append(preparedEntry)

            Log.info("[CoreDataImportService] importEntries: imported entry \(index + 1)/\(total)", category: .migration)

            // 凑够 chunkSize 条 save 一次。失败时 chunk 内逐条 retry,避免 1 条坏数据拖垮整组。
            if pendingEntries.count >= chunkSize {
                let result = savePendingEntries(pendingEntries, context: context, label: "chunk")
                succeeded += result.succeeded
                failed += result.failed
                pendingEntries.removeAll(keepingCapacity: true)
                // 每次 save 后重新 fetch fingerprint,捕获 import 期间 viewContext/CloudKit 的并发写入。
                seenFingerprints = existingEntryFingerprints(in: context)
            }
        }

        // 收尾:还剩 < chunkSize 条没 save 的
        if !pendingEntries.isEmpty {
            let result = savePendingEntries(pendingEntries, context: context, label: "final")
            succeeded += result.succeeded
            failed += result.failed
        }

        // 导入完成后
        importProgress = 1.0
        Log.info("[CoreDataImportService] importEntries: import completed succeeded=\(succeeded) failed=\(failed) skipped=\(skipped)", category: .migration)

        // J: 大批 import 完成后,首页占位 / askPast suggestion 池里的指纹已变。
        // 下次 refreshIfNeeded 会用新指纹重建,但要主动 trigger 一次让用户立刻看到新主题。
        // 不调 judgeAfterWrite —— 一次 import 50 条 = 50× judge call($$),过度;用户想要 alias
        // 识别要走 Settings 的"扫描已有主题"(scanAllHistory)显式触发。
        if succeeded > 0 {
            Task { @MainActor in
                await PromptSuggestionEngine.shared.refreshIfNeeded()
            }
        }
        return ImportResult(succeeded: succeeded, failed: failed, skipped: skipped)
    }

    private struct PreparedImportEntry {
        let date: Date
        let text: String
        let summary: String?
        let moodValue: Double
        let themes: [String]?
        let embedding: [Float]?
    }

    @discardableResult
    private func insertPreparedEntry(_ entry: PreparedImportEntry, into context: NSManagedObjectContext) -> Bool {
        let raw = NSEntityDescription.insertNewObject(forEntityName: "DiaryEntry", into: context)
        guard let newEntry = raw as? DiaryEntry else {
            Log.error("[CoreDataImportService] DiaryEntry 类型转换失败，跳过", category: .migration)
            context.delete(raw)
            return false
        }
        newEntry.id = UUID()
        newEntry.date = entry.date
        newEntry.text = entry.text
        newEntry.moodValue = entry.moodValue
        newEntry.summary = entry.summary
        if let themes = entry.themes {
            newEntry.setThemes(themes)
        }
        if let vector = entry.embedding {
            newEntry.setEmbedding(vector)
        }
        newEntry.recomputeWordCount()
        return true
    }

    private func savePendingEntries(
        _ entries: [PreparedImportEntry],
        context: NSManagedObjectContext,
        label: String
    ) -> (succeeded: Int, failed: Int) {
        do {
            try context.save()
            return (entries.count, 0)
        } catch {
            Log.error(
                "[CoreDataImportService] \(label) 保存失败，回滚 \(entries.count) 条并逐条重试: \(error)",
                category: .migration
            )
            context.rollback()
            return retryEntriesIndividually(entries, context: context, label: label)
        }
    }

    private func retryEntriesIndividually(
        _ entries: [PreparedImportEntry],
        context: NSManagedObjectContext,
        label: String
    ) -> (succeeded: Int, failed: Int) {
        var succeeded = 0
        var failed = 0
        for entry in entries {
            guard insertPreparedEntry(entry, into: context) else {
                context.rollback()
                failed += 1
                continue
            }
            do {
                try context.save()
                succeeded += 1
            } catch {
                context.rollback()
                failed += 1
                Log.error(
                    "[CoreDataImportService] \(label) 单条保存失败 \(entry.date): \(error)",
                    category: .migration
                )
            }
        }
        return (succeeded, failed)
    }

    private func existingEntryFingerprints(in context: NSManagedObjectContext) -> Set<String> {
        let request = NSFetchRequest<NSDictionary>(entityName: "DiaryEntry")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["date", "text"]
        guard let rows = try? context.fetch(request) else { return [] }
        return Set(rows.compactMap { row in
            guard let date = row["date"] as? Date,
                  let text = row["text"] as? String else { return nil }
            return Self.fingerprint(date: date, text: text)
        })
    }

    /// 用 day 粒度 + NFC normalize + lowercased 做 fingerprint。
    /// 之前用 `timeIntervalSinceReferenceDate`(秒级 Double)+ raw text:
    ///   - 同一天内多次 import 同文本秒级时戳不同 → 误判不重复 → 重复入库
    ///   - 用户从两个源粘贴同一日记,一处 NFC 一处 NFD,fingerprint 不同 → 误判不重复
    /// 改成 `startOfDay` 秒级整数 + NFC normalized + lowercased trim,贴近"用户认知里的同一篇"。
    private static func fingerprint(date: Date, text: String) -> String {
        let dayStart = Calendar.current.startOfDay(for: date)
        let daySeconds = Int(dayStart.timeIntervalSince1970)
        let normalizedText = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
        return "\(daySeconds)|\(normalizedText)"
    }
}
