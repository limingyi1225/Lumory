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
    
    /// 从Core Data DiaryEntry创建安全的数据副本
    static func from(_ entry: DiaryEntry) -> DiaryEntryData? {
        // 在主线程中安全访问Core Data属性
        guard let context = entry.managedObjectContext else { return nil }
        
        var result: DiaryEntryData?
        context.performAndWait {
            do {
                // 确保对象不是fault
                if entry.isFault {
                    try context.existingObject(with: entry.objectID)
                }
                
                result = DiaryEntryData(
                    id: entry.id ?? UUID(),
                    date: entry.date ?? Date(),
                    text: entry.text ?? "",
                    moodValue: entry.moodValue,
                    summary: entry.summary ?? ""
                )
            } catch {
                print("[DiaryEntryData] 创建数据副本失败: \(error)")
                result = nil
            }
        }
        
        return result
    }
    
    /// 从一组DiaryEntry安全地创建数据副本，使用独立的后台上下文
    static func safelyExtractData(from entries: [DiaryEntry], dateRange: ClosedRange<Date>) -> [DiaryEntryData] {
        print("[DiaryEntryData] 开始安全提取数据，条目数量: \(entries.count)")
        
        // 获取所有objectID，这些在不同上下文间是安全的
        let objectIDs = entries.map { $0.objectID }
        
        // 创建一个独立的后台上下文，不参与CloudKit同步
        let backgroundContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        backgroundContext.parent = PersistenceController.shared.container.viewContext
        backgroundContext.automaticallyMergesChangesFromParent = false // 重要：不自动合并变更
        
        var safeData: [DiaryEntryData] = []
        
        backgroundContext.performAndWait {
            do {
                for objectID in objectIDs {
                    do {
                        let entry = try backgroundContext.existingObject(with: objectID) as! DiaryEntry
                        
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
            }
        }
        
        print("[DiaryEntryData] 安全提取完成，有效条目数量: \(safeData.count)")
        return safeData
    }
}