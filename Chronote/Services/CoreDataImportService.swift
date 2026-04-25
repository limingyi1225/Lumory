import Foundation
import CoreData
import SwiftUI

@MainActor
class CoreDataImportService: ObservableObject {
    @Published var isImporting: Bool = false
    @Published var importProgress: Double = 0.0

    // 注入 AI 服务（后端代理处理认证）。默认用真实 OpenAIService；
    // 测试可传入 MockAIService 来跳过网络调用。
    private let aiService: AIServiceProtocol

    init(aiService: AIServiceProtocol = OpenAIService.shared) {
        self.aiService = aiService
    }

    /// 根据用户粘贴的原始文本批量导入日记到 Core Data
    /// 返回 (成功条数, 失败条数) 供 UI 向用户反馈。
    /// **抛错语义**:解析层(网络 / 后端 / JSON)失败时抛 `DiaryImportError`,UI 应 catch
    /// 后展示真错误,而非把它当 "succeeded=0" 的 happy-path。
    /// 解析返回 `[]`(粘贴内容里没识别到日记)是合法情况,这里仍返回 `(0, 0)`,UI 在
    /// `DiaryImportView` 里用专门的 "no entries detected" 文案区分。
    @discardableResult
    func importEntries(from rawText: String, context: NSManagedObjectContext) async throws -> (succeeded: Int, failed: Int) {
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
            return (0, 0)
        }

        let total = parsed.count
        var succeeded = 0
        var failed = 0
        for (index, entry) in parsed.enumerated() {
            let date = entry.date
            let text = entry.text
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

            // **错误时 rollback**：以前 save 失败只 log 继续循环，但失败的 NSManagedObject 已经
            // `insertNewObject` 进 context 了，仍挂在脏集合里——下一次 save（别的 entry、或 CloudKit
            // 触发的 merge）会连带尝试再提交一次，context 持续中毒。
            // `context.delete(newEntry)` 把这条从 context 里摘掉（save 前的 delete 是免 disk round-trip 的）。
            do {
                try context.save()
                succeeded += 1
            } catch {
                Log.error("[CoreDataImportService] 保存条目失败，回滚此条: \(error)", category: .migration)
                context.delete(newEntry)
                // rollback 把未提交状态全丢掉；对已经 save 过的前面的条目没影响
                context.rollback()
                failed += 1
            }

            // 更新进度
            importProgress = Double(index + 1) / Double(total)
            Log.info("[CoreDataImportService] importEntries: imported entry \(index + 1)/\(total)", category: .migration)
        }

        // 导入完成后
        isImporting = false
        importProgress = 1.0
        Log.info("[CoreDataImportService] importEntries: import completed succeeded=\(succeeded) failed=\(failed)", category: .migration)
        return (succeeded, failed)
    }
} 