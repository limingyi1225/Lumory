import Foundation

// MARK: - Network Retry Helper

struct NetworkRetryHelper {
    static let maxRetries = 3
    static let retryDelay: TimeInterval = 1.0
    static let maxRetryDelay: TimeInterval = 8.0

    /// Execute a network request with automatic retry on SSL/network errors.
    /// 指数回退 (1s → 2s → 4s, cap at maxRetryDelay)，避免 3× 平推在短 2s 内把下游打死。
    static func performWithRetry<T>(
        maxRetries: Int = maxRetries,
        retryDelay: TimeInterval = retryDelay,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        var lastError: Error?

        for attempt in 0..<maxRetries {
            do {
                return try await operation()
            } catch {
                lastError = error

                // Check if it's a retryable error
                if isRetryableError(error) && attempt < maxRetries - 1 {
                    // Exponential backoff: 1s, 2s, 4s, ... capped at maxRetryDelay
                    let backoff = min(retryDelay * pow(2.0, Double(attempt)), maxRetryDelay)
                    Log.error("[NetworkRetryHelper] Attempt \(attempt + 1) failed: \(error.localizedDescription). Retrying in \(backoff)s...", category: .network)
                    try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                } else {
                    throw error
                }
            }
        }

        throw lastError ?? NSError(domain: "NetworkRetryHelper", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown error after retries"])
    }
    
    /// Check if an error is retryable (SSL, timeout, network issues, server errors)
    private static func isRetryableError(_ error: Error) -> Bool {
        let nsError = error as NSError
        
        // Check HTTP status codes for retryable server errors
        if nsError.domain == "OpenAIService" {
            switch nsError.code {
            case 429: // Rate limited —— 我们自己的后端 limiter 或 OpenAI 的都可能返这个。
                // 以前没列为 retryable，backfill 撞到 429 就静默丢 entry，Ask Past / 搜索缺失。
                // 列为可重试；指数回退（1s→2s→4s）足够等窗口滑过一半。
                Log.error("[NetworkRetryHelper] 429 rate limited —— 可重试", category: .network)
                return true
            case 502, 503, 504: // Bad Gateway, Service Unavailable, Gateway Timeout
                Log.error("[NetworkRetryHelper] 检测到可重试的服务器错误: \(nsError.code)", category: .network)
                return true
            case 500...599: // Other 5xx server errors (but be more conservative)
                let shouldRetry = nsError.code != 501 // Not Implemented is not retryable
                Log.error("[NetworkRetryHelper] 服务器错误 \(nsError.code)，可重试: \(shouldRetry)", category: .network)
                return shouldRetry
            default:
                break
            }
        }
        
        // SSL errors
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorSecureConnectionFailed,
                 NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid,
                 NSURLErrorClientCertificateRejected,
                 NSURLErrorClientCertificateRequired,
                 NSURLErrorCannotLoadFromNetwork,
                 NSURLErrorTimedOut,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorDNSLookupFailed:
                return true
            case -1200: // kCFURLErrorSecureConnectionFailed
                return true
            default:
                break
            }
        }
        
        // CFNetwork errors
        if nsError.domain == kCFErrorDomainCFNetwork as String {
            return true
        }
        
        return false
    }
}

// MARK: - URLSession Extension for Better SSL Handling

extension URLSession {
    /// SSL-tolerant session for the AI backend proxy.
    ///
    /// **`static let` not `static var`**：以前是 computed property，每次访问都 new 一个 URLSession
    /// 且从不 invalidate。日记保存 = 3 次 AI 请求，每次 new 一个 session → 持续累积 OS-level
    /// socket handle + 后台线程 + DNS 缓存，长会话下泄漏可观；同时绕过系统连接池白白增加延迟。
    /// 换成 `static let` 确保进程内只一个实例复用。
    static let sslTolerantSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30.0
        // **timeoutIntervalForResource 是整个资源传输的总 deadline**，不是每次读超时。
        // 原值 60s 会在长 SSE 流（gpt-5.4 写 800 字中文报告要 60-90s）中途被 URLSession 掐掉。
        // 拉长到 300s，给长流式响应留余量。
        configuration.timeoutIntervalForResource = 300.0
        configuration.waitsForConnectivity = true

        // Allow cellular access
        configuration.allowsCellularAccess = true

        // Increase tolerance for poor network conditions
        #if !os(macOS)
        configuration.multipathServiceType = .handover
        #endif

        return URLSession(configuration: configuration)
    }()
}

