import Foundation

// **P1 fix (2026-05-13 superreview)**:DailyCell 之前定义在 WritingHeatmap.swift(View 层)
// 但被 Service 层(InsightsResultCache.Snapshot)反向引用,违反分层。挪到 Service 文件让所有
// reader(InsightsView 数据流 + WritingHeatmap 视图组件)从同一处 import。
// DailyCell 没有任何 View 依赖(纯 Date / Double / Int),搬运成本零。
struct DailyCell: Identifiable, Equatable, Hashable {
    let date: Date
    let mood: Double
    let wordCount: Int
    var id: Date { date }
}

/// Insights sheet 的 stale-while-revalidate 缓存。
///
/// 背景:`InsightsView` 是 HomeView 的 `.sheet`,SwiftUI dismiss 后整个 view 销毁,
/// 所有 `@State` 重置 —— 下次开 sheet 全部归零,`.task(id: range)` 触发 reload,
/// 用户看到 ~300-600ms 的 loading 占位。
///
/// 这个 cache 在 `reload()` 入口 hydrate 上次结果秒显,后台静默 reload 后覆盖,
/// 把"占位骨架→数据"换成"旧数据→新数据"的平滑过渡。
///
/// **失效策略:不主动失效**。reload 总会跑完,几百 ms 后被新数据覆盖。
/// - 写一篇日记后再开 sheet 会先看到旧聚合 ~300ms,然后被新结果盖掉 —— 可接受的 SWR trade。
/// - 主题别名 merge 时 InsightsView 监听 `.themeAliasMapDidChange` 重 reload,同样路径。
/// - **唯一例外:批量删除日记**(SettingsEntryDeletionService / DatabaseRecoveryService)
///   要主动 `clear()`,跟 CLAUDE.md "批量删 entry 三件套" 同源 —— 用户主动清空数据后,
///   再开 Insights 看到引用已删 entry 的旧聚合不可接受。
@MainActor
final class InsightsResultCache {
    static let shared = InsightsResultCache()
    private init() {}

    struct Snapshot {
        let themes: [InsightsEngine.Theme]
        // **P1 fix (2026-05-13 superreview)**:原 `stats: WritingStats` 字段在 InsightsView
        // 重构 wave 后已无 reader(只一处 writer 塞 `.empty`),归类 dead code,删除。
        // 全局 writingStats 仍由 InsightsEngine.writingStats() / AskPastView preset 使用,
        // 但跟浓缩卡 SWR cache 无关。
        let dailyCells: [DailyCell]
        // MoodStoryChart 整块删除(用户决定 2026-05-12)— `moodPoints` 字段一并退出 snapshot,
        // pointsTask 在 reload 中也删掉,省一次 bg fetch + reduce 聚合。
        // CorrelationChipList 整块删除 — `facts` 字段同步退出 snapshot,所有 caller 都不再读写。
        // wave15 v3 — 浓缩卡专用 stats 也进 SWR snapshot。原本 reload 入口强制把这俩
        // 设 nil 等 async,导致 SWR 命中时仍要走 SkeletonNarrativeSummaryCard 中间态,
        // 卡 in/out 触发 LazyVStack reflow → 切 range 闪烁。一并 cache 后命中即用,
        // 后台 reload 完成后用 fresh 值覆盖。
        let entryCount: Int
        let mostRecentEntryDate: Date?
    }

    /// Key = TimeRange。Bucket 一一对应 range,不入 key。
    /// TimeRange 只 4 个 case,缓存总量 < 1MB,不做容量上限。
    private var store: [TimeRange: Snapshot] = [:]

    func snapshot(for range: TimeRange) -> Snapshot? {
        store[range]
    }

    func update(_ snapshot: Snapshot, for range: TimeRange) {
        store[range] = snapshot
    }

    /// 批量删日记后清空。沿用 CLAUDE.md "三件套" 思路。
    func clear() {
        store.removeAll()
    }
}
