import Foundation

// MARK: - Anthropic(Claude)通路
//
// **2026-06-11 GPT→Claude 迁移**:chat 类调用(叙事 / Ask Past / 导入 / 别名判定 +
// 端上模型的云端兜底)走自建后端的 `/api/anthropic/messages` 哑代理 —— 后端透传
// Anthropic Messages API 原生格式,不做翻译,客户端这里直接讲 Anthropic 的请求/响应方言。
// embeddings / 转写仍走 OpenAI 端点(`+OneShotAI.swift` 的 embed / OpenAITranscriber)。
// 类名仍叫 `OpenAIService` —— 历史遗留,改名牵动 22+ callsite 与测试,跟 `Chronote/`
// 目录名同一逻辑:成本大于收益,不动。
//
// 与 OpenAI 通路的关键差异:
//   - `system` 是独立顶层字段,不是 messages 里的 role
//   - token 上限字段叫 `max_tokens`(不是 max_completion_tokens)
//   - 没有 reasoning_effort;Opus 4.8 上 thinking 只有 `{type:"adaptive"}` 一种开法
//     (省略 = 关;`enabled+budget_tokens` 会 400),配 `output_config.effort` 调深度
//   - 结构化输出走 `output_config.format` + JSON schema(比旧 forceJSON 的
//     response_format=json_object 强:返回保证匹配 schema,解析兜底代码可删)
//   - SSE 成功终止帧是 `event: message_stop`,没有 `data: [DONE]`
//   - 截断信号在 `message_delta` 帧的 `delta.stop_reason`(max_tokens / refusal),
//     不是 choices[].finish_reason

@available(iOS 15.0, macOS 12.0, *)
extension OpenAIService {
    /// 客户端侧的 Claude 模型常量。后端 `ANTHROPIC_MODEL_ALLOWLIST` 同步维护,
    /// 不在 allowlist 内的会被服务端静默回落到 opus。
    enum ClaudeModel {
        /// 质量敏感调用:叙事报告 / Ask Past / 导入解析 / 别名判定
        static let opus = "claude-opus-4-8"
        /// 端上 Foundation Models 不可用时的兜底:心情 / 主题 / 摘要 / 写作建议
        static let sonnet = "claude-sonnet-4-6"
    }

    // MARK: - Wire types

    /// 非流式 Messages 响应。只取我们需要的字段(text content + stop_reason)。
    struct AnthropicResponseBody: Decodable {
        struct ContentBlock: Decodable {
            let type: String
            let text: String?
        }
        let content: [ContentBlock]
        let stopReason: String?

        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
        }

        var firstText: String? {
            content.first(where: { $0.type == "text" })?.text
        }
    }

    /// 流式 SSE 的单条 data 帧。Anthropic 每帧都带 `type` 判别字段
    /// (message_start / content_block_start / content_block_delta / content_block_stop /
    /// message_delta / message_stop / ping / error),这里用一个全可选结构吃下所有帧,
    /// caller 按 `type` 分发。SSEParser 只解析 `data:` 行,`event:` 行被忽略 —— 没问题,
    /// data payload 里的 `type` 字段跟 event 名一致。
    struct AnthropicStreamChunk: Decodable {
        struct Delta: Decodable {
            let type: String?
            let text: String?
            let stopReason: String?

            enum CodingKeys: String, CodingKey {
                case type, text
                case stopReason = "stop_reason"
            }
        }
        struct ErrorPayload: Decodable {
            let type: String?
            let message: String?
        }

        let type: String
        let delta: Delta?
        let error: ErrorPayload?

        /// `message_delta` 帧里 stop_reason 表示"流要收尾了"。max_tokens / refusal
        /// 对应旧 OpenAI 的 finish_reason length / content_filter → `.truncated`。
        var isTruncatedStop: Bool {
            type == "message_delta" && (delta?.stopReason == "max_tokens" || delta?.stopReason == "refusal")
        }
    }

    // MARK: - Request builder

    /// 组 `/api/anthropic/messages` 请求。body 用 JSONSerialization 而非 Codable struct ——
    /// `output_config.format.schema` 是任意嵌套 JSON schema,字典直拼比给 schema 建一套
    /// Codable 包装类型干净得多。字段都是我们自己手写的常量结构,不存在编码失败面
    /// (JSONSerialization 仅在非法类型时 throw,下面所有 value 都是 plist-safe 类型)。
    /// `requestTimeout`:覆盖 `sharedRetrySession` 的 30s **idle** 超时(timeoutIntervalForRequest
    /// 语义是"无数据空闲",非流式调用在完整响应回来前零字节静默)。长输出非流式调用(导入 16K token /
    /// 别名判定 adaptive thinking)在 Opus 上静默期常超 30s,必须放宽;上限受 session 的
    /// timeoutIntervalForResource=300s 兜底。流式调用不需要 —— SSE chunk 持续到达会重置 idle 计时。
    func makeAnthropicRequest(
        prompt: String,
        system: String? = nil,
        model: String,
        maxTokens: Int,
        stream: Bool = false,
        adaptiveThinking: Bool = false,
        effort: String? = nil,
        jsonSchema: [String: Any]? = nil,
        requestTimeout: TimeInterval? = nil
    ) throws -> URLRequest {
        guard let url = URL(string: "\(AppSecrets.backendURL)/api/anthropic/messages") else {
            throw BackendErrorMapper.error(forStatus: -1)
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": prompt]]
        ]
        if let system, !system.isEmpty {
            body["system"] = system
        }
        if stream {
            body["stream"] = true
        }
        // Opus 4.8:省略 thinking = 关(不要传 {type:"disabled"},Fable 5 上会 400,
        // 统一省略写法跨模型最稳)。adaptive 时配 effort 控制深度/成本。
        if adaptiveThinking {
            body["thinking"] = ["type": "adaptive"]
        }
        var outputConfig: [String: Any] = [:]
        if let effort {
            outputConfig["effort"] = effort
        }
        if let jsonSchema {
            outputConfig["format"] = ["type": "json_schema", "schema": jsonSchema]
        }
        if !outputConfig.isEmpty {
            body["output_config"] = outputConfig
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if stream {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        if let requestTimeout {
            request.timeoutInterval = requestTimeout
        }
        request.applyBackendAuth(sharedSecret: appSharedSecret)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Non-streaming chat(吞错版,对齐旧 `chat()` 的调用方语义)

    /// Claude 非流式单轮。失败返回 nil(网络 / 鉴权 / 空内容都归一),caller 自己降级。
    /// 结构化输出场景传 `jsonSchema`,返回的 text 保证是匹配 schema 的合法 JSON。
    func claudeChat(
        prompt: String,
        system: String? = nil,
        model: String = ClaudeModel.opus,
        maxTokens: Int,
        adaptiveThinking: Bool = false,
        effort: String? = nil,
        jsonSchema: [String: Any]? = nil,
        requestTimeout: TimeInterval? = nil
    ) async -> String? {
        do {
            return try await claudeChatThrowing(
                prompt: prompt,
                system: system,
                model: model,
                maxTokens: maxTokens,
                adaptiveThinking: adaptiveThinking,
                effort: effort,
                jsonSchema: jsonSchema,
                requestTimeout: requestTimeout
            )
        } catch {
            Log.error("[OpenAIService] claudeChat error after retries: \(error)", category: .ai)
            return nil
        }
    }

    // MARK: - Non-streaming chat(throws 版,import 等需要 typed error 分流的调用方用)

    func claudeChatThrowing(
        prompt: String,
        system: String? = nil,
        model: String = ClaudeModel.opus,
        maxTokens: Int,
        adaptiveThinking: Bool = false,
        effort: String? = nil,
        jsonSchema: [String: Any]? = nil,
        requestTimeout: TimeInterval? = nil
    ) async throws -> String {
        guard !appSharedSecret.isEmpty else {
            throw BackendErrorMapper.missingSharedSecretError()
        }
        let request = try makeAnthropicRequest(
            prompt: prompt,
            system: system,
            model: model,
            maxTokens: maxTokens,
            adaptiveThinking: adaptiveThinking,
            effort: effort,
            jsonSchema: jsonSchema,
            requestTimeout: requestTimeout
        )

        return try await NetworkRetryHelper.performWithRetry {
            let (data, response) = try await self.session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let httpResponse = response as? HTTPURLResponse
                let statusCode = httpResponse?.statusCode ?? -1
                // 诊断只记 path/status/长度,不打 body(可能含日记原文)。
                Log.error("[OpenAIService] claudeChat failed — status=\(statusCode) bodyLen=\(data.count)", category: .ai)
                throw BackendErrorMapper.error(forStatus: statusCode, retryAfter: httpResponse?.value(forHTTPHeaderField: "Retry-After"))
            }
            let decoded = try self.jsonDecoder.decode(AnthropicResponseBody.self, from: data)
            guard let content = decoded.firstText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else {
                throw NSError(
                    domain: "OpenAIService",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Empty content from model"]
                )
            }
            return content
        }
    }
}
