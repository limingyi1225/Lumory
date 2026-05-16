import Foundation
import CryptoKit

// MARK: - OneShotAI(一次性 AI:输入文本 → 输出值)
//
// **wave11 拆出**:从 OpenAIService.swift 把 5 条"非流式 / 单次往返"AI 入口聚到一起。
// 共同特征:caller `await` 一个值返回(摘要/分数/向量/标签数组),底下都走 `chat`
// 这条共享通路。流式入口(askEvents / streamReportEvents / generateReportFromData)在
// `+Streaming.swift`,职责完全不同。
//
// 包含:
//   - summarize       —— 日记摘要
//   - analyzeMood     —— 情绪分数(0-1)
//   - firstValidScore —— 静态 helper:从自由文本提取 mood 分数(测试可见)
//   - extractThemes   —— 抽 2-4 个主题标签
//   - embed           —— 向量嵌入
//   - bannedThemes / embeddingPayload —— 私有静态 helper

@available(iOS 15.0, macOS 12.0, *)
extension OpenAIService {
    // MARK: Public — 摘要 / 情绪
    func summarize(text: String) async -> String? {
        // SHA256 前缀做 debounce key：hashValue 碰撞概率虽低但不为零，且不稳定；SHA256 前 16 hex
        // 对 debounce 场景足够（碰撞概率 <2^-64），一次改干净。
        let digest = SHA256.hash(data: Data(text.utf8))
        let shortHash = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        let requestKey = "summarize-\(shortHash)"
        return await debouncedRequest(key: requestKey, cancelledFallback: nil) {
            let prompt: String
            if text.containsChinese {
                prompt = "概括以下日记内容，抓住重点，不超过15个字，仅使用逗号和分号。\n# Steps\n1. 阅读并理解日记内容。\n2. 抓住日记的关键信息和主题。\n3. 使用简洁精准的语言进行概括。\n4. 确保概括不超过15个字。\n5. 仅使用逗号和分号作为标点符号。\n# Output Format\n- 一个简短的概括，不超过15个字。\n- 仅使用逗号和分号，最后一个字后面不要有标点符号\n日记：\n\n\(text)"
            } else {
                prompt = "Summarize the following diary entry, focusing on the key points, in no more than 10 words, using only commas and semicolons.\n# Steps\n1. Read and understand the diary entry.\n2. Identify the key information and theme.\n3. Summarize using concise and precise language.\n4. Ensure the summary does not exceed 10 words.\n5. Use only commas and semicolons as punctuation.\n# Output Format\n- A short summary, no more than 10 words.\n- Only commas and semicolons used.\nDiary:\n\n\(text)"
            }
            // 显式 maxTokens: 512——`chat` 的默认 128 对 gpt-5.5 "low" reasoning 太紧，
            // reasoning tokens 本身就会吃掉一半以上，content 经常被截 / 返回空串。
            return await self.chat(prompt: prompt, model: "gpt-5.5", maxTokens: 512, reasoningEffort: "low")
        }
    }

    func analyzeMood(text: String) async -> Double {
        // gpt-5.4-mini + effort=none。mini 家族支持 `none`（零推理开销），大模型 5.5 只支持 low+。
        // prompt 显式列出 1-20 / 21-40 / 41-60 / 61-80 / 81-100 五档 + "avoid 50" 强硬指令，
        // 让 mini 不经推理也能直接给出决断分。
        let diaryEscaped = text.replacingOccurrences(of: "\"", with: "\\\"")
        let prompt = """
            Classify the mood of this diary entry on a 1-100 scale. Be decisive — avoid 50 unless truly neutral.

            Scale:
            - 1-20: very negative (grief, despair, fury)
            - 21-40: negative (sad, frustrated, anxious)
            - 41-60: neutral (factual, calm, mixed)
            - 61-80: positive (content, accomplished, warm)
            - 81-100: very positive (excited, ecstatic, deeply grateful)

            Pick the bucket that best matches the dominant feeling, then pick a specific number inside it.
            Reply with JSON ONLY: {"mood_score": N}

            Diary: "\(diaryEscaped)"
            """

        let rawOpt = await self.chat(
            prompt: prompt,
            model: "gpt-5.4-mini",
            maxTokens: 256,
            forceJSON: true,
            reasoningEffort: "none"      // mini 家族支持 none，直接省掉推理开销
        )?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let resultStr = rawOpt else {
            Log.error("[analyzeMood] 网络/模型无响应，回退中性", category: .ai)
            return 0.5
        }

        if let data = resultStr.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let score = json["mood_score"] as? Int, (1...100).contains(score) {
                return Double(score) / 100.0
            }
            if let score = json["mood_score"] as? Double, (1...100).contains(Int(score)) {
                return score / 100.0
            }
        }
        // 回退：提取文本中最后一个 1-100 区间的数字（避免匹配到 "mood_score" 里的 score=5）
        if let number = Self.firstValidScore(in: resultStr) {
            return Double(number) / 100.0
        }

        Log.error("[analyzeMood] 无法解析情绪分数，bodyLen=\(resultStr.count) —— 回退中性 0.5", category: .ai)
        return 0.5
    }

    /// 从自由文本里找第一个看起来像 mood 分数的整数（1...100）。
    /// 遇到 4+ 位长数字（比如 `2024` 年份 / 请求 ID / token 计数）时**跳过这个整数剩余位**
    /// 而不是 `break` 退出整个扫描——否则 LLM 响应里夹一个"2024"就把真正的 mood 分数吃掉了。
    static func firstValidScore(in string: String) -> Int? {
        var current = ""
        var skipRestOfNumber = false
        for ch in string {
            if ch.isNumber {
                if skipRestOfNumber { continue }
                current.append(ch)
                if current.count > 3 {
                    // 超长整数，丢弃这一坨的剩余位，继续找后面的数字
                    current.removeAll()
                    skipRestOfNumber = true
                }
            } else {
                skipRestOfNumber = false
                if !current.isEmpty {
                    if let number = Int(current), (1...100).contains(number) { return number }
                    current.removeAll()
                }
            }
        }
        if let number = Int(current), (1...100).contains(number) { return number }
        return nil
    }

    // MARK: Themes — 抽取
    /// 从日记里抽取 2-4 个「可聚合」标签：具体的人、地方、活动、项目、事件名。
    /// 情绪 / 心情 / 感受这类元描述是另一条线单独捕获的（见 analyzeMood），
    /// 不应混进来——否则所有 entry 都会被贴"情绪"，导致聚合时出现一大堆同名噪音。
    func extractThemes(text: String) async -> [String] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let diaryEscaped = text.replacingOccurrences(of: "\"", with: "\\\"")
        let isZh = text.containsChinese
        let prompt: String
        if isZh {
            prompt = """
            从下面这篇日记里抽取 2-4 个最具辨识度的标签。
            标签必须是**具体的实体**：人、宠物、地方、项目、活动、事件。

            **重要：可以保留完整的多词短语**，带关系/修饰的更好：
              ✓ "女朋友 Abby"（比单个 "Abby" 强——保留了角色关系）
              ✓ "Orion 项目"、"上海出差"、"周三的跑步"、"妈妈打来的电话"
              ✗ 单独的 "男朋友"、"项目"（太泛）
              ✗ "情绪"、"焦虑"、"心情"（元描述，禁止）

            原则：标签长度 2-12 字，保持原文大小写、中英混合、emoji 原样。
            同一实体在不同日记里要**能稳定聚合**——比如 Abby 这个人名本身是主键，
            如果这篇里写的是"女朋友 Abby"而上篇是"Abby"，两篇都返回 "Abby" 即可，
            关系/修饰词只在**第一次**出现或特别有意义时保留。

            禁止使用情绪/评价词：情绪、心情、感受、反思、日常、记录、生活、
            思考、想法、感想、焦虑、开心、难过、疲惫。情绪单独记录了。

            如果整篇只是抒情没有具体对象，返回空数组。
            只返回 JSON：{"themes": ["标签1","标签2"]}

            日记：\"\(diaryEscaped)\"
            """
        } else {
            prompt = """
            Extract 2-4 highly specific entity tags from this diary entry.
            Tags MUST be concrete entities: people, pets, places, projects, activities, events.

            **Multi-word phrases are allowed and often better** when they carry relationship or modifier context:
              ✓ "girlfriend Abby" (beats bare "Abby" — preserves role)
              ✓ "Orion project", "trip to Tokyo", "Wednesday run", "call from mom"
              ✗ bare "boyfriend", "project" (too generic)
              ✗ "emotion", "anxiety", "mood" (meta, banned)

            Rules: 2-12 characters per tag, keep original casing, mixed script, emoji.
            For the same entity across entries (e.g. Abby), **stable canonical form** matters —
            prefer bare name once it's established; only carry the role modifier on first mention
            or when the relationship is the salient part of the entry.

            NEVER use feeling/evaluation words. Banned: emotion, feeling, mood, reflection, daily,
            journal, thought, anxiety, happy, sad, tired, vibe, general, life.

            If the entry is pure venting with no concrete subject, return an empty array.
            Return JSON only: {"themes": ["tag1","tag2"]}

            Diary: "\(diaryEscaped)"
            """
        }
        // 用 gpt-5.4-mini + reasoning=none；mini 支持 none，标签抽取不需要推理
        guard let raw = await chat(prompt: prompt, model: "gpt-5.4-mini",
                                   maxTokens: 256, forceJSON: true,
                                   reasoningEffort: "none")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["themes"] as? [String] else {
            return []
        }
        let cleaned = arr
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { !Self.bannedThemes.contains($0.lowercased()) }
        return Array(cleaned.prefix(4))
    }

    /// 后处理兜底：即使 prompt 已经明说不要，模型偶尔仍会回吐元描述词。
    /// 这里做一次硬过滤，阻止这些词进 Core Data。
    private static let bannedThemes: Set<String> = [
        // zh
        "情绪", "心情", "感受", "反思", "日常", "记录", "生活",
        "思考", "想法", "感想", "焦虑", "开心", "难过", "疲惫",
        "情感", "心得", "感悟",
        // en (lowercased 比较)
        "emotion", "emotions", "feeling", "feelings", "mood", "moods",
        "reflection", "daily", "journal", "journaling", "thought",
        "thoughts", "anxiety", "happy", "sad", "tired", "life", "general",
        "vibe", "vibes"
    ]

    // MARK: Embeddings
    private static let maxEmbeddingPayloadUTF16Units = 8_000

    private static func embeddingPayload(from text: String) -> String {
        guard text.utf16.count > maxEmbeddingPayloadUTF16Units else { return text }

        var end = text.startIndex
        var utf16Count = 0
        while end < text.endIndex {
            let next = text.index(after: end)
            let scalarCount = text[end].utf16.count
            if utf16Count + scalarCount > maxEmbeddingPayloadUTF16Units {
                break
            }
            utf16Count += scalarCount
            end = next
        }
        return String(text[..<end])
    }

    func embed(text: String) async -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let payload = Self.embeddingPayload(from: trimmed)

        struct RequestBody: Codable {
            let model: String
            let input: String
        }
        struct ResponseBody: Codable {
            struct Item: Codable { let embedding: [Float] }
            let data: [Item]
        }

        guard let url = URL(string: "\(AppSecrets.backendURL)/api/openai/embeddings") else {
            Log.error("[OpenAIService] Invalid embeddings URL", category: .ai)
            return nil
        }
        guard !appSharedSecret.isEmpty else {
            Log.error("[OpenAIService] Backend shared secret not configured", category: .ai)
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.applyBackendAuth(sharedSecret: appSharedSecret)
        let body = RequestBody(model: "text-embedding-3-small", input: payload)
        // (2026-05-15 megareview P2-2)同 `chat()`,显式 catch 让 encode 失败可诊断。
        do {
            request.httpBody = try jsonEncoder.encode(body)
        } catch {
            Log.error("[OpenAIService] embed httpBody encode 失败: \(error)", category: .ai)
            return nil
        }

        // **不用 [weak self]**：OpenAIService.shared 是进程级 singleton，self 永不释放。
        // Release `-O` 下 Swift ARC optimizer 在"singleton 方法 + escaping closure + `[weak self]`"
        // 组合上偶发 lifetime-shortening：编译器把 strong-ref 收紧到闭包创建前，闭包实际执行
        // 时 weak self 拿到 nil → guard 抛 NSError(code: -1) → 不在 retryable 列表 → catch 返 nil。
        // Debug `-Onone` 不做这种优化所以看不到。症状：Xcode 直装好 / TestFlight 全失败。
        // 换成默认 strong capture（闭包里的 `self.`），singleton 本来就会自己活着，无泄漏风险。
        do {
            return try await NetworkRetryHelper.performWithRetry {
                let (data, response) = try await self.session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    Log.error("[OpenAIService] Embed: non-HTTP response", category: .ai)
                    throw BackendErrorMapper.error(forStatus: -1)
                }
                guard (200...299).contains(http.statusCode) else {
                    // 只记 status + body 长度;body 内容可能夹带 embedding input(用户日记原文)或上游
                    // error payload,不进日志。需要原因的话在 backend 端按 req-id 反查。
                    Log.error("[OpenAIService] Embed request failed: status=\(http.statusCode) bodyLen=\(data.count)", category: .ai)
                    throw BackendErrorMapper.error(forStatus: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
                }
                let decoded = try self.jsonDecoder.decode(ResponseBody.self, from: data)
                return decoded.data.first?.embedding
            }
        } catch {
            Log.error("[OpenAIService] Embed error: \(error)", category: .ai)
            return nil
        }
    }
}
