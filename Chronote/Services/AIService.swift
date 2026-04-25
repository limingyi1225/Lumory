import Foundation
import SwiftUI

// MARK: - AI Service Contract
//
// 语音转录已从本协议中移除，由独立的 `AppleSpeechRecognizer` 承担。
// 这里只定义"文本理解/生成"层面的 AI 能力（摘要、情绪、报告、主题、向量、问答）。

// MARK: - Structured stream event
//
// 流式 AI 输出的结构化事件。用来替代早先"把中文警告当普通 chunk 吐回去"的做法——
// 调用方看到的 `.chunk` 就是真正的 AI 正文；`.truncated` 表示流被非致命地中断
// (典型：已 yield 过内容后断网)，UI 应该提示"内容不完整、可重新生成"；
// `.failed` 表示错误到未能产出任何内容；`.done` 是自然结束。
//
// 旧的 `AsyncThrowingStream<String>` / `(onChunk: (String) -> Void)` API 继续保留，
// 内部包装新的事件流做兼容。
@available(iOS 15.0, macOS 12.0, *)
enum StreamEvent: Sendable {
    /// 正常 content chunk (来自 delta.content)
    case chunk(String)
    /// 流被中断但先前已产出部分内容 —— UI 应显示"内容不完整"提示,允许重新生成
    case truncated(reason: String)
    /// 流彻底失败未产出任何内容
    case failed(Error)
    /// 正常结束 (收到 [DONE])
    case done
}

// MARK: - Import parsing types
//
// `parseImportedDiaries` 的返回结构:`(date, text)` 元组按时间顺序排列。
// 之前 `DiaryImportService.ParsedEntry` 只是私有 Decodable 中间型;现在挪到协议层,
// 调用方(`CoreDataImportService`)拿到这个结构后再走 themes / mood / embedding 流水线。
struct ParsedDiaryEntry: Sendable, Equatable {
    let date: Date
    let text: String
}

/// 导入解析层错误。**与"成功但 0 条"(`[]`)严格区分**——后者是合法的"粘贴里没找到日记",
/// 前者是网络 / 后端 / 模型解析失败,UI 必须给两种不同提示。
enum DiaryImportError: LocalizedError, Sendable {
    /// 输入为空 / 全空白
    case emptyInput
    /// 后端返回非 2xx 或网络异常
    case network(Error)
    /// 模型回传内容缺失 / JSON 不可解析
    case parsingFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return NSLocalizedString("error.import.emptyInput",
                                     value: "粘贴的内容为空。",
                                     comment: "Empty input on import")
        case .network(let underlying):
            return String(format: NSLocalizedString("error.import.network",
                                                    value: "导入时网络出错:%@",
                                                    comment: "Network error on import"),
                          underlying.localizedDescription)
        case .parsingFailed(let reason):
            return String(format: NSLocalizedString("error.import.parsingFailed",
                                                    value: "解析日记失败:%@",
                                                    comment: "Parsing failed on import"),
                          reason)
        }
    }
}

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

    /// 结构化事件版回顾流 —— 能区分 `.chunk` / `.truncated` / `.failed`。
    /// 旧 `ask` 保留作 wrapper;新 UI 用这个,才能显示"回答不完整"条。
    @available(iOS 15.0, macOS 12.0, *)
    func askEvents(question: String, context entries: [DiaryEntryData]) -> AsyncStream<StreamEvent>

    /// 统一的流式报告 API（AsyncStream 封装，取代回调式 onChunk）。
    /// 用于 Insights Dashboard 的叙事面板、Ask 之外的长文生成等场景。
    func streamReport(entries: [DiaryEntryData]) -> AsyncStream<String>

    /// 结构化流式报告事件 —— 内部实现发的是 `StreamEvent`,UI 想区分"断流"和"正常"
    /// 可以直接消费这个流。旧 `streamReport` 仍可用,行为上只吐 `.chunk` 的文本。
    @available(iOS 15.0, macOS 12.0, *)
    func streamReportEvents(entries: [DiaryEntryData]) -> AsyncStream<StreamEvent>

    /// 根据 grounding context（主题/情绪/近期条目）**用 LLM 原创**一批给用户的
    /// 提问和输入框占位语。返回 nil 表示失败或内容不可用，调用方应 fallback。
    /// 这个接口刻意不给 prompt 模板——实现侧自己写 prompt、自己约束返回格式。
    func composeSuggestions(context: SuggestionContext) async -> SuggestionBundle?

    /// 解析用户粘贴的整段文本(可能含多篇日记),返回结构化 `[(date, text)]`。
    /// 成功但解析不出任何日记 → 返回 `[]`(合法,UI 应提示"未识别到日记");
    /// 网络 / 后端 / JSON 解码失败 → `throws DiaryImportError`。
    /// **不要再用旧的 static `DiaryImportService.parse`**——那条路径绕过了 DI、
    /// 也吞了所有错误。新路径走 `AIServiceProtocol`,Mock 注入对单测全程有效。
    func parseImportedDiaries(rawText: String) async throws -> [ParsedDiaryEntry]
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

    @available(iOS 15.0, macOS 12.0, *)
    func askEvents(question: String, context entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
        AsyncStream { continuation in
            continuation.yield(.chunk("Mock 回答：你问了『\(question)』，基于 \(entries.count) 条日记。"))
            continuation.yield(.done)
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

    @available(iOS 15.0, macOS 12.0, *)
    func streamReportEvents(entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
        AsyncStream { continuation in
            Task {
                let total = entries.count
                let avg = entries.isEmpty ? 0.5 : entries.map { $0.moodValue }.reduce(0, +) / Double(total)
                continuation.yield(.chunk("共 \(total) 条日记，"))
                continuation.yield(.chunk("平均情绪 \(String(format: "%.0f", avg * 100))/100。"))
                continuation.yield(.done)
                continuation.finish()
            }
        }
    }

    func parseImportedDiaries(rawText: String) async throws -> [ParsedDiaryEntry] {
        // Mock 默认返回空数组——单测里需要"成功导入 N 条"场景的可以 wrap 一层自定义 Mock。
        // 不抛错可让 UI happy-path 测试更容易。
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DiaryImportError.emptyInput
        }
        return []
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

// MARK: - SwiftUI Environment 注入
//
// 以前 View 里直接写 `OpenAIService.shared`，测试 / Preview 没办法替换成 MockAIService。
// 现在暴露成 Environment value，UI 层用 `@Environment(\.aiService) private var aiService`
// 就能透过 `.environment(\.aiService, MockAIService())` 做替换。
//
// 默认值仍然指向 `OpenAIService.shared`，生产路径零行为变化;ChronoteApp 在 WindowGroup
// 顶层显式注入一次，保证启动后 `@Environment(\.aiService)` 能拿到 singleton。

@available(iOS 15.0, macOS 12.0, *)
private struct AIServiceEnvironmentKey: EnvironmentKey {
    static let defaultValue: AIServiceProtocol = OpenAIService.shared
}

@available(iOS 15.0, macOS 12.0, *)
extension EnvironmentValues {
    var aiService: AIServiceProtocol {
        get { self[AIServiceEnvironmentKey.self] }
        set { self[AIServiceEnvironmentKey.self] = newValue }
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
