import Foundation

enum AppSecrets {
    /// Lumory backend 的基础 URL（HTTPS，经 Cloudflare 代理到 origin）。
    /// 架构：iPhone → Cloudflare edge (公共 cert) → origin nginx :443 (self-signed, 自动接受)
    /// → Node :3000。
    static let backendURL = "https://lumory.isaabby.com"

    /// 客户端与后端代理之间的共享密钥。必须和 `server/.env` 里的 `APP_SHARED_SECRET` 一致。
    /// 每次访问 `/api/*` 都要在 `X-App-Secret` header 里带上，否则后端拒绝。
    ///
    /// **读取方式**：Info.plist 的 `APP_SHARED_SECRET` 键，由 Xcode build settings 的
    /// `INFOPLIST_KEY_APP_SHARED_SECRET = $(APP_SHARED_SECRET)` 从 xcconfig 注入。
    /// 真实值在 `Lumory.local.xcconfig`（已 gitignore，不进仓库）。
    /// 首次 clone 仓库后的 setup：
    /// 1. `cp Lumory.local.xcconfig.sample Lumory.local.xcconfig`
    /// 2. 填入 `APP_SHARED_SECRET` 真实值
    /// 3. Xcode → Lumory project → Info → Configurations → Debug/Release 都选 `Lumory.xcconfig`
    ///
    /// 故意**没有**硬编码 fallback。之前的硬编码方案导致密钥进公开 git 历史 → 等于没轮换。
    /// 宁可让 App 以 401 失败得刺眼，也不让密钥再一次泄漏。
    static let appSharedSecret: String = {
        if let value = Bundle.main.object(forInfoDictionaryKey: "APP_SHARED_SECRET") as? String,
           !value.isEmpty,
           !value.hasPrefix("$(") {
            return value
        }
        #if DEBUG
        Log.error(
            "[AppSecrets] APP_SHARED_SECRET missing from Info.plist. 后端会返 401。"
            + " 配置步骤见 AppSecrets.swift 顶部注释或 Lumory.local.xcconfig.sample。",
            category: .general
        )
        #endif
        return ""
    }()
}
