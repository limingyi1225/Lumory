import Foundation

// MARK: - Suggestions(AI 写作建议)
//
// **wave11 拆出**:从 OpenAIService.swift 把"写作建议"子系统聚到一起。
// `PromptSuggestionEngine` 是真源,这里是它调的 AI 接口 —— 一次 gpt-5.5 同时生成
// AskPast 4 条预设 + 首页 5 条占位语,JSON 返回。
//
// 包含:
//   - composeSuggestions       —— 主入口
//   - parseSuggestionBundle    —— 静态纯函数,JSON → SuggestionBundle(便于单测)
//   - buildSuggestionPrompt    —— 私有静态 helper,构造 prompt(含中英两套 + 真实数据片段)

@available(iOS 15.0, macOS 12.0, *)
extension OpenAIService {
    /// 一次 gpt-5.5 调用生成 AskPast 预设 + 首页占位语池，JSON 返回。
    /// 失败 / 畸形 / 字段不全 → 返回 nil，让 PromptSuggestionEngine 保留旧 cache 或上游 fallback。
    func composeSuggestions(context: SuggestionContext) async -> SuggestionBundle? {
        let prompt = Self.buildSuggestionPrompt(context: context)
        guard let raw = await chat(
            prompt: prompt,
            model: "gpt-5.5",
            maxTokens: 1024,
            forceJSON: true,
            reasoningEffort: "low"
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
        let zh = context.language == "zh"

        // 主题清单
        let themesBlock: String = {
            guard !context.topThemes.isEmpty else { return zh ? "暂无" : "(none yet)" }
            return context.topThemes.prefix(5).enumerated().map { i, t in
                let moodInt = Int(t.avgMood * 100)
                return zh
                    ? "\(i + 1). \(t.name)（出现 \(t.uniqueDays) 个不同的日子，平均情绪 \(moodInt)/100）"
                    : "\(i + 1). \(t.name) (on \(t.uniqueDays) distinct days, avg mood \(moodInt)/100)"
            }.joined(separator: "\n")
        }()

        // 近期原文 —— **刻意不给日期**。前版把每条原文前缀 `[MM-dd]`，LLM 被诱导写出
        // "1 月 10 号的开心你还记得吗" 这类以日期为锚点的问题，但用户不会按日期记事。
        // 只给情绪分数作为内部区分，每条加 tag（A/B/C）只为让 LLM 在 prompt 内部可引用，
        // 输出里禁止重新出现 tag（由规则约束）。
        let recentBlock: String = {
            guard !context.recentEntries.isEmpty else { return zh ? "暂无" : "(none yet)" }
            return context.recentEntries.map { entry in
                let moodInt = Int(entry.moodValue * 100)
                let snippet = entry.summary.isEmpty ? entry.text : entry.summary + "｜" + entry.text
                return "[mood=\(moodInt)] \(snippet)"
            }.joined(separator: "\n\n")
        }()

        // 情绪极端 —— 同样去日期。只保留 summary/text 和 "high/low" 标签。
        let extremesBlock: String = {
            var lines: [String] = []
            if let high = context.moodHighEntry {
                let text = high.summary.isEmpty ? String(high.text.prefix(120)) : high.summary
                lines.append(zh ? "最开心那篇：\(text)" : "Happiest entry: \(text)")
            }
            if let low = context.moodLowEntry {
                let text = low.summary.isEmpty ? String(low.text.prefix(120)) : low.summary
                lines.append(zh ? "最低落那篇：\(text)" : "Lowest entry: \(text)")
            }
            return lines.isEmpty ? (zh ? "无" : "(n/a)") : lines.joined(separator: "\n")
        }()

        let avgMoodInt = Int(context.moodAvg30d * 100)

        if zh {
            return """
            你要为一个日记 App 写两类文案,都从用户的真实数据里取材,让人一眼觉得"这个 App 真的认识我"。
            **A 类是用户自己的内心独白(主语"我")**;**B 类是 App 跟今天的用户搭话(主语"你")**。
            视角不同,语气都要具体、有温度、扎到心。

            ## 通用规则(适用所有条目)

            1. **每一条都引用真实细节**:从下面给的数据里挑具体人名、事件、场景、原文金句,
               把它们直接写进句子里。

            2. **用事件 / 人物 / 主题做时间锚**:像"和妈妈通话之后"、"在咖啡馆那次"、
               "为了 X 项目焦虑那阵"。

            3. **名字直接融进句子**,像写小说,不加括号或引号包装。

            4. **语气走心、具体、有温度**,像翻日记翻到那一页时心里冒出来的那句话。

            ## A. askPastPresets — 4 条问题(第一人称 · 用户内心独白)

            - **主语只能是"我" / "我们" / "我自己"** —— 用户对自己说的话。
            - 长度 15-40 字。
            - **问号结尾**。
            - 写给"想搞清楚关于自己的某件事"的用户 —— 让用户一眼想点进去翻自己的日记找答案。

            ✅ "我和 Abby 之间最近的紧张感到底从哪来的？"
            ✅ "为什么提到妈妈我总会变得安静？"
            ✅ "我最开心的几篇为什么都和深夜散步有关？"

            ## B. homePlaceholders — 5 条占位文字(第二人称 · App 跟今天的用户搭话)

            - **主语只能是"你"** —— App 在跟用户对话,**不是**用户对自己说话。**不要出现"我"**。
            - **聚焦"当下"和"最近"**:用户最近写过的人 / 事 / 状态,以一个朋友
              的语气问问"现在怎么样了?""最近怎么应对的?""今天有没有...?"。
            - **不要问用户具体某天的感受**(像"3 月 5 号那天怎么样")。聊"现在"和"最近"。
            - **每条必须是完整句子**,问号或句号收尾,不能是半截观察。
            - 长度 8-22 字。

            ### homePlaceholders 示例(基于"用户最近经历了分手 + 工作焦虑"这种真实数据)

            ✅ "分手之后你做了什么让自己好一些？"
            ✅ "你最近还和她联系吗？想聊聊吗？"
            ✅ "今天那场会议还在让你紧张吗？"
            ✅ "有没有什么你想对今天的自己说的？"
            ✅ "和爸爸通完电话,你想记下什么？"
            ✅ "想聊聊昨晚没睡好的原因吗？"

            ## 输出 JSON(字段严格)

            {
              "askPastPresets": ["我...?", "我...?", "我...?", "我...?"],
              "homePlaceholders": ["你...?", "你...?", "你...?", "你...?", "你...?"]
            }

            ## 用户数据

            【最常出现的人 / 事 / 地】
            \(themesBlock)

            【最近 30 天情绪均值】\(avgMoodInt)/100
            \(extremesBlock)

            【连续写了 \(context.currentStreak) 天,一共 \(context.totalEntries) 篇】

            【最近 3 篇原文片段】
            \(recentBlock)
            """
        } else {
            return """
            Write two kinds of copy for a journaling app, both grounded in the user's real
            data so every line feels like the app knows the user. **Type A is the user's
            inner monologue (subject = "I")**; **Type B is the app speaking to the user
            today (subject = "you")**. Different voices, same intimate tone — specific,
            warm, emotionally precise.

            ## Universal rules (apply to every entry)

            1. **Every line references real details**: pick specific names, events, scenes,
               quoted phrases from the data below and weave them in.

            2. **Anchor time with events / people / themes** — phrases like "after talking
               to Mom", "at the coffee shop that time", "during the X project crunch".

            3. **Integrate names naturally** into the sentence, like prose, no brackets
               or quotes around them.

            4. **Tone = concrete, warm, intimate** — like the line that flashes through
               your head when you flip to that page.

            ## A. askPastPresets — 4 questions (first-person, user's inner monologue)

            - **Subject must be "I" / "my" / "we"** — the user speaking to themselves.
            - 15-40 chars each.
            - **End with a question mark.**
            - Written for a user trying to figure out something about themselves — should
              make them tap to dig through their diary for the answer.

            ✅ "Why does talking about Mom always make me go quiet?"
            ✅ "What is it about Abby that always relaxes me?"
            ✅ "Why are my happiest entries all from late-night walks?"

            ## B. homePlaceholders — 5 placeholder lines (second-person, APP speaks to user)

            - **Subject must be "you" / "your"** — the app talks to the user,
              **not** the user to themselves. **Do not use "I".**
            - **Focus on the present and the recent**: pick people / events / states the
              user has been writing about lately, then ask how it's going **right now**
              or **how they've been coping recently**.
            - **Don't ask about specific past dates** (no "on March 5"). Talk in
              "now" / "lately" terms.
            - **Each line must be a complete sentence**, ending in ? or . — no half-
              finished observations.
            - 4-14 words each.

            ### homePlaceholders examples (assuming "user just went through a breakup + work stress")

            ✅ "What's helped you feel a little better since the breakup?"
            ✅ "Have you reached out to her at all recently?"
            ✅ "Is that meeting still weighing on you today?"
            ✅ "Anything you want to tell yourself today?"
            ✅ "Want to write about how the call with Dad went?"
            ✅ "What's keeping you up at night these days?"

            ## Output JSON (strict)

            {
              "askPastPresets": ["I ...?", "I ...?", "I ...?", "I ...?"],
              "homePlaceholders": ["You ...?", "You ...?", "You ...?", "You ...?", "You ...?"]
            }

            ## User data

            [Most recurring people / events / places]
            \(themesBlock)

            [Past 30 days mood average] \(avgMoodInt)/100
            \(extremesBlock)

            [Streak: \(context.currentStreak) days, \(context.totalEntries) entries total]

            [Last 3 entries]
            \(recentBlock)
            """
        }
    }
}
