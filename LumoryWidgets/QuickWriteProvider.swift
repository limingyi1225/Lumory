import Foundation
import WidgetKit

/// Widget 的 timeline entry struct。把 snapshot 的静态字段 + provider 算的相对字段
/// 一起打包,view 端就不用每次重新算 today 状态。`date` 是这条 entry 生效的时间。
struct QuickWriteEntry: TimelineEntry {
    let date: Date
    let longestStreak: Int
    let lastEntryMood: Double?
    let prompt: String?

    /// 由 `QuickWriteProvider.makeEntry` 用 `asOf` 时间相对算出来:
    /// - `wroteToday`: lastEntryDate 跟 asOf 是否同一天
    /// - `effectiveStreak`: 跟 InsightsEngine 的"今天/昨天写过都算继续"语义一致
    let wroteToday: Bool
    let effectiveStreak: Int
}

struct QuickWriteProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickWriteEntry {
        Self.makeEntry(snapshot: .empty(), asOf: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickWriteEntry) -> Void) {
        let snap = WidgetSnapshotStore.read() ?? .empty()
        completion(Self.makeEntry(snapshot: snap, asOf: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickWriteEntry>) -> Void) {
        let snap = WidgetSnapshotStore.read() ?? .empty()
        let now = Date()
        let calendar = Calendar.current
        // **必须用 calendar.date(byAdding:value:to:)**,不是 now + 86400 ——
        // DST 切换日 86400 秒 ≠ 一天,会偏。
        let startOfToday = calendar.startOfDay(for: now)
        let nextMidnight = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now.addingTimeInterval(86_400)

        // 两条 entry,各自独立 makeEntry —— 第二条用未来时间,会重新算 wroteToday/effectiveStreak,
        // 系统跨午夜后展示 entry2 时自动翻"今天未写"。**不要**让两条 entry 共享一个 makeEntry 结果,
        // 那样午夜不会真翻状态。
        let entry1 = Self.makeEntry(snapshot: snap, asOf: now)
        let entry2 = Self.makeEntry(snapshot: snap, asOf: nextMidnight.addingTimeInterval(5 * 60))

        let timeline = Timeline(
            entries: [entry1, entry2],
            policy: .after(nextMidnight.addingTimeInterval(6 * 60))
        )
        completion(timeline)
    }

    /// 纯函数。`WidgetTodayContext.compute` 在 `LumoryWidgetShared` 里也被单测覆盖。
    static func makeEntry(
        snapshot: WidgetSnapshot,
        asOf now: Date,
        calendar: Calendar = .current
    ) -> QuickWriteEntry {
        let ctx = WidgetTodayContext.compute(snapshot: snapshot, asOf: now, calendar: calendar)
        return QuickWriteEntry(
            date: now,
            longestStreak: snapshot.longestStreak,
            lastEntryMood: snapshot.lastEntryMood,
            prompt: snapshot.prompt,
            wroteToday: ctx.wroteToday,
            effectiveStreak: ctx.effectiveStreak
        )
    }
}
