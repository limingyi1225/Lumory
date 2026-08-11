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

// (2026-05-15 megareview OPT-MID-1)`AnalysisResult` 结构 + `extension AIServiceProtocol { analyze }`
// 默认实现 都删 — grep 全仓 0 caller(实际生产路径 EntryCreationService 各自并发调
// summarize / analyzeMood / extractThemes,从来没走过 analyze 这条总入口)。原实现保留在 git history。

// MARK: - Theme alias judge types
//
// `judgeThemeAliases` (on-write) 与 `scanThemeAliasGroups` (一次性 scan) 共用的 IO。
// 都 Sendable 因为会跨 await boundary。

/// 喂给模型的"已有标签库存"条目。`sampleSnippet` 可空——能给一两句例子最准,
/// 没有也能跑(只看 tag 文本本身,准确率会下降但不致命)。
struct ThemeAliasJudgeCandidate: Sendable, Codable, Equatable {
    let tag: String
    let count: Int
    let sampleSnippet: String?
}

/// on-write judge 的一条匹配。`reason` 仅作 Log/UI 透出,不强依赖。
struct ThemeAliasJudgeMatch: Sendable, Codable, Equatable {
    let newTag: String
    let canonical: String
    let confidence: Confidence
    let reason: String?
    enum Confidence: String, Sendable, Codable { case high, medium }
}

/// scan 的一组聚合。canonical 由模型选(通常是出现次数最高的);UI 仍允许用户反选 / 自定义。
struct ThemeAliasJudgeGroup: Sendable, Codable, Equatable {
    let canonical: String
    let aliases: [String]
    let confidence: Confidence
    let reason: String?
    enum Confidence: String, Sendable, Codable { case high, medium }
}

/// 网络 / 后端 / AI 解析失败时,scan 路径用此 error 走 UI 区分"真的扫到 0 条"和"网络挂了 0 条"。
enum ThemeAliasError: LocalizedError, Sendable {
    case requestFailed
    case parsingFailed
    var errorDescription: String? {
        switch self {
        case .requestFailed:
            return NSLocalizedString("无法连接到服务器,请稍后再试。", comment: "Theme alias scan network error")
        case .parsingFailed:
            return NSLocalizedString("AI 返回内容无法解析,请稍后再试。", comment: "Theme alias scan parsing error")
        }
    }
}

/// 主题抽取的回填专用结果。普通写入路径仍可把失败降级成 `[]`,但批量重建必须区分
/// "AI 合法判断无主题" 与 "请求/解析失败",否则会把已有主题误清空。
enum ThemeExtractionOutcome: Sendable, Equatable {
    case success([String])
    case failed
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

// `: Sendable` — 协议实例(`OpenAIService.shared` / `MockAIService`)被 9+ 处当
// `let ai: AIServiceProtocol` 跨 await / actor 边界传(`EntryCreationService` Task →
// `performAIWriteback`,`InsightsEngine` / `InsightsSearchEngine` / `NarrativePrecomputeService`
// 间接持等)。Swift 5 mode 是 warning,Swift 6 strict mode 全仓编不过 — 显式 Sendable
// 锁住契约 + 未来再加 stored property 时编译器立刻强制满足 Sendable 不变量。
// `OpenAIService` 是 immutable stored state(let session / let appSharedSecret / static
// actor),`MockAIService` 是 struct,都满足 Sendable;若 future 实现含 mutable shared
// state 必须改 `@unchecked Sendable` + 内部锁。
protocol AIServiceProtocol: Sendable {
    /// 根据文本生成简要摘要
    func summarize(text: String) async -> String?

    /// 根据文本分析心情，返回 0.0 ~ 1.0
    func analyzeMood(text: String) async -> Double

    // MARK: - Phase 0: AI × 统计融合地基

    /// 从日记文本抽取 0-4 个主题标签。
    /// 返回值顺序不重要，语言应匹配输入文本。
    func extractThemes(text: String) async -> [String]

    /// 区分失败与合法空数组的主题抽取。批量回填使用这条避免失败时抹掉已有主题。
    func extractThemesOutcome(text: String) async -> ThemeExtractionOutcome

    /// 跨日记主题别名判断:给定一组**新抽出来的 tag** 和用户**已有的 tag 库存**,
    /// 让 LLM 找出"新 tag 可能与已有某 tag 指向同一实体"的对子。
    /// 用在 on-write 路径:写完日记 → extractThemes → 这一调用 → 入 PendingSuggestion 队列。
    /// `inventory` 每条带出现次数和 1-2 句样例上下文,让模型判断更稳。
    /// 实现侧约束:严苛宁缺勿滥,只返回 high/medium,low 全部丢。
    func judgeThemeAliases(
        newTags: [String],
        inventory: [ThemeAliasJudgeCandidate]
    ) async -> [ThemeAliasJudgeMatch]

    /// 一次性扫描已有 tag 列表的相互别名关系。Settings 的"扫描已有主题"按钮调。
    /// 不区分新/旧,模型自己在列表里找成组的(canonical + aliases)。
    /// **throws** 区分"网络/解析失败"(throw)和"AI 真的没找到匹配"(返回 [])——
    /// 让 Settings 扫描页能区分两种情况:`.failed("network error")` vs `.done` 但 0 条。
    func scanThemeAliasGroups(
        candidates: [ThemeAliasJudgeCandidate]
    ) async throws -> [ThemeAliasJudgeGroup]

    /// 生成语义向量（float32），用于语义搜索与 RAG 检索。
    /// 失败返回 nil；调用方应妥善处理（例如延后 backfill）。
    func embed(text: String) async -> [Float]?

    /// 结构化事件版对话式回顾流 —— 能区分 `.chunk` / `.truncated` / `.failed`。
    /// 实现方负责 prompt 组装;调用方负责先做检索把 `context` 限制在合理数量内。
    /// UI 用 `.truncated` 显示"回答不完整"条,`.failed` 显示错误条。
    @available(iOS 15.0, macOS 12.0, *)
    func askEvents(question: String, context entries: [DiaryEntryData]) -> AsyncStream<StreamEvent>

    /// 结构化流式报告事件 —— UI 可区分 `.chunk` / `.truncated` / `.failed` / `.done`。
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
    func extractThemesOutcome(text: String) async -> ThemeExtractionOutcome {
        .success(await extractThemes(text: text))
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

    func judgeThemeAliases(
        newTags: [String],
        inventory: [ThemeAliasJudgeCandidate]
    ) async -> [ThemeAliasJudgeMatch] {
        // 离线 mock:简单的"互含子串 + 长度差不大"启发式,只用于跑 happy-path 测试。
        // 真实判断走 OpenAIService。
        var out: [ThemeAliasJudgeMatch] = []
        let inventoryTags = inventory.map { $0.tag }
        for newTag in newTags {
            for invTag in inventoryTags where invTag != newTag {
                let a = newTag.lowercased()
                let b = invTag.lowercased()
                if a == b { continue }
                if a.contains(b) || b.contains(a) {
                    out.append(ThemeAliasJudgeMatch(
                        newTag: newTag,
                        canonical: invTag,
                        confidence: .medium,
                        reason: "mock: substring"
                    ))
                }
            }
        }
        return out
    }

    func scanThemeAliasGroups(
        candidates: [ThemeAliasJudgeCandidate]
    ) async throws -> [ThemeAliasJudgeGroup] {
        // 离线 mock:基于 lowercased prefix 的 trivial 聚类。仅供单测。
        var byPrefix: [String: [ThemeAliasJudgeCandidate]] = [:]
        for c in candidates {
            let key = String(c.tag.lowercased().prefix(2))
            byPrefix[key, default: []].append(c)
        }
        return byPrefix.values.compactMap { group -> ThemeAliasJudgeGroup? in
            guard group.count >= 2 else { return nil }
            let canon = group.max(by: { $0.count < $1.count })?.tag ?? group[0].tag
            let aliases = group.map { $0.tag }.filter { $0 != canon }
            return ThemeAliasJudgeGroup(
                canonical: canon,
                aliases: aliases,
                confidence: .medium,
                reason: "mock: prefix"
            )
        }
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

    @available(iOS 15.0, macOS 12.0, *)
    func askEvents(question: String, context entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
        AsyncStream { continuation in
            continuation.yield(.chunk("Mock 回答：你问了『\(question)』，基于 \(entries.count) 条日记。"))
            continuation.yield(.done)
            continuation.finish()
        }
    }

    @available(iOS 15.0, macOS 12.0, *)
    func streamReportEvents(entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
        // wave15 — 输出 [HEADLINE]/[BODY] marker 格式,匹配 prompt 让客户端 splitter 能拿到
        // headline。所有依赖 mock narrative 文本的测试要相应更新。
        AsyncStream { continuation in
            Task {
                let total = entries.count
                let avg = entries.isEmpty ? 0.5 : entries.map { $0.moodValue }.reduce(0, +) / Double(total)
                continuation.yield(.chunk("[HEADLINE]\n"))
                continuation.yield(.chunk("这段时间像一杯凉茶 慢慢见底\n"))
                continuation.yield(.chunk("[BODY]\n"))
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
        // Mock:不调用 LLM,直接拼出能跑的最简 bundle,单测友好。
        let zh = context.language == "zh"
        let presets = zh
            ? ["最近最牵挂什么？", "我为什么会反复想到那件事？"]
            : ["What's been on your mind?", "Why does this keep coming back?"]
        let placeholders = zh
            ? ["今天怎么样？", "想写点什么？"]
            : ["How was today?", "Want to write something?"]
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
