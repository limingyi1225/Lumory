import Foundation

/// 把"今天/连续状态"算出来的纯函数。`QuickWriteProvider.makeEntry` 调用,
/// 单测从这里入口验证跨午夜翻状态(测试不需要 import widget target,只需 LumoryWidgetShared)。
///
/// 规则:
/// - `wroteToday`: lastEntryDate 跟 asOf 是否同一天(用 `Calendar.isDate(_:inSameDayAs:)`,
///   不直接比 startOfDay 等式,避 timezone/DST)。
/// - `effectiveStreak`: lastEntryDate 落在今天 / 昨天 → snapshot.currentStreak 仍有效;
///   再老 → 0。这条跟 `InsightsEngine.computeStreaks` 的"今天或昨天写过都算继续"语义一致,
///   widget 不重跑 streak 算法。
public struct WidgetTodayContext: Equatable {
    public let wroteToday: Bool
    public let effectiveStreak: Int

    public static func compute(
        snapshot: WidgetSnapshot,
        asOf now: Date,
        calendar: Calendar = .current
    ) -> WidgetTodayContext {
        let wroteToday: Bool
        if let last = snapshot.lastEntryDate {
            wroteToday = calendar.isDate(last, inSameDayAs: now)
        } else {
            wroteToday = false
        }

        let effectiveStreak: Int
        if let last = snapshot.lastEntryDate {
            let lastDay = calendar.startOfDay(for: last)
            let today = calendar.startOfDay(for: now)
            let daysAgo = calendar.dateComponents([.day], from: lastDay, to: today).day ?? Int.max
            effectiveStreak = (daysAgo <= 1) ? snapshot.currentStreak : 0
        } else {
            effectiveStreak = 0
        }

        return WidgetTodayContext(wroteToday: wroteToday, effectiveStreak: effectiveStreak)
    }
}
