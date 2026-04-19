import Foundation

// MARK: - AI Service Contract
//
// 语音转录已从本协议中移除，由独立的 `AppleSpeechRecognizer` 承担。
// 这里只定义"文本理解/生成"层面的 AI 能力（摘要、情绪、报告、主题、向量、问答）。

protocol AIServiceProtocol {
    /// 根据文本生成简要摘要
    func summarize(text: String) async -> String?

    /// 根据文本分析心情，返回 0.0 ~ 1.0
    func analyzeMood(text: String) async -> Double

    /// 根据多条日记生成情绪+内容分析报告
    func generateReport(entries: [DiaryEntry]) async -> String?

    /// 流式生成情绪+内容分析报告，逐步返回内容
    /// `onChunk` 必须 MainActor——调用方普遍更新 `@Published` / SwiftUI state，
    /// 后台线程触发 UI 写会在 strict concurrency 下崩。
    func generateReport(entries: [DiaryEntry], onChunk: @escaping @MainActor (String) -> Void) async

    /// 同时分析情绪并生成摘要
    func analyzeAndSummarize(text: String) async -> (summary: String?, mood: Double)

    // MARK: - Phase 0: AI × 统计融合地基

    /// 从日记文本抽取 2-4 个主题标签（如：工作 / 家人 / 健康 / 睡眠）。
    /// 返回值顺序不重要，语言应匹配输入文本。
    func extractThemes(text: String) async -> [String]

    /// 生成语义向量（float32），用于语义搜索与 RAG 检索。
    /// 失败返回 nil；调用方应妥善处理（例如延后 backfill）。
    func embed(text: String) async -> [Float]?

    /// 对话式回顾：基于检索到的上下文日记，流式回答一个自然语言问题。
    /// 实现方负责 prompt 组装；调用方负责先做检索把 `context` 限制在合理数量内。
    func ask(question: String, context entries: [DiaryEntryData]) -> AsyncStream<String>

    /// 统一的流式报告 API（AsyncStream 封装，取代回调式 onChunk）。
    /// 用于 Insights Dashboard 的叙事面板、Ask 之外的长文生成等场景。
    func streamReport(entries: [DiaryEntryData]) -> AsyncStream<String>

    /// 根据 grounding context（主题/情绪/近期条目）**用 LLM 原创**一批给用户的
    /// 提问和输入框占位语。返回 nil 表示失败或内容不可用，调用方应 fallback。
    /// 这个接口刻意不给 prompt 模板——实现侧自己写 prompt、自己约束返回格式。
    func composeSuggestions(context: SuggestionContext) async -> SuggestionBundle?
}

extension AIServiceProtocol {
    /// 一次调用同时拿到摘要、心情、主题三件套。默认实现并发调用三个子接口，
    /// OpenAI 实现可以覆盖以合并成单次请求省 token。
    func analyze(text: String) async -> (summary: String?, mood: Double, themes: [String]) {
        async let s = summarize(text: text)
        async let m = analyzeMood(text: text)
        async let t = extractThemes(text: text)
        return (await s, await m, await t)
    }
}

struct MockAIService: AIServiceProtocol {
    func summarize(text: String) async -> String? {
        String(text.prefix(50)) + (text.count > 50 ? "..." : "")
    }

    func analyzeMood(text: String) async -> Double {
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

    func generateReport(entries: [DiaryEntry], onChunk: @escaping @MainActor (String) -> Void) async {
        if let fullReport = await generateReport(entries: entries) {
            await MainActor.run { onChunk(fullReport) }
        }
    }

    func analyzeAndSummarize(text: String) async -> (summary: String?, mood: Double) {
        let summary = String(text.prefix(50)) + (text.count > 50 ? "..." : "")
        let mood = await analyzeMood(text: text)
        return (summary, mood)
    }

    // MARK: - Phase 0 stubs

    func extractThemes(text: String) async -> [String] {
        // 规则版主题抽取：匹配常见中英文关键词，便于测试和离线回退
        let lowered = text.lowercased()
        var tags: [String] = []
        let buckets: [(String, [String])] = [
            ("工作", ["工作", "项目", "会议", "加班", "老板", "同事", "work", "meeting", "project", "boss"]),
            ("家人", ["家", "父母", "爸妈", "妈妈", "爸爸", "家人", "family", "mom", "dad", "parent"]),
            ("健康", ["身体", "生病", "运动", "跑步", "健身", "睡眠", "health", "exercise", "run", "sleep", "sick"]),
            ("情绪", ["焦虑", "开心", "难过", "happy", "sad", "anxious", "calm"]),
            ("朋友", ["朋友", "聚会", "friend", "party"])
        ]
        for (tag, keywords) in buckets where keywords.contains(where: { lowered.contains($0) }) {
            tags.append(tag)
        }
        return Array(tags.prefix(4))
    }

    func embed(text: String) async -> [Float]? {
        // 确定性伪向量：长度 16，数值由字符哈希生成，够用于 mock 下的 cosine 计算
        var vector = [Float](repeating: 0, count: 16)
        for (i, scalar) in text.unicodeScalars.enumerated() {
            let bucket = (i + Int(scalar.value)) % 16
            vector[bucket] += Float(scalar.value & 0xFF) / 255.0
        }
        // 归一化
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    func ask(question: String, context entries: [DiaryEntryData]) -> AsyncStream<String> {
        AsyncStream { continuation in
            continuation.yield("Mock 回答：你问了『\(question)』，基于 \(entries.count) 条日记。")
            continuation.finish()
        }
    }

    func streamReport(entries: [DiaryEntryData]) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task {
                let total = entries.count
                let avg = entries.isEmpty ? 0.5 : entries.map { $0.moodValue }.reduce(0, +) / Double(total)
                continuation.yield("共 \(total) 条日记，")
                continuation.yield("平均情绪 \(String(format: "%.0f", avg * 100))/100。")
                continuation.finish()
            }
        }
    }

    func composeSuggestions(context: SuggestionContext) async -> SuggestionBundle? {
        // Mock：直接按主题拼出能跑的最简 bundle，单测友好
        let sampleThemes = context.topThemes.prefix(2).map { $0.name }
        let zh = context.language == "zh"
        let presets: [String] = sampleThemes.isEmpty
            ? [zh ? "最近最牵挂什么？" : "What's been on your mind?"]
            : sampleThemes.map { zh ? "想写写\($0)吗？" : "Want to write about \($0)?" }
        let placeholders: [String] = sampleThemes.isEmpty
            ? [zh ? "今天怎么样？" : "How was today?"]
            : sampleThemes.map { zh ? "再聊聊\($0)" : "More on \($0)" }
        return SuggestionBundle(
            askPastPresets: presets,
            homePlaceholders: placeholders,
            generatedAt: Date(),
            fingerprint: context.makeFingerprint(),
            language: context.language
        )
    }
}

// MARK: - Mock Transcriber
//
// 测试侧使用：固定返回一段预设文本，不触碰 Apple Speech / 权限 / 音频引擎。
final class MockTranscriber: TranscriberProtocol {
    let stubbedResult: String?

    init(stubbedResult: String? = "mock transcription") {
        self.stubbedResult = stubbedResult
    }

    func transcribeAudio(fileURL: URL, localeIdentifier: String) async -> String? {
        stubbedResult
    }
}
