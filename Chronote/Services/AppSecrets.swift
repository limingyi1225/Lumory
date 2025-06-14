import Foundation

enum AppSecrets {
    // 在生产应用中请将此 Key 存放于 Keychain / iCloud Key-Value / Remote Config 等安全位置。
    // 请确保这个 OpenRouter API 密钥是有效的并且有足够的余额
    
    /// 本地后端代理的基础 URL
    static let backendURL = "http://64.176.209.155:3000"
    
    /// OpenAI API Key，用于音频转录等功能，若不使用可留空
    static let openAIKey = "REDACTED_API_KEY"
    
    /// 检查后端代理地址是否已配置
    static var isValidKey: Bool { !backendURL.isEmpty }
}
