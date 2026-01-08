import Foundation
import CoreData

/// 简单的数据结构，用于在AI服务中传递日记数据，避免CloudKit同步冲突
struct DiaryEntryData {
    let id: UUID
    let date: Date
    let text: String
    let moodValue: Double
    let summary: String
    
    init(id: UUID, date: Date, text: String, moodValue: Double, summary: String) {
        self.id = id
        self.date = date
        self.text = text
        self.moodValue = moodValue
        self.summary = summary
    }
    
    /// 从Core Data DiaryEntry创建安全的数据副本 (async版本，推荐使用)
    static func from(_ entry: DiaryEntry) async -> DiaryEntryData? {
        guard let context = entry.managedObjectContext else { return nil }

        // Capture objectID which is Sendable, then fetch in context.perform
        let objectID = entry.objectID

        return await context.perform {
            do {
                let fetchedEntry = try context.existingObject(with: objectID) as! DiaryEntry

                return DiaryEntryData(
                    id: fetchedEntry.id ?? UUID(),
                    date: fetchedEntry.date ?? Date(),
                    text: fetchedEntry.text ?? "",
                    moodValue: fetchedEntry.moodValue,
                    summary: fetchedEntry.summary ?? ""
                )
            } catch {
                print("[DiaryEntryData] 创建数据副本失败: \(error)")
                return nil
            }
        }
    }

    /// 从Core Data DiaryEntry创建安全的数据副本 (同步版本，仅在已知主线程时使用)
    @MainActor
    static func fromSync(_ entry: DiaryEntry) -> DiaryEntryData? {
        guard entry.managedObjectContext != nil else { return nil }

        // 在主线程直接访问 viewContext 是安全的
        return DiaryEntryData(
            id: entry.id ?? UUID(),
            date: entry.date ?? Date(),
            text: entry.text ?? "",
            moodValue: entry.moodValue,
            summary: entry.summary ?? ""
        )
    }
    
    /// 从一组DiaryEntry安全地创建数据副本，使用独立的后台上下文 (async版本，推荐使用)
    static func safelyExtractData(from entries: [DiaryEntry], dateRange: ClosedRange<Date>) async -> [DiaryEntryData] {
        print("[DiaryEntryData] 开始安全提取数据，条目数量: \(entries.count)")

        // 获取所有objectID，这些在不同上下文间是安全的
        let objectIDs = entries.map { $0.objectID }

        return await withCheckedContinuation { continuation in
            // 使用 performBackgroundTask 确保在后台线程执行
            PersistenceController.shared.container.performBackgroundTask { context in
                context.automaticallyMergesChangesFromParent = false // 不自动合并变更

                var safeData: [DiaryEntryData] = []

                for objectID in objectIDs {
                    do {
                        let entry = try context.existingObject(with: objectID) as! DiaryEntry

                        // 提取数据
                        let entryDate = entry.date ?? Date()

                        // 检查日期范围
                        guard dateRange.contains(entryDate) else { continue }

                        let data = DiaryEntryData(
                            id: entry.id ?? UUID(),
                            date: entryDate,
                            text: entry.text ?? "",
                            moodValue: entry.moodValue,
                            summary: entry.summary ?? ""
                        )

                        safeData.append(data)
                        print("[DiaryEntryData] 成功提取条目: \(data.id), 文本长度: \(data.text.count)")
                    } catch {
                        print("[DiaryEntryData] 跳过无法访问的条目: \(error)")
                        continue
                    }
                }

                print("[DiaryEntryData] 安全提取完成，有效条目数量: \(safeData.count)")
                continuation.resume(returning: safeData)
            }
        }
    }

    /// 从一组DiaryEntry安全地创建数据副本 (同步版本，已废弃)
    @available(*, deprecated, message: "Use async version instead to avoid blocking main thread")
    static func safelyExtractDataSync(from entries: [DiaryEntry], dateRange: ClosedRange<Date>) -> [DiaryEntryData] {
        print("[DiaryEntryData] 开始安全提取数据（同步），条目数量: \(entries.count)")

        // 获取所有objectID
        let objectIDs = entries.map { $0.objectID }

        // 创建一个独立的后台上下文
        let backgroundContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        backgroundContext.parent = PersistenceController.shared.container.viewContext
        backgroundContext.automaticallyMergesChangesFromParent = false

        var safeData: [DiaryEntryData] = []

        backgroundContext.performAndWait {
            for objectID in objectIDs {
                do {
                    let entry = try backgroundContext.existingObject(with: objectID) as! DiaryEntry
                    let entryDate = entry.date ?? Date()

                    guard dateRange.contains(entryDate) else { continue }

                    let data = DiaryEntryData(
                        id: entry.id ?? UUID(),
                        date: entryDate,
                        text: entry.text ?? "",
                        moodValue: entry.moodValue,
                        summary: entry.summary ?? ""
                    )

                    safeData.append(data)
                } catch {
                    continue
                }
            }
        }

        return safeData
    }
}