import Foundation
import CoreData

struct DataMigrationService {
    static let migrationKey = "hasPerformedCoreDataMigration"
    
    /// 执行从 JSON 到 Core Data 的一次性迁移
    static func performMigrationIfNeeded() {
        // 检查是否已经迁移过
        guard !UserDefaults.standard.bool(forKey: migrationKey) else {
            Log.info("[DataMigration] 已完成迁移，跳过", category: .migration)
            return
        }
        
        // 读取旧的 JSON 文件
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let jsonURL = documentsURL.appendingPathComponent("diary.json")
        
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            Log.info("[DataMigration] 没有找到旧数据文件，标记为已迁移", category: .migration)
            UserDefaults.standard.set(true, forKey: migrationKey)
            return
        }
        
        do {
            // 解码 JSON 数据
            let data = try Data(contentsOf: jsonURL)
            let oldEntries = try JSONDecoder().decode([LegacyDiaryEntry].self, from: data)
            
            Log.info("[DataMigration] 找到 \(oldEntries.count) 条日记待迁移", category: .migration)
            
            // 获取 Core Data 上下文
            let context = PersistenceController.shared.container.newBackgroundContext()
            
            // 在后台线程执行迁移
            context.performAndWait {
                // **去重守卫**：save 失败路径不会写 `migrationKey`，下次启动会重跑本函数。
                // Core Data 模型没有 uniquenessConstraints，重跑时把同一批 UUID 再插一次
                // **不会**被 Core Data 拦下，会得到同 id 的两条 ghost entry 同步到 CloudKit。
                // 插入前先一次性 fetch 已有 id 集合，按 UUID 去重（O(N) 一次 vs. N × O(log N) 每条 fetch）。
                let existingIDs: Set<UUID> = {
                    let req = NSFetchRequest<NSDictionary>(entityName: "DiaryEntry")
                    req.resultType = .dictionaryResultType
                    req.propertiesToFetch = ["id"]
                    guard let rows = try? context.fetch(req) else { return [] }
                    return Set(rows.compactMap { $0["id"] as? UUID })
                }()

                var inserted = 0
                var skipped = 0
                for oldEntry in oldEntries {
                    if existingIDs.contains(oldEntry.id) {
                        skipped += 1
                        continue
                    }
                    let newEntry = NSEntityDescription.insertNewObject(forEntityName: "DiaryEntry", into: context)
                    newEntry.setValue(oldEntry.id, forKey: "id")
                    newEntry.setValue(oldEntry.date, forKey: "date")
                    newEntry.setValue(oldEntry.text, forKey: "text")
                    newEntry.setValue(oldEntry.moodValue, forKey: "moodValue")
                    newEntry.setValue(oldEntry.summary, forKey: "summary")
                    if let audioFileName = oldEntry.audioFileName {
                        newEntry.setValue(audioFileName, forKey: "audioFileName")
                    }
                    inserted += 1
                }

                // 保存到 Core Data
                do {
                    try context.save()
                    Log.info("[DataMigration] 迁移完成：新增 \(inserted) 条，跳过已存在 \(skipped) 条", category: .migration)

                    // **同步写标志** —— 不能 DispatchQueue.main.async 到下一 runloop。
                    // UserDefaults 是线程安全的（Apple 文档明确），可以直接在 performAndWait
                    // 的 bg 队列里同步写入。async 写法下，context.save() 成功到 UserDefaults 写入
                    // 之间存在窗口，如果 App 被系统杀（内存压力 / 用户 force-quit），下次启动
                    // migrationKey 还没落盘 → performMigrationIfNeeded 再跑一遍 → **数据翻倍导入**。
                    UserDefaults.standard.set(true, forKey: migrationKey)

                    // 备份原文件（非关键路径，失败可接受）
                    let backupURL = jsonURL.appendingPathExtension("backup")
                    try? FileManager.default.moveItem(at: jsonURL, to: backupURL)
                    Log.info("[DataMigration] 原文件已备份至: \(backupURL.lastPathComponent)", category: .migration)
                } catch {
                    Log.error("[DataMigration] Core Data 保存失败: \(error)", category: .migration)
                }
            }
        } catch {
            Log.error("[DataMigration] 迁移失败: \(error)", category: .migration)
        }
    }
} 