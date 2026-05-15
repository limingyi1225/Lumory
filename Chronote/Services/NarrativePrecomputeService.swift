import Foundation
import CoreData

// MARK: - NarrativePrecomputeService
//
// 写日记完成后,后台 60s debounce 重生当前 .month 浓缩 — 把"AI 总结"从用户主动
// 触发变成"已经替你读完,你打开 InsightsView 直接看到结论"。**只对 .month 自动**;
// .all/.quarter/.year 是长程总结(加 1 篇日记边际 < 1%),且 API 一次 ~$0.05-0.10,
// 全量预生成成本不划算 → 用户切到时手动点"为我浓缩"。
//
// **守卫**:
//  - entryCount < 3 → noop(< 3 篇 narrative 内容空洞,浪费 API)
//  - 当前 cache 已 fresh(staleness 判定包含 entryCount / mostRecentEntryDate)
//    → noop,避免和用户手动生成写两条
//  - 失败静默 → Log.warning,不打扰用户
//
// **AI 注入 seam**:`init(persistence:engine:debounce:)` — prod 用 `.shared` /
// `InsightsEngine.shared` / 60s;test 用 mock InsightsEngine + 短 debounce(50ms)。

actor NarrativePrecomputeService {

    static let shared = NarrativePrecomputeService(
        persistence: .shared,
        engine: .shared,
        debounce: .seconds(60)
    )

    private let persistence: PersistenceController
    private let engine: InsightsEngine
    private let debounce: Duration
    private var pendingTask: Task<Void, Never>?
    private var lastFailureAtByRange: [TimeRange: Date] = [:]
    private let failureBackoff: TimeInterval = 5 * 60
    /// **wave15 race fix** — supersession 世代号。`requestRefreshIfNeeded` 每次自增,
    /// `performRefresh` 在长 await 边界(stream done 后、persist 前)对照 actor 当前值,
    /// 不等于即丢弃,避免老 task 已通过 staleness 守卫但被新 task 取消后仍写盘的双写竞争。
    /// 用世代号(不是 `Task.isCancelled`)是因为 actor 内 supersession 比 cooperative
    /// cancellation 语义更准:cancel 信号 + bg.perform 闭包内不可被 cancel,会留下漏窗口。
    private var refreshGeneration: Int = 0

    init(persistence: PersistenceController, engine: InsightsEngine, debounce: Duration) {
        self.persistence = persistence
        self.engine = engine
        self.debounce = debounce
    }

    /// 写日记 callsite 调这个 — debounce 期内连续多次调只保留最后一个 task。
    /// 失败仅 Log,不抛。
    func requestRefreshIfNeeded(for range: TimeRange) async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        pendingTask?.cancel()
        pendingTask = Task { [weak self, debounce] in
            guard let self else { return }
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self.performRefresh(for: range, generation: generation)
        }
    }

    /// 当前 actor 世代号是否仍是调用方持有的世代号。stream / bg.perform 后调,确认这次 task 未被超越。
    private func isCurrentGeneration(_ generation: Int) -> Bool {
        generation == refreshGeneration
    }

    /// Settings 的"清除 AI 回顾缓存"用 — cancel 待跑 / 在跑的 debounce task 并 bump 世代号,
    /// 让仍在 stream 中的旧 task 通过 `isCurrentGeneration` 守卫被丢弃。
    /// **race fix**:写日记 → 60s debounce 启动 → 用户立刻进 Settings 点 Reset → main context
    /// 删全部 narrative → save → 老 task 醒来通过 staleness check(check was 在 delete 前)
    /// → 完成 stream → 写回新 narrative,reset 失效。先调这个再删 = 即使老 task 抢跑到 bg.perform
    /// 写盘也会被新世代号挡住。这里还会等待旧 task 完整退出,覆盖它已经越过 actor
    /// 守卫、正在 `bg.perform` 写盘的最后窗口。
    func cancelPendingAndBumpGeneration() async {
        let task = pendingTask
        task?.cancel()
        refreshGeneration &+= 1
        let cancelGeneration = refreshGeneration
        await task?.value
        if refreshGeneration == cancelGeneration {
            pendingTask = nil
        }
    }

    /// **测试 seam** — 等当前 pending task 跑完(或被取消)。生产代码不会调。
    /// 单测要 await 整条 debounce + stream + persist 的链路完成才好做断言。
    #if DEBUG
    func drainPendingForTesting() async {
        await pendingTask?.value
    }
    #endif

    private func performRefresh(for range: TimeRange, generation: Int) async {
        let interval = range.dateInterval

        // 守卫 1: < 3 篇 → 不浪费 API
        let count = await engine.entryCount(in: interval)
        // **P1 fix (2026-05-13 superreview round 2)**:每次 await 边界都 check generation。
        // bg.perform 闭包内不响应 Task.cancel,只有 actor-isolated generation 比对能挡 superseded
        // 老 task 继续烧 API + 网络。
        guard isCurrentGeneration(generation) else { return }
        guard count >= 3 else {
            Log.info("[NarrativePrecompute] skip \(range.rawValue): only \(count) entries", category: .ai)
            return
        }
        if let lastFailure = lastFailureAtByRange[range],
           Date().timeIntervalSince(lastFailure) < failureBackoff {
            Log.info("[NarrativePrecompute] skip \(range.rawValue): in failure backoff", category: .ai)
            return
        }

        // 守卫 2: 当前 cache 已 fresh → 跳过(避免和用户手动 InsightsView 内重生写重复)
        let mostRecent = await engine.mostRecentEntryDate(in: interval)
        guard isCurrentGeneration(generation) else { return }
        let bg = persistence.container.newBackgroundContext()
        // **P2 fix (2026-05-13 superreview)**:默认 NSErrorMergePolicy 在 CloudKit pull 与本机
        // bg 写并发时 save 会 throw 被 do/catch 静默吞。viewContext 已设
        // NSMergeByPropertyStoreTrumpMergePolicy,bg 写盘也对齐。
        bg.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
        let stale: Bool = await bg.perform {
            let latest = NarrativeCacheService.latest(for: range, in: bg)
            return NarrativeCacheService.isStale(
                payload: latest?.payload,
                createdAt: latest?.createdAt,
                mostRecentEntryDate: mostRecent,
                currentEntryCount: count
            )
        }
        guard stale else {
            Log.info("[NarrativePrecompute] skip \(range.rawValue): cache fresh", category: .ai)
            return
        }

        // wave15 — 累 rawOutput,done 后用 NarrativeStreamSplitter 一次 split。
        // 不再 chunk-by-chunk 拆段(streaming 期间 UI 也只显 thinking 占位)。
        // `.chunk` / `.truncated` 状态机抽进 `NarrativeStreamAccumulator`,与 coordinator 共享。
        var acc = NarrativeStreamAccumulator()
        // **P1 fix (2026-05-14 superreview round 3)**:记 stream 开始时间,完成后判断 entry
        // 集合是否在生成期间被改动(见下方 invalidatedBeforeDate 守卫)。
        let streamStartTime = Date()

        streamLoop: for await event in engine.streamNarrativeEvents(in: interval) {
            if Task.isCancelled { return }
            // **P2 fix (2026-05-13 superreview)**:stream 期间(可能几十秒)旧 task 若已被
            // supersede,继续累 rawOutput 没意义且烧 API。每个 event 边界 check generation,
            // 不等则提前断开(stream task continuation 会 onTermination cancel 上游 URLSession)。
            guard isCurrentGeneration(generation) else { return }
            switch event {
            case .chunk(let text):
                acc.appendChunk(text)
            case .truncated(let reason):
                acc.markTruncated(reason: reason)
            case .failed(let error):
                Log.warning("[NarrativePrecompute] stream failed for \(range.rawValue): \(error)", category: .ai)
                // **P1 fix (2026-05-13 superreview)**:backoff 写入也要 generation guard,
                // 否则旧 task 被 supersede 后若仍能拿到 .failed,会污染当前 range 的 5min
                // backoff,误伤新 task。
                if isCurrentGeneration(generation) {
                    lastFailureAtByRange[range] = Date()
                }
                return  // 失败静默,不写盘
            case .done:
                // **P2 fix (2026-05-14 superreview round 3)**:labeled break 跳出 for-await。
                // .done 是 terminal event,显式 break 防未来 InsightsEngine 实现忘 finish。
                break streamLoop
            }
        }

        let isIncomplete = acc.isIncomplete
        let incompleteReason = acc.truncatedReason
        let (headline, body) = NarrativeStreamSplitter.split(rawOutput: acc.rawOutput)
        guard !body.isEmpty else {
            Log.warning("[NarrativePrecompute] empty body for \(range.rawValue), skip persist", category: .ai)
            // **P2 fix (2026-05-13 superreview round 2)**:.truncated 时 body 空(stream 在
            // `[BODY]` 标记前被截) → 不写盘但也得记 backoff,否则 60s debounce 后又重试同款
            // 失败路径,反复烧 API。failed 路径已写 backoff,这里语义对齐。
            if isIncomplete, isCurrentGeneration(generation) {
                lastFailureAtByRange[range] = Date()
            }
            return
        }

        // **wave15 race fix** — stream 跑完后再次确认本 task 没被超越。
        // 老 task 已通过 staleness 守卫并完成 stream,但 requestRefreshIfNeeded 期间又来一次新调用 →
        // 两条都会持续到 bg.perform 各写一条,导致同 range 重复 narrative。
        // bg.perform 闭包内 NSManagedObjectContext 不响应 Task.cancel,这里是最后能抓的位置。
        guard isCurrentGeneration(generation) else {
            Log.info("[NarrativePrecompute] skip \(range.rawValue): superseded by newer request", category: .ai)
            return
        }

        // **P1 fix (2026-05-14 superreview round 3)**:body 是基于 stream 开始时的 entry 快照
        // 生成的。stream 期间用户(或 CloudKit 同步)删/编辑了 entry → `markInvalidatedForEntryChange`
        // 推进 invalidation marker。若 marker 已晚于 streamStartTime,本次 body 已过期 → 丢弃,
        // 否则旧正文配新 createdAt 会重新成为 fresh cache。`cancelPendingAndBumpGeneration` 只挡
        // generation,不挡 entry 内容变化。
        if let invalidated = NarrativeCacheService.invalidatedBeforeDate(),
           invalidated >= streamStartTime {
            Log.info("[NarrativePrecompute] skip \(range.rawValue): entry set changed during stream", category: .ai)
            return
        }

        // **P1 fix (2026-05-13 superreview round 2)**:stream 期间(30-60s)用户可能新增/删除
        // 日记。line 96 的 count + line 108 的 mostRecent 已过期。同时 line 93 拍照的 interval
        // 也是 stream 开始时的快照(`range.dateInterval` 的 `now = Date()`),30-60s 后早过了 →
        // 用户在 stream 期间写的 fresh entry(date > 老 interval.end)不被算入 → 写盘后立即
        // isStale → 下次 debounce 又重生 → 多烧一次 API。重新算 finalInterval 拿真最终值。
        let finalInterval = range.dateInterval
        let finalCount = await engine.entryCount(in: finalInterval)
        let finalMostRecent = await engine.mostRecentEntryDate(in: finalInterval)
        guard isCurrentGeneration(generation) else {
            Log.info("[NarrativePrecompute] skip \(range.rawValue): superseded between refresh metrics", category: .ai)
            return
        }

        // local copies for sendable closure
        let finalHeadline = headline
        let finalIsIncomplete = isIncomplete
        let finalIncompleteReason = incompleteReason
        let title = range.narrativeTitleLabel

        let didPersist: Bool = await bg.perform {
            do {
                let payload = AIConversation.NarrativePayload(
                    rangeStart: finalInterval.start,
                    rangeEnd: finalInterval.end,
                    body: body,
                    isIncomplete: finalIsIncomplete,
                    truncatedReason: finalIncompleteReason,
                    rangeKind: range.rawValue,
                    entryCount: finalCount,
                    sourceLatestEntryDate: finalMostRecent,
                    generatedAt: Date(),
                    headline: finalHeadline
                )
                _ = try AIConversation.insertNarrative(
                    in: bg,
                    title: title,
                    payload: payload,
                    citedEntryIds: []
                )
                try bg.save()
                Log.info("[NarrativePrecompute] persisted \(range.rawValue) narrative (\(body.count) chars)", category: .ai)
                return true
            } catch {
                Log.error("[NarrativePrecompute] persist failed for \(range.rawValue): \(error)", category: .persistence)
                return false
            }
        }
        if didPersist {
            lastFailureAtByRange[range] = nil
        }
    }
}
