import Foundation
import CoreData

// MARK: - NarrativeGenerationCoordinator
//
// 用户在 InsightsView 主动点「生成回顾」/「重试」时的 narrative 生成生命周期 owner。
//
// **为什么从 NarrativeSummaryCard 抬出来**:原本生成的 Task + streaming 状态全锁在卡片的
// `@State` 里,作用域 =「该 view 实例 × 该 range」。切 TimeRange → 卡片 `.task(id: range)`
// 直接 cancel 在飞 stream;关 Insights sheet → 卡片销毁,streaming 状态丢失(后台 Task 靠
// 闭包捕获 @State box 苟活、能跑完 persist,但新卡片 @State 全新、`isStreaming=false`,重开
// 看到「生成回顾」CTA 像没生成过,用户再点一次就双开流)。把 Task + 状态搬进这个
// `@MainActor @Observable` 单例后:切 range / 关 sheet 都不打断;卡片退化成观察者,读
// `generating` / `streamFailure` 渲染状态机,生成结果走 CoreData save → 卡片 onChange /
// onReceive 回灌。
//
// **跟 NarrativePrecomputeService 的分工**:Precompute 是写日记后 8s debounce 的**后台
// 自动**预生成(只 .month);本 coordinator 是**用户主动触发**(任意 range)。两者 persist
// 到同一张 AIConversation 表 —— coordinator 在 persist 前 `await
// NarrativePrecomputeService.shared.cancelPendingAndBumpGeneration()` 去重,跟原
// `NarrativeSummaryCard.persistNarrativeIfNeeded` 行为一致。清缓存 / 删日记的入口
// (`EntryWipeOrchestrator.performBulkWipeCleanup` / `SettingsEntryDeletionService` /
// `AdvancedSettingsView.resetNarrativeCache`)同时调 `cancelAll()` 把两个 service 一起停掉,
// 杜绝在飞 task 在 record 删除后又写回。
//
// **race / supersession**:per-range `streamGeneration` 世代号(不用 Task self-reference,
// 见 CLAUDE.md「Race-prevention 用世代号别用 var task: Task! self-reference」)。同 range 再
// `start` → bump 世代号 + cancel 旧 Task,旧 Task 在每个 await 边界比对世代号,不等就丢弃不
// 写盘。不同 range 各自独立世代号,可并行生成。

@MainActor
@Observable
final class NarrativeGenerationCoordinator {
    /// 一次失败 / 截断且**没产出可持久化 body** 的记录。`occurredAt` 让卡片能判断「之后有
    /// 更新的 cache 写进来了(用户重试成功 / precompute 后台补上)」→ 失败标记作废。
    struct StreamFailure: Equatable {
        let reason: String
        let occurredAt: Date
    }

    private struct PersistRequest {
        let range: TimeRange
        let dateInterval: DateInterval
        let entryCount: Int
        let mostRecentEntryDate: Date?
        let generation: Int
        let streamStartTime: Date
        let rawOutput: String
        let isIncomplete: Bool
        let truncatedReason: String?
        let citedEntryIds: [UUID]
    }

    static let shared = NarrativeGenerationCoordinator(
        engine: .shared,
        persistence: .shared
    )

    /// 用户主动 start 在飞的 range。卡片读这个渲染 skeleton + spark 呼吸,tap / 重试按钮逻辑也只看它。
    private(set) var generating: Set<TimeRange> = []

    /// 后台 `NarrativePrecomputeService` 在飞的 range(写日记后 debounce + stream 期间)。卡片
    /// 渲染 `isStreaming` 时把它跟 `generating` 取并集,这样用户写完立刻进 Insights 就能看到
    /// shimmer,不必等 silent precompute 走完才"突然"出结果。**只**影响视觉(skeleton + tap
    /// 屏蔽),tap 走的 startGeneration / cancelAll 等业务路径不读它 —— 用户主动重试和后台
    /// 预生成的 cancel 语义不同,混在一起会让 cancelAll 误伤 precompute task。
    private(set) var precomputing: Set<TimeRange> = []

    /// 生成失败且无可持久化 body 的 range → 失败信息。卡片读这个渲染 streamFailedView /
    /// incompleteFooter。成功 persist(哪怕 incomplete payload)→ 清空,incomplete 状态改由
    /// 持久化的 payload.isIncomplete 携带。
    private(set) var streamFailure: [TimeRange: StreamFailure] = [:]

    private let engine: InsightsEngine
    private let persistence: PersistenceController

    /// per-range 在飞 Task。同 range 再 start 先 cancel 旧的。
    @ObservationIgnored private var tasks: [TimeRange: Task<Void, Never>] = [:]
    /// per-range supersession 世代号。
    @ObservationIgnored private var streamGeneration: [TimeRange: Int] = [:]

    init(engine: InsightsEngine, persistence: PersistenceController) {
        self.engine = engine
        self.persistence = persistence
    }

    // MARK: - Public

    /// 卡片点「生成回顾」/「重试」时调。同 range 已有在飞 task → 当「重试」cancel 旧的再起。
    /// **不阻塞**;结果走 CoreData save 回灌卡片(卡片 onChange(isStreaming) / onReceive)。
    func start(
        range: TimeRange,
        dateInterval: DateInterval,
        entryCount: Int,
        mostRecentEntryDate: Date?
    ) async {
        let supersededTask = tasks[range]
        if let supersededTask {
            supersededTask.cancel()
        }
        streamGeneration[range, default: 0] &+= 1
        let generation = streamGeneration[range]!
        let streamStartTime = Date()

        generating.insert(range)
        streamFailure[range] = nil

        let task = Task { @MainActor in
            if let supersededTask {
                // Wait for the old stream to observe cancellation before starting the replacement.
                // Otherwise two streams for the same range can race to write the same cache slot.
                await supersededTask.value
                guard self.isCurrent(range, generation) else { return }
            }
            await self.runStream(
                range: range,
                dateInterval: dateInterval,
                entryCount: entryCount,
                mostRecentEntryDate: mostRecentEntryDate,
                generation: generation,
                streamStartTime: streamStartTime
            )
            // 自家清自家:仅当世代号仍是自己才清 generating / tasks。被更新的 start 或
            // cancelAll bump 过 → 留给它们清,不 clobber。
            if self.streamGeneration[range] == generation {
                self.generating.remove(range)
                self.tasks[range] = nil
            }
        }
        tasks[range] = task
    }

    /// `NarrativePrecomputeService` 把"我在替你后台预生成"信号 broadcast 给卡片用。卡片
    /// `isStreaming` 取 `generating ∪ precomputing`,语义并到一个 UI 状态。**不**走 tasks /
    /// streamGeneration —— precompute 的 cancel 语义归 Precompute 自己管,coordinator 只是
    /// 信号桥。supersede / 完成时 PrecomputeService 主动调 `endPrecompute(range)` 清掉。
    func beginPrecompute(_ range: TimeRange) {
        precomputing.insert(range)
    }

    func endPrecompute(_ range: TimeRange) {
        precomputing.remove(range)
    }

    /// 清 AI 回顾缓存 / 删日记入口调:cancel + bump 所有在飞生成,**await 它们完整退出**后
    /// 返回 —— 跟 `NarrativePrecomputeService.cancelPendingAndBumpGeneration` 同语义,确保
    /// 调用方接着删 record 时没有在飞 task 会在删后写回。幂等(无在飞 task 直接返回)。
    func cancelAll() async {
        let inFlight = tasks
        guard !inFlight.isEmpty else { return }
        for range in inFlight.keys {
            streamGeneration[range, default: 0] &+= 1
        }
        for task in inFlight.values {
            task.cancel()
        }
        tasks.removeAll()
        generating.removeAll()
        streamFailure.removeAll()
        // 防 fragile contract:当前所有 cancelAll callsite 都成对调 `Precompute.cancelPendingAndBumpGeneration`
        // (那条内部清 .month precomputing),但未来新增 callsite 忘配套调 → shimmer 残留。
        // 兜底清,跟 generating.removeAll() 语义对齐。
        precomputing.removeAll()
        for task in inFlight.values {
            await task.value
        }
    }

    // MARK: - Private

    private func isCurrent(_ range: TimeRange, _ generation: Int) -> Bool {
        streamGeneration[range] == generation
    }

    private func runStream(
        range: TimeRange,
        dateInterval: DateInterval,
        entryCount: Int,
        mostRecentEntryDate: Date?,
        generation: Int,
        streamStartTime: Date
    ) async {
        // wave15 idiom — 累 rawOutput,done 后 NarrativeStreamSplitter 一次 split。
        // `.chunk` / `.truncated` 状态机抽进 `NarrativeStreamAccumulator`,与 precompute 共享。
        // `.failed` 在这里把 error 字符串塞 accumulator 然后 `break streamLoop` 退出(它是
        // terminal event,服务器不会再 yield .done)。后续 `persistIfNeeded` 根据 body 是否
        // 空决定 → 挂 streamFailure(用户看失败 banner)还是写盘 + isIncomplete(部分内容)。
        // 跟 precompute 的"立刻 return + 记 backoff"语义有意识地不同(本侧不 backoff,
        // 让用户能在 UI 上手动 retry)。
        var acc = NarrativeStreamAccumulator()
        let narrativeInput = await engine.narrativeInput(in: dateInterval)
        guard isCurrent(range, generation), !Task.isCancelled else { return }

        streamLoop: for await event in engine.streamNarrativeEvents(for: narrativeInput) {
            if Task.isCancelled { break }
            guard isCurrent(range, generation) else { return }
            switch event {
            case .chunk(let text):
                acc.appendChunk(text)
            case .truncated(let reason):
                acc.markTruncated(reason: reason)
            case .failed(let error):
                // (2026-05-15 superreview-3 P1)三件事一起做:
                // (1) `error.localizedDescription` 可能空(URLError 子类 / 没实现 LocalizedError
                //     的 Swift Error)→ fallback 非空 reason 让 UI 失败 banner 能显示 + retry CTA
                //     可点。否则 accumulator 防御吃掉空字符串 → coordinator persist `streamFailure[range]=nil`
                //     → 卡片回落 notGenerated 用户看不到失败。
                // (2) `.failed` 是 terminal event:服务器只 yield .failed 就 finish stream,
                //     永远不会再来 .done,显式 break 避免 future caller 在循环里加新逻辑误以为还会等 done。
                //     跟 NarrativePrecomputeService 的 `.failed → return` 语义对齐(那边 abort + backoff)。
                let reason = error.localizedDescription.isEmpty
                    ? NSLocalizedString("narrative.generation.failed", value: "回顾生成失败,稍后再试", comment: "Narrative streaming failed fallback")
                    : error.localizedDescription
                acc.markTruncated(reason: reason)
                break streamLoop
            case .done:
                break streamLoop
            }
        }
        guard isCurrent(range, generation), !Task.isCancelled else { return }

        await persistIfNeeded(PersistRequest(
            range: range,
            dateInterval: dateInterval,
            entryCount: entryCount,
            mostRecentEntryDate: mostRecentEntryDate,
            generation: generation,
            streamStartTime: streamStartTime,
            rawOutput: acc.rawOutput,
            isIncomplete: acc.isIncomplete,
            truncatedReason: acc.truncatedReason,
            citedEntryIds: narrativeInput.sourceEntryIds
        ))
    }

    /// 流结束写盘 v3 record。跟原 `NarrativeSummaryCard.persistNarrativeIfNeeded` 同逻辑,
    /// 只是改写主 viewContext(本类 @MainActor)而非卡片的 @Environment context。失败仅 Log。
    private func persistIfNeeded(_ request: PersistRequest) async {
        let (headline, body) = NarrativeStreamSplitter.split(rawOutput: request.rawOutput)

        // body 空 = stream 失败 / 在 [BODY] marker 前被截 → 不写盘。把失败原因挂 streamFailure
        // 让卡片显 streamFailedView / 重试;无失败原因(纯空 .done)→ 不挂,卡片回落 notGenerated。
        guard !body.isEmpty else {
            if isCurrent(request.range, request.generation) {
                streamFailure[request.range] = request.truncatedReason.map {
                    StreamFailure(reason: $0, occurredAt: Date())
                }
            }
            return
        }

        // 写盘前 cancel 在飞的后台 precompute,避免「用户手动生成」+「后台预生成」同 range
        // 各写一条。`cancelPendingAndBumpGeneration` 内含 await,返回后须重新比对世代号。
        await NarrativePrecomputeService.shared.cancelPendingAndBumpGeneration()
        guard isCurrent(request.range, request.generation), !Task.isCancelled else { return }

        // stream 跑了几十秒,期间用户删/编辑 entry → markInvalidatedForEntryChange 推进
        // marker。marker 晚于 streamStartTime → 本次 body 基于过期快照,丢弃不写盘,否则旧
        // 正文配新 createdAt 会重新成为 fresh cache,用户看到引用已删/旧文字的 ghost 回顾。
        if let invalidated = NarrativeCacheService.invalidatedBeforeDate(),
           invalidated >= request.streamStartTime {
            Log.info("[NarrativeGen] entry set changed during stream, discard stale narrative for \(request.range.rawValue)", category: .ai)
            return
        }

        let viewContext = persistence.container.viewContext
        let payload = AIConversation.NarrativePayload(
            rangeStart: request.dateInterval.start,
            rangeEnd: request.dateInterval.end,
            body: body,
            isIncomplete: request.isIncomplete,
            truncatedReason: request.truncatedReason,
            rangeKind: request.range.rawValue,
            entryCount: request.entryCount,
            sourceLatestEntryDate: request.mostRecentEntryDate,
            generatedAt: Date(),
            headline: headline
        )
        do {
            _ = try AIConversation.insertNarrative(
                in: viewContext,
                title: request.range.narrativeTitleLabel,
                payload: payload,
                citedEntryIds: request.citedEntryIds
            )
            try viewContext.save()
            // persist 成功 → 清失败标记;incomplete-ness 由 payload.isIncomplete 携带。
            if isCurrent(request.range, request.generation) {
                streamFailure[request.range] = nil
            }
        } catch {
            viewContext.rollback()
            Log.error("[NarrativeGen] persist failed for \(request.range.rawValue): \(error)", category: .persistence)
        }
    }
}
