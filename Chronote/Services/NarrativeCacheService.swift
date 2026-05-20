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
    /// - cache.createdAt 早于该 range 内最新一篇日记的 date(用户后又编辑/替换了日记)
    /// - payload.entryCount 变少(删除要立刻重生)
    /// - payload.entryCount 增加到 range 对应阈值(月 1 / 季 3 / 年和全部 5)
    ///
    /// **2026-05-10 删 age-based freshness window 判定**:原本 .month 设 24h、其他
    /// range 设 3-7 day,期望"超过窗口即便没新日记也重生(防止 narrative 自身陈旧)"。
    /// 实测引出体验 bug:用户没写日记,只是隔天打开 InsightsView,卡凭空被重生 —
    /// LLM 输出有温度,每次 headline / body 都换一种说法,用户感觉 app 擅自改了自己
    /// 的回顾,还烧 API。原"窗口滑动"理由(.month dateInterval.start 每天滑动)在用户
    /// 没新日记的场景里没意义 — 滑动只是丢一些旧日记,内容信号没变化,值得重生的是
    /// **真有新内容**的时刻,那两条已经覆盖。
    static func isStale(
        range: TimeRange,
        payload: AIConversation.NarrativePayload?,
        createdAt: Date?,
        mostRecentEntryDate: Date?,
        currentEntryCount: Int
    ) -> Bool {
        guard let payload, let createdAt else { return true }
        // 老 cache(v2 之前没 headline / 半路 stream failed)需要重生 narrative,
        // 但展示侧 `isOutdatedForCurrentEntries` 故意不挡这条 —— 见那边注释。
        if payload.headline == nil || payload.isIncomplete {
            return true
        }
        return entrySetChanged(
            range: range,
            payload: payload,
            createdAt: createdAt,
            mostRecentEntryDate: mostRecentEntryDate,
            currentEntryCount: currentEntryCount
        )
    }

    /// 只判断 entry 集合是否已经让缓存内容过期。它和 `isStale` 刻意不同:
    /// v2 老 cache 没 headline、incomplete cache 有 warning,前台仍可以展示;但新写/删/改
    /// entry 后的旧 body 必须隐藏,避免 ghost 内容。
    static func isOutdatedForCurrentEntries(
        range: TimeRange,
        payload: AIConversation.NarrativePayload?,
        createdAt: Date?,
        mostRecentEntryDate: Date?,
        currentEntryCount: Int
    ) -> Bool {
        guard let payload, let createdAt else { return true }
        return entrySetChanged(
            range: range,
            payload: payload,
            createdAt: createdAt,
            mostRecentEntryDate: mostRecentEntryDate,
            currentEntryCount: currentEntryCount
        )
    }

    // MARK: - 共享的"entry 集合变化"判定
    //
    // **H-2 superreview 2026-05-19** — 原来 `isStale` 和 `isOutdatedForCurrentEntries`
    // 各自手写了"delta < 0 / delta >= threshold / createdAt < mostRecent" 同一套规则,
    // 两份 copy 一旦漂移就出现"后台决定生成新 narrative + 前台决定继续显示旧 body" 的
    // silent inconsistency,而且没有任何告警机制。统一到这个 private helper,两个 public
    // API 都 thin-wrap 它,差异只在 headline/incomplete 触发的 regenerate 语义。
    //
    // **关于 B-05 superreview finding 的处置**(2026-05-19 codex 终审反驳后回归):
    // Slice B 主张"把 mostRecent 检查抬到 delta 检查之前"是 over-correction —— 任何
    // 用户新写一篇日记都会推进 mostRecent 超过 cache.createdAt(by construction),那等于
    // 废除 entry-delta threshold 机制("加 1 篇立即重生",项目本意是"加少于阈值不重生")。
    // 真正的 B-05 场景"用户编辑日记 mostRecent 推进"是 delta == 0 情况,旧实现本来就
    // fall through 到 mostRecent 检查,**没有 bug**。所以这里保持旧顺序:
    //   delta < 0 → stale
    //   delta > 0 → 看是否到阈值
    //   delta == 0 → 看 mostRecent 是否推进过 createdAt
    //
    // 严格 `<` — `createdAt == mostRecent` 视为 cache 仍覆盖最后那篇 entry(narrative 是
    // entry 写入之后才生成,实践中 createdAt 严格晚于 mostRecent;同秒是测试 / 时钟漂移
    // 边界,语义为"cache 是 fresh 的")。
    private static func entrySetChanged(
        range: TimeRange,
        payload: AIConversation.NarrativePayload,
        createdAt: Date,
        mostRecentEntryDate: Date?,
        currentEntryCount: Int
    ) -> Bool {
        if let cachedCount = payload.entryCount {
            let delta = currentEntryCount - cachedCount
            if delta < 0 { return true }
            if delta > 0 {
                return delta >= range.narrativeRefreshEntryDeltaThreshold
            }
            // delta == 0:落到下方 mostRecent 检查(用户编辑日记的场景)
        }
        if let mostRecent = mostRecentEntryDate, createdAt < mostRecent {
            return true
        }
        return false
    }
}

extension TimeRange {
    var narrativeRefreshEntryDeltaThreshold: Int {
        switch self {
        case .month: return 1
        case .quarter: return 3
        case .year, .all: return 5
        }
    }
}

extension Notification.Name {
    static let lumoryNarrativeCacheInvalidated = Notification.Name("lumoryNarrativeCacheInvalidated")
}
