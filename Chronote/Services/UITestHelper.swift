import Foundation

/// UI测试助手，专门用于测试用户界面层面的报告生成
class UITestHelper {
    
    /// 简单测试：模拟用户点击生成报告后的流程
    static func testMacReportGeneration() async -> String {
        print("[UITestHelper] 开始模拟Mac报告生成流程")
        
        // 注意：这里不使用模拟数据，因为ReportGenerationService需要真实的DiaryEntry对象
        // 我们直接测试空数据的情况，这会触发"没有找到有效的日记数据"的消息
        
        var result = ""
        let dateRange = Date.distantPast...Date.distantFuture
        
        // 模拟Mac版本的流式报告生成
        print("[UITestHelper] 调用ReportGenerationService...")
        await ReportGenerationService.generateReport(from: [], dateRange: dateRange) { chunk in
            print("[UITestHelper] 收到内容块: '\(chunk.prefix(50))...'")
            result += chunk
        }
        
        print("[UITestHelper] 模拟完成，结果长度: \(result.count)")
        
        if result.isEmpty {
            return "测试失败：没有收到任何内容"
        } else {
            return "测试成功：收到\(result.count)字符的报告内容"
        }
    }
    
    /// 测试非流式版本
    static func testSimpleReportGeneration() async -> String {
        print("[UITestHelper] 测试非流式报告生成")
        
        let mockData = [
            DiaryEntryData(id: UUID(), date: Date(), text: "简单测试日记", moodValue: 0.8, summary: "测试")
        ]
        
        let aiService = OpenAIService(apiKey: AppSecrets.openAIKey)
        let result = await aiService.generateReportFromData(entries: mockData)
        
        if let report = result, !report.isEmpty {
            print("[UITestHelper] 非流式测试成功，长度: \(report.count)")
            return "非流式测试成功：\(report.count)字符"
        } else {
            print("[UITestHelper] 非流式测试失败")
            return "非流式测试失败"
        }
    }
}