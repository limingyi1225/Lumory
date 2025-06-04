import Foundation

@available(iOS 15.0, macOS 12.0, *)
final class OpenAIService: AIServiceProtocol {

    private let apiKey: String
    private let baseURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")! // 使用 OpenRouter 完整端点
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    // MARK: - Public
    func transcribeAudio(fileURL: URL, localeIdentifier: String) async -> String? {
        // 转录已移至 AppleRecognitionService，此处不再实现
        return nil
    }

    func summarize(text: String) async -> String? {
        let prompt: String
        if text.containsChinese {
            prompt = "概括以下日记内容，抓住重点，不超过15个字，仅使用逗号和分号。\n# Steps\n1. 阅读并理解日记内容。\n2. 抓住日记的关键信息和主题。\n3. 使用简洁精准的语言进行概括。\n4. 确保概括不超过15个字。\n5. 仅使用逗号和分号作为标点符号。\n# Output Format\n- 一个简短的概括，不超过15个字。\n- 仅使用逗号和分号，最后一个字后面不要有标点符号\n日记：\n\n\(text)"
        } else {
            prompt = "Summarize the following diary entry, focusing on the key points, in no more than 10 words, using only commas and semicolons.\n# Steps\n1. Read and understand the diary entry.\n2. Identify the key information and theme.\n3. Summarize using concise and precise language.\n4. Ensure the summary does not exceed 10 words.\n5. Use only commas and semicolons as punctuation.\n# Output Format\n- A short summary, no more than 10 words.\n- Only commas and semicolons used.\nDiary:\n\n\(text)"
        }
        return await chat(prompt: prompt, model: "qwen/qwen-turbo")
    }

    func analyzeMood(text: String) async -> Double {
        // 通用英文 prompt，返回 JSON，可包含"不确定"选项
        let diaryEscaped = text.replacingOccurrences(of: "\"", with: "\\\"")
        let prompt = """
            // 请大胆使用极端值：如果日记内容非常消极，请使用1；如果非常积极，请使用100。
            Analyze a provided diary entry and generate a mood score on a scale from 1 to 100, where 1 represents a very negative mood and 100 represents a very positive mood.

            Consider the language, tone, and expressed emotions in the diary entry to assess the mood accurately.

            # Steps
            1. **Read the Diary Entry**: Carefully interpret the content, context, and emotional nuances present in the diary entry.
            2. **Analyze Emotional Content**: Identify words and phrases that indicate the mood, such as expressions of joy, sadness, anger, or anxiety.
            3. **Determine Mood Score**: Use the analysis to assign a mood score between 1 and 100. If unable to determine the mood clearly, you may choose the string "uncertain".

            # Output Format
            The response should be in JSON format, containing the following field:
            - "mood_score": An integer between 1 and 100 indicating the mood assessment, or the string "uncertain" if the mood cannot be determined.

            # Diary Entry
            "
            \(diaryEscaped)
            "
            """

        if let resultStr = await chat(prompt: prompt, model: "qwen/qwen-turbo", maxTokens: 32, forceJSON: true)?
                .trimmingCharacters(in: .whitespacesAndNewlines) {
            // 解析 JSON 或字符串中的 mood_score
            if let data = resultStr.data(using: .utf8) {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let score = json["mood_score"] as? Int, (1...100).contains(score) {
                        return Double(score) / 100.0
                    }
                    if let strVal = json["mood_score"] as? String {
                        let lower = strVal.lowercased()
                        if lower.contains("uncertain") || lower.contains("不确定") {
                            return 0.5
                        }
                        if let number = Int(strVal.filter({ $0.isNumber })), (1...100).contains(number) {
                            return Double(number) / 100.0
                        }
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
        guard !entries.isEmpty else { return nil }
        let textBlock = entries.map { entry in
            "日期: \(entry.date)\n心情分数: \(Int(entry.moodValue * 100))\n摘要: \(entry.summary ?? "")\n正文: \(entry.text)"
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
- 1-4段落的报告（总字数不超过400字）。
- 每个段落之间用空行（两行换行）分隔。
- 不得使用括号、破折号，引号，星号，加粗，斜体或其他类似标点符号。

Diary Entries:
\(textBlock)
"""
        // 使用 deepseek/deepseek-chat-v3-0324 写情绪报告
        return await chat(prompt: prompt,
                          model: "deepseek/deepseek-chat-v3-0324",
                          maxTokens: 4096,
                          stream: true)
    }

    func generateReport(entries: [DiaryEntry], onChunk: @escaping (String) -> Void) async {
        guard !entries.isEmpty else { return }
        let textBlock = entries.map { entry in
            "日期: \(entry.date)\n心情分数: \(Int(entry.moodValue * 100))\n摘要: \(entry.summary ?? "")\n正文: \(entry.text)"
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
- 1-4段落的报告（总字数不超过400字）。
- 每个段落之间用空行（两行换行）分隔。
- 不得使用括号、破折号，引号，星号，加粗，斜体或其他类似标点符号。

Diary Entries:
\(textBlock)
"""
        struct Message: Codable { let role: String; let content: String }
        struct RequestBody: Codable {
            let model: String
            let messages: [Message]
            let max_tokens: Int
            let temperature: Double
            let stream: Bool

            enum CodingKeys: String, CodingKey { case model, messages, max_tokens, temperature, stream }
        }
        let requestBody = RequestBody(
            model: "deepseek/deepseek-chat-v3-0324",
            messages: [Message(role: "user", content: prompt)],
            max_tokens: 4096,
            temperature: 0.7, // 较高温度，加快首token输出
            stream: true
        )
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? jsonEncoder.encode(requestBody)

        do {
            try await NetworkRetryHelper.performWithRetry { [weak self] in
                guard let self = self else { throw NSError(domain: "OpenAIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Self deallocated"]) }
                let (bytes, response) = try await URLSession.sslTolerantSession.bytes(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                    print("[OpenAIService] Bad streaming response: \(statusCode)")
                    throw NSError(domain: "OpenAIService", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "Bad response code"])
                }
                struct StreamChoice: Codable { struct Delta: Codable { let content: String? }; let delta: Delta }
                struct StreamResponse: Codable { let choices: [StreamChoice] }

                var buffer = Data()
                let newline = "\n".data(using: .utf8)!
                for try await chunk in bytes {
                    buffer.append(chunk)
                    while let range = buffer.range(of: newline) {
                        let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                        guard let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), line.hasPrefix("data:") else { continue }
                        let dataString = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
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
            let errorMessage = prompt.contains("中文") ? 
                "生成报告时遇到网络问题，请稍后再试。" : 
                "Network error while generating report. Please try again later."
            onChunk(errorMessage)
        }
    }

    // MARK: - Core
    private func chat(prompt: String,
                      model: String? = nil,
                      maxTokens: Int = 128,
                      forceJSON: Bool = false,
                      stream: Bool = false) async -> String? {
        struct Message: Codable { let role: String; let content: String }
        struct RequestBody: Codable {
            let model: String
            let messages: [Message]
            let max_tokens: Int
            let temperature: Double
            let response_format: ResponseFormat?
            let stream: Bool?

            struct ResponseFormat: Codable { let type: String }
            enum CodingKeys: String, CodingKey {
                case model, messages, max_tokens, temperature, response_format, stream
            }
        }
        struct ResponseBody: Codable {
            struct Choice: Codable { let message: Message }
            let choices: [Choice]
        }

        // 根据是否流式设置温度：提高流式生成速度
        let temp = stream ? 0.7 : 0.0
        let requestBody = RequestBody(
            model: model ?? "deepseek/deepseek-chat-v3-0324",
            messages: [Message(role: "user", content: prompt)],
            max_tokens: maxTokens,
            temperature: temp, // 流式模式使用较高温度
            response_format: forceJSON ? RequestBody.ResponseFormat(type: "json_object") : nil,
            stream: stream ? true : nil
        )

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
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
                    var buffer = Data()
                    let newline = "\n".data(using: .utf8)!
                    for try await chunk in bytes {
                        buffer.append(chunk)
                        while let range = buffer.range(of: newline) {
                            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                            if let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                               line.hasPrefix("data:") {
                                let dataString = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                                if dataString == "[DONE]" { break }
                                if let jsonData = dataString.data(using: .utf8),
                                   let streamResp = try? self.jsonDecoder.decode(StreamResponse.self, from: jsonData),
                                   let content = streamResp.choices.first?.delta.content {
                                    result.append(content)
                                }
                            }
                        }
                    }
                    return result  // 保留换行符，不要trim
                }
            } catch {
                print("[OpenAIService] Request error after retries: \(error)")
                return nil
            }
        } else {
            do {
                return try await NetworkRetryHelper.performWithRetry { [weak self] in
                    guard let self = self else { throw NSError(domain: "OpenAIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Self deallocated"]) }
                    let (data, response) = try await URLSession.sslTolerantSession.data(for: request)
                    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                        if let httpResponse = response as? HTTPURLResponse {
                            let statusCode = httpResponse.statusCode
                            let responseBody = String(data: data, encoding: .utf8) ?? "Could not decode response body for error reporting."
                            print("[OpenAIService] Bad response. Status code: \(statusCode). Body: \(responseBody)")
                            throw NSError(domain: "OpenAIService", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "Bad response: \(statusCode)"])
                        } else {
                            print("[OpenAIService] Bad response. Not an HTTPURLResponse. Response: \(response)")
                            throw NSError(domain: "OpenAIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
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
}

extension String {
    var containsChinese: Bool {
        return range(of: "[\u{4E00}-\u{9FFF}]", options: .regularExpression) != nil
    }
} 
