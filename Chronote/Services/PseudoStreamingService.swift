import Foundation

/// 伪流式服务：当后端不支持真正的流式响应时，使用非流式请求然后模拟流式显示
@available(iOS 15.0, macOS 12.0, *)
class PseudoStreamingService {
    
    /// 模拟流式报告生成：获取完整响应后分块发送
    static func generateStreamingReport(entries: [DiaryEntryData], onChunk: @escaping (String) -> Void) async {
        print("[PseudoStreamingService] 开始伪流式报告生成")
        
        // 使用非流式方式获取完整报告
        let aiService = OpenAIService(apiKey: AppSecrets.openAIKey)
        let fullReport = await aiService.generateReportFromData(entries: entries)
        
        guard let report = fullReport, !report.isEmpty else {
            onChunk("无法生成报告，请稍后重试。")
            return
        }
        
        print("[PseudoStreamingService] 获得完整报告，长度: \(report.count)，开始模拟流式发送")
        
        // 将报告分成小块，模拟流式发送
        let chunkSize = 10 // 每次发送10个字符
        let delayBetweenChunks: UInt64 = 50_000_000 // 50毫秒延迟
        
        var startIndex = report.startIndex
        var chunkNumber = 0
        
        while startIndex < report.endIndex {
            let endIndex = report.index(startIndex, offsetBy: chunkSize, limitedBy: report.endIndex) ?? report.endIndex
            let chunk = String(report[startIndex..<endIndex])
            
            chunkNumber += 1
            print("[PseudoStreamingService] 发送第\(chunkNumber)个块: '\(chunk.prefix(20))...'")
            
            onChunk(chunk)
            
            if endIndex < report.endIndex {
                try? await Task.sleep(nanoseconds: delayBetweenChunks)
            }
            
            startIndex = endIndex
        }
        
        print("[PseudoStreamingService] 伪流式发送完成，总共发送 \(chunkNumber) 个块")
    }
    
    /// 测试后端是否支持真正的流式响应
    static func testStreamingSupport() async -> Bool {
        print("[PseudoStreamingService] 测试后端流式支持...")
        
        let testData = [
            DiaryEntryData(id: UUID(), date: Date(), text: "测试流式响应", moodValue: 0.8, summary: "测试")
        ]
        
        var receivedAnyContent = false
        let aiService = OpenAIService(apiKey: AppSecrets.openAIKey)
        
        await aiService.generateReportFromData(entries: testData) { chunk in
            print("[PseudoStreamingService] 收到流式测试内容: '\(chunk.prefix(30))...'")
            receivedAnyContent = true
        }
        
        print("[PseudoStreamingService] 流式支持测试结果: \(receivedAnyContent ? "支持" : "不支持")")
        return receivedAnyContent
    }
}