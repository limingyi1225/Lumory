import Foundation

/// 后端健康检查服务
@available(iOS 13.0, macOS 10.15, *)
class BackendHealthCheck {
    
    static func checkBackendConnection() async -> (isHealthy: Bool, message: String) {
        let url = URL(string: "\(AppSecrets.backendURL)/health")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10.0
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                switch httpResponse.statusCode {
                case 200:
                    if let responseString = String(data: data, encoding: .utf8) {
                        return (true, "Backend is healthy: \(responseString)")
                    } else {
                        return (true, "Backend is healthy (status 200)")
                    }
                case 404:
                    return (false, "Backend is running but health endpoint not found. Status: 404")
                default:
                    return (false, "Backend returned status: \(httpResponse.statusCode)")
                }
            } else {
                return (false, "Invalid response type")
            }
        } catch {
            if error.localizedDescription.contains("Could not connect to the server") {
                return (false, "Cannot connect to backend server at \(AppSecrets.backendURL)")
            } else if error.localizedDescription.contains("The request timed out") {
                return (false, "Backend server timeout - server may be down")
            } else {
                return (false, "Connection error: \(error.localizedDescription)")
            }
        }
    }
    
    static func testOpenAIProxy() async -> (isWorking: Bool, message: String) {
        // Test with a simple prompt
        let testRequest = OpenAITestRequest(
            model: "gpt-4.1-mini",
            messages: [Message(role: "user", content: "测试")],
            max_tokens: 10,
            temperature: 0.0
        )
        
        let url = URL(string: "\(AppSecrets.backendURL)/api/openai/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30.0
        
        print("[BackendHealthCheck] Testing proxy with URL: \(url)")
        
        do {
            let encoder = JSONEncoder()
            request.httpBody = try encoder.encode(testRequest)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                print("[BackendHealthCheck] Proxy test response:")
                print("  Status Code: \(httpResponse.statusCode)")
                print("  Headers: \(httpResponse.allHeaderFields)")
                
                let responseString = String(data: data, encoding: .utf8) ?? "Could not decode response"
                print("  Body: \(responseString)")
                
                switch httpResponse.statusCode {
                case 200:
                    return (true, "代理工作正常。响应: \(responseString.prefix(100))")
                case 401:
                    return (false, "后端代理认证失败 - 检查后端API密钥配置")
                case 404:
                    return (false, "后端代理端点未找到: /api/openai/chat/completions")
                case 502:
                    return (false, "后端网关错误(502) - 服务器可能临时不可用")
                case 503:
                    return (false, "后端服务暂时不可用(503)")
                case 504:
                    return (false, "后端网关超时(504)")
                case 500...599:
                    return (false, "后端服务器错误(\(httpResponse.statusCode)): \(responseString.prefix(100))")
                default:
                    return (false, "后端返回状态 \(httpResponse.statusCode): \(responseString.prefix(100))")
                }
            } else {
                return (false, "无效的响应类型")
            }
        } catch {
            let errorDesc = error.localizedDescription
            print("[BackendHealthCheck] Proxy test error: \(errorDesc)")
            
            if errorDesc.contains("Could not connect to the server") {
                return (false, "无法连接到后端服务器 - 服务器可能离线")
            } else if errorDesc.contains("The request timed out") {
                return (false, "请求超时 - 服务器响应缓慢")
            } else {
                return (false, "测试请求失败: \(errorDesc)")
            }
        }
    }
    
    private struct OpenAITestRequest: Codable {
        let model: String
        let messages: [Message]
        let max_tokens: Int
        let temperature: Double
    }
    
    private struct Message: Codable {
        let role: String
        let content: String
    }
}