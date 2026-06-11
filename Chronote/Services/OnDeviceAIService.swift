import Foundation
import FoundationModels

// MARK: - 端上 AI(Apple Foundation Models)
//
// **2026-06-11 新增**:四个高频、单条日记、结构化输出的 AI 任务跑在 iPhone 本地的
// Apple Intelligence 端上模型上 —— 心情打分 / 主题提取 / 一句话摘要 / 写作提示建议。
// 收益:零网络延迟、零 token 成本、离线可用、日记原文不出设备。
//
// **降级契约**:所有方法返回 Optional,`nil` = "端上不可用或本次生成失败",caller
// (`OpenAIService+OneShotAI` / `+Suggestions`)负责回落云端 Claude Sonnet 4.6。
// 触发 nil 的情况:
//   - Apple Intelligence 未开启 / 机型不支持 / 模型还在下载(`availability != .available`)
//   - 输入超过端上 4K token 上下文的保守预算(超长日记直接走云端,不截断硬塞)
//   - guardrails 拒答(日记常含心理健康内容,端上安全层可能误伤 —— 云端兜底)
//   - 其他生成错误(语言不支持等)
//
// **@Generable 守护式生成**:输出在解码层就被约束成目标 Swift 类型,不存在
// "模型返回非法 JSON → 手写解析兜底"这条失败路径。范围/数量类校验(分数 1-100、
// 标签 ≤4)仍在 caller 后处理,跟云端路径共用同一套清洗逻辑。
//
// 每次调用新建 `LanguageModelSession`(单轮无状态任务,不复用 session 避免上下文累积)。
// 任务指令放 `instructions`(系统层,优先级高于 prompt 内容),日记原文放 prompt ——
// 跟云端 import payload 的"指令/数据隔离"同思路,降低日记内容被当指令的注入面。

@available(iOS 26.0, *)
enum OnDeviceAIService {
    /// 单条输入的保守上限(UTF-16 units)。端上模型上下文 4096 token,中文 1 字 ≈ 1-2 token,
    /// 6000 units 给 instructions + 输出留足余量。超长不截断 —— 直接返回 nil 走云端,
    /// 保证超长日记的摘要/主题覆盖全文而不是前半截。
    static let maxInputUTF16Units = 6_000

    /// 端上模型当前是否可用。不可用的细分原因(未开 Apple Intelligence / 机型不支持 /
    /// 模型下载中)对 caller 无差别 —— 都走云端兜底,所以只暴露 Bool。
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability {
            return true
        }
        return false
    }

    /// 四个任务共用的模型句柄:`permissiveContentTransformations` guardrails。
    /// 日记任务全部是"对用户自有内容做转换"(摘要/打分/打标签),Apple 给这类场景专门
    /// 提供了宽松档 —— 默认 guardrails 对情绪沉重的日记内容(心理健康/哭/焦虑)有误伤面,
    /// 摘要尤其危险(输出要复述原文内容)。宽松档只放行内容转换,不放行自由生成。
    private static let permissiveModel = SystemLanguageModel(
        useCase: .general,
        guardrails: .permissiveContentTransformations
    )

    /// `task` 仅用于日志定位(诊断"哪个任务在哪一关被跳过")。
    private static func canHandle(_ text: String, task: String) -> Bool {
        guard isAvailable else {
            Log.info("[OnDeviceAI] \(task) 跳过端上: 模型不可用(\(SystemLanguageModel.default.availability))", category: .ai)
            return false
        }
        guard text.utf16.count <= maxInputUTF16Units else {
            Log.info("[OnDeviceAI] \(task) 跳过端上: 输入超长(\(text.utf16.count) utf16 units)", category: .ai)
            return false
        }
        return true
    }

    // MARK: - Generable 输出类型

    @Generable
    struct MoodScoreResult {
        @Guide(description: "Mood score from 1 (very negative) to 100 (very positive). Be decisive — avoid 50 unless truly neutral.")
        var moodScore: Int
    }

    @Generable
    struct ThemeTagsResult {
        @Guide(description: "2-4 concrete entity tags (people, pets, places, projects, activities, events) in the diary's own language. Empty if the entry has no concrete subject.")
        var themes: [String]
    }

    @Generable
    struct SummaryResult {
        @Guide(description: "One-line digest of the diary entry in its own language.")
        var summary: String
    }

    @Generable
    struct SuggestionsResult {
        @Guide(description: "4 first-person questions the user asks themselves, grounded in their recent entries.")
        var askPastPresets: [String]
        @Guide(description: "5 second-person placeholder lines the app says to the user, grounded in their recent entries.")
        var homePlaceholders: [String]
    }

    // MARK: - 心情打分

    /// 返回 1-100 的整数分(跟云端 prompt 同一把尺),caller 自己除以 100 + 共用范围校验。
    static func moodScore(text: String) async -> Int? {
        guard canHandle(text, task: "moodScore") else { return nil }
        let instructions = """
        Classify the mood of the diary entry on a 1-100 scale. Be decisive — avoid 50 unless truly neutral.
        Scale:
        - 1-20: very negative (grief, despair, fury)
        - 21-40: negative (sad, frustrated, anxious)
        - 41-60: neutral (factual, calm, mixed)
        - 61-80: positive (content, accomplished, warm)
        - 81-100: very positive (excited, ecstatic, deeply grateful)
        Pick the bucket that best matches the dominant feeling, then pick a specific number inside it.
        """
        do {
            let session = LanguageModelSession(model: Self.permissiveModel, instructions: instructions)
            let response = try await session.respond(to: text, generating: MoodScoreResult.self)
            return response.content.moodScore
        } catch {
            Log.warning("[OnDeviceAI] moodScore 端上生成失败: \(error)", category: .ai)
            #if compiler(>=6.4)
            if #available(iOS 27.0, *),
               let r = await pccRespond(prompt: text, instructions: instructions,
                                        generating: MoodScoreResult.self, task: "moodScore") {
                return r.moodScore
            }
            #endif
            return nil
        }
    }

    // MARK: - 主题提取

    /// 返回原始标签数组(未清洗)。banned-themes 过滤 / 截到 4 条在 caller 跟云端路径共用。
    static func themes(text: String) async -> [String]? {
        guard canHandle(text, task: "themes") else { return nil }
        let isZh = text.containsChinese
        let instructions: String
        if isZh {
            instructions = """
            从日记里抽取 2-4 个最具辨识度的标签。标签必须是具体的实体:人、宠物、地方、项目、活动、事件。
            可以保留完整的多词短语(如"女朋友 Abby"、"Orion 项目")。
            禁止使用情绪/评价/元描述词(情绪、心情、感受、反思、日常、记录、生活、思考、想法、焦虑、开心、难过、疲惫)。
            如果整篇只是抒情没有具体对象,返回空数组。标签语言跟随日记原文。
            """
        } else {
            instructions = """
            Extract 2-4 highly specific entity tags from the diary entry: people, pets, places, projects, activities, events.
            Multi-word phrases are allowed ("girlfriend Abby", "Orion project").
            NEVER use feeling/evaluation/meta words (emotion, feeling, mood, reflection, daily, journal, thought, anxiety, happy, sad, tired, vibe, life, general).
            If the entry is pure venting with no concrete subject, return an empty array. Tags follow the diary's language.
            """
        }
        do {
            let session = LanguageModelSession(model: Self.permissiveModel, instructions: instructions)
            let response = try await session.respond(to: text, generating: ThemeTagsResult.self)
            return response.content.themes
        } catch {
            Log.warning("[OnDeviceAI] themes 端上生成失败: \(error)", category: .ai)
            #if compiler(>=6.4)
            if #available(iOS 27.0, *),
               let r = await pccRespond(prompt: text, instructions: instructions,
                                        generating: ThemeTagsResult.self, task: "themes") {
                return r.themes
            }
            #endif
            return nil
        }
    }

    // MARK: - 一句话摘要

    static func summary(text: String) async -> String? {
        guard canHandle(text, task: "summary") else { return nil }
        let instructions: String
        if text.containsChinese {
            instructions = "概括这篇日记,抓住重点,不超过 15 个字。只能使用逗号和分号作为标点,最后一个字后面不要有标点。只输出概括本身。"
        } else {
            instructions = "Summarize the diary entry, focusing on key points, in no more than 10 words. Use only commas and semicolons as punctuation. Output the summary only."
        }
        do {
            let session = LanguageModelSession(model: Self.permissiveModel, instructions: instructions)
            let response = try await session.respond(to: text, generating: SummaryResult.self)
            let trimmed = response.content.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            Log.warning("[OnDeviceAI] summary 端上生成失败: \(error)", category: .ai)
            #if compiler(>=6.4)
            if #available(iOS 27.0, *),
               let r = await pccRespond(prompt: text, instructions: instructions,
                                        generating: SummaryResult.self, task: "summary") {
                let trimmed = r.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            #endif
            return nil
        }
    }

    // MARK: - 写作提示建议

    /// `prompt` 由 caller(`OpenAIService+Suggestions.buildSuggestionPrompt`)组装,
    /// 端上/云端共用同一份 prompt 模板,保证两条路径的产出风格一致。
    /// 返回 (presets, placeholders) 原始数组,空数组校验 / 截断在 caller。
    static func suggestions(prompt: String) async -> (presets: [String], placeholders: [String])? {
        guard canHandle(prompt, task: "suggestions") else { return nil }
        do {
            let session = LanguageModelSession(model: Self.permissiveModel)
            let response = try await session.respond(to: prompt, generating: SuggestionsResult.self)
            return (response.content.askPastPresets, response.content.homePlaceholders)
        } catch {
            Log.warning("[OnDeviceAI] suggestions 端上生成失败: \(error)", category: .ai)
            #if compiler(>=6.4)
            if #available(iOS 27.0, *),
               let r = await pccRespond(prompt: prompt, instructions: nil,
                                        generating: SuggestionsResult.self, task: "suggestions") {
                return (r.askPastPresets, r.homePlaceholders)
            }
            #endif
            return nil
        }
    }

    // MARK: - PCC(Apple 服务器模型)中间兜底

    #if compiler(>=6.4)
    /// Apple Private Cloud Compute 服务器模型 —— **端上失败后的第一兜底**(端上 → PCC → Sonnet)。
    /// 免费(Small Business Program 资格 Lumory 满足)、私有(Apple 不留存)、32K 上下文、
    /// 每用户每日限额;需联网。失败/不可用返回 nil,caller 继续落云端 Sonnet,断网时两者都失败。
    ///
    /// **双门控**:`#if compiler(>=6.4)` = 只在 Xcode 27(iOS 27 SDK)构建时编译,日常
    /// Xcode 26.5 命令行构建/测试不受影响;`#available(iOS 27.0, *)` = 只在 iOS 27+ 运行时执行。
    /// 注意:PCC 靠 App 签名身份认证(无 API key),裸 CLI 二进制会被 ModelManagerError 1046
    /// 拒掉 —— 必须在真实签名 App 内验证。
    @available(iOS 27.0, *)
    private static func pccRespond<T: Generable & Sendable>(
        prompt: String,
        instructions: String?,
        generating type: T.Type,
        task: String
    ) async -> T? {
        let model = PrivateCloudComputeLanguageModel()
        guard model.isAvailable else {
            Log.info("[OnDeviceAI] \(task) PCC 不可用(\(model.availability)),落云端", category: .ai)
            return nil
        }
        do {
            let session: LanguageModelSession
            if let instructions {
                session = LanguageModelSession(model: model, instructions: instructions)
            } else {
                session = LanguageModelSession(model: model)
            }
            let result = try await session.respond(to: prompt, generating: type).content
            Log.info("[OnDeviceAI] \(task) PCC 兜底成功", category: .ai)
            return result
        } catch {
            Log.warning("[OnDeviceAI] \(task) PCC 失败,落云端: \(error)", category: .ai)
            return nil
        }
    }
    #endif
}
