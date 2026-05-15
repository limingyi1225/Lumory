import Foundation
import CoreData
import CryptoKit

@available(iOS 15.0, macOS 12.0, *)
final class OpenAIService: AIServiceProtocol {
    /// 进程内共享实例——后台代理模式下不再需要每次编辑都 new 一个网络客户端。
    /// 调用方优先用 `.shared`，避免在 hot-path 上重复初始化。
    static let shared = OpenAIService()

    private static let backendEndpoint = "\(AppSecrets.backendURL)/api/openai/chat/completions"
    private let backendURL: URL
    // **wave11 access 策略**:`jsonEncoder` / `jsonDecoder` 跨 extension 文件被
    // generateReportFromData / askEvents / embed 共用,从 private 提升到 internal。
    // 它们是无状态工具(`JSONEncoder()` / `JSONDecoder()` 默认配置,无敏感 state),
    // 提升不暴露任何 secret。`backendURL`(配置 URL)/ `debounceDelay`(参数)留 private —
    // 都是配置层 state,不该跨文件直接访问。其他 extension 通过 chat / chatThrowing /
    // debouncedRequest 这几个 internal helper 间接走。
    let jsonEncoder = JSONEncoder()
    let jsonDecoder = JSONDecoder()
    static let narrativeTextBlockMaxUTF16Units = 28_000

    // Debounce delay for summarize requests
    private let debounceDelay: TimeInterval = 0.3 // 300ms debounce

    init() {
        guard let backendURL = URL(string: Self.backendEndpoint) else {
            preconditionFailure("[OpenAIService] Invalid backend endpoint: \(Self.backendEndpoint)")
        }
        self.backendURL = backendURL
    }

    // MARK: - Public — 这一节的公开 API 已按职责拆分到子目录:
    //   summarize / analyzeMood / firstValidScore / extractThemes / embed → +OneShotAI.swift
    //   generateReportFromData / askEvents / streamReportEvents → +Streaming.swift
    //   judgeThemeAliases / scanThemeAliasGroups → +ThemeAlias.swift
    //   composeSuggestions / parseSuggestionBundle → +Suggestions.swift
    //   parseImportedDiaries → +Import.swift
    // wave11 拆分,主文件只保留共享基础设施(chat / chatThrowing / debouncedRequest / 类壳)。


    // MARK: - Core
    /// 非流式 chat。流式路径走 `streamChatEvents` / `generateReportFromData` 自建 RequestBody,
    /// 不经过这里 —— 历史上 `chat()` 还有一个 `stream:true` 分支(~35 行 SSE 累加 buffer),
    /// `grep "chat(.*stream: true"` 全仓 0 caller,2026-05 删除避免将来误用。
    ///
    /// **wave11**:从 `private` 改成 `internal` —— 跨 extension 文件
    /// (OneShotAI / ThemeAlias / Suggestions)调用,它们都通过 `chat` 这条共享通路发请求。
    /// stored state(backendURL / debounceDelay)仍然 private,本方法是包装这些 state 的 helper。
    func chat(prompt: String,
                      model: String? = nil,
                      maxTokens: Int = 128,
                      forceJSON: Bool = false,
                      reasoningEffort: String? = nil) async -> String? {
        struct Message: Codable { let role: String; let content: String }
        struct RequestBody: Codable {
            let model: String
            let messages: [Message]
            let response_format: ResponseFormat?
            let reasoning_effort: String?
            // gpt-5 系列用 max_completion_tokens，不是 max_tokens。Swift 侧用 camelCase 以过 lint，
            // 通过 CodingKeys 映射到 OpenAI 期望的 snake_case。
            let maxCompletionTokens: Int?

            struct ResponseFormat: Codable { let type: String }
            enum CodingKeys: String, CodingKey {
                case model, messages, response_format, reasoning_effort
                case maxCompletionTokens = "max_completion_tokens"
            }
        }
        struct ResponseBody: Codable {
            struct Choice: Codable { let message: Message }
            let choices: [Choice]
        }

        let requestBody = RequestBody(
            model: model ?? "gpt-5.5",
            messages: [Message(role: "user", content: prompt)],
            response_format: forceJSON ? RequestBody.ResponseFormat(type: "json_object") : nil,
            reasoning_effort: reasoningEffort,
            maxCompletionTokens: maxTokens > 0 ? maxTokens : nil
        )

        guard !AppSecrets.appSharedSecret.isEmpty else {
            Log.error("[OpenAIService] Backend shared secret not configured", category: .ai)
            return nil
        }

        // 改为走本地后端代理，不在客户端暴露 Key
        let url = backendURL
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.applyBackendAuth()
        // (2026-05-15 megareview P2-2)`try?` 改 `do/try/catch` —— 原 `try?` 编码失败时 httpBody 是 nil,
        // 服务器返 400 messages-array-missing,被 BackendErrorMapper 当成普通 400 不重试,客户端只看到
        // "no content" 模糊错。理论上 Codable 固定 struct 几乎不会失败,但显式 catch 让真失败可诊断。
        do {
            request.httpBody = try jsonEncoder.encode(requestBody)
        } catch {
            Log.error("[OpenAIService] chat httpBody encode 失败: \(error)", category: .ai)
            return nil
        }

        do {
            Log.info("[OpenAIService] 执行非流式请求", category: .ai)
            // 不用 [weak self]：见 embed() 上方注释
            return try await NetworkRetryHelper.performWithRetry {
                Log.info("[OpenAIService] 发送网络请求...", category: .ai)
                let (data, response) = try await URLSession.sharedRetrySession.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    if let httpResponse = response as? HTTPURLResponse {
                        let statusCode = httpResponse.statusCode
                        // 诊断用最小信息：只 URL path + status + body 长度，不把 body 打进日志（避免泄日记/PII）
                        Log.error("[OpenAIService] Backend request failed — path=\(request.url?.path ?? "?") status=\(statusCode) bodyLen=\(data.count)", category: .ai)
                        throw BackendErrorMapper.error(forStatus: statusCode, retryAfter: httpResponse.value(forHTTPHeaderField: "Retry-After"))
                    } else {
                        Log.info("[OpenAIService] Bad response. Not an HTTPURLResponse. Response: \(response)", category: .ai)
                        throw NSError(
                            domain: "OpenAIService",
                            code: -1,
                            userInfo: [
                                NSLocalizedDescriptionKey: NSLocalizedString(
                                    "error.backend.invalidResponse",
                                    comment: "Invalid response from backend"
                                )
                            ]
                        )
                    }
                }
                let decoded = try self.jsonDecoder.decode(ResponseBody.self, from: data)
                guard let content = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    throw NSError(
                        domain: "OpenAIService",
                        code: -1,
                        userInfo: [
                            NSLocalizedDescriptionKey: NSLocalizedString(
                                "error.backend.emptyContent",
                                comment: "No content in response"
                            )
                        ]
                    )
                }
                return content
            }
        } catch {
            Log.error("[OpenAIService] Request error after retries: \(error)", category: .ai)
            return nil
        }
    }

    // MARK: - Throwing chat (used by parseImportedDiaries for typed error mapping)
    //
    // 和 `chat()` 共享同一个请求/重试/解码骨架,但**不吞错**——把上游 401 / 429 / offline 等
    // 直接 throw 出去,让 caller(目前是 `parseImportedDiaries`)能区分"网络/认证/限流"和
    // "AI 真的没返回内容"。reviewer 第二轮指出旧 `chat` 全部错误归一成 `noContent`,导致
    // 用户在配置/网络异常时被引导到错误的恢复路径。
    //
    // 仅支持非流式 —— 当前唯一用例(import 解析)是非流式调用,流式路径走原 `chat()`。
    //
    // **wave11**:从 `private` 改成 `internal` —— `OpenAIService+Import.swift` 跨文件调用。
    func chatThrowing(prompt: String,
                              model: String? = nil,
                              maxTokens: Int = 128,
                              reasoningEffort: String? = nil) async throws -> String {
        struct Message: Codable { let role: String; let content: String }
        struct RequestBody: Codable {
            let model: String
            let messages: [Message]
            let stream: Bool?
            let reasoning_effort: String?
            let maxCompletionTokens: Int?
            enum CodingKeys: String, CodingKey {
                case model, messages, stream, reasoning_effort
                case maxCompletionTokens = "max_completion_tokens"
            }
        }
        struct ResponseBody: Codable {
            struct Choice: Codable { let message: Message }
            let choices: [Choice]
        }

        // Reviewer 二轮指出:`AppSecrets.appSharedSecret` 注入失败(xcconfig 没挂、Info.plist
        // 没填)时,客户端会把空 header 送上去,后端 timing-safe compare 直接判 401。我们在这里
        // 提前拦下来,转成 `network` 错误带明确说明,而不是让用户看到"AI 未返回内容"误导提示。
        guard !AppSecrets.appSharedSecret.isEmpty else {
            throw NSError(
                domain: "OpenAIService",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "Backend shared secret not configured (xcconfig injection failed)."]
            )
        }

        let requestBody = RequestBody(
            model: model ?? "gpt-5.5",
            messages: [Message(role: "user", content: prompt)],
            stream: nil,
            reasoning_effort: reasoningEffort,
            maxCompletionTokens: maxTokens > 0 ? maxTokens : nil
        )
        var request = URLRequest(url: backendURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.applyBackendAuth()
        request.httpBody = try jsonEncoder.encode(requestBody)

        return try await NetworkRetryHelper.performWithRetry {
            let (data, response) = try await URLSession.sharedRetrySession.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let httpResponse = response as? HTTPURLResponse
                let statusCode = httpResponse?.statusCode ?? -1
                Log.error("[OpenAIService] chatThrowing failed — status=\(statusCode) bodyLen=\(data.count)", category: .ai)
                throw BackendErrorMapper.error(forStatus: statusCode, retryAfter: httpResponse?.value(forHTTPHeaderField: "Retry-After"))
            }
            let decoded = try self.jsonDecoder.decode(ResponseBody.self, from: data)
            guard let content = decoded.choices.first?.message.content
                .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
                throw NSError(
                    domain: "OpenAIService",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Empty content from model"]
                )
            }
            return content
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

    /// **wave11**:从 `private` 改成 `internal` —— summarize / analyzeMood / extractThemes /
    /// composeSuggestions 都跨文件调度过 debounce 通路。`DebounceRegistry` actor 跟
    /// `ResultBox` helper 仍然是 file-private 的(它们是 `debouncedRequest` 的实现细节)。
    func debouncedRequest<T>(
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
        return await withTaskCancellationHandler {
            await task.value
            await Self.debounceRegistry.clearIfCurrent(key: key, token: token)
            return resultBox.get() ?? cancelledFallback
        } onCancel: {
            task.cancel()
        }
    }
}

/// 小的引用容器，用来把 debounce Task 内部算出的泛型值存到外层作用域。
/// 锁是不可避免的——Task 内外是两个调度域；但只有两次 set+get，单锁够用。
private final class ResultBox<T: Sendable>: @unchecked Sendable {
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

extension String {
    var containsChinese: Bool {
        return range(of: "[\u{4E00}-\u{9FFF}]", options: .regularExpression) != nil
    }
}

// MARK: - SSE parsing / stream response → OpenAI/SSEParser.swift (wave11 拆出)

// MARK: - Phase 0: AI × 统计融合地基（主题 / 向量 / 对话 / 统一流式）
@available(iOS 15.0, macOS 12.0, *)
extension OpenAIService {
    // MARK: - 业务方法已全部按职责拆到 OpenAI/ 子目录:
    //   summarize / analyzeMood / firstValidScore / extractThemes / embed → +OneShotAI.swift
    //   generateReportFromData / streamReportEvents / askEvents / streamChatEvents → +Streaming.swift
    //   judgeThemeAliases / scanThemeAliasGroups / themeKey → +ThemeAlias.swift
    //   composeSuggestions / parseSuggestionBundle → +Suggestions.swift
    //   parseImportedDiaries → +Import.swift
    // 主文件保留:类壳 / stored state / chat / chatThrowing / debouncedRequest 共享底座。
}
