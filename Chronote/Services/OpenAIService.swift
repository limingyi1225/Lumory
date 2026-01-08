import Foundation

@available(iOS 15.0, macOS 12.0, *)
final class OpenAIService: AIServiceProtocol {

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
    func transcribeAudio(fileURL: URL, localeIdentifier: String) async -> String? {
        // 转录已移至 AppleRecognitionService，此处不再实现
        return nil
    }

    func summarize(text: String) async -> String? {
        let requestKey = "summarize-\(text.hashValue)"
        return await debouncedRequest(key: requestKey) {
            let prompt: String
            if text.containsChinese {
                prompt = "概括以下日记内容，抓住重点，不超过15个字，仅使用逗号和分号。\n# Steps\n1. 阅读并理解日记内容。\n2. 抓住日记的关键信息和主题。\n3. 使用简洁精准的语言进行概括。\n4. 确保概括不超过15个字。\n5. 仅使用逗号和分号作为标点符号。\n# Output Format\n- 一个简短的概括，不超过15个字。\n- 仅使用逗号和分号，最后一个字后面不要有标点符号\n日记：\n\n\(text)"
            } else {
                prompt = "Summarize the following diary entry, focusing on the key points, in no more than 10 words, using only commas and semicolons.\n# Steps\n1. Read and understand the diary entry.\n2. Identify the key information and theme.\n3. Summarize using concise and precise language.\n4. Ensure the summary does not exceed 10 words.\n5. Use only commas and semicolons as punctuation.\n# Output Format\n- A short summary, no more than 10 words.\n- Only commas and semicolons used.\nDiary:\n\n\(text)"
            }
            return await self.chat(prompt: prompt, model: "gpt-5.2", reasoningEffort: "none")
        }
    }

    func analyzeMood(text: String) async -> Double {
        // 使用 gpt-5-nano 快速判断情绪，minimal reasoning
        let diaryEscaped = text.replacingOccurrences(of: "\"", with: "\\\"")
        let prompt = """
            Rate the mood of this diary entry from 1 (very negative) to 100 (very positive).
            Use extreme values when appropriate: 1-20 for very negative, 80-100 for very positive.
            Reply with JSON: {"mood_score": <number>}

            Diary: "\(diaryEscaped)"
            """

        if let resultStr = await self.chat(prompt: prompt, model: "gpt-5-nano", maxTokens: 16, forceJSON: true, reasoningEffort: "minimal")?
                .trimmingCharacters(in: .whitespacesAndNewlines) {
            // 解析 JSON 或字符串中的 mood_score
            if let data = resultStr.data(using: .utf8) {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let score = json["mood_score"] as? Int, (1...100).contains(score) {
                        return Double(score) / 100.0
                    }
                    if let score = json["mood_score"] as? Double, (1...100).contains(Int(score)) {
                        return score / 100.0
                    }
                }
            }
            // 回退：提取文本中的数字
            if let number = Int(resultStr.filter({ $0.isNumber })), (1...100).contains(number) {
                return Double(number) / 100.0
            }
        }
        // 默认为中立
        return 0.5
    }

    func analyzeAndSummarize(text: String) async -> (summary: String?, mood: Double) {
        // 同时调用 summarize 和 analyzeMood，避免重复的情绪判断逻辑
        async let summaryResult = summarize(text: text)
        async let moodResult = analyzeMood(text: text)
        return (await summaryResult, await moodResult)
    }

    /// 根据多条日记生成情绪+内容分析报告，返回完整报告（同步）
    func generateReport(entries: [DiaryEntry]) async -> String? {
        print("[OpenAIService] 开始生成情绪报告，日记条目数量: \(entries.count)")
        guard !entries.isEmpty else { 
            print("[OpenAIService] 错误：没有日记条目")
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
        
        print("[OpenAIService] 文本块长度: \(textBlock.count) 字符")

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
        // 使用 gpt-5.2 写情绪报告
        print("[OpenAIService] 开始调用chat方法生成报告")
        let result = await chat(prompt: prompt,
                          model: "gpt-5.2",
                          maxTokens: 4096,
                          stream: false,
                          reasoningEffort: "low")
        print("[OpenAIService] chat方法返回结果: \(result != nil ? "成功，长度 \(result!.count)" : "失败，返回nil")")
        return result
    }
    
    /// 根据安全数据结构生成情绪报告，避免CloudKit同步冲突
    func generateReportFromData(entries: [DiaryEntryData]) async -> String? {
        print("[OpenAIService] 开始从安全数据生成情绪报告，条目数量: \(entries.count)")
        guard !entries.isEmpty else { 
            print("[OpenAIService] 错误：没有安全数据条目")
            return nil 
        }
        
        let textBlock = entries.map { entry in
            "日期: \(entry.date)\n心情分数: \(Int(entry.moodValue * 100))\n摘要: \(entry.summary)\n正文: \(entry.text)"
        }.joined(separator: "\n---\n")
        
        print("[OpenAIService] 安全数据文本块长度: \(textBlock.count) 字符")

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
        // 使用 gpt-5.2 写情绪报告
        print("[OpenAIService] 开始调用chat方法生成安全数据报告")
        let result = await chat(prompt: prompt,
                          model: "gpt-5.2",
                          maxTokens: 4096,
                          stream: false,
                          reasoningEffort: "low")
        print("[OpenAIService] 安全数据chat方法返回结果: \(result != nil ? "成功，长度 \(result!.count)" : "失败，返回nil")")
        return result
    }
    
    /// 根据安全数据结构生成情绪报告（流式版本），避免CloudKit同步冲突
    func generateReportFromData(entries: [DiaryEntryData], onChunk: @escaping (String) -> Void) async {
        print("[OpenAIService] 开始从安全数据生成流式情绪报告，条目数量: \(entries.count)")
        guard !entries.isEmpty else { return }
        
        let textBlock = entries.map { entry in
            "日期: \(entry.date)\n心情分数: \(Int(entry.moodValue * 100))\n摘要: \(entry.summary)\n正文: \(entry.text)"
        }.joined(separator: "\n---\n")
        
        print("[OpenAIService] 安全数据流式文本块长度: \(textBlock.count) 字符")

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
            model: "gpt-5.2",
            messages: [Message(role: "user", content: prompt)],
            stream: true,
            reasoning_effort: "low"
        )
        
        let url = backendURL
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 后端代理会处理认证，这里不需要添加Authorization头
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try? jsonEncoder.encode(requestBody)
        
        print("[OpenAIService] 发送流式请求，模型: \(requestBody.model), stream: \(requestBody.stream)")

        do {
            try await NetworkRetryHelper.performWithRetry { [weak self] in
                guard let self = self else { throw NSError(domain: "OpenAIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Self deallocated"]) }
                print("[OpenAIService] 开始安全数据流式请求...")
                let (bytes, response) = try await URLSession.sslTolerantSession.bytes(for: request)
                
                if let http = response as? HTTPURLResponse {
                    print("[OpenAIService] 响应状态码: \(http.statusCode)")
                    print("[OpenAIService] 响应头: \(http.allHeaderFields)")
                    
                    if let contentType = http.value(forHTTPHeaderField: "Content-Type") {
                        print("[OpenAIService] Content-Type: \(contentType)")
                        if !contentType.contains("text/event-stream") && !contentType.contains("text/plain") {
                            print("[OpenAIService] ⚠️ 警告：服务器没有返回流式响应格式！")
                        }
                    }
                }
                
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                    print("[OpenAIService] 安全数据流式请求失败，状态码: \(statusCode)")
                    
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
                print("[OpenAIService] 流式请求响应正常，开始处理字节流...")
                
                struct StreamChoice: Codable { struct Delta: Codable { let content: String? }; let delta: Delta }
                struct StreamResponse: Codable { let choices: [StreamChoice] }

                // 处理真正的流式响应
                var chunkCount = 0
                
                for try await line in bytes.lines {
                    if line.isEmpty {
                        // 空行表示事件结束
                        continue
                    }
                    
                    if line.hasPrefix(":") {
                        // SSE注释，跳过
                        continue
                    }
                    
                    if line.hasPrefix("data:") {
                        let dataString = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        
                        if dataString == "[DONE]" {
                            print("[OpenAIService] 安全数据流式响应完成，总共收到 \(chunkCount) 个内容块")
                            return
                        }
                        
                        if let jsonData = dataString.data(using: .utf8) {
                            do {
                                let streamResp = try self.jsonDecoder.decode(StreamResponse.self, from: jsonData)
                                if let content = streamResp.choices.first?.delta.content, !content.isEmpty {
                                    chunkCount += 1
                                    onChunk(content)
                                }
                            } catch {
                                print("[OpenAIService] JSON解析失败: \(error)")
                                print("[OpenAIService] 问题数据: '\(dataString)'")
                            }
                        }
                    }
                }
                print("[OpenAIService] 字节流处理完成，总共收到 \(chunkCount) 个内容块")
            }
        } catch {
            print("[OpenAIService] 安全数据流式请求错误: \(error)")
            let errorMessage = prompt.contains("中文") ? 
                "生成报告时遇到错误：\(error.localizedDescription)" : 
                "Error generating report: \(error.localizedDescription)"
            onChunk(errorMessage)
        }
    }

    func generateReport(entries: [DiaryEntry], onChunk: @escaping (String) -> Void) async {
        guard !entries.isEmpty else { return }
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
            model: "gpt-5.2",
            messages: [Message(role: "user", content: prompt)],
            stream: true,
            reasoning_effort: "low"
        )
        // 改为走本地后端代理，不在客户端暴露 Key
        let url = backendURL
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 后端代理会处理认证，这里不需要添加Authorization头
        request.httpBody = try? jsonEncoder.encode(requestBody)

        do {
            try await NetworkRetryHelper.performWithRetry { [weak self] in
                guard let self = self else { throw NSError(domain: "OpenAIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Self deallocated"]) }
                let (bytes, response) = try await URLSession.sslTolerantSession.bytes(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                    print("[OpenAIService] Streaming request failed:")
                    print("  URL: \(request.url?.absoluteString ?? "unknown")")
                    print("  Status Code: \(statusCode)")
                    if let httpResponse = response as? HTTPURLResponse {
                        print("  Response Headers: \(httpResponse.allHeaderFields)")
                    }
                    
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
                            onChunk(content)
                        }
                    }
                }
            }
        } catch {
            print("[OpenAIService] Streaming error after retries: \(error)")
            // Send error message to user in their language
            let errorMessage: String
            if error.localizedDescription.contains("Could not connect to the server") || 
               error.localizedDescription.contains("The Internet connection appears to be offline") ||
               error.localizedDescription.contains("The request timed out") {
                errorMessage = prompt.contains("中文") ? 
                    "无法连接到AI服务器 (\(AppSecrets.backendURL))，请检查网络连接或联系开发者。" : 
                    "Cannot connect to AI server (\(AppSecrets.backendURL)). Please check network or contact developer."
            } else {
                errorMessage = prompt.contains("中文") ? 
                    "生成报告时遇到错误：\(error.localizedDescription)" : 
                    "Error generating report: \(error.localizedDescription)"
            }
            onChunk(errorMessage)
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

            struct ResponseFormat: Codable { let type: String }
            enum CodingKeys: String, CodingKey {
                case model, messages, response_format, stream, reasoning_effort
            }
        }
        struct ResponseBody: Codable {
            struct Choice: Codable { let message: Message }
            let choices: [Choice]
        }

        let requestBody = RequestBody(
            model: model ?? "gpt-5.2",
            messages: [Message(role: "user", content: prompt)],
            response_format: forceJSON ? RequestBody.ResponseFormat(type: "json_object") : nil,
            stream: stream ? true : nil,
            reasoning_effort: reasoningEffort
        )

        // 改为走本地后端代理，不在客户端暴露 Key
        let url = backendURL
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 后端代理会处理认证，这里不需要添加Authorization头
        request.httpBody = try? jsonEncoder.encode(requestBody)

        // 新增：支持流式响应
        if stream {
            do {
                return try await NetworkRetryHelper.performWithRetry { [weak self] in
                    guard let self = self else { throw NSError(domain: "OpenAIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Self deallocated"]) }
                    let (bytes, response) = try await URLSession.sslTolerantSession.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                        print("[OpenAIService] Bad response. Status code: \(statusCode)")
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
                print("[OpenAIService] Request error after retries: \(error)")
                if error.localizedDescription.contains("Could not connect to the server") || 
                   error.localizedDescription.contains("The Internet connection appears to be offline") ||
                   error.localizedDescription.contains("The request timed out") {
                    print("[OpenAIService] Cannot connect to backend proxy at \(AppSecrets.backendURL)")
                }
                return nil
            }
        } else {
            do {
                print("[OpenAIService] 执行非流式请求")
                return try await NetworkRetryHelper.performWithRetry { [weak self] in
                    guard let self = self else { throw NSError(domain: "OpenAIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Self deallocated"]) }
                    print("[OpenAIService] 发送网络请求...")
                    let (data, response) = try await URLSession.sslTolerantSession.data(for: request)
                    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                        if let httpResponse = response as? HTTPURLResponse {
                            let statusCode = httpResponse.statusCode
                            let responseBody = String(data: data, encoding: .utf8) ?? "Could not decode response body for error reporting."
                            
                            // Enhanced logging for debugging
                            print("[OpenAIService] Backend request failed:")
                            print("  URL: \(request.url?.absoluteString ?? "unknown")")
                            print("  Status Code: \(statusCode)")
                            print("  Response Headers: \(httpResponse.allHeaderFields)")
                            print("  Response Body: \(responseBody)")
                            
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
                            print("[OpenAIService] Bad response. Not an HTTPURLResponse. Response: \(response)")
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
                print("[OpenAIService] Request error after retries: \(error)")
                return nil
            }
        }
    }
    
    // MARK: - Debouncing
    private func debouncedRequest<T>(key: String, request: @escaping () async -> T) async -> T {
        // Add a delay before executing to allow for debouncing
        do {
            try await Task.sleep(nanoseconds: UInt64(debounceDelay * 1_000_000_000))
        } catch {
            // Task was cancelled, return default value
            if T.self == Optional<String>.self {
                return Optional<String>.none as! T
            } else if T.self == Double.self {
                return 0.5 as! T
            }
        }

        return await request()
    }
}

extension String {
    var containsChinese: Bool {
        return range(of: "[\u{4E00}-\u{9FFF}]", options: .regularExpression) != nil
    }
} 
