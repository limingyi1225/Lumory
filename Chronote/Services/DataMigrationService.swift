import Foundation
import CoreData

struct DataMigrationService {
    static let migrationKey = "hasPerformedCoreDataMigration"
    
    /// 执行从 JSON 到 Core Data 的一次性迁移
    static func performMigrationIfNeeded() {
        // 检查是否已经迁移过
        guard !UserDefaults.standard.bool(forKey: migrationKey) else {
            print("[DataMigration] 已完成迁移，跳过")
            return
        }
        
        // 读取旧的 JSON 文件
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let jsonURL = documentsURL.appendingPathComponent("diary.json")
        
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            print("[DataMigration] 没有找到旧数据文件，标记为已迁移")
            UserDefaults.standard.set(true, forKey: migrationKey)
            return
        }
        
        do {
            // 解码 JSON 数据
            let data = try Data(contentsOf: jsonURL)
            let oldEntries = try JSONDecoder().decode([LegacyDiaryEntry].self, from: data)
            
            print("[DataMigration] 找到 \(oldEntries.count) 条日记待迁移")
            
            // 获取 Core Data 上下文
            let context = PersistenceController.shared.container.newBackgroundContext()
            
            // 在后台线程执行迁移
            context.performAndWait {
                for oldEntry in oldEntries {
                    // 假设你的 Core Data 实体名为 DiaryEntryMO
                    let newEntry = NSEntityDescription.insertNewObject(forEntityName: "DiaryEntry", into: context)
                    newEntry.setValue(oldEntry.id, forKey: "id")
                    newEntry.setValue(oldEntry.date, forKey: "date")
                    newEntry.setValue(oldEntry.text, forKey: "text")
                    newEntry.setValue(oldEntry.moodValue, forKey: "moodValue")
                    newEntry.setValue(oldEntry.summary, forKey: "summary")
                    if let audioFileName = oldEntry.audioFileName {
                        newEntry.setValue(audioFileName, forKey: "audioFileName")
                    }
                }
                
                // 保存到 Core Data
                do {
                    try context.save()
                    print("[DataMigration] 成功迁移 \(oldEntries.count) 条日记")
                    
                    // 标记迁移完成
                    DispatchQueue.main.async {
                        UserDefaults.standard.set(true, forKey: migrationKey)
                        
                        // 可选：备份原 JSON 文件而不是删除
                        let backupURL = jsonURL.appendingPathExtension("backup")
                        try? FileManager.default.moveItem(at: jsonURL, to: backupURL)
                        print("[DataMigration] 原文件已备份至: \(backupURL.lastPathComponent)")
                    }
                } catch {
                    print("[DataMigration] Core Data 保存失败: \(error)")
                }
            }
        } catch {
            print("[DataMigration] 迁移失败: \(error)")
        }
    }
} 