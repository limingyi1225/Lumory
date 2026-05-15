import Foundation

// MARK: - NarrativeStreamAccumulator
//
// `NarrativePrecomputeService` 和 `NarrativeGenerationCoordinator` 都消费同一个
// `engine.streamNarrativeEvents` 的 `.chunk` / `.truncated` 事件序列,两边各 10 行重复
// 状态机(累 rawOutput + cap 守卫 + 翻 isIncomplete + 记 truncatedReason)。抽进这个
// 值类型一处维护:
//
//   - `.chunk` → 走 `NarrativeStreamLimits.append` cap 守卫,溢出自动翻 incomplete +
//     首次溢出时挂 `localTruncationReason`。
//   - `.truncated(reason)` → 服务器或上游显式截断,翻 incomplete + 覆盖 reason
//     (后到的服务器原因比本地 cap 的 fallback 准确)。
//
// **不管 `.failed` 和 `.done`** —— 两边语义故意不同:Precompute 失败立刻 abort + 记 backoff,
// Coordinator 把 error 字符串塞进 truncatedReason 继续等 `.done` 让 UI 看到失败原因。这部分
// 留给 caller 自己处理,不抽。

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
