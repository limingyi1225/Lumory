import Foundation

// MARK: - NarrativeStreamAccumulator
//
// `NarrativePrecomputeService` 和 `NarrativeGenerationCoordinator` 共用的 `.chunk` /
// `.truncated` 折叠器。**故意不管 `.failed` 和 `.done`** —— 两边语义不同:Precompute 失败
// 立刻 abort + 记 backoff(后台静默);Coordinator 把 error 塞 truncatedReason 继续等
// `.done`(UI 要看到失败原因)。这部分留给 caller 自己写。

struct NarrativeStreamAccumulator {
    private(set) var rawOutput: String = ""
    private(set) var isIncomplete: Bool = false
    private(set) var truncatedReason: String?

    /// 处理一个 `.chunk` event。返回值仅用于测试断言;生产 caller 不需要看。
    @discardableResult
    mutating func appendChunk(_ text: String) -> Bool {
        let didCap = NarrativeStreamLimits.append(text, to: &rawOutput)
        if didCap {
            isIncomplete = true
            if truncatedReason == nil {
                truncatedReason = NarrativeStreamLimits.localTruncationReason
            }
        }
        return didCap
    }

    /// 处理 `.truncated(reason)` event。reason 直接覆盖(服务器原因比本地 cap fallback 准)。
    /// **空字符串当 "没传"**:reason 来自不受信外部(SSE 服务器 / `Error.localizedDescription`),
    /// 万一上游真发了空字符串,继续把 isIncomplete 翻 true 但**不**覆盖既有 reason(也不
    /// 写空字符串当 reason),防止 UI 渲染空白失败 banner。
    mutating func markTruncated(reason: String) {
        isIncomplete = true
        if !reason.isEmpty {
            truncatedReason = reason
        }
    }
}
