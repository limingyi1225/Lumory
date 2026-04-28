import Foundation

/// 把后端代理(`/api/openai/*`)的失败统一翻成本地化 `NSError`。
///
/// 原本这两个 helper 是 `OpenAIService` 的 fileprivate 方法。新增 `OpenAITranscriber`
/// 走相同的鉴权 + 状态码语义,把它们抽到一个共享 namespace,避免改 internal 把
/// `OpenAIService` 内部细节渗出去。后续新代理路由也复用这一套。
enum BackendErrorMapper {
    /// HTTP 状态码 → 本地化 NSError(domain: BackendError)。
    /// 复用 `error.backend.*` 现有翻译键,所有路由共享一份文案。
    static func error(forStatus statusCode: Int, retryAfter: String? = nil) -> NSError {
        let message: String
        switch statusCode {
        case 401:
            message = NSLocalizedString("error.backend.auth", comment: "Backend auth failed")
        case 404:
            message = String(
                format: NSLocalizedString("error.backend.notFound", comment: "Backend endpoint not found"),
                AppSecrets.backendURL
            )
        case 413:
            message = NSLocalizedString("error.backend.payloadTooLarge", comment: "413 payload too large")
        case 429:
            message = NSLocalizedString("error.backend.rateLimited", comment: "Rate limited")
        case 502:
            message = NSLocalizedString("error.backend.badGateway", comment: "502 bad gateway")
        case 503:
            message = NSLocalizedString("error.backend.unavailable", comment: "503 unavailable")
        case 504:
            message = NSLocalizedString("error.backend.timeout", comment: "504 timeout")
        case 500...599:
            message = String(format: NSLocalizedString("error.backend.server5xx", comment: "Generic 5xx"), statusCode)
        default:
            message = String(format: NSLocalizedString("error.backend.generic", comment: "Generic backend error"), statusCode)
        }
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: message]
        if let retryAfter {
            userInfo["Retry-After"] = retryAfter
        }
        return NSError(domain: "BackendError", code: statusCode, userInfo: userInfo)
    }

    /// xcconfig 注入失败 → AppSecrets.appSharedSecret 为空,直接断言式失败,不发请求。
    static func missingSharedSecretError() -> NSError {
        NSError(
            domain: "BackendError",
            code: 401,
            userInfo: [NSLocalizedDescriptionKey: "Backend shared secret not configured (xcconfig injection failed)."]
        )
    }
}
