import Foundation
import CoreData

// MARK: - NarrativeCacheService
//
// 浓缩卡的"按 rangeKind 查 cache + 判 staleness"逻辑统一入口。
//
// **为什么不挂 `@MainActor`**:`NarrativePrecomputeService` 在后台 actor 里
// `bg.perform { }` 闭包内调 `latest(...)`,跨 MainActor edge 编不过。这里所有
// method 都是纯逻辑(无 mutable state、不持有任何 actor-isolated 引用),自然
// `nonisolated static` 即可 —— 调用方负责 context 的线程安全(viewContext
// 在 main / bg context 在 perform 闭包内)。
//
// **为什么还要 decode payload**:`rangeKind` 在 JSON payload 内,Core Data 不能
// NSPredicate 索引。查询先用 `payloadVersion >= 2` 排除无 rangeKind 的 v1 老记录,
// 再按批 fetch + decode,避免重度用户每次 hydrate 都一次性 materialize 全量历史。
//
// **为什么忽略 v1 record**:v1 的 NarrativePayload 没 rangeKind 字段,无法绑定
// 到 `.month / .quarter / .year / .all` 语义 range。v1 老 record 仍在
// ConversationHistoryView 历史回顾里能看到 + 删,只是不参与浓缩卡 cache hit。
// 用户进 InsightsView 时 v1 cache 不命中 → 触发重生写一条 v2 → 之后命中。

enum NarrativeCacheService {
    private static let invalidatedBeforeDefaultsKey = "lumory.narrativeCache.invalidatedBefore"

    // MARK: - 查询

    /// 按 rangeKind 找最新一条 v2+ narrative。**分页** fetch + decode,命中即返回。
    /// **调用方负责 context 线程**(viewContext 在 main / bg context 在 perform 内)。
    ///
    /// **P2 fix (2026-05-14 superreview round 3)**:之前不设 fetchLimit 一次性 `context.fetch`
    /// 把所有 v2+ narrative 拉成 fault 数组 —— 重度用户有数百条历史 narrative 时,在主
    /// viewContext 上 hydrate 会一次 materialize 全量。改成 fetchLimit + fetchOffset 分页:
    /// 每页 32 条,命中即停;`invalidatedBefore` 之后的页(按 createdAt desc 全更老)直接早退。
    static func latest(
        for range: TimeRange,
        in context: NSManagedObjectContext
    ) -> (payload: AIConversation.NarrativePayload, createdAt: Date)? {
        let invalidatedBefore = invalidatedBeforeDate()
        let pageSize = 32
        var offset = 0
        while true {
            let request = NSFetchRequest<AIConversation>(entityName: "AIConversation")
            request.predicate = NSPredicate(
                format: "kind == %@ AND payloadVersion >= 2",
                AIConversation.Kind.narrative.rawValue
            )
            request.sortDescriptors = [NSSortDescriptor(keyPath: \AIConversation.createdAt, ascending: false)]
            request.fetchLimit = pageSize
            request.fetchOffset = offset
            guard let rows = try? context.fetch(request), !rows.isEmpty else { return nil }
            for conv in rows {
                guard let createdAt = conv.createdAt else { continue }
                if let invalidatedBefore, createdAt <= invalidatedBefore { continue }
                guard let payload = conv.narrativePayload else {
                    // 候选里 decode 失败 silently skip 会让"损坏 record 占位 + 健康 record
                    // 排后面永久 miss"的极端 case 无声踩。CloudKit 同步残缺 / Data corruption
                    // 时浮出来便于诊断。
                    if conv.payload != nil {
                        Log.warning("[NarrativeCache] payload decode failed for record \(conv.id?.uuidString ?? "<nil>")", category: .persistence)
                    }
                    continue
                }
                guard let kind = payload.rangeKind, kind == range.rawValue else { continue }
                return (payload, createdAt)
            }
            // rows 按 createdAt desc 排序:本页最后一条已 <= invalidatedBefore,则后续页
            // 全部更老,都会被 invalidation 守卫跳过 → 没有继续翻页的意义。
            if let invalidatedBefore,
               let lastCreatedAt = rows.last?.createdAt,
               lastCreatedAt <= invalidatedBefore {
                return nil
            }
            offset += pageSize
        }
    }

    // MARK: - Invalidation

    /// 标记"此时间点之前生成的 narrative 不能再当缓存使用"。不删除 AIConversation,
    /// 让历史回顾仍可读,只让 Insights 浓缩卡与后台 precompute 忽略旧 cache。
    static func markInvalidatedForEntryChange(at date: Date = Date()) {
        UserDefaults.standard.set(date.timeIntervalSinceReferenceDate, forKey: invalidatedBeforeDefaultsKey)
    }

    static func invalidatedBeforeDate() -> Date? {
        guard UserDefaults.standard.object(forKey: invalidatedBeforeDefaultsKey) != nil else { return nil }
        return Date(timeIntervalSinceReferenceDate: UserDefaults.standard.double(forKey: invalidatedBeforeDefaultsKey))
    }

    static func resetInvalidationForTesting() {
        UserDefaults.standard.removeObject(forKey: invalidatedBeforeDefaultsKey)
    }

    // MARK: - Staleness

    /// stale 判定 — 任意一条满足即 stale:
    /// - cache 不存在
    /// - cache.createdAt 早于该 range 内最新一篇日记的 date(用户后又写了日记)
    /// - payload.entryCount != currentEntryCount(用户删了一篇日记后 mostRecent 可能不变,
    ///   但 entryCount 变 → 仍要重生)
    ///
    /// **2026-05-10 删 age-based freshness window 判定**:原本 .month 设 24h、其他
    /// range 设 3-7 day,期望"超过窗口即便没新日记也重生(防止 narrative 自身陈旧)"。
    /// 实测引出体验 bug:用户没写日记,只是隔天打开 InsightsView,卡凭空被重生 —
    /// LLM 输出有温度,每次 headline / body 都换一种说法,用户感觉 app 擅自改了自己
    /// 的回顾,还烧 API。原"窗口滑动"理由(.month dateInterval.start 每天滑动)在用户
    /// 没新日记的场景里没意义 — 滑动只是丢一些旧日记,内容信号没变化,值得重生的是
    /// **真有新内容**的时刻,那两条已经覆盖。
    static func isStale(
        payload: AIConversation.NarrativePayload?,
        createdAt: Date?,
        mostRecentEntryDate: Date?,
        currentEntryCount: Int
    ) -> Bool {
        guard let payload, let createdAt else { return true }
        if payload.headline == nil || payload.isIncomplete {
            return true
        }
        // 严格 `<` — `createdAt == mostRecent` 视为 cache 仍覆盖最后那篇 entry(narrative 是
        // entry 写入之后才生成,实践中 createdAt 严格晚于 mostRecent;同秒是测试 / 时钟漂移
        // 边界,语义为"cache 是 fresh 的")。`isStale_cacheOlderThanWindow_returnsFalse` 测试
        // 锁死此行为。
        if let mostRecent = mostRecentEntryDate, createdAt < mostRecent {
            return true
        }
        if let cachedCount = payload.entryCount, cachedCount != currentEntryCount {
            return true
        }
        return false
    }

    /// 只判断 entry 集合是否已经让缓存内容过期。它和 `isStale` 刻意不同:
    /// v2 老 cache 没 headline、incomplete cache 有 warning,前台仍可以展示;但新写/删/改
    /// entry 后的旧 body 必须隐藏,避免 ghost 内容。
    static func isOutdatedForCurrentEntries(
        payload: AIConversation.NarrativePayload?,
        createdAt: Date?,
        mostRecentEntryDate: Date?,
        currentEntryCount: Int
    ) -> Bool {
        guard let payload, let createdAt else { return true }
        if let mostRecent = mostRecentEntryDate, createdAt < mostRecent {
            return true
        }
        if let cachedCount = payload.entryCount, cachedCount != currentEntryCount {
            return true
        }
        return false
    }
}

extension Notification.Name {
    static let lumoryNarrativeCacheInvalidated = Notification.Name("lumoryNarrativeCacheInvalidated")
}
