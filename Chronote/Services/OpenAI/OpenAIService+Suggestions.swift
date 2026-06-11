import Foundation

// MARK: - Suggestions(AI 写作建议)
//
// **wave11 拆出**:从 OpenAIService.swift 把"写作建议"子系统聚到一起。
// `PromptSuggestionEngine` 是真源,这里是它调的 AI 接口 —— 一次调用同时生成
// AskPast 4 条预设 + 首页 5 条占位语(2026-06-11 起端上 Foundation Models 优先,
// 云端 Claude Sonnet 4.6 兜底,共用同一份 prompt 模板)。
//
// 包含:
//   - composeSuggestions       —— 主入口
//   - parseSuggestionBundle    —— 静态纯函数,JSON → SuggestionBundle(便于单测)
//   - buildSuggestionPrompt    —— 私有静态 helper,构造 prompt(含中英两套 + 真实数据片段)

@available(iOS 15.0, macOS 12.0, *)
extension OpenAIService {
    /// 一次调用生成 AskPast 预设 + 首页占位语池。**端上优先(Apple Foundation Models)+
    /// 云端 Claude Sonnet 4.6 兜底**(2026-06-11 迁移),两条路径共用同一份 prompt 模板。
    /// 失败 / 畸形 / 字段不全 → 返回 nil,让 PromptSuggestionEngine 保留旧 cache 或上游 fallback。
    func composeSuggestions(context: SuggestionContext) async -> SuggestionBundle? {
        let prompt = Self.buildSuggestionPrompt(context: context)

        // 端上优先。产出走 parseSuggestionBundle 同款 trim / 空校验 / 截断,
        // 任一字段为空回落云端(端上小模型偶发只填一个字段)。
        if let onDevice = await OnDeviceAIService.suggestions(prompt: prompt) {
            let presets = onDevice.presets
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(5)
            let placeholders = onDevice.placeholders
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(8)
            if !presets.isEmpty, !placeholders.isEmpty {
                return SuggestionBundle(
                    askPastPresets: Array(presets),
                    homePlaceholders: Array(placeholders),
                    generatedAt: Date(),
                    fingerprint: context.makeFingerprint(),
                    language: context.language
                )
            }
            Log.info("[composeSuggestions] 端上产出字段不全,回落云端", category: .ai)
        }

        guard let raw = await claudeChat(
            prompt: prompt,
            model: ClaudeModel.sonnet,
            maxTokens: 1024,
            jsonSchema: Self.suggestionBundleSchema
        )?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            Log.error("[composeSuggestions] 无响应", category: .ai)
            return nil
        }

        return Self.parseSuggestionBundle(
            rawJSON: raw,
            fingerprint: context.makeFingerprint(),
            language: context.language,
            generatedAt: Date()
        )
    }

    /// 云端兜底的结构化输出 schema。字段名与 prompt 的"输出 JSON"段一致,
    /// parseSuggestionBundle 的同义 key 容错(presets/placeholders)继续保留无妨。
    private static let suggestionBundleSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "askPastPresets": ["type": "array", "items": ["type": "string"]],
            "homePlaceholders": ["type": "array", "items": ["type": "string"]]
        ],
        "required": ["askPastPresets", "homePlaceholders"],
        "additionalProperties": false
    ]

    /// 纯函数版的 JSON → SuggestionBundle 解析。提取出来是为了能在单测里喂各种
    /// 畸形 / 缺字段 / 同义 key 的输入验证 fallback 行为，同时也让 composeSuggestions
    /// 本身更短好读。`now` 做参数让测试不依赖当前时间。
    /// 接受两个字段名别名：`askPastPresets` 或 `presets`；`homePlaceholders` 或 `placeholders`。
    /// presets 最多保留 5 条，placeholders 最多保留 8 条。任一字段为空 → 返回 nil。
    static func parseSuggestionBundle(
        rawJSON: String,
        fingerprint: String,
        language: String,
        generatedAt: Date
    ) -> SuggestionBundle? {
        guard let data = rawJSON.data(using: .utf8) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // 新 prompt 明确要求模型引用具体人名 / 事件 / 原文片段。rawJSON 极大概率含 PII,
            // 无论 build 都只记长度 / 是否空;需要排查本地换 DEBUG 临时加 dump,不入日志/crashlog。
            Log.error("[composeSuggestions] JSON parse 失败 (len=\(rawJSON.count), empty=\(rawJSON.isEmpty))", category: .ai)
            return nil
        }

        let presetsRaw = json["askPastPresets"] as? [String] ?? json["presets"] as? [String] ?? []
        let placeholdersRaw = json["homePlaceholders"] as? [String] ?? json["placeholders"] as? [String] ?? []

        let presets = presetsRaw
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(5)
        let placeholders = placeholdersRaw
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(8)

        guard !presets.isEmpty, !placeholders.isEmpty else {
            Log.error("[composeSuggestions] 字段缺失 presets=\(presets.count) placeholders=\(placeholders.count)", category: .ai)
            return nil
        }

        return SuggestionBundle(
            askPastPresets: Array(presets),
            homePlaceholders: Array(placeholders),
            generatedAt: generatedAt,
            fingerprint: fingerprint,
            language: language
        )
    }

    fileprivate static func buildSuggestionPrompt(context: SuggestionContext) -> String {
        let isZh = context.language == "zh"
        let todayStr = formatDateForPrompt(context.today, isZh: isZh)
        let entriesBlock = buildEntriesBlock(context: context, isZh: isZh)

        if isZh {
            return """
            你为一个日记 App 生成两类提示文案,都从用户最近 5 篇日记的真实内容里取材,让人一眼觉得"这个 App 真的认识我"。

            ## 时间锚(关键)

            今天是 \(todayStr)。下面每篇日记都标了日期 —— **用日期推断事件的时序**(已经发生 / 还没发生 / 过去多久了),但**生成的句子里绝对不要回吐具体日期**,改用相对时间("上周"、"前几天")或事件 / 人物 / 主题做锚。

            ❌ "5 月 8 号说要去滑冰,后来怎么样?"
            ✅ "周末滑冰怎么样?膝盖还在疼吗?"

            ## A 类 askPastPresets:4 条第一人称问题

            - 主语只能是"我" / "我自己" / "我们"。
            - 15-40 字,问号结尾。
            - 用户对自己发问 —— 看到想点进去翻自己的日记找答案。

            ## B 类 homePlaceholders:5 条第二人称占位文字

            - 主语只能是"你",**不要出现"我"**。
            - 8-22 字,完整句子,问号或句号结尾。
            - App 用朋友的语气跟今天的用户搭话,聊"现在 / 最近"。

            ## 通用规则

            每条都要扎进真实细节(具体人名、事件、原文里出现过的场景),语气走心、具体、有温度,不要堆套话。

            ## 输出 JSON(字段严格)

            {
              "askPastPresets": ["我...?", "我...?", "我...?", "我...?"],
              "homePlaceholders": ["你...?", "你...?", "你...?", "你...?", "你...?"]
            }

            ## 用户最近的日记(时间正序,最下面是最新一篇)

            \(entriesBlock)
            """
        } else {
            return """
            Write two kinds of prompt copy for a journaling app, both grounded in the user's last 5 entries — every line should feel like the app actually knows them.

            ## Time anchor (critical)

            Today is \(todayStr). Each entry below is dated — **use the dates to reason about timing** (already happened / hasn't yet / how long ago), but **never echo a specific date in your output**. Use relative time ("last week", "the other day") or event / person / theme anchors instead.

            ❌ "How did the skating you mentioned on May 8 go?"
            ✅ "How was skating this weekend? Knees still sore?"

            ## A. askPastPresets — 4 first-person questions

            - Subject must be "I" / "my" / "we".
            - 15-40 chars each, ending with "?".
            - User asking themselves — should make them want to dig through their diary for the answer.

            ## B. homePlaceholders — 5 second-person placeholders

            - Subject must be "you" / "your". **Do not use "I".**
            - 4-14 words each, complete sentence, ending in "?" or ".".
            - App talks to today's user like a close friend, about "now" / "lately".

            ## Universal

            Every line must pull in real details (names, events, specific moments from the entries below). Tone: concrete, warm, intimate. No generic filler.

            ## Output JSON (strict)

            {
              "askPastPresets": ["I ...?", "I ...?", "I ...?", "I ...?"],
              "homePlaceholders": ["You ...?", "You ...?", "You ...?", "You ...?", "You ...?"]
            }

            ## User's recent entries (chronological, newest at the bottom)

            \(entriesBlock)
            """
        }
    }

    private static func buildEntriesBlock(context: SuggestionContext, isZh: Bool) -> String {
        guard !context.recentEntries.isEmpty else {
            return isZh ? "(用户还没写过日记)" : "(no entries yet)"
        }
        // recentEntries 来自 InsightsEngine 是降序(最新在前),这里 reversed 翻成时间正序,
        // 让模型按"日记本翻页"的顺序读,最新一篇出现在 prompt 最末,自然偏向"当下"。
        return context.recentEntries.reversed().map { entry in
            let dateStr = formatDateForPrompt(entry.date, isZh: isZh)
            let body = entry.text.isEmpty ? entry.summary : entry.text
            return "[\(dateStr)] \(body)"
        }.joined(separator: "\n\n")
    }

    private static func formatDateForPrompt(_ date: Date, isZh: Bool) -> String {
        let dayFmt = DateFormatter()
        let weekFmt = DateFormatter()
        if isZh {
            dayFmt.locale = Locale(identifier: "zh_Hans")
            dayFmt.dateFormat = "M月d日"
            weekFmt.locale = Locale(identifier: "zh_Hans")
            weekFmt.dateFormat = "EEE"
            return "\(dayFmt.string(from: date))(\(weekFmt.string(from: date)))"
        } else {
            dayFmt.locale = Locale(identifier: "en_US_POSIX")
            dayFmt.dateFormat = "MMM d"
            weekFmt.locale = Locale(identifier: "en_US_POSIX")
            weekFmt.dateFormat = "EEE"
            return "\(dayFmt.string(from: date)) (\(weekFmt.string(from: date)))"
        }
    }
}
