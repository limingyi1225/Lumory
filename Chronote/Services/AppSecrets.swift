import Foundation

enum AppSecrets {
    /// Lumory backend 的基础 URL（HTTPS，经 Cloudflare 代理到 origin）。
    /// 架构：iPhone → Cloudflare edge (公共 cert) → origin nginx :443 (self-signed, 自动接受)
    /// → Node :3000。老的 `http://<ip>:3000` 已废弃——明文传输 secret + 日记正文不可接受。
    static let backendURL = "https://lumory.isaabby.com"

    /// 客户端与后端代理之间的共享密钥。必须和 `server/.env` 里的 `APP_SHARED_SECRET` 一致。
    /// 每次访问 `/api/*` 都要在 `X-App-Secret` header 里带上，否则后端拒绝。
    /// 下一步应该迁到 Xcode xcconfig / CI secret injection，避免硬编码入 git。
    /// NOTE: 上一版 secret 在 plain HTTP 时代传输过，已在 server 端作废轮换，此值是新生成的。
    static let appSharedSecret = "l3Sp+bzv29c6KxUIfR997UXgycQd4fRnrWlBRXi1HJX0h8DVPX4erbOerqzXkdTu"

    /// OpenAI API Key，用于音频转录等功能，若不使用可留空
    static let openAIKey = ""

    /// 检查后端代理地址是否已配置
    static var isValidKey: Bool { !backendURL.isEmpty }
}
