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
        var insertedCount = 0
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
            insertedCount += 1

            // 更新进度
            importProgress = Double(index + 1) / Double(total)
            Log.info("[CoreDataImportService] importEntries: imported entry \(index + 1)/\(total)", category: .migration)
        }

        if insertedCount > 0 {
            do {
                try context.save()
                succeeded += insertedCount
            } catch {
                Log.error("[CoreDataImportService] 批量保存导入条目失败，回滚 \(insertedCount) 条: \(error)", category: .migration)
                context.rollback()
                failed += insertedCount
            }
        }

        // 导入完成后
        isImporting = false
        importProgress = 1.0
        Log.info("[CoreDataImportService] importEntries: import completed succeeded=\(succeeded) failed=\(failed) skipped=\(skipped)", category: .migration)
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

    private static func fingerprint(date: Date, text: String) -> String {
        "\(date.timeIntervalSinceReferenceDate)|\(text.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}
