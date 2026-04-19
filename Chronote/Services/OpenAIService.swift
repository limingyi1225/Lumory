import Foundation
import CoreData

@available(iOS 15.0, macOS 12.0, *)
final class OpenAIService: AIServiceProtocol {

    /// 进程内共享实例——后台代理模式下不再需要每次编辑都 new 一个带 apiKey 的对象。
    /// 调用方优先用 `.shared`，避免在 hot-path 上重复初始化。
    static let shared = OpenAIService(apiKey: "")

    private let apiKey: String
    private let baseURL = URL(string: "https://api.openai.com/v1/chat/completions")!
    private let backendURL = URL(string: "\(AppSecrets.backendURL)/api/openai/chat/completions")!
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    // Debounce delay for summarize requests
    private let debounceDelay: TimeInterval = 0.3 // 300ms debounce

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    // MARK: - Public
    func summarize(text: String) async -> String? {
        let requestKey = "summarize-\(text.hashValue)"
        return await debouncedRequest(key: requestKey, cancelledFallback: nil) {
            let prompt: String
            if text.containsChinese {
                prompt = "概括以下日记内容，抓住重点，不超过15个字，仅使用逗号和分号。\n# Steps\n1. 阅读并理解日记内容。\n2. 抓住日记的关键信息和主题。\n3. 使用简洁精准的语言进行概括。\n4. 确保概括不超过15个字。\n5. 仅使用逗号和分号作为标点符号。\n# Output Format\n- 一个简短的概括，不超过15个字。\n- 仅使用逗号和分号，最后一个字后面不要有标点符号\n日记：\n\n\(text)"
            } else {
                prompt = "Summarize the following diary entry, focusing on the key points, in no more than 10 words, using only commas and semicolons.\n# Steps\n1. Read and understand the diary entry.\n2. Identify the key information and theme.\n3. Summarize using concise and precise language.\n4. Ensure the summary does not exceed 10 words.\n5. Use only commas and semicolons as punctuation.\n# Output Format\n- A short summary, no more than 10 words.\n- Only commas and semicolons used.\nDiary:\n\n\(text)"
            }
            // 显式 maxTokens: 512——`chat` 的默认 128 对 gpt-5.4 "low" reasoning 太紧，
            // reasoning tokens 本身就会吃掉一半以上，content 经常被截 / 返回空串。
            return await self.chat(prompt: prompt, model: "gpt-5.4", maxTokens: 512, reasoningEffort: "low")
        }
    }

    func analyzeMood(text: String) async -> Double {
        // gpt-5.4-mini + effort=none。mini 家族支持 `none`（零推理开销），大模型 5.4 只支持 low+。
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

        Log.error("[analyzeMood] 无法解析情绪分数，原始响应: \(resultStr.prefix(200)) —— 回退中性 0.5", category: .ai)
        return 0.5
    }

    /// 从自由文本里找第一个看起来像 mood 分数的整数（1...100）。
    /// 遇到 4+ 位长数字（比如 `2024` 年份 / 请求 ID / token 计数）时**跳过这个整数剩余位**
    /// 而不是 `break` 退出整个扫描——否则 LLM 响应里夹一个"2024"就把真正的 mood 分数吃掉了。
    static func firstValidScore(in s: String) -> Int? {
        var current = ""
        var skipRestOfNumber = false
        for ch in s {
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
                    if let n = Int(current), (1...100).contains(n) { return n }
                    current.removeAll()
                }
            }
        }
        if let n = Int(current), (1...100).contains(n) { return n }
        return nil
    }

    func analyzeAndSummarize(text: String) async -> (summary: String?, mood: Double) {
        // 同时调用 summarize 和 analyzeMood，避免重复的情绪判断逻辑
        async let summaryResult = summarize(text: text)
        async let moodResult = analyzeMood(text: text)
        return (await summaryResult, await moodResult)
    }

    /// 根据多条日记生成情绪+内容分析报告，返回完整报告（同步）
    func generateReport(entries: [DiaryEntry]) async -> String? {
        Log.info("[OpenAIService] 开始生成情绪报告，日记条目数量: \(entries.count)", category: .ai)
        guard !entries.isEmpty else { 
            Log.error("[OpenAIService] 错误：没有日记条目", category: .ai)
            return nil 
        }
        
        let textBlock = entries.compactMap { entry in
            // 安全访问Core Data属性，避免CloudKit同步时的编码问题
            let entryDate = entry.date ?? Date()
            let entryMood = Int(entry.moodValue * 100)
            let entrySummary = entry.summary ?? ""
            let entryText = entry.text ?? ""
            
            return "日期: \(entryDate)\n心情分数: \(entryMood)\n摘要: \(entrySummary)\n正文: \(entryText)"
        }.joined(separator: "\n---\n")
        
        Log.info("[OpenAIService] 文本块长度: \(textBlock.count) 字符", category: .ai)

        let prompt = """
阅读提供的日记条目，并基于内容撰写一份连贯的分析报告。
# 指南
- **写作风格与语言**：如果日记是中文的，请用中文进行分析；如果是英文的，请用英文进行分析。通过使用"你 xxxx"而非"他们 xxx"等直接称呼，与读者建立直接联系。确保行文生动有趣，富有吸引力。
- **定性分析**：描述情感时避免使用数值或定量指标。
- **主题与模式**：识别反复出现的主题、生活方式模式或情感变化，以加深自我理解。
- **日期引用**：使用口语化的日期表达方式（如"四月初"），避免使用过于正式的数字格式（如2024-12-1）。
- **结构**：不包含标题、小标题、引言或结论。使用1-4段落，段落之间用空行分隔。
# 输出格式
- 1-6段落的报告（Mac版本总字数不超过800字，其他平台不超过400字）。
- 每个段落之间用空行（两行换行）分隔。
- 不得使用括号、破折号，引号，星号，加粗，斜体或其他类似标点符号。

Diary Entries:
\(textBlock)
"""
        // 使用 gpt-5.4 写情绪报告
        Log.info("[OpenAIService] 开始调用chat方法生成报告", category: .ai)
        let result = await chat(prompt: prompt,
                          model: "gpt-5.4",
                          maxTokens: 4096,
                          stream: false,
                          reasoningEffort: "low")
        Log.info("[OpenAIService] chat方法返回结果: \(result != nil ? "成功，长度 \(result!.count)" : "失败，返回nil")", category: .ai)
        return result
    }
    
    /// 根据安全数据结构生成情绪报告，避免CloudKit同步冲突
    func generateReportFromData(entries: [DiaryEntryData]) async -> String? {
        Log.info("[OpenAIService] 开始从安全数据生成情绪报告，条目数量: \(entries.count)", category: .ai)
        guard !entries.isEmpty else { 
            Log.error("[OpenAIService] 错误：没有安全数据条目", category: .ai)
            return nil 
        }
        
        let textBlock = entries.map { entry in
            "日期: \(entry.date)\n心情分数: \(Int(entry.moodValue * 100))\n摘要: \(entry.summary)\n正文: \(entry.text)"
        }.joined(separator: "\n---\n")
        
        Log.info("[OpenAIService] 安全数据文本块长度: \(textBlock.count) 字符", category: .ai)

        let prompt = """
阅读提供的日记条目，并基于内容撰写一份连贯的分析报告。
# 指南
- **写作风格与语言**：如果日记是中文的，请用中文进行分析；如果是英文的，请用英文进行分析。通过使用"你 xxxx"而非"他们 xxx"等直接称呼，与读者建立直接联系。确保行文生动有趣，富有吸引力。
- **定性分析**：描述情感时避免使用数值或定量指标。
- **主题与模式**：识别反复出现的主题、生活方式模式或情感变化，以加深自我理解。
- **日期引用**：使用口语化的日期表达方式（如"四月初"），避免使用过于正式的数字格式（如2024-12-1）。
- **结构**：不包含标题、小标题、引言或结论。使用1-4段落，段落之间用空行分隔。
# 输出格式
- 1-6段落的报告（不超过1000字）。
- 每个段落之间用空行（两行换行）分隔。
- 不得使用括号、破折号，引号，星号，加粗，斜体或其他类似标点符号。

Diary Entries:
\(textBlock)
"""
        // 使用 gpt-5.4 写情绪报告
        Log.info("[OpenAIService] 开始调用chat方法生成安全数据报告", category: .ai)
        let result = await chat(prompt: prompt,
                          model: "gpt-5.4",
                          maxTokens: 4096,
                          stream: false,
                          reasoningEffort: "low")
        Log.info("[OpenAIService] 安全数据chat方法返回结果: \(result != nil ? "成功，长度 \(result!.count)" : "失败，返回nil")", category: .ai)
        return result
    }
    
    /// 根据安全数据结构生成情绪报告（流式版本），避免CloudKit同步冲突
    /// `onChunk` 标 `@MainActor`：所有调用方都要更新 `@Published` / SwiftUI state，
    /// 如果闭包在后台线程触发 UI 更新，strict concurrency 会直接崩。
    func generateReportFromData(entries: [DiaryEntryData], onChunk: @escaping @MainActor (String) -> Void) async {
        Log.info("[OpenAIService] 开始从安全数据生成流式情绪报告，条目数量: \(entries.count)", category: .ai)
        guard !entries.isEmpty else { return }

        // **用户真正的语言**：从日记原文里测。之前用 `prompt.contains("中文")` 判定，但 prompt
        // 模板里本身就硬写了"如果日记是中文的…"这种中文字样 → `contains("中文")` 恒真，英文
        // 用户报错时也看到中文错误提示。改成聚合原文再测 CJK 字符占比。
        let isChinese = entries.contains { $0.text.containsChinese }

        let textBlock = entries.map { entry in
            "日期: \(entry.date)\n心情分数: \(Int(entry.moodValue * 100))\n摘要: \(entry.summary)\n正文: \(entry.text)"
        }.joined(separator: "\n---\n")
        
        Log.info("[OpenAIService] 安全数据流式文本块长度: \(textBlock.count) 字符", category: .ai)

        let prompt = """
阅读提供的日记条目，并基于内容撰写一份连贯的分析报告。
# 指南
- **写作风格与语言**：如果日记是中文的，请用中文进行分析；如果是英文的，请用英文进行分析。通过使用"你 xxxx"而非"他们 xxx"等直接称呼，与读者建立直接联系。确保行文生动有趣，富有吸引力。
- **定性分析**：描述情感时避免使用数值或定量指标。
- **主题与模式**：识别反复出现的主题、生活方式模式或情感变化，以加深自我理解。
- **日期引用**：使用口语化的日期表达方式（如"四月初"），避免使用过于正式的数字格式（如2024-12-1）。
- **结构**：不包含标题、小标题、引言或结论。使用1-4段落，段落之间用空行分隔。
# 输出格式
- 1-6段落的报告（Mac版本总字数不超过800字，其他平台不超过400字）。
- 每个段落之间用空行（两行换行）分隔。
- 不得使用括号、破折号，引号，星号，加粗，斜体或其他类似标点符号。

Diary Entries:
\(textBlock)
"""
        
        struct Message: Codable { let role: String; let content: String }
        struct RequestBody: Codable {
            let model: String
            let messages: [Message]
            let stream: Bool
            let reasoning_effort: String?

            enum CodingKeys: String, CodingKey { case model, messages, stream, reasoning_effort }
        }
        let requestBody = RequestBody(
            model: "gpt-5.4",
            messages: [Message(role: "user", content: prompt)],
            stream: true,
            reasoning_effort: "low"
        )
        
        let url = backendURL
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 后端鉴权用 shared secret；后端 middleware `requireAppSecret` 会 time-safe compare。
        request.setValue(AppSecrets.appSharedSecret, forHTTPHeaderField: "X-App-Secret")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try? jsonEncoder.encode(requestBody)
        
        Log.info("[OpenAIService] 发送流式请求，模型: \(requestBody.model), stream: \(requestBody.stream)", category: .ai)

        // **与 streamChat 相同的去重保护**：NarrativeReader 直接把每个 onChunk 累加进 buffer，
        // 一旦断流后 NetworkRetryHelper 整段回放，生成的故事会出现前缀重复。一次成功 yield 过 chunk 后
        // 不允许重试，直接吐截断标记收尾。
        var hasEmittedAnyChunk = false
        do {
            // singleton method + escaping closure 不用 [weak self]，防 Release -O ARC 假早释放
            try await NetworkRetryHelper.performWithRetry {
                Log.info("[OpenAIService] 开始安全数据流式请求...", category: .ai)
                let (bytes, response) = try await URLSession.sslTolerantSession.bytes(for: request)
                
                if let http = response as? HTTPURLResponse {
                    Log.info("[OpenAIService] 响应状态码: \(http.statusCode)", category: .ai)
                    // 不再打印整个 allHeaderFields —— 可能含 Set-Cookie / Authorization / X-Request-Id
                    // 等服务器内部字段。只留 Content-Type 用来判断 SSE。
                    if let contentType = http.value(forHTTPHeaderField: "Content-Type") {
                        Log.info("[OpenAIService] Content-Type: \(contentType)", category: .ai)
                        if !contentType.contains("text/event-stream") && !contentType.contains("text/plain") {
                            Log.warning("[OpenAIService] ⚠️ 警告：服务器没有返回流式响应格式！", category: .ai)
                        }
                    }
                }
                
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                    Log.error("[OpenAIService] 安全数据流式请求失败，状态码: \(statusCode)", category: .ai)
                    
                    let errorMessage: String
                    switch statusCode {
                    case 502:
                        errorMessage = "后端网关错误(502)，服务器可能临时不可用，请稍后再试。"
                    case 503:
                        errorMessage = "后端服务暂时不可用(503)，请稍后再试。"
                    case 504:
                        errorMessage = "后端网关超时(504)，请稍后再试。"
                    case 500...599:
                        errorMessage = "后端服务器错误(\(statusCode))，请稍后再试。"
                    default:
                        errorMessage = "后端代理错误: \(statusCode)"
                    }
                    
                    throw NSError(domain: "OpenAIService", code: statusCode, userInfo: [NSLocalizedDescriptionKey: errorMessage])
                }
                Log.info("[OpenAIService] 流式请求响应正常，开始处理字节流...", category: .ai)
                
                struct StreamChoice: Codable { struct Delta: Codable { let content: String? }; let delta: Delta }
                struct StreamResponse: Codable { let choices: [StreamChoice] }

                // 处理真正的流式响应
                var chunkCount = 0

                do {
                    for try await line in bytes.lines {
                        if line.isEmpty { continue }
                        if line.hasPrefix(":") { continue }
                        if line.hasPrefix("data:") {
                            let dataString = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                            if dataString == "[DONE]" {
                                Log.info("[OpenAIService] 安全数据流式响应完成，总共收到 \(chunkCount) 个内容块", category: .ai)
                                return
                            }
                            if let jsonData = dataString.data(using: .utf8) {
                                do {
                                    let streamResp = try self.jsonDecoder.decode(StreamResponse.self, from: jsonData)
                                    if let content = streamResp.choices.first?.delta.content, !content.isEmpty {
                                        chunkCount += 1
                                        hasEmittedAnyChunk = true
                                        // `onChunk` 需要在 MainActor 上跑：所有调用方都更新 @Published state
                                        await MainActor.run { onChunk(content) }
                                    }
                                } catch {
                                    Log.error("[OpenAIService] JSON解析失败: \(error)", category: .ai)
                                    // 原始 `dataString` 可能是部分 AI 生成文本（用户隐私），不落日志。
                                    Log.info("[OpenAIService] 问题数据长度: \(dataString.count) 字符", category: .ai)
                                }
                            }
                        }
                    }
                    Log.info("[OpenAIService] 字节流处理完成，总共收到 \(chunkCount) 个内容块", category: .ai)
                } catch {
                    // 中途断流：已发过 chunk 就不重试（避免叙事正文前缀重复）；吐截断标记后正常返回
                    if hasEmittedAnyChunk {
                        Log.error("[OpenAIService] 报告流式中断; emitting truncation marker: \(error)", category: .ai)
                        let truncMarker = isChinese
                            ? "\n\n⚠️ 报告未完整（网络中断），请重新生成。"
                            : "\n\n⚠️ Report incomplete (connection interrupted). Please regenerate."
                        await MainActor.run { onChunk(truncMarker) }
                        return
                    }
                    throw error
                }
            }
        } catch {
            Log.error("[OpenAIService] 安全数据流式请求错误: \(error)", category: .ai)
            let errorMessage = isChinese ?
                "生成报告时遇到错误：\(error.localizedDescription)" :
                "Error generating report: \(error.localizedDescription)"
            await MainActor.run { onChunk(errorMessage) }
        }
    }

    func generateReport(entries: [DiaryEntry], onChunk: @escaping @MainActor (String) -> Void) async {
        guard !entries.isEmpty else { return }
        // 同 generateReportFromData：从原文测语言，不从 prompt 模板测（模板恒含"中文"字样）
        let isChinese = entries.contains { ($0.text ?? "").containsChinese }
        let textBlock = entries.compactMap { entry in
            // 安全访问Core Data属性，避免CloudKit同步时的编码问题
            let entryDate = entry.date ?? Date()
            let entryMood = Int(entry.moodValue * 100)
            let entrySummary = entry.summary ?? ""
            let entryText = entry.text ?? ""
            
            return "日期: \(entryDate)\n心情分数: \(entryMood)\n摘要: \(entrySummary)\n正文: \(entryText)"
        }.joined(separator: "\n---\n")

        let prompt = """
阅读提供的日记条目，并基于内容撰写一份连贯的分析报告。
# 指南
- **写作风格与语言**：如果日记是中文的，请用中文进行分析；如果是英文的，请用英文进行分析。通过使用"你 xxxx"而非"他们 xxx"等直接称呼，与读者建立直接联系。确保行文生动有趣，富有吸引力。
- **定性分析**：描述情感时避免使用数值或定量指标。
- **主题与模式**：识别反复出现的主题、生活方式模式或情感变化，以加深自我理解。
- **日期引用**：使用口语化的日期表达方式（如"四月初"），避免使用过于正式的数字格式（如2024-12-1）。
- **结构**：不包含标题、小标题、引言或结论。使用1-4段落，段落之间用空行分隔。
# 输出格式
- 1-6段落的报告（Mac版本总字数不超过800字，其他平台不超过400字）。
- 每个段落之间用空行（两行换行）分隔。
- 不得使用括号、破折号，引号，星号，加粗，斜体或其他类似标点符号。

Diary Entries:
\(textBlock)
"""
        struct Message: Codable { let role: String; let content: String }
        struct RequestBody: Codable {
            let model: String
            let messages: [Message]
            let stream: Bool
            let reasoning_effort: String?

            enum CodingKeys: String, CodingKey { case model, messages, stream, reasoning_effort }
        }
        let requestBody = RequestBody(
            model: "gpt-5.4",
            messages: [Message(role: "user", content: prompt)],
            stream: true,
            reasoning_effort: "low"
        )
        // 改为走本地后端代理，不在客户端暴露 Key
        let url = backendURL
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 后端鉴权用 shared secret；后端 middleware `requireAppSecret` 会 time-safe compare。
        request.setValue(AppSecrets.appSharedSecret, forHTTPHeaderField: "X-App-Secret")
        request.httpBody = try? jsonEncoder.encode(requestBody)

        do {
            // 不用 [weak self]：见 embed() 上方注释（Release `-O` ARC lifetime-shortening 咬）
            try await NetworkRetryHelper.performWithRetry {
                let (bytes, response) = try await URLSession.sslTolerantSession.bytes(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                    Log.error("[OpenAIService] Streaming request failed:", category: .ai)
                    Log.info("  URL path: \(request.url?.path ?? "unknown")", category: .ai)
                    Log.info("  Status Code: \(statusCode)", category: .ai)
                    // 不再 dump allHeaderFields —— 可能含 Set-Cookie / X-Request-Id 等内部信息。
                    
                    let errorMessage: String
                    switch statusCode {
                    case 502:
                        errorMessage = "后端网关错误(502)，服务器可能临时不可用，请稍后再试。"
                    case 503:
                        errorMessage = "后端服务暂时不可用(503)，请稍后再试。"
                    case 504:
                        errorMessage = "后端网关超时(504)，请稍后再试。"
                    case 500...599:
                        errorMessage = "后端服务器错误(\(statusCode))，请稍后再试。"
                    default:
                        errorMessage = "后端代理错误: \(statusCode)"
                    }
                    
                    throw NSError(domain: "OpenAIService", code: statusCode, userInfo: [NSLocalizedDescriptionKey: errorMessage])
                }
                struct StreamChoice: Codable { struct Delta: Codable { let content: String? }; let delta: Delta }
                struct StreamResponse: Codable { let choices: [StreamChoice] }

                // 处理真正的流式响应
                for try await line in bytes.lines {
                    if line.isEmpty || line.hasPrefix(":") {
                        continue
                    }
                    
                    if line.hasPrefix("data:") {
                        let dataString = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        if dataString == "[DONE]" { return }
                        if let jsonData = dataString.data(using: .utf8), let streamResp = try? self.jsonDecoder.decode(StreamResponse.self, from: jsonData), let content = streamResp.choices.first?.delta.content {
                            await MainActor.run { onChunk(content) }
                        }
                    }
                }
            }
        } catch {
            Log.error("[OpenAIService] Streaming error after retries: \(error)", category: .ai)
            // Send error message to user in their language — 不泄露内部 IP 给用户 UI。
            let errorMessage: String
            if error.localizedDescription.contains("Could not connect to the server") ||
               error.localizedDescription.contains("The Internet connection appears to be offline") ||
               error.localizedDescription.contains("The request timed out") {
                errorMessage = isChinese ?
                    "无法连接到 AI 服务，请检查网络连接或稍后再试。" :
                    "Cannot connect to AI service. Please check network or try again later."
            } else {
                errorMessage = isChinese ?
                    "生成报告时遇到错误：\(error.localizedDescription)" :
                    "Error generating report: \(error.localizedDescription)"
            }
            await MainActor.run { onChunk(errorMessage) }
        }
    }

    // MARK: - Core
    private func chat(prompt: String,
                      model: String? = nil,
                      maxTokens: Int = 128,
                      forceJSON: Bool = false,
                      stream: Bool = false,
                      reasoningEffort: String? = nil) async -> String? {
        struct Message: Codable { let role: String; let content: String }
        struct RequestBody: Codable {
            let model: String
            let messages: [Message]
            let response_format: ResponseFormat?
            let stream: Bool?
            let reasoning_effort: String?
            // gpt-5 系列用 max_completion_tokens，不是 max_tokens。Swift 侧用 camelCase 以过 lint，
            // 通过 CodingKeys 映射到 OpenAI 期望的 snake_case。
            let maxCompletionTokens: Int?

            struct ResponseFormat: Codable { let type: String }
            enum CodingKeys: String, CodingKey {
                case model, messages, response_format, stream, reasoning_effort
                case maxCompletionTokens = "max_completion_tokens"
            }
        }
        struct ResponseBody: Codable {
            struct Choice: Codable { let message: Message }
            let choices: [Choice]
        }

        let requestBody = RequestBody(
            model: model ?? "gpt-5.4",
            messages: [Message(role: "user", content: prompt)],
            response_format: forceJSON ? RequestBody.ResponseFormat(type: "json_object") : nil,
            stream: stream ? true : nil,
            reasoning_effort: reasoningEffort,
            maxCompletionTokens: maxTokens > 0 ? maxTokens : nil
        )

        // 改为走本地后端代理，不在客户端暴露 Key
        let url = backendURL
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 后端鉴权用 shared secret；后端 middleware `requireAppSecret` 会 time-safe compare。
        request.setValue(AppSecrets.appSharedSecret, forHTTPHeaderField: "X-App-Secret")
        request.httpBody = try? jsonEncoder.encode(requestBody)

        // 新增：支持流式响应
        if stream {
            do {
                // 不用 [weak self]：见 embed() 上方注释
                return try await NetworkRetryHelper.performWithRetry {
                    let (bytes, response) = try await URLSession.sslTolerantSession.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                        Log.info("[OpenAIService] Bad response. Status code: \(statusCode)", category: .ai)
                        throw NSError(domain: "OpenAIService", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "Bad response code"])
                    }
                    struct StreamResponse: Codable {
                        struct Choice: Codable {
                            struct Delta: Codable { let content: String? }
                            let delta: Delta
                        }
                        let choices: [Choice]
                    }
                    var result = ""
                    
                    // 处理真正的流式响应
                    for try await line in bytes.lines {
                        if line.isEmpty || line.hasPrefix(":") {
                            continue
                        }
                        
                        if line.hasPrefix("data:") {
                            let dataString = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                            if dataString == "[DONE]" { break }
                            if let jsonData = dataString.data(using: .utf8),
                               let streamResp = try? self.jsonDecoder.decode(StreamResponse.self, from: jsonData),
                               let content = streamResp.choices.first?.delta.content {
                                result.append(content)
                            }
                        }
                    }
                    return result  // 保留换行符，不要trim
                }
            } catch {
                Log.error("[OpenAIService] Request error after retries: \(error)", category: .ai)
                if error.localizedDescription.contains("Could not connect to the server") ||
                   error.localizedDescription.contains("The Internet connection appears to be offline") ||
                   error.localizedDescription.contains("The request timed out") {
                    // 不再把后端具体地址写日志（避免给终端用户或 log collect 留 IP 线索）
                    Log.info("[OpenAIService] Cannot connect to backend proxy", category: .ai)
                }
                return nil
            }
        } else {
            do {
                Log.info("[OpenAIService] 执行非流式请求", category: .ai)
                // 不用 [weak self]：见 embed() 上方注释
                return try await NetworkRetryHelper.performWithRetry {
                    Log.info("[OpenAIService] 发送网络请求...", category: .ai)
                    let (data, response) = try await URLSession.sslTolerantSession.data(for: request)
                    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                        if let httpResponse = response as? HTTPURLResponse {
                            let statusCode = httpResponse.statusCode
                            let responseBody = String(data: data, encoding: .utf8) ?? "<no body>"
                            _ = httpResponse // 避免 warning
                            // 诊断用最小信息：只 URL path + status + body 前 200 字符（截断避免泄日记/错误内容）
                            Log.error("[OpenAIService] Backend request failed — path=\(request.url?.path ?? "?") status=\(statusCode) bodyPrefix=\(responseBody.prefix(200))", category: .ai)
                            
                            // Handle specific error codes with user-friendly messages
                            let errorMessage: String
                            switch statusCode {
                            case 401:
                                errorMessage = "后端代理认证失败，请联系开发者。"
                            case 404:
                                errorMessage = "后端代理端点未找到(\(AppSecrets.backendURL))，请联系开发者。"
                            case 429:
                                errorMessage = "API调用频率限制，请稍后再试。"
                            case 502:
                                errorMessage = "后端网关错误(502)，服务器可能临时不可用，请稍后再试。"
                            case 503:
                                errorMessage = "后端服务暂时不可用(503)，请稍后再试。"
                            case 504:
                                errorMessage = "后端网关超时(504)，请稍后再试。"
                            case 500...599:
                                errorMessage = "后端服务器错误(\(statusCode))，请稍后再试。"
                            default:
                                errorMessage = "后端代理错误: \(statusCode) - \(responseBody.prefix(100))"
                            }
                            
                            throw NSError(domain: "OpenAIService", code: statusCode, userInfo: [NSLocalizedDescriptionKey: errorMessage])
                        } else {
                            Log.info("[OpenAIService] Bad response. Not an HTTPURLResponse. Response: \(response)", category: .ai)
                            throw NSError(domain: "OpenAIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "从后端代理接收到无效响应"])
                        }
                    }
                    let decoded = try self.jsonDecoder.decode(ResponseBody.self, from: data)
                    guard let content = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) else {
                        throw NSError(domain: "OpenAIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No content in response"])
                    }
                    return content
                }
            } catch {
                Log.error("[OpenAIService] Request error after retries: \(error)", category: .ai)
                return nil
            }
        }
    }
    
    // MARK: - Debouncing
    /// 在启动 `request` 前先 sleep 一个短 delay，让极短时间内连发的请求合并。
    /// 原实现只是延迟，不去重——同 key 的两个 task 都会 sleep 完再各自 fire，
    /// 等于两次独立网络请求。现在用 actor 维护 `[key: Task]`，同 key 后来者 cancel 前一个。
    private actor DebounceRegistry {
        private var tasks: [String: Task<Void, Never>] = [:]

        /// 注册本次 Task 并 cancel 之前同 key 的 Task（返回一个新 id 用于 self-cleanup 时匹配）
        func register(key: String, task: Task<Void, Never>) -> UUID {
            tasks[key]?.cancel()
            let id = UUID()
            tasks[key] = task
            tokens[key] = id
            return id
        }

        /// 只有我们自己的 token 还是当前值时才清空（防止覆盖更晚者）
        func clearIfCurrent(key: String, token: UUID) {
            if tokens[key] == token {
                tasks[key] = nil
                tokens[key] = nil
            }
        }

        private var tokens: [String: UUID] = [:]
    }

    private static let debounceRegistry = DebounceRegistry()

    private func debouncedRequest<T>(
        key: String,
        cancelledFallback: T,
        request: @escaping () async -> T
    ) async -> T {
        let delaySeconds = self.debounceDelay
        // 用 Box 把泛型返回值在 Task 内部存起来，外层 await 时再取。
        // 不把 Task 自己泛型化是因为 actor 里存异构 Task<T, Never> 需要 erase，
        // 而我们只关心"是否最后一个"——控制流不需要返回值透传。
        let resultBox = ResultBox<T>()

        let task = Task<Void, Never> {
            do {
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            } catch {
                resultBox.set(cancelledFallback)
                return
            }
            if Task.isCancelled {
                resultBox.set(cancelledFallback)
                return
            }
            let value = await request()
            resultBox.set(value)
        }

        let token = await Self.debounceRegistry.register(key: key, task: task)
        await task.value
        await Self.debounceRegistry.clearIfCurrent(key: key, token: token)
        return resultBox.get() ?? cancelledFallback
    }
}

/// 小的引用容器，用来把 debounce Task 内部算出的泛型值存到外层作用域。
/// 锁是不可避免的——Task 内外是两个调度域；但只有两次 set+get，单锁够用。
private final class ResultBox<T> {
    private var value: T?
    private let lock = NSLock()
    func set(_ newValue: T) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }
    func get() -> T? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

// MARK: - CloudKit-isolated report generation
//
// 这两个入口先在隔离的只读 Core Data 栈里把 `[DiaryEntry]` 提取成纯值类型
// `[DiaryEntryData]`，再调 `generateReportFromData` 生成报告。目的是避免
// 主 viewContext 在报告生成过程中被 CloudKit 同步触发的 fault/merge 打断。
@available(iOS 15.0, macOS 12.0, *)
extension OpenAIService {

    func generateReport(from entries: [DiaryEntry], dateRange: ClosedRange<Date>) async -> String? {
        let safe = await Self.extractDataSafely(from: entries, dateRange: dateRange)
        guard !safe.isEmpty else { return nil }
        // `[weak self]` + 空返 guard：Task.detached 原先强持 self 直到 gpt-5.4 流返完，
        // 视图侧 owning 了这个 service 的 VM 被释放后 service 仍被挂住。
        return await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return nil }
            return await self.generateReportFromData(entries: safe)
        }.value
    }

    func generateReport(
        from entries: [DiaryEntry],
        dateRange: ClosedRange<Date>,
        onChunk: @escaping @MainActor (String) -> Void
    ) async {
        let safe = await Self.extractDataSafely(from: entries, dateRange: dateRange)
        guard !safe.isEmpty else {
            await MainActor.run { onChunk("没有找到有效的日记数据用于分析。") }
            return
        }
        await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            await self.generateReportFromData(entries: safe, onChunk: onChunk)
        }.value
    }

    private static func extractDataSafely(
        from entries: [DiaryEntry],
        dateRange: ClosedRange<Date>
    ) async -> [DiaryEntryData] {
        // **不再** 开一个独立的 NSPersistentContainer 指向同一个 SQLite 文件。
        // 两个容器共打 WAL 模式下的同一文件会和 NSPersistentCloudKitContainer 的镜像
        // 抢 `-wal` / `-shm` 锁，少数情况下触发 torn read / 加载失败（静默返回 [] → 报告为空）。
        // 改走主容器的 background context，CoreData 负责把读路径序列化到自己的 WAL 管理里。
        let objectIDs = entries.map { $0.objectID }
        let bg = PersistenceController.shared.container.newBackgroundContext()
        return await withCheckedContinuation { continuation in
            bg.perform {
                var safeData: [DiaryEntryData] = []
                for objectID in objectIDs {
                    guard let entry = try? bg.existingObject(with: objectID) as? DiaryEntry else { continue }
                    let entryDate = entry.date ?? Date()
                    guard dateRange.contains(entryDate) else { continue }
                    safeData.append(DiaryEntryData.from(fetchedEntry: entry))
                }
                continuation.resume(returning: safeData)
            }
        }
    }
}

extension String {
    var containsChinese: Bool {
        return range(of: "[\u{4E00}-\u{9FFF}]", options: .regularExpression) != nil
    }
}

// MARK: - Phase 0: AI × 统计融合地基（主题 / 向量 / 对话 / 统一流式）
@available(iOS 15.0, macOS 12.0, *)
extension OpenAIService {

    // MARK: Themes
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

    // MARK: Suggestions (AI-authored presets + placeholders)

    /// 一次 gpt-5.4 调用生成 AskPast 预设 + 首页占位语池，JSON 返回。
    /// 失败 / 畸形 / 字段不全 → 返回 nil，让 PromptSuggestionEngine 保留旧 cache 或上游 fallback。
    func composeSuggestions(context: SuggestionContext) async -> SuggestionBundle? {
        let prompt = Self.buildSuggestionPrompt(context: context)
        guard let raw = await chat(
            prompt: prompt,
            model: "gpt-5.4",
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
            Log.error("[composeSuggestions] JSON parse 失败，原始片段: \(rawJSON.prefix(200))", category: .ai)
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

    private static func buildSuggestionPrompt(context: SuggestionContext) -> String {
        let zh = context.language == "zh"

        // 主题清单
        let themesBlock: String = {
            guard !context.topThemes.isEmpty else { return zh ? "暂无" : "(none yet)" }
            return context.topThemes.prefix(5).enumerated().map { (i, t) in
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
            return context.recentEntries.enumerated().map { (i, e) in
                let moodInt = Int(e.moodValue * 100)
                let snippet = e.summary.isEmpty ? e.text : e.summary + "｜" + e.text
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
            你要为一个日记 App 写一批提问和输入框占位语，用户最讨厌的就是"关于 X 最近怎么样？"
            这种模板化填空。请像一个真正读过他日记的朋友，写具体、带细节、能扎到心的句子。

            ## 绝对规则
            1. 每一条都必须**引用真实细节**——具体人名、事件、场景、金句片段——从我下面给的
               数据里挑出来用。不能写成任何模板套公式。
            2. 不要心灵鸡汤，不要 coach 话术，不要审判。语气像一个熟识的朋友。
            3. 视角变化：问现在（"今天还在想 TA 吗？"）、问对比（"A 让你放松、B 让你紧张——
               察觉了吗？"）、问反思（"你最开心那篇正好和 Abby 在一起——你注意到了吗？"）。
            4. **禁止引用具体日期或相对时间锚点**。不要出现"1 月 10 号"、"三天前"、
               "上周"、"两个月前"、"X 天前"这类表达——用户不会按日期记事，看到只会困惑。
               用**事件/人物/主题**锚定，不用时间。
            5. **不要用括号『』包起名字**——自然融入句子。

            ## 输出格式（JSON，字段严格）
            {
              "askPastPresets": ["问题1?", "问题2?", "问题3?", "问题4?"],
              "homePlaceholders": ["短句1", "短句2", "短句3", "短句4", "短句5"]
            }

            - askPastPresets：4 条，每条 15-40 字，以问号结尾。这是在 Ask Past 界面给用户
              "试试这些问题"用的——要让用户一眼就想点进去。
            - homePlaceholders：5 条，每条 8-20 字，可以不是问号。这是首页输入框里的占位
              文字——要让用户看了就想开始写。可以是陈述句、引子、观察。

            ## 用户数据
            【最常出现的人/事/地】
            \(themesBlock)

            【最近 30 天情绪均值】\(avgMoodInt)/100
            \(extremesBlock)

            【连续写了 \(context.currentStreak) 天，一共 \(context.totalEntries) 篇】

            【最近 3 篇原文片段】
            \(recentBlock)
            """
        } else {
            return """
            You're writing prompts for a journaling app. The user hates mechanical template
            substitutions like "How's X going?". Write like a close friend who's actually read
            their diary — specific, concrete, emotionally precise.

            ## Absolute rules
            1. Every line must **reference real details** — names, events, scenes, quoted
               phrases — drawn from the data below. No formulaic fill-in-the-blank.
            2. No self-help clichés, no coaching language, no judgment. Voice = a close friend.
            3. Vary perspective: present ("Still thinking about her today?"), contrast
               ("A relaxes you, B tenses you — have you noticed?"), reflection ("Your happiest
               entry happened to be with Abby — did you catch that?").
            4. **Never reference specific dates or relative time anchors.** Don't say "on Jan 10",
               "three days ago", "last week", "two months back", "X days ago", etc. People don't
               remember their lives by date — it just confuses the reader. Anchor on
               events/people/themes instead of time.
            5. Do **not** wrap names in quotes or brackets — integrate them naturally.

            ## Output format (strict JSON)
            {
              "askPastPresets": ["question 1?", "question 2?", "question 3?", "question 4?"],
              "homePlaceholders": ["line 1", "line 2", "line 3", "line 4", "line 5"]
            }

            - askPastPresets: 4 entries, 10-25 words each, ending with a question mark.
              Shown on Ask Past screen — should make the user want to tap.
            - homePlaceholders: 5 entries, 4-14 words each, not necessarily questions.
              Shown inside the home text editor as placeholder — should entice the user to write.

            ## User data
            [Most recurring people/events/places]
            \(themesBlock)

            [Past 30 days mood average] \(avgMoodInt)/100
            \(extremesBlock)

            [Streak: \(context.currentStreak) days, total \(context.totalEntries) entries]

            [Last 3 entries]
            \(recentBlock)
            """
        }
    }

    // MARK: Embeddings
    func embed(text: String) async -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

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
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppSecrets.appSharedSecret, forHTTPHeaderField: "X-App-Secret")
        let body = RequestBody(model: "text-embedding-3-small", input: trimmed)
        request.httpBody = try? jsonEncoder.encode(body)

        // **不用 [weak self]**：OpenAIService.shared 是进程级 singleton，self 永不释放。
        // Release `-O` 下 Swift ARC optimizer 在"singleton 方法 + escaping closure + `[weak self]`"
        // 组合上偶发 lifetime-shortening：编译器把 strong-ref 收紧到闭包创建前，闭包实际执行
        // 时 weak self 拿到 nil → guard 抛 NSError(code: -1) → 不在 retryable 列表 → catch 返 nil。
        // Debug `-Onone` 不做这种优化所以看不到。症状：Xcode 直装好 / TestFlight 全失败。
        // 换成默认 strong capture（闭包里的 `self.`），singleton 本来就会自己活着，无泄漏风险。
        do {
            return try await NetworkRetryHelper.performWithRetry {
                let (data, response) = try await URLSession.sslTolerantSession.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    Log.error("[OpenAIService] Embed: non-HTTP response", category: .ai)
                    throw NSError(domain: "OpenAIService", code: -1)
                }
                guard (200...299).contains(http.statusCode) else {
                    // 把 body 前 200 字节也带上——backend 返 {error: "..."} 时能直接看原因
                    let bodySnippet = String(data: data.prefix(200), encoding: .utf8) ?? "<non-utf8>"
                    Log.error("[OpenAIService] Embed request failed: http=\(http.statusCode) body=\(bodySnippet)", category: .ai)
                    throw NSError(domain: "OpenAIService", code: http.statusCode)
                }
                let decoded = try self.jsonDecoder.decode(ResponseBody.self, from: data)
                return decoded.data.first?.embedding
            }
        } catch {
            Log.error("[OpenAIService] Embed error: \(error)", category: .ai)
            return nil
        }
    }

    // MARK: Ask (RAG)
    func ask(question: String, context entries: [DiaryEntryData]) -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task {
                let isZh = question.containsChinese
                let contextBlock = entries.prefix(8).map { entry in
                    "[id:\(entry.id.uuidString.prefix(6)) date:\(Self.shortDate(entry.date)) mood:\(Int(entry.moodValue*100))]\n\(entry.text)"
                }.joined(separator: "\n---\n")

                let prompt: String
                if isZh {
                    prompt = """
                    你是一位温和、擅长倾听的私人回顾助手。下面是用户的几条相关日记片段（[]里是元数据），
                    请基于这些日记真诚、具体地回答用户的问题。引用具体日期或情绪分数时请自然融入表达，
                    不要暴露 id 编号，也不要编造未出现的内容。如果证据不足，请直说并建议用户多写一些。

                    相关日记：
                    \(contextBlock)

                    用户问题：\(question)
                    """
                } else {
                    prompt = """
                    You are a gentle, attentive personal-reflection assistant. Below are the user's most
                    relevant diary excerpts ([]-bracketed is metadata). Answer their question honestly
                    and specifically, weaving in real dates and mood scores naturally. Do not expose
                    raw ids. Do not invent content. If evidence is thin, say so and suggest journaling more.

                    Relevant entries:
                    \(contextBlock)

                    Question: \(question)
                    """
                }

                await self.streamChat(prompt: prompt, model: "gpt-5.4", reasoningEffort: "low") { chunk in
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Unified streaming report
    func streamReport(entries: [DiaryEntryData]) -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task {
                // `onChunk` 签名是 `@MainActor (String) -> Void`。`continuation.yield` 本身线程安全，
                // 标一下 @MainActor 让签名对得上即可——真正的消费方（InsightsView 等）在 MainActor 侧读。
                await self.generateReportFromData(entries: entries) { @MainActor chunk in
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Helpers
    private static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// 低层流式 chat：把 SSE 解析成 async 回调。用于 ask / 任意长文流式生成。
    /// `maxTokens` 必传——之前 RequestBody 没有 `max_completion_tokens` 字段，
    /// ask / streamReport 每次调用 token 完全不封顶，单次能烧上万 token + 转圈几分钟。
    fileprivate func streamChat(prompt: String,
                                model: String,
                                reasoningEffort: String?,
                                maxTokens: Int = 4096,
                                onChunk: @escaping (String) -> Void) async {
        struct Message: Codable { let role: String; let content: String }
        struct RequestBody: Codable {
            let model: String
            let messages: [Message]
            let stream: Bool
            let reasoning_effort: String?
            let maxCompletionTokens: Int?

            enum CodingKeys: String, CodingKey {
                case model, messages, stream, reasoning_effort
                case maxCompletionTokens = "max_completion_tokens"
            }
        }
        let body = RequestBody(
            model: model,
            messages: [Message(role: "user", content: prompt)],
            stream: true,
            reasoning_effort: reasoningEffort,
            maxCompletionTokens: maxTokens
        )

        guard let url = URL(string: "\(AppSecrets.backendURL)/api/openai/chat/completions") else {
            Log.error("[OpenAIService] Invalid chat-completions URL", category: .ai)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(AppSecrets.appSharedSecret, forHTTPHeaderField: "X-App-Secret")
        request.httpBody = try? jsonEncoder.encode(body)

        struct StreamChoice: Codable { struct Delta: Codable { let content: String? }; let delta: Delta }
        struct StreamResponse: Codable { let choices: [StreamChoice] }

        // 重试保护：一旦已经向 caller yield 过任意 chunk，就不允许再重试——
        // 否则 NetworkRetryHelper 会把整个请求从头回放，caller 把新 chunk 累加进
        // 同一条 message，用户看到 "你好你好我今天…" 这种前缀重复。
        var hasEmittedAnyChunk = false
        do {
            // 不用 [weak self]：见 embed() 上方注释
            try await NetworkRetryHelper.performWithRetry {
                let (bytes, response) = try await URLSession.sslTolerantSession.bytes(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw NSError(domain: "OpenAIService", code: (response as? HTTPURLResponse)?.statusCode ?? -1)
                }
                do {
                    for try await line in bytes.lines {
                        if Task.isCancelled { return }
                        if line.isEmpty || line.hasPrefix(":") { continue }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { return }
                        if let data = payload.data(using: .utf8),
                           let decoded = try? self.jsonDecoder.decode(StreamResponse.self, from: data),
                           let content = decoded.choices.first?.delta.content, !content.isEmpty {
                            hasEmittedAnyChunk = true
                            onChunk(content)
                        }
                    }
                } catch {
                    // 中途断流：已 yield 过 chunk 就**吐一个可见截断标记**后正常返回，
                    // 不能再重试（重试会让 caller 前缀重复）。caller 必须向用户明确显示"回答不完整"，
                    // 否则他会以为那就是完整答案。标记用中/英两种，跟错误提示选择同一语言判定。
                    if hasEmittedAnyChunk {
                        Log.error("[OpenAIService] streamChat interrupted mid-stream; emitting truncation marker: \(error)", category: .ai)
                        let truncMarker = (prompt.containsChinese)
                            ? "\n\n⚠️ 回答未完整（网络中断），请重试。"
                            : "\n\n⚠️ Response incomplete (connection interrupted). Please retry."
                        onChunk(truncMarker)
                        return
                    }
                    throw error
                }
            }
        } catch {
            Log.error("[OpenAIService] streamChat error: \(error)", category: .ai)
            // 以前直接把错误文案当 content yield，UI 把它当正文末尾渲染（"今天还好 + Error answering: ..."）
            // 看起来像答案的一部分。统一带 `⚠️` 前缀 + 换行，让 UI（MarkdownText）和用户一眼识别为错误。
            let msg = prompt.containsChinese
                ? "\n\n⚠️ 回答时出错：\(error.localizedDescription)"
                : "\n\n⚠️ Error answering: \(error.localizedDescription)"
            onChunk(msg)
        }
    }
}

