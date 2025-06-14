import Foundation
import CoreData

/// 简单的报告生成测试助手
class ReportTestHelper {
    
    static func testBackendConnection() async {
        print("[ReportTestHelper] 开始测试后端连接...")
        let (isWorking, message) = await BackendHealthCheck.testOpenAIProxy()
        print("[ReportTestHelper] 后端测试结果: \(isWorking ? "成功" : "失败") - \(message)")
    }
    
    static func testSimpleAIRequest() async {
        print("[ReportTestHelper] 开始测试简单AI请求...")
        let aiService = OpenAIService(apiKey: AppSecrets.openAIKey)
        
        // 使用analyzeMood来测试基本AI功能
        let testMood = await aiService.analyzeMood(text: "今天心情不错，天气很好")
        print("[ReportTestHelper] 心情分析测试结果: \(testMood)")
        
        // 使用summarize来测试另一个AI功能
        let testSummary = await aiService.summarize(text: "今天是个好日子，阳光明媚，心情愉快")
        if let summary = testSummary {
            print("[ReportTestHelper] 摘要生成测试成功: \(summary)")
        } else {
            print("[ReportTestHelper] 摘要生成测试失败")
        }
    }
    
    static func testReportGenerationWithMockData() async {
        print("[ReportTestHelper] 开始测试报告生成（使用模拟数据）...")
        let aiService = OpenAIService(apiKey: AppSecrets.openAIKey)
        
        // 创建模拟的DiaryEntry数据
        let context = PersistenceController.shared.container.viewContext
        let mockEntry = DiaryEntry(context: context)
        mockEntry.date = Date()
        mockEntry.text = "今天是个美好的一天，阳光明媚，心情很好。"
        mockEntry.moodValue = 0.8
        mockEntry.summary = "美好的一天"
        
        let result = await aiService.generateReport(entries: [mockEntry])
        if let report = result {
            print("[ReportTestHelper] 报告生成测试成功，长度: \(report.count)")
            print("[ReportTestHelper] 报告内容预览: \(String(report.prefix(100)))...")
        } else {
            print("[ReportTestHelper] 报告生成测试失败")
        }
        
        // 清理模拟数据（不保存到持久化存储）
        context.rollback()
    }
    
    static func debugReportGeneration() async {
        print("[ReportTestHelper] 开始调试报告生成...")
        
        // 先测试后端连接
        await testBackendConnection()
        
        // 然后测试简单AI请求
        await testSimpleAIRequest()
        
        // 最后测试报告生成
        await testReportGenerationWithMockData()
        
        print("[ReportTestHelper] 调试完成")
    }
}

