import Foundation
import CoreData

/// 简单的数据结构，用于在AI服务中传递日记数据，避免CloudKit同步冲突
struct DiaryEntryData {
    let id: UUID
    let date: Date
    let text: String
    let moodValue: Double
    let summary: String
    // Phase 0 扩展：AI × 统计融合需要的额外字段，缺省为空以兼容旧调用点
    let themes: [String]
    let embedding: [Float]?
    let wordCount: Int

    init(id: UUID,
         date: Date,
         text: String,
         moodValue: Double,
         summary: String,
         themes: [String] = [],
         embedding: [Float]? = nil,
         wordCount: Int = 0) {
        self.id = id
        self.date = date
        self.text = text
        self.moodValue = moodValue
        self.summary = summary
        self.themes = themes
        self.embedding = embedding
        self.wordCount = wordCount
    }
    
    /// 同步的纯函数构造器——**调用方必须保证已经在 entry.managedObjectContext 的队列里**。
    /// 把 CoreData 字段拷成值类型时把新加的 themes/embedding/wordCount 一并带上，
    /// 避免经 DiaryEntryData 再写回 CoreData 时用默认值清零这三列。
    static func from(fetchedEntry: DiaryEntry) -> DiaryEntryData {
        DiaryEntryData(
            id: fetchedEntry.id ?? UUID(),
            date: fetchedEntry.date ?? Date(),
            text: fetchedEntry.text ?? "",
            moodValue: fetchedEntry.moodValue,
            summary: fetchedEntry.summary ?? "",
            themes: fetchedEntry.themeArray,
            embedding: fetchedEntry.embeddingVector,
            wordCount: Int(fetchedEntry.wordCount)
        )
    }

    /// 从Core Data DiaryEntry创建安全的数据副本 (async版本，推荐使用)
    static func from(_ entry: DiaryEntry) async -> DiaryEntryData? {
        guard let context = entry.managedObjectContext else { return nil }

        // Capture objectID which is Sendable, then fetch in context.perform
        let objectID = entry.objectID

        return await context.perform {
            do {
                // `as?` 而不是 `as!`：即使 existingObject 成功取到对象，类型漂移 / 测试桩 / CloudKit
                // 同步过来的残留实体都可能不是 DiaryEntry，force cast 会触发 runtime trap 整个 App 崩。
                guard let fetchedEntry = try context.existingObject(with: objectID) as? DiaryEntry else {
                    Log.error("[DiaryEntryData] objectID 不是 DiaryEntry: \(objectID)", category: .persistence)
                    return nil
                }
                return DiaryEntryData.from(fetchedEntry: fetchedEntry)
            } catch {
                Log.error("[DiaryEntryData] 创建数据副本失败: \(error)", category: .persistence)
                return nil
            }
        }
    }

    /// 从Core Data DiaryEntry创建安全的数据副本 (同步版本，仅在已知主线程时使用)
    @MainActor
    static func fromSync(_ entry: DiaryEntry) -> DiaryEntryData? {
        guard entry.managedObjectContext != nil else { return nil }
        return DiaryEntryData.from(fetchedEntry: entry)
    }
}