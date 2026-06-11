import Foundation
import CoreData
import CryptoKit

@available(iOS 15.0, macOS 12.0, *)
// `@unchecked Sendable` — 协议 `AIServiceProtocol: Sendable` 要求 conformer 满足 Sendable。
// 这个类全是 `let` immutable stored state(`session` / `appSharedSecret` / 两个
// JSONEncoder/Decoder),理论 inferred Sendable;但 `JSONEncoder` / `JSONDecoder` 类型自身在
// Swift 类型系统上**不是** `Sendable`(reference type 有内部 cache state),所以无法 inferred。
// 实际生产路径上两个 coder 只调 encode/decode 不改配置,跨线程使用安全。`@unchecked` 把这条
// "我已经验过线程安全"的承诺挂出来。如果 future 加 mutable shared state,改用内部锁 + 保留
// `@unchecked` 或者拆掉变成 actor。
final class OpenAIService: AIServiceProtocol, @unchecked Sendable {
    /// 进程内共享实例——后台代理模式下不再需要每次编辑都 new 一个网络客户端。
    /// 调用方优先用 `.shared`，避免在 hot-path 上重复初始化。
    static let shared = OpenAIService()

    // **wave11 access 策略**:`jsonEncoder` / `jsonDecoder` 跨 extension 文件被
    // claudeChat / streamClaudeChatEvents / embed 共用,从 private 提升到 internal。
    // 它们是无状态工具(`JSONEncoder()` / `JSONDecoder()` 默认配置,无敏感 state),
    // 提升不暴露任何 secret。`debounceDelay`(参数)留 private。
    let jsonEncoder = JSONEncoder()
    let jsonDecoder = JSONDecoder()
    static let narrativeTextBlockMaxUTF16Units = 28_000

    // Debounce delay for summarize requests
    private let debounceDelay: TimeInterval = 0.3 // 300ms debounce

    /// URLSession 注入点:生产走 `.sharedRetrySession`(默认),测试可注入 URLProtocol-mocked session。
    /// 跨 extension 共用,因此 internal(同模块可见)。`OpenAIService+Streaming` / `+OneShotAI` /
    /// `+Anthropic` 全部走 `self.session`,统一一个 URLSession 实例。
    let session: URLSession
    /// 后端共享密钥注入点。生产走 `AppSecrets.appSharedSecret`;URLProtocol-mocked 单测可传
    /// dummy secret,避免 clean checkout / CI 因缺少 gitignored xcconfig 而跳过测试。
    let appSharedSecret: String

    init(session: URLSession = .sharedRetrySession, appSharedSecret: String = AppSecrets.appSharedSecret) {
        self.session = session
        self.appSharedSecret = appSharedSecret
    }

    // MARK: - Public — 这一节的公开 API 已按职责拆分到子目录:
    //   summarize / analyzeMood / firstValidScore / extractThemes / embed → +OneShotAI.swift
    //   generateReportFromData / askEvents / streamReportEvents → +Streaming.swift
    //   claudeChat / claudeChatThrowing / makeAnthropicRequest → +Anthropic.swift
    //   judgeThemeAliases / scanThemeAliasGroups → +ThemeAlias.swift
    //   composeSuggestions / parseSuggestionBundle → +Suggestions.swift
    //   parseImportedDiaries → +Import.swift
    // wave11 拆分,主文件只保留共享基础设施(debouncedRequest / 类壳)。

    // MARK: - Core
    //
    // **2026-06-11 GPT→Claude 迁移**:旧 `chat()` / `chatThrowing()`(OpenAI chat/completions
    // 通路)已删 —— 全部业务调用切到 `claudeChat` / `claudeChatThrowing`(`+Anthropic.swift`,
    // 走 `/api/anthropic/messages`)或端上 `OnDeviceAIService`。embed()(`+OneShotAI.swift`)
    // 是唯一还打 OpenAI 端点的调用(Anthropic 无 embeddings API)。原实现保留在 git history。

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
    //   generateReportFromData / streamReportEvents / askEvents / streamClaudeChatEvents → +Streaming.swift
    //   claudeChat / claudeChatThrowing / makeAnthropicRequest / wire 类型 → +Anthropic.swift
    //   judgeThemeAliases / scanThemeAliasGroups / themeKey → +ThemeAlias.swift
    //   composeSuggestions / parseSuggestionBundle → +Suggestions.swift
    //   parseImportedDiaries → +Import.swift
    // 主文件保留:类壳 / stored state / debouncedRequest 共享底座。
}
