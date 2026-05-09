import Foundation

// MARK: - Streaming(SSE 事件流 / 长输出 AI)
//
// **wave11 拆出**:从 OpenAIService.swift 把 4 条流式入口聚到一起。
// 共同特征:caller 订阅 `AsyncStream<StreamEvent>`,中间会反复 yield `.chunk` /
// `.truncated` / `.failed` / `.done` 四类事件;底下都走 SSEParser 拆字节流。
//
// 包含:
//   - generateReportFromData —— 流式情绪报告(原始入口,onEvent closure 风格)
//   - streamReportEvents     —— 上面的 AsyncStream 包装(`AIServiceProtocol` 要求)
//   - askEvents              —— Ask Past RAG 流式问答
//   - streamChatEvents       —— 底层共享 SSE chat helper(askEvents 用,fileprivate)
//   - narrativeTextBlock + helpers —— 把 entries 拼成有 token cap 的 prompt 文本块
//   - shortDate / NarrativeTextBlock struct —— 共享文本结构

@available(iOS 15.0, macOS 12.0, *)
extension OpenAIService {
    // MARK: - 流式情绪报告(closure 风格 + AsyncStream 包装)

    /// 结构化事件版本 —— NarrativeReader / InsightsEngine 用这个,可以区分 chunk vs truncated vs failed。
    /// 所有事件都在 MainActor 上投递。
    func generateReportFromData(entries: [DiaryEntryData], onEvent: @escaping @MainActor (StreamEvent) -> Void) async {
        Log.info("[OpenAIService] 开始从安全数据生成流式情绪报告，条目数量: \(entries.count)", category: .ai)
        guard !entries.isEmpty else {
            await MainActor.run { onEvent(.done) }
            return
        }

        let textBlockInfo = Self.narrativeTextBlock(from: entries)
        let textBlock = textBlockInfo.text

        if textBlockInfo.truncated {
            Log.info(
                "[OpenAIService] Narrative input truncated: included=\(textBlockInfo.includedEntries)/\(textBlockInfo.totalEntries), utf16=\(textBlock.utf16.count)",
                category: .ai
            )
        }
        Log.info("[OpenAIService] 安全数据流式文本块长度: \(textBlock.count) 字符", category: .ai)

        let coverageNote = textBlockInfo.truncated
            ? "\n# 范围说明\n由于日记总量较大,以下仅包含最近 \(textBlockInfo.includedEntries) / \(textBlockInfo.totalEntries) 篇日记,请基于已提供的内容分析,不要暗示你看过被省略的日记。\n"
            : ""

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
\(coverageNote)

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
            model: "gpt-5.5",
            messages: [Message(role: "user", content: prompt)],
            stream: true,
            reasoning_effort: "low"
        )

        guard !AppSecrets.appSharedSecret.isEmpty else {
            await MainActor.run { onEvent(.failed(BackendErrorMapper.missingSharedSecretError())) }
            return
        }

        // wave11:`backendURL` 是主文件 private stored property —— 在这里直接构造 URL,
        // 跟 streamChatEvents / embed 的写法一致(它们都用 `AppSecrets.backendURL`)。
        guard let url = URL(string: "\(AppSecrets.backendURL)/api/openai/chat/completions") else {
            await MainActor.run { onEvent(.failed(BackendErrorMapper.error(forStatus: -1))) }
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.applyBackendAuth()
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try? jsonEncoder.encode(requestBody)

        Log.info("[OpenAIService] 发送流式请求，模型: \(requestBody.model), stream: \(requestBody.stream)", category: .ai)

        // **与 streamChat 相同的去重保护**：NarrativeReader 直接把每个 onChunk 累加进 buffer，
        // 一旦断流后 NetworkRetryHelper 整段回放，生成的故事会出现前缀重复。一次成功 yield 过 chunk 后
        // 不允许重试，直接吐截断标记收尾。
        var hasEmittedAnyChunk = false
        var didEmitTerminalStreamEvent = false
        do {
            // singleton method + escaping closure 不用 [weak self]，防 Release -O ARC 假早释放
            try await NetworkRetryHelper.performWithRetry {
                Log.info("[OpenAIService] 开始安全数据流式请求...", category: .ai)
                let (bytes, response) = try await URLSession.sharedRetrySession.bytes(for: request)

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
                    let httpResponse = response as? HTTPURLResponse
                    let statusCode = httpResponse?.statusCode ?? -1
                    Log.error("[OpenAIService] 安全数据流式请求失败，状态码: \(statusCode)", category: .ai)
                    throw BackendErrorMapper.error(forStatus: statusCode, retryAfter: httpResponse?.value(forHTTPHeaderField: "Retry-After"))
                }
                Log.info("[OpenAIService] 流式请求响应正常，开始处理字节流...", category: .ai)

                // 统一经 SSEParser 解析 —— 不再 inline 重复实现。
                var chunkCount = 0
                do {
                    for try await streamResp in SSEParser.parse(
                        bytes: bytes,
                        type: OpenAIStreamResponse.self,
                        decoder: self.jsonDecoder
                    ) {
                        try Task.checkCancellation()
                        if streamResp.hasTruncatedFinish {
                            let reason = NSLocalizedString("stream.truncated.report", comment: "Report truncated marker")
                            didEmitTerminalStreamEvent = true
                            await MainActor.run { onEvent(.truncated(reason: reason)) }
                            return
                        }
                        if let content = streamResp.choices.first?.delta?.content, !content.isEmpty {
                            chunkCount += 1
                            hasEmittedAnyChunk = true
                            await MainActor.run { onEvent(.chunk(content)) }
                        }
                    }
                    Log.info("[OpenAIService] 字节流处理完成，总共收到 \(chunkCount) 个内容块", category: .ai)
                } catch {
                    // 中途断流：已发过 chunk 就不重试（避免叙事正文前缀重复）；发 truncated 事件后正常返回
                    if hasEmittedAnyChunk {
                        Log.error("[OpenAIService] 报告流式中断; emitting truncation event: \(error)", category: .ai)
                        let reason = NSLocalizedString("stream.truncated.report", comment: "Report truncated marker")
                        didEmitTerminalStreamEvent = true
                        await MainActor.run { onEvent(.truncated(reason: reason)) }
                        return
                    }
                    throw error
                }
            }
            if !didEmitTerminalStreamEvent {
                await MainActor.run { onEvent(.done) }
            }
        } catch {
            Log.error("[OpenAIService] 安全数据流式请求错误: \(error)", category: .ai)
            if hasEmittedAnyChunk {
                // 已经吐过内容才断 —— 依然归到 truncated（不是致命 failure）
                let reason = NSLocalizedString("stream.truncated.report", comment: "Report truncated marker")
                didEmitTerminalStreamEvent = true
                await MainActor.run { onEvent(.truncated(reason: reason)) }
            } else {
                didEmitTerminalStreamEvent = true
                await MainActor.run { onEvent(.failed(error)) }
            }
        }
    }

    /// 事件流版本的 streamReport —— AIServiceProtocol 要求。
    func streamReportEvents(entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
        AsyncStream { continuation in
            let task = Task {
                await self.generateReportFromData(entries: entries) { @MainActor event in
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Narrative text block helpers
    //
    // 把 [DiaryEntryData] 拼成一个有 token cap 的纯文本块,给 generateReportFromData 的 prompt
    // 用。`narrativeTextBlock` 有外部 caller(InsightsEngine 也调它),`narrativeEntryBlock` /
    // `trimToUTF16Limit` 是私有 helper。

    struct NarrativeTextBlock: Equatable {
        let text: String
        let includedEntries: Int
        let totalEntries: Int
        let truncated: Bool
    }

    static func narrativeTextBlock(
        from entries: [DiaryEntryData],
        maxUTF16Units: Int = narrativeTextBlockMaxUTF16Units
    ) -> NarrativeTextBlock {
        let separator = "\n---\n"
        guard maxUTF16Units > 0 else {
            return NarrativeTextBlock(text: "", includedEntries: 0, totalEntries: entries.count, truncated: !entries.isEmpty)
        }

        var newestFirst: [String] = []
        var usedUTF16 = 0
        var didTrimEntry = false

        for entry in entries.reversed() {
            let block = narrativeEntryBlock(entry)
            let separatorCost = newestFirst.isEmpty ? 0 : separator.utf16.count
            let remaining = maxUTF16Units - usedUTF16 - separatorCost
            guard remaining > 0 else { break }

            let blockCost = block.utf16.count
            if blockCost <= remaining {
                newestFirst.append(block)
                usedUTF16 += separatorCost + blockCost
            } else if newestFirst.isEmpty {
                newestFirst.append(trimToUTF16Limit(block, maxUTF16Units))
                didTrimEntry = true
                usedUTF16 = newestFirst[0].utf16.count
                break
            } else {
                break
            }
        }

        let text = newestFirst.reversed().joined(separator: separator)
        return NarrativeTextBlock(
            text: text,
            includedEntries: newestFirst.count,
            totalEntries: entries.count,
            truncated: didTrimEntry || newestFirst.count < entries.count
        )
    }

    private static func narrativeEntryBlock(_ entry: DiaryEntryData) -> String {
        "日期: \(entry.date)\n心情分数: \(Int(entry.moodValue * 100))\n摘要: \(entry.summary)\n正文: \(entry.text)"
    }

    private static func trimToUTF16Limit(_ text: String, _ maxUTF16Units: Int) -> String {
        guard text.utf16.count > maxUTF16Units else { return text }
        guard maxUTF16Units > 0 else { return "" }

        var output = ""
        output.reserveCapacity(min(text.count, maxUTF16Units))
        var used = 0
        for character in text {
            let cost = character.utf16.count
            guard used + cost <= maxUTF16Units else { break }
            output.append(character)
            used += cost
        }
        return output
    }

    // MARK: - Ask Past (RAG)

    /// 结构化事件版 RAG 问答流。UI 想区分"中断 / 失败 / 正常"直接消费这个。
    func askEvents(question: String, context entries: [DiaryEntryData]) -> AsyncStream<StreamEvent> {
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

                for await event in self.streamChatEvents(prompt: prompt, model: "gpt-5.5", reasoningEffort: "low") {
                    if Task.isCancelled { break }
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Helpers (file-private)

    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// 低层流式 chat（**结构化事件版本**）：把 SSE 解析成 `StreamEvent` 流。
    /// 三类事件:`.chunk` / `.truncated` / `.failed` / `.done`,caller 自己决定怎么渲染。
    /// `fileprivate` —— 仅 askEvents 用,跨 extension 文件不暴露。
    fileprivate func streamChatEvents(prompt: String,
                                      model: String,
                                      reasoningEffort: String?,
                                      maxTokens: Int = 4096) -> AsyncStream<StreamEvent> {
        AsyncStream { continuation in
            let task = Task {
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
                    continuation.yield(.failed(NSError(
                        domain: "OpenAIService",
                        code: -1,
                        userInfo: [
                            NSLocalizedDescriptionKey: NSLocalizedString(
                                "error.backend.invalidResponse",
                                comment: "Invalid response from backend"
                            )
                        ]
                    )))
                    continuation.finish()
                    return
                }
                guard !AppSecrets.appSharedSecret.isEmpty else {
                    continuation.yield(.failed(BackendErrorMapper.missingSharedSecretError()))
                    continuation.finish()
                    return
                }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                request.applyBackendAuth()
                request.httpBody = try? self.jsonEncoder.encode(body)

                // 重试保护：一旦已经向 caller yield 过任意 chunk，就不允许再重试——
                // 否则 NetworkRetryHelper 会把整个请求从头回放，caller 把新 chunk 累加进
                // 同一条 message，用户看到 "你好你好我今天…" 这种前缀重复。
                var hasEmittedAnyChunk = false
                var didEmitTerminalStreamEvent = false
                do {
                    try await NetworkRetryHelper.performWithRetry {
                        let (bytes, response) = try await URLSession.sharedRetrySession.bytes(for: request)
                        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                            let http = response as? HTTPURLResponse
                            throw BackendErrorMapper.error(forStatus: http?.statusCode ?? -1, retryAfter: http?.value(forHTTPHeaderField: "Retry-After"))
                        }
                        do {
                            for try await streamResp in SSEParser.parse(
                                bytes: bytes,
                                type: OpenAIStreamResponse.self,
                                decoder: self.jsonDecoder
                            ) {
                                try Task.checkCancellation()
                                if streamResp.hasTruncatedFinish {
                                    let reason = NSLocalizedString("stream.truncated.answer", comment: "Answer truncated marker")
                                    didEmitTerminalStreamEvent = true
                                    continuation.yield(.truncated(reason: reason))
                                    return
                                }
                                if let content = streamResp.choices.first?.delta?.content, !content.isEmpty {
                                    hasEmittedAnyChunk = true
                                    continuation.yield(.chunk(content))
                                }
                            }
                        } catch {
                            if hasEmittedAnyChunk {
                                Log.error("[OpenAIService] streamChat interrupted mid-stream; emitting truncated event: \(error)", category: .ai)
                                let reason = NSLocalizedString("stream.truncated.answer", comment: "Answer truncated marker")
                                didEmitTerminalStreamEvent = true
                                continuation.yield(.truncated(reason: reason))
                                return
                            }
                            throw error
                        }
                    }
                    if !didEmitTerminalStreamEvent {
                        continuation.yield(.done)
                    }
                } catch {
                    Log.error("[OpenAIService] streamChat error: \(error)", category: .ai)
                    if hasEmittedAnyChunk {
                        let reason = NSLocalizedString("stream.truncated.answer", comment: "Answer truncated marker")
                        didEmitTerminalStreamEvent = true
                        continuation.yield(.truncated(reason: reason))
                    } else {
                        didEmitTerminalStreamEvent = true
                        continuation.yield(.failed(error))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
