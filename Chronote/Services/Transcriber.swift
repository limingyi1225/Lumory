import Foundation

// MARK: - Transcriber Contract
//
// 抽象化"音频文件 → 文本"。线上实现 `OpenAITranscriber`(走 Lumory 后端代理 OpenAI)。
//
// 历史:旧实现是 Apple `SFSpeechRecognizer` on-device 转写,中英混合 / 嘈杂环境
// 准确率明显低,2026-04 替换。

@MainActor
protocol TranscriberProtocol: AnyObject {
    var lastFailure: TranscriptionFailure? { get }
    /// - Parameter localeIdentifier: AppStorage `appLanguage` 原值(如 `zh-Hans` / `en`)。
    ///   实现内部决定如何映射给上游(对 OpenAI 通常忽略,让模型自动检测;以后要传就规范化成
    ///   ISO-639-1)。
    func transcribeAudio(fileURL: URL, localeIdentifier: String) async -> String?
}

/// 可重试 / 不可重试 / 致命:三档分类驱动 UI 决策(显示重试按钮还是冷处理)。
/// 实现 `Error` 让 `OpenAITranscriber.prepareUpload` 在后台 Task 里能直接 throw 它,
/// 上层 catch-as 不用再多包一层 wrapper enum。
enum TranscriptionFailure: Error, Equatable {
    /// 网络层断了 / TLS / DNS / 客户端超时。建议提示重试。
    case networkFailed
    /// 后端 / OpenAI 返回非 2xx。携带状态码,UI 自行翻译。
    case serverError(Int)
    /// 读取本地音频文件失败(被删 / 损坏 / 权限)。不可重试。
    case audioReadFailed
    /// 音频超出后端 25 MB 上限或时长太长。提示用户分段。
    case audioTooLarge
    /// 后端共享密钥未注入(xcconfig 配置错误)。开发期才该出现。
    case sharedSecretMissing

    /// 网络/服务端类错误可重试;读文件失败 / 超大 / 配置缺失不可重试。
    var isRetryable: Bool {
        switch self {
        case .networkFailed, .serverError:
            return true
        case .audioReadFailed, .audioTooLarge, .sharedSecretMissing:
            return false
        }
    }
}
