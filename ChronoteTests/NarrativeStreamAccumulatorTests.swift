//
//  NarrativeStreamAccumulatorTests.swift
//  ChronoteTests
//
//  `NarrativeStreamAccumulator` 是 `NarrativePrecomputeService` 和
//  `NarrativeGenerationCoordinator` 共用的 .chunk / .truncated 折叠器。纯值类型,
//  不依赖 actor / engine / persistence,可纯函数式测试每个分支。
//
//  覆盖:
//  - 初始态
//  - appendChunk 不溢出 / 溢出 cap / 多次溢出 nil-guard 守卫
//  - markTruncated 正常 reason / 空字符串防御 / reason 覆盖优先级
//

import Testing
import Foundation
@testable import Lumory

struct NarrativeStreamAccumulatorTests {

    // MARK: - 初始态

    @Test func initialState_isEmpty() {
        let acc = NarrativeStreamAccumulator()
        #expect(acc.rawOutput.isEmpty)
        #expect(acc.isIncomplete == false)
        #expect(acc.truncatedReason == nil)
    }

    // MARK: - appendChunk

    @Test func appendChunk_smallText_accumulatesWithoutCap() {
        var acc = NarrativeStreamAccumulator()
        let didCap1 = acc.appendChunk("hello ")
        let didCap2 = acc.appendChunk("world")
        #expect(didCap1 == false)
        #expect(didCap2 == false)
        #expect(acc.rawOutput == "hello world")
        #expect(acc.isIncomplete == false)
        #expect(acc.truncatedReason == nil)
    }

    @Test func appendChunk_overflowsCap_marksIncompleteWithLocalReason() {
        var acc = NarrativeStreamAccumulator()
        let overflow = String(repeating: "a", count: NarrativeStreamLimits.rawOutputCharacterLimit + 100)
        let didCap = acc.appendChunk(overflow)
        #expect(didCap == true)
        #expect(acc.rawOutput.count == NarrativeStreamLimits.rawOutputCharacterLimit)
        #expect(acc.isIncomplete == true)
        #expect(acc.truncatedReason == NarrativeStreamLimits.localTruncationReason)
    }

    @Test func appendChunk_repeatedOverflow_keepsFirstReason() {
        var acc = NarrativeStreamAccumulator()
        let overflow = String(repeating: "a", count: NarrativeStreamLimits.rawOutputCharacterLimit + 10)
        _ = acc.appendChunk(overflow)
        let firstReason = acc.truncatedReason
        // 再来一次溢出,nil-guard 应该挡住覆盖
        _ = acc.appendChunk("more text after cap")
        #expect(acc.truncatedReason == firstReason)
        #expect(acc.isIncomplete == true)
    }

    /// (2026-05-15 superreview-4 P2)Emoji case —— 锁住 `appendChunk` 的 cap 单位语义
    /// 是 `String.count`(grapheme cluster),不是 `utf8.count` / `unicodeScalars.count`。
    /// 单字节 ASCII("a")测试这一项凑巧三种实现都过,emoji(每个 grapheme 占 4 UTF-8 字节)
    /// 才能真正分辨。如果以后有人把 cap 改成 byte-based,这条 test 会立刻 fail。
    @Test func appendChunk_overflowsCap_emojiUsesGraphemeUnit() {
        var acc = NarrativeStreamAccumulator()
        let limit = NarrativeStreamLimits.rawOutputCharacterLimit
        // 每个 🌸 = 1 grapheme(2 UTF-16 / 4 UTF-8)。送 limit+10 个 grapheme。
        let overflow = String(repeating: "🌸", count: limit + 10)
        let didCap = acc.appendChunk(overflow)
        #expect(didCap == true)
        #expect(acc.rawOutput.count == limit, "cap 单位必须是 grapheme,实际 count=\(acc.rawOutput.count) limit=\(limit)")
        #expect(acc.isIncomplete == true)
        #expect(acc.truncatedReason == NarrativeStreamLimits.localTruncationReason)
    }

    @Test func appendChunk_emptyString_isNoop() {
        var acc = NarrativeStreamAccumulator()
        let didCap = acc.appendChunk("")
        #expect(didCap == false)
        #expect(acc.rawOutput.isEmpty)
        #expect(acc.isIncomplete == false)
    }

    /// (round-5 D9)overflow 后再来空 chunk:state 不动,truncatedReason 仍是 cap fallback。
    /// 防 future 优化让"空 chunk 重置 isIncomplete"等边角 bug。
    @Test func appendChunkOverflow_thenEmptyChunk_isNoop() {
        var acc = NarrativeStreamAccumulator()
        let limit = NarrativeStreamLimits.rawOutputCharacterLimit
        let overflow = String(repeating: "a", count: limit + 10)
        _ = acc.appendChunk(overflow)
        let stateBeforeEmpty = (
            rawOutput: acc.rawOutput,
            isIncomplete: acc.isIncomplete,
            truncatedReason: acc.truncatedReason
        )

        let didCap = acc.appendChunk("")
        #expect(didCap == false, "空 chunk 不算 cap 触发")
        #expect(acc.rawOutput == stateBeforeEmpty.rawOutput, "空 chunk 不动 rawOutput")
        #expect(acc.isIncomplete == stateBeforeEmpty.isIncomplete, "空 chunk 不动 isIncomplete")
        #expect(acc.truncatedReason == stateBeforeEmpty.truncatedReason, "空 chunk 不动 truncatedReason")
    }

    // MARK: - markTruncated

    @Test func markTruncated_normalReason_setsBothFlags() {
        var acc = NarrativeStreamAccumulator()
        acc.markTruncated(reason: "server timeout")
        #expect(acc.isIncomplete == true)
        #expect(acc.truncatedReason == "server timeout")
    }

    @Test func markTruncated_emptyReason_flipsIncompleteButKeepsReasonNil() {
        // 防御 fix: SSE / Error.localizedDescription 万一传 "",
        // 不要把 truncatedReason 写成 "" 导致 UI 渲染空白失败 banner。
        var acc = NarrativeStreamAccumulator()
        acc.markTruncated(reason: "")
        #expect(acc.isIncomplete == true)
        #expect(acc.truncatedReason == nil)
    }

    @Test func markTruncated_emptyAfterRealReason_doesNotClobber() {
        // 已有真实 reason 时,后到的空字符串不应该把它清掉。
        var acc = NarrativeStreamAccumulator()
        acc.markTruncated(reason: "real reason")
        acc.markTruncated(reason: "")
        #expect(acc.truncatedReason == "real reason")
        #expect(acc.isIncomplete == true)
    }

    // MARK: - 状态交互

    @Test func markTruncated_thenAppendChunkOverflow_keepsServerReason() {
        // 服务器原因比本地 cap fallback 准 —— 先到的 .truncated 写入的 reason
        // 不应被随后的 appendChunk 溢出覆盖(appendChunk 内部有 nil-guard)。
        var acc = NarrativeStreamAccumulator()
        acc.markTruncated(reason: "stopped by server")
        let overflow = String(repeating: "a", count: NarrativeStreamLimits.rawOutputCharacterLimit + 10)
        _ = acc.appendChunk(overflow)
        #expect(acc.truncatedReason == "stopped by server")
        #expect(acc.isIncomplete == true)
    }

    @Test func appendChunkOverflow_thenMarkTruncated_serverReasonOverrides() {
        // 本地先溢出挂 fallback,随后服务器明确给 reason 应当覆盖 fallback
        // (注释里说"服务器原因比本地 cap fallback 准")。
        var acc = NarrativeStreamAccumulator()
        let overflow = String(repeating: "a", count: NarrativeStreamLimits.rawOutputCharacterLimit + 10)
        _ = acc.appendChunk(overflow)
        #expect(acc.truncatedReason == NarrativeStreamLimits.localTruncationReason)
        acc.markTruncated(reason: "context length exceeded")
        #expect(acc.truncatedReason == "context length exceeded")
    }
}
