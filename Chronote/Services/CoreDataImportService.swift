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

        let parsed: [ParsedDiaryEntry]
        do {
            // 走注入的 AIService,Mock 在测试中可拦截。旧实现调静态 `DiaryImportService.parse`,
            // 完全绕过 DI;现已删除该 free function。
            parsed = try await aiService.parseImportedDiaries(rawText: rawText)
        } catch {
            Log.error("[CoreDataImportService] parse failed: \(error)", category: .migration)
            isImporting = false
            importProgress = 0.0
            throw error
        }
        Log.info("[CoreDataImportService] importEntries: parsed count = \(parsed.count)", category: .migration)

        guard !parsed.isEmpty else {
            Log.info("[CoreDataImportService] importEntries: parsed isEmpty (no entries detected in paste)", category: .migration)
            isImporting = false
            importProgress = 0.0
            return .empty
        }

        let total = parsed.count
        var succeeded = 0
        var failed = 0
        var skipped = 0
        var insertedSinceLastSave = 0
        // **chunk save** — 每 chunkSize 条 save 一次,而不是全部 N 条结束后单次 save。
        // 单次 save 失败 = 整批 N×4 = 4N 个 AI call(~$1)钱白付。chunk=10 是经验值:
        // 失败时丢的最大 batch 是 10 条 = 40 AI call 的 cost,比一次性 200 强 5×。
        let chunkSize = 10
        var seenFingerprints = existingEntryFingerprints(in: context)
        for (index, entry) in parsed.enumerated() {
            let date = entry.date
            let text = entry.text
            let fingerprint = Self.fingerprint(date: date, text: text)
            guard seenFingerprints.insert(fingerprint).inserted else {
                Log.info("[CoreDataImportService] 跳过重复导入条目: \(date)", category: .migration)
                skipped += 1
                importProgress = Double(index + 1) / Double(total)
                continue
            }
            // 和 HomeView.addEntry 保持一致的四件套流水线：summary / mood / themes / embedding
            // 并行发 AI 请求，避免一条日记串行等 4 轮。wordCount 本地算，免费。
            async let summaryTask = aiService.summarize(text: text)
            async let moodTask = aiService.analyzeMood(text: text)
            async let themesTask = aiService.extractThemes(text: text)
            async let embeddingTask = aiService.embed(text: text)

            let (summary, moodValue, themes, embedding) =
                await (summaryTask, moodTask, themesTask, embeddingTask)

            // 创建 Core Data 实体
            let raw = NSEntityDescription.insertNewObject(forEntityName: "DiaryEntry", into: context)
            guard let newEntry = raw as? DiaryEntry else {
                Log.error("[CoreDataImportService] DiaryEntry 类型转换失败，跳过", category: .migration)
                context.delete(raw)
                failed += 1
                continue
            }
            newEntry.id = UUID()
            newEntry.date = date
            newEntry.text = text
            newEntry.moodValue = moodValue
            newEntry.summary = summary
            newEntry.setThemes(themes)
            if let vector = embedding {
                newEntry.setEmbedding(vector)
            }
            newEntry.recomputeWordCount()
            insertedSinceLastSave += 1

            // 更新进度
            importProgress = Double(index + 1) / Double(total)
            Log.info("[CoreDataImportService] importEntries: imported entry \(index + 1)/\(total)", category: .migration)

            // 凑够 chunkSize 条 save 一次。失败仅丢这 chunk(已经 AI 跑完的钱白付,但比全 N 强)。
            if insertedSinceLastSave >= chunkSize {
                do {
                    try context.save()
                    succeeded += insertedSinceLastSave
                    insertedSinceLastSave = 0
                } catch {
                    Log.error("[CoreDataImportService] chunk 保存失败，回滚 \(insertedSinceLastSave) 条: \(error)", category: .migration)
                    context.rollback()
                    failed += insertedSinceLastSave
                    insertedSinceLastSave = 0
                    // 重新 fetch fingerprint(rollback 把 in-memory 的也清了,后续 dedup 仍要正确)。
                    seenFingerprints = existingEntryFingerprints(in: context)
                }
            }
        }

        // 收尾:还剩 < chunkSize 条没 save 的
        if insertedSinceLastSave > 0 {
            do {
                try context.save()
                succeeded += insertedSinceLastSave
            } catch {
                Log.error("[CoreDataImportService] 收尾 save 失败，回滚 \(insertedSinceLastSave) 条: \(error)", category: .migration)
                context.rollback()
                failed += insertedSinceLastSave
            }
        }

        // 导入完成后
        isImporting = false
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
