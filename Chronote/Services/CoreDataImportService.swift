import Foundation
import CoreData
import SwiftUI

@MainActor
class CoreDataImportService: ObservableObject {
    @Published var isImporting: Bool = false
    @Published var importProgress: Double = 0.0
    
    private let aiService = AppleRecognitionService(openAIApiKey: AppSecrets.openAIKey)
    
    /// 根据用户粘贴的原始文本批量导入日记到 Core Data
    func importEntries(from rawText: String, context: NSManagedObjectContext) async {
        print("[CoreDataImportService] importEntries: rawText length = \(rawText.count)")
        isImporting = true
        importProgress = 0.0
        
        let parsed = await DiaryImportService.parse(rawText: rawText)
        print("[CoreDataImportService] importEntries: parsed count = \(parsed.count)")
        
        guard !parsed.isEmpty else {
            print("[CoreDataImportService] importEntries: parsed isEmpty, abort import")
            isImporting = false
            importProgress = 0.0
            return
        }
        
        let total = parsed.count
        for (index, (date, text)) in parsed.enumerated() {
            // 先执行摘要
            let summary = await aiService.summarize(text: text)
            // 再执行心情分析
            let moodValue = await aiService.analyzeMood(text: text)
            
            // 创建 Core Data 实体
            let newEntry = NSEntityDescription.insertNewObject(forEntityName: "DiaryEntry", into: context)
            newEntry.setValue(UUID(), forKey: "id")
            newEntry.setValue(date, forKey: "date")
            newEntry.setValue(text, forKey: "text")
            newEntry.setValue(moodValue, forKey: "moodValue")
            newEntry.setValue(summary, forKey: "summary")
            
            // 保存
            do {
                try context.save()
            } catch {
                print("[CoreDataImportService] 保存条目失败: \(error)")
            }
            
            // 更新进度
            importProgress = Double(index + 1) / Double(total)
            print("[CoreDataImportService] importEntries: imported entry \(index + 1)/\(total)")
        }
        
        // 导入完成后
        isImporting = false
        importProgress = 1.0
        print("[CoreDataImportService] importEntries: import completed")
    }
} 