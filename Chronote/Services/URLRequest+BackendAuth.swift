import Foundation

/// 后端鉴权 / install identity header 统一入口。
///
/// **历史背景**:6 处 callsite(`OpenAIService.generateReportFromData / chat / chatThrowing /
/// embed / streamChatEvents` + `OpenAITranscriber.transcribeAudio`)各自重复:
/// ```
/// request.setValue(AppSecrets.appSharedSecret, forHTTPHeaderField: "X-App-Secret")
/// request.setValue(InstallIdentity.current,    forHTTPHeaderField: "X-Install-Id")
/// ```
/// 这是一笔小但反复出现的重复;以后改 header 名 / 加 header(签名机制升级 / `Authorization: Bearer`
/// 切换 / 加 client version header 给灰度判断)需要 6 处一起改,容易漏。
///
/// 这里抽统一入口。`Content-Type` / `Accept` / 业务 header(`Connection: keep-alive`,
/// `Cache-Control: no-cache`)各 callsite 自己管 —— 它们随业务变化(stream 用
/// `text/event-stream` / multipart 用 boundary)。
extension URLRequest {
    /// 给请求添加后端鉴权 + install id header。
    /// **不**改 `Content-Type` / `Accept` —— 调用方自己 set。
    mutating func applyBackendAuth() {
        setValue(AppSecrets.appSharedSecret, forHTTPHeaderField: "X-App-Secret")
        setValue(InstallIdentity.current, forHTTPHeaderField: "X-Install-Id")
    }
}
