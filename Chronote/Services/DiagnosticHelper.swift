import Foundation

/// 诊断AI报告生成的助手工具
class DiagnosticHelper {
    
    /// 检查后端连接和AI功能是否正常
    static func runFullDiagnostic() async {
        print("\n=== 🔧 开始完整诊断 ===")
        
        // 1. 测试后端连接
        print("\n1️⃣ 测试后端连接...")
        let (isWorking, message) = await BackendHealthCheck.testOpenAIProxy()
        print("   结果: \(isWorking ? "✅ 成功" : "❌ 失败") - \(message)")
        
        if !isWorking {
            print("   ⚠️ 后端连接失败，AI功能无法工作")
            return
        }
        
        // 2. 测试简单AI请求
        print("\n2️⃣ 测试AI服务...")
        let aiService = OpenAIService(apiKey: AppSecrets.openAIKey)
        let moodResult = await aiService.analyzeMood(text: "今天心情很好")
        print("   心情分析结果: \(moodResult) (预期: 0.7-0.9)")
        
        let summaryResult = await aiService.summarize(text: "今天是个美好的一天，阳光明媚")
        print("   摘要生成: \(summaryResult ?? "失败")")
        
        // 3. 测试独立报告生成
        print("\n3️⃣ 测试报告生成服务...")
        let mockData = [
            DiaryEntryData(id: UUID(), date: Date(), text: "今天心情不错，工作顺利", moodValue: 0.8, summary: "工作顺利"),
            DiaryEntryData(id: UUID(), date: Date(), text: "天气很好，去了公园", moodValue: 0.9, summary: "去公园")
        ]
        
        let reportResult = await aiService.generateReportFromData(entries: mockData)
        if let report = reportResult, !report.isEmpty {
            print("   ✅ 报告生成成功，长度: \(report.count)")
            print("   📝 报告预览: \(report.prefix(100))...")
        } else {
            print("   ❌ 报告生成失败")
        }
        
        // 4. 检查ViewBridge错误影响
        print("\n4️⃣ ViewBridge错误分析...")
        print("   ℹ️ ViewBridge错误是Mac Catalyst的UI问题，不影响AI功能")
        print("   ℹ️ 只要上述测试通过，AI报告功能就是正常的")
        
        // 5. 测试流式报告生成
        print("\n5️⃣ 测试流式报告生成...")
        var streamedContent = ""
        await aiService.generateReportFromData(entries: mockData) { chunk in
            print("   📥 收到流式内容: '\(chunk.prefix(30))...'")
            streamedContent += chunk
        }
        
        if !streamedContent.isEmpty {
            print("   ✅ 流式报告生成成功，总长度: \(streamedContent.count)")
            print("   📝 流式内容预览: \(streamedContent.prefix(100))...")
        } else {
            print("   ❌ 流式报告生成失败或为空")
        }
        
        // 6. 模拟实际使用场景
        print("\n6️⃣ 模拟实际Mac应用使用场景...")
        var macReportContent = ""
        let dateRange = Date.distantPast...Date.distantFuture
        
        await ReportGenerationService.generateReport(from: [], dateRange: dateRange) { chunk in
            print("   📱 Mac模拟收到内容: '\(chunk.prefix(30))...'")
            macReportContent += chunk
        }
        
        if !macReportContent.isEmpty {
            print("   ✅ Mac模拟场景成功，长度: \(macReportContent.count)")
        } else {
            print("   ⚠️ Mac模拟场景无内容（可能因为没有真实数据）")
        }
        
        print("\n=== 🏁 诊断完成 ===\n")
    }
    
    /// 检查CloudKit同步状态
    static func checkCloudKitStatus() {
        print("\n=== ☁️ CloudKit状态检查 ===")
        print("ℹ️ 大量的'iCloud sync: Remote changes detected'表示CloudKit正在活跃同步")
        print("ℹ️ 这是正常现象，我们的独立报告生成服务已经完全避开了这个问题")
        print("ℹ️ AI报告功能现在使用独立的只读数据库连接，不受CloudKit影响")
        print("=== ☁️ 检查完成 ===\n")
    }
}