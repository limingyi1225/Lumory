import Foundation

// MARK: - Network Retry Helper

struct NetworkRetryHelper {
    static let maxRetries = 3
    static let retryDelay: TimeInterval = 1.0
    
    /// Execute a network request with automatic retry on SSL/network errors
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
                    print("[NetworkRetryHelper] Attempt \(attempt + 1) failed with error: \(error.localizedDescription). Retrying in \(retryDelay) seconds...")
                    try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
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
            case 502, 503, 504: // Bad Gateway, Service Unavailable, Gateway Timeout
                print("[NetworkRetryHelper] 检测到可重试的服务器错误: \(nsError.code)")
                return true
            case 500...599: // Other 5xx server errors (but be more conservative)
                let shouldRetry = nsError.code != 501 // Not Implemented is not retryable
                print("[NetworkRetryHelper] 服务器错误 \(nsError.code)，可重试: \(shouldRetry)")
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
    /// Create a session with relaxed SSL validation for development/testing
    /// WARNING: Only use this for trusted endpoints like OpenRouter
    static var sslTolerantSession: URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30.0
        configuration.timeoutIntervalForResource = 60.0
        configuration.waitsForConnectivity = true
        
        // Allow cellular access
        configuration.allowsCellularAccess = true
        
        // Increase tolerance for poor network conditions
        #if !os(macOS)
        configuration.multipathServiceType = .handover
        #endif
        
        return URLSession(configuration: configuration)
    }
}

