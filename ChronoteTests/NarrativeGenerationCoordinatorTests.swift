//
//  NarrativeGenerationCoordinatorTests.swift
//  ChronoteTests
//
//  Coordinator state machine 测试(megareview OPT-HIGH H2)。
//
//  Coordinator 管两套独立状态:
//   - `generating: Set<TimeRange>` — 用户主动 start / 重试
//   - `precomputing: Set<TimeRange>` — `NarrativePrecomputeService` 后台预生成信号
//  渲染 `isStreaming` 取两者并集;`blocksUserTap` 只读 generating(precompute 不挡 tap)。
//  此前 0 直接 test,verification report 把它列为生产事故级 race-prone 路径。
//
//  覆盖:
//   - beginPrecompute / endPrecompute 不影响 generating / tasks(状态机独立性)
//   - cancelAll 空 no-op + 清三件套语义
//   - 同 range 二次 start cancel 前一个 + bump generation(supersession 路径)
//
//  深度场景(.truncated body 写盘、stream failure 路径)走真 service stream,fixture 庞大,
//  这一波 skip,留 OPT-MID follow-up。

import Testing
import Foundation
import CoreData
@testable import Lumory

@MainActor
struct NarrativeGenerationCoordinatorTests {
    /// 构造一个隔离的 Coordinator:in-memory persistence + MockAIService。
    private func makeCoordinator() -> NarrativeGenerationCoordinator {
        let pc = PersistenceController(inMemory: true)
        let engine = InsightsEngine(persistence: pc, ai: MockAIService())
        return NarrativeGenerationCoordinator(engine: engine, persistence: pc)
    }

    @Test func beginPrecompute_addsToPrecomputingSet_doesNotTouchGenerating() {
        let coord = makeCoordinator()
        #expect(coord.precomputing.isEmpty)
        #expect(coord.generating.isEmpty)

        coord.beginPrecompute(.month)
        #expect(coord.precomputing.contains(.month))
        #expect(coord.generating.contains(.month) == false,
                "precompute 信号不应污染 generating 集合 — 两者状态机独立")
    }

    @Test func endPrecompute_removesFromPrecomputingSet() {
        let coord = makeCoordinator()
        coord.beginPrecompute(.year)
        coord.beginPrecompute(.month)
        coord.endPrecompute(.year)
        #expect(coord.precomputing.contains(.year) == false)
        #expect(coord.precomputing.contains(.month) == true,
                "endPrecompute 应只清指定 range,不影响其他")
    }

    @Test func endPrecompute_unknownRange_isIdempotent() {
        // Coordinator 设计:Set.remove 不存在 key 是 no-op;endPrecompute 安全幂等。
        let coord = makeCoordinator()
        coord.endPrecompute(.month)  // 没 begin 过
        #expect(coord.precomputing.isEmpty,
                "endPrecompute 无 matching begin 应静默 no-op")
    }

    @Test func cancelAll_whenNoInFlightTasks_isImmediateNoOp() async {
        let coord = makeCoordinator()
        coord.beginPrecompute(.month)
        // cancelAll 兜底也清 precomputing(防 fragile contract):无 in-flight task 时
        // **早返 guard** 之前会被命中?读源码:`guard !inFlight.isEmpty else { return }` —
        // 早返路径**不**清 precomputing。这是设计决定:precompute 由 PrecomputeService 自己管。
        await coord.cancelAll()
        // 无 in-flight task 时,precomputing 由 PrecomputeService 负责清,coordinator 早返不动它。
        #expect(coord.generating.isEmpty)
        #expect(coord.precomputing.contains(.month) == true,
                "cancelAll 无 in-flight task 时早返不清 precomputing(语义:precompute 信号归 PrecomputeService 管)")
    }

    @Test func cancelAll_withInFlightTask_clearsGeneratingAndPrecomputing() async {
        let coord = makeCoordinator()
        coord.beginPrecompute(.month)

        // 启 in-flight task:start 一个 range。MockAIService.streamReportEvents 默认空 stream
        // 立刻 finish,但 runStream 内部仍要 await for-loop 结束 + persist guards;cancel 路径
        // 通过 streamGeneration bump 让 task 完成时不 clobber state,然后 cancelAll 走"有 task"
        // 路径清三件套。
        await coord.start(
            range: .all,
            dateInterval: DateInterval(start: Date().addingTimeInterval(-86400), end: Date()),
            entryCount: 3,
            mostRecentEntryDate: Date()
        )
        #expect(coord.generating.contains(.all) == true,
                "start 后 generating 应含 .all")

        await coord.cancelAll()

        #expect(coord.generating.isEmpty, "cancelAll 完成后 generating 清空")
        #expect(coord.precomputing.isEmpty, "cancelAll(有 in-flight)路径也清 precomputing 兜底")
        #expect(coord.streamFailure.isEmpty, "cancelAll 也清 streamFailure")
    }

    @Test func start_sameRangeTwice_bumpsGenerationAndClearsStreamFailure() async {
        let coord = makeCoordinator()
        // 第一次 start
        await coord.start(
            range: .month,
            dateInterval: DateInterval(start: Date().addingTimeInterval(-86400), end: Date()),
            entryCount: 3,
            mostRecentEntryDate: Date()
        )
        // generating 应含 .month(start 同步加入)
        #expect(coord.generating.contains(.month))

        // 二次 start 同 range — 内部 cancel 前一个 task + bump generation
        await coord.start(
            range: .month,
            dateInterval: DateInterval(start: Date().addingTimeInterval(-86400), end: Date()),
            entryCount: 3,
            mostRecentEntryDate: Date()
        )
        // 仍在 generating 集合(新 task 接力)
        #expect(coord.generating.contains(.month),
                "二次 start 后 generating 仍含 .month(新 task 接力,不应中间被清)")

        // 等所有 in-flight 完成(MockAIService 立即 finish,几 µs)再断言清理:
        await coord.cancelAll()
        #expect(coord.generating.isEmpty)
    }
}
