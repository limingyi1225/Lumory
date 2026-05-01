import Foundation

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
        let moodPoints: [InsightsEngine.MoodPoint]
        let themes: [InsightsEngine.Theme]
        let stats: InsightsEngine.WritingStats
        let dailyCells: [DailyCell]
        let facts: [CorrelationFact]
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
