import Foundation
import CoreData

struct DataCleanupService {
    static let cleanupKey = "hasPerformedDataCleanup"
    
    /// 清理重复的日记记录（基于相同的 ID） - 异步操作
    static func removeDuplicateEntries() {
        // 检查是否已经清理过
        guard !UserDefaults.standard.bool(forKey: cleanupKey) else {
            print("[DataCleanup] 已完成清理，跳过")
            return
        }
        
        let context = PersistenceController.shared.container.newBackgroundContext()
        
        // Use async perform instead of performAndWait to avoid blocking
        context.perform {
            // 获取所有日记
            let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: true)]
            // Add batch size for memory efficiency
            request.fetchBatchSize = 50
            
            do {
                let allEntries = try context.fetch(request)
                print("[DataCleanup] 找到 \(allEntries.count) 条日记")
                
                // 按 ID 分组 - 优化内存使用
                let groupedById = Dictionary(grouping: allEntries) { $0.id }
                allEntries.forEach { context.refresh($0, mergeChanges: false) } // Release memory
                
                var duplicatesRemoved = 0
                
                // 对于每个 ID 组，只保留最早的一条（按日期）
                for (id, entries) in groupedById {
                    if entries.count > 1 {
                        print("[DataCleanup] 发现重复 ID: \(id?.uuidString ?? "nil")，共 \(entries.count) 条")
                        
                        // 按日期排序，保留最早的
                        let sortedEntries = entries.sorted { ($0.date ?? Date.distantPast) < ($1.date ?? Date.distantPast) }
                        let toKeep = sortedEntries.first!
                        let toDelete = Array(sortedEntries.dropFirst())
                        
                        // 删除重复的记录
                        for duplicate in toDelete {
                            // Delete associated images before deleting the entry
                            duplicate.deleteAllImages()
                            
                            context.delete(duplicate)
                            duplicatesRemoved += 1
                        }
                        
                        // Periodically save to avoid memory pressure
                        if duplicatesRemoved % 20 == 0 {
                            try context.save()
                        }
                        
                        print("[DataCleanup] 保留日期为 \(toKeep.date ?? Date()) 的记录，删除 \(toDelete.count) 条重复记录")
                    }
                }
                
                // 保存更改
                if duplicatesRemoved > 0 {
                    try context.save()
                    print("[DataCleanup] 成功删除 \(duplicatesRemoved) 条重复记录")
                } else {
                    print("[DataCleanup] 没有发现重复记录")
                }
                
                // 标记清理完成
                DispatchQueue.main.async {
                    UserDefaults.standard.set(true, forKey: cleanupKey)
                }
                
            } catch {
                print("[DataCleanup] 清理失败: \(error)")
            }
        }
    }
    
    /// 异步清理方法 with completion handler
    static func removeDuplicateEntriesAsync(completion: @escaping (Bool, Error?) -> Void) {
        // 检查是否已经清理过
        guard !UserDefaults.standard.bool(forKey: cleanupKey) else {
            print("[DataCleanup] 已完成清理，跳过")
            completion(true, nil)
            return
        }
        
        Task {
            await performCleanup(completion: completion)
        }
    }
    
    @MainActor
    private static func performCleanup(completion: @escaping (Bool, Error?) -> Void) async {
        let context = PersistenceController.shared.container.newBackgroundContext()
        
        do {
            let success = try await context.perform {
                // 获取所有日记
                let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
                request.sortDescriptors = [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: true)]
                request.fetchBatchSize = 50
                
                let allEntries = try context.fetch(request)
                print("[DataCleanup] 找到 \(allEntries.count) 条日记")
                
                // 按 ID 分组
                let groupedById = Dictionary(grouping: allEntries) { $0.id }
                
                var duplicatesRemoved = 0
                
                // 对于每个 ID 组，只保留最早的一条（按日期）
                for (id, entries) in groupedById {
                    if entries.count > 1 {
                        print("[DataCleanup] 发现重复 ID: \(id?.uuidString ?? "nil")，共 \(entries.count) 条")
                        
                        // 按日期排序，保留最早的
                        let sortedEntries = entries.sorted { ($0.date ?? Date.distantPast) < ($1.date ?? Date.distantPast) }
                        let toKeep = sortedEntries.first!
                        let toDelete = Array(sortedEntries.dropFirst())
                        
                        // 删除重复的记录
                        for duplicate in toDelete {
                            duplicate.deleteAllImages()
                            context.delete(duplicate)
                            duplicatesRemoved += 1
                        }
                        
                        print("[DataCleanup] 保留日期为 \(toKeep.date ?? Date()) 的记录，删除 \(toDelete.count) 条重复记录")
                    }
                }
                
                // 保存更改
                if duplicatesRemoved > 0 {
                    try context.save()
                    print("[DataCleanup] 成功删除 \(duplicatesRemoved) 条重复记录")
                } else {
                    print("[DataCleanup] 没有发现重复记录")
                }
                
                return true
            }
            
            // 标记清理完成
            UserDefaults.standard.set(true, forKey: cleanupKey)
            completion(success, nil)
            
        } catch {
            print("[DataCleanup] 清理失败: \(error)")
            completion(false, error)
        }
    }
} 