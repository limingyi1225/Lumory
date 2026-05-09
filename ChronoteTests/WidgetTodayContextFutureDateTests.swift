import Testing
import Foundation
@testable import Lumory

/// 回归测试 `WidgetTodayContext.compute` 的 `daysAgo >= 0` future-date guard
/// (见 `LumoryWidgetShared/WidgetTodayContext.swift` line 33-35)。
///
/// 守卫的现实场景:CK-synced 的 entry 来自时钟跑前的另一台设备 / 用户手动导入未来
/// 日期 → `lastEntryDate` 落在 `asOf` 之后,`daysAgo` 是负数,光 `<= 1` 会通过让 widget
/// 错误地继承 `currentStreak`。守卫要把这种 case 识别成 `effectiveStreak == 0`。
///
/// 现有 `WidgetSnapshotTests` 的 today-context 4 组(today / yesterday / 2 days ago / empty)
/// 不覆盖 future case,本 suite 专补这条。
@Suite("WidgetTodayContext future-date guard")
struct WidgetTodayContextFutureDateTests {

    /// 未来 1 天的 entry:不算今天写过,也不能继承 streak。
    @Test
    func todayContext_lastEntryInFuture_doesNotInheritStreak() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let asOf = calendar.date(from: DateComponents(year: 2026, month: 5, day: 4, hour: 12))!
        let lastEntry = calendar.date(from: DateComponents(year: 2026, month: 5, day: 5, hour: 12))!

        let snap = makeSnap(currentStreak: 5, lastEntryDate: lastEntry)
        let ctx = WidgetTodayContext.compute(snapshot: snap, asOf: asOf, calendar: calendar)

        #expect(ctx.wroteToday == false,
                "future entry must not be treated as today-written")
        #expect(ctx.effectiveStreak == 0,
                "future entry must NOT inherit currentStreak (daysAgo<0 guard)")
    }

    /// 极端:未来 30 天的 entry。同样必须返回 0,锁住守卫不被改成 `daysAgo >= -N`。
    @Test
    func todayContext_lastEntryInDistantFuture_stillReturnsZeroStreak() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let asOf = calendar.date(from: DateComponents(year: 2026, month: 5, day: 4, hour: 12))!
        let lastEntry = calendar.date(from: DateComponents(year: 2026, month: 6, day: 3, hour: 12))!

        let snap = makeSnap(currentStreak: 42, lastEntryDate: lastEntry)
        let ctx = WidgetTodayContext.compute(snapshot: snap, asOf: asOf, calendar: calendar)

        #expect(ctx.wroteToday == false)
        #expect(ctx.effectiveStreak == 0,
                "distant future entry must always collapse streak to 0")
    }

    /// 边界:`lastEntryDate == asOf`(刚写完同一时刻)必须算今天写过 + 继承 streak。
    /// 防御未来有人把守卫错改成 `daysAgo > 0`(strict greater)误把"刚写完"算成 future。
    @Test
    func todayContext_lastEntryExactlyAsOf_treatsAsToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let asOf = calendar.date(from: DateComponents(year: 2026, month: 5, day: 4, hour: 12))!

        let snap = makeSnap(currentStreak: 3, lastEntryDate: asOf)
        let ctx = WidgetTodayContext.compute(snapshot: snap, asOf: asOf, calendar: calendar)

        #expect(ctx.wroteToday == true,
                "lastEntryDate == asOf must count as wroteToday (boundary)")
        #expect(ctx.effectiveStreak == 3,
                "boundary daysAgo == 0 must inherit streak (not get clipped by guard)")
    }

    // MARK: - Helpers

    private func makeSnap(currentStreak: Int, lastEntryDate: Date) -> WidgetSnapshot {
        WidgetSnapshot(
            generatedAt: Date(),
            currentStreak: currentStreak,
            longestStreak: currentStreak,
            lastEntryDate: lastEntryDate,
            lastEntryMood: 0.5,
            prompt: nil
        )
    }
}
