import Foundation

protocol AIServiceProtocol {
    /// 根据文本生成简要摘要
    func summarize(text: String) async -> String?
    /// 根据文本分析心情，返回 0.0 ~ 1.0
    func analyzeMood(text: String) async -> Double
    /// 根据多条日记生成情绪+内容分析报告
    func generateReport(entries: [DiaryEntry]) async -> String?
    /// 流式生成情绪+内容分析报告，逐步返回内容
    func generateReport(entries: [DiaryEntry], onChunk: @escaping (String) -> Void) async
    /// 转录音频文件为文本
    func transcribeAudio(fileURL: URL, localeIdentifier: String) async -> String?
    /// 同时分析情绪并生成摘要
    func analyzeAndSummarize(text: String) async -> (summary: String?, mood: Double)
}

struct MockAIService: AIServiceProtocol {
    func summarize(text: String) async -> String? {
        // 这里只是示例，真实环境应调用 GPT 接口
        return String(text.prefix(50)) + (text.count > 50 ? "..." : "")
    }

    func analyzeMood(text: String) async -> Double {
        // 简单 mock：根据 happy/sad 判断，返回连续值
        let lowered = text.lowercased()
        if lowered.contains("happy") || lowered.contains("快乐") {
            return 1.0
        } else if lowered.contains("sad") || lowered.contains("难过") {
            return 0.0
        } else {
            return 0.5
        }
    }

    func generateReport(entries: [DiaryEntry]) async -> String? {
        let total = entries.count
        guard total > 0 else { return "无数据" }
        let avg = entries.map { $0.moodValue }.reduce(0, +) / Double(total)
        return "共 \(total) 条日记，平均情绪得分 \(String(format: "%.0f", avg * 100))/100\n(示例 mock，可接入 GPT)"
    }

    func generateReport(entries: [DiaryEntry], onChunk: @escaping (String) -> Void) async {
        if let fullReport = await generateReport(entries: entries) {
            onChunk(fullReport)
        }
    }

    func transcribeAudio(fileURL: URL, localeIdentifier: String) async -> String? {
        // Mock implementation, can be improved
        print("[MockAIService] Transcribing with locale: \(localeIdentifier)")
        return "这是使用 Apple API 转录的模拟文本。"
    }

    func analyzeAndSummarize(text: String) async -> (summary: String?, mood: Double) {
        // Mock implementation
        let summary = String(text.prefix(50)) + (text.count > 50 ? "..." : "")
        let mood: Double
        let lowered = text.lowercased()
        if lowered.contains("happy") || lowered.contains("快乐") {
            mood = 1.0
        } else if lowered.contains("sad") || lowered.contains("难过") {
            mood = 0.0
        } else {
            mood = 0.5
        }
        return (summary, mood)
    }
} 