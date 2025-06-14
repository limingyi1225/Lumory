import Foundation
import CoreData

/// 专门用于生成AI报告的服务，完全隔离CloudKit同步影响
@available(iOS 15.0, macOS 12.0, *)
class ReportGenerationService {
    
    /// 安全生成报告（非流式版本）
    static func generateReport(from entries: [DiaryEntry], dateRange: ClosedRange<Date>) async -> String? {
        print("[ReportGenerationService] 开始安全报告生成流程")
        
        // 第1步：在完全隔离的环境中提取数据
        let safeData = await extractDataSafely(from: entries, dateRange: dateRange)
        guard !safeData.isEmpty else {
            print("[ReportGenerationService] 没有有效数据")
            return nil
        }
        
        // 第2步：创建独立的AI服务实例，避免共享状态
        let aiService = OpenAIService(apiKey: AppSecrets.openAIKey)
        
        // 第3步：在独立的Task中生成报告
        let result = await Task.detached(priority: .userInitiated) {
            return await aiService.generateReportFromData(entries: safeData)
        }.value
        
        print("[ReportGenerationService] 报告生成完成: \(result != nil ? "成功" : "失败")")
        return result
    }
    
    /// 安全生成报告（流式版本）
    static func generateReport(from entries: [DiaryEntry], dateRange: ClosedRange<Date>, onChunk: @escaping (String) -> Void) async {
        print("[ReportGenerationService] 开始安全流式报告生成流程")
        
        // 第1步：在完全隔离的环境中提取数据
        let safeData = await extractDataSafely(from: entries, dateRange: dateRange)
        guard !safeData.isEmpty else {
            onChunk("没有找到有效的日记数据用于分析。")
            return
        }
        
        // 第2步：创建独立的AI服务实例，避免共享状态
        let aiService = OpenAIService(apiKey: AppSecrets.openAIKey)
        
        // 第3步：在独立的Task中生成真实的流式报告
        await Task.detached(priority: .userInitiated) {
            await aiService.generateReportFromData(entries: safeData, onChunk: onChunk)
        }.value
        
        print("[ReportGenerationService] 流式报告生成完成")
    }
    
    /// 在完全隔离的环境中安全提取数据
    private static func extractDataSafely(from entries: [DiaryEntry], dateRange: ClosedRange<Date>) async -> [DiaryEntryData] {
        return await Task.detached(priority: .utility) {
            print("[ReportGenerationService] 在后台线程中安全提取数据")
            
            // 获取objectID列表，这些在不同上下文间是安全的
            let objectIDs = entries.map { $0.objectID }
            
            // 创建一个完全独立的持久化容器，避免CloudKit干扰
            guard let modelURL = Bundle.main.url(forResource: "Model", withExtension: "momd"),
                  let model = NSManagedObjectModel(contentsOf: modelURL) else {
                print("[ReportGenerationService] 无法加载数据模型")
                return []
            }
            
            let container = NSPersistentContainer(name: "Model", managedObjectModel: model)
            
            // 配置存储描述符，禁用CloudKit
            let description = NSPersistentStoreDescription()
            description.type = NSSQLiteStoreType
            description.url = PersistenceController.shared.container.persistentStoreDescriptions.first?.url
            description.setOption(true as NSNumber, forKey: NSReadOnlyPersistentStoreOption) // 只读模式
            
            container.persistentStoreDescriptions = [description]
            
            var safeData: [DiaryEntryData] = []
            
            await withCheckedContinuation { continuation in
                container.loadPersistentStores { _, error in
                    if let error = error {
                        print("[ReportGenerationService] 加载存储失败: \(error)")
                    } else {
                        let context = container.viewContext
                        context.performAndWait {
                            for objectID in objectIDs {
                                do {
                                    let entry = try context.existingObject(with: objectID) as! DiaryEntry
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
                                    print("[ReportGenerationService] 安全提取条目: \(data.id)")
                                } catch {
                                    print("[ReportGenerationService] 跳过条目: \(error)")
                                    continue
                                }
                            }
                        }
                    }
                    continuation.resume()
                }
            }
            
            print("[ReportGenerationService] 安全提取完成，条目数量: \(safeData.count)")
            return safeData
        }.value
    }
}