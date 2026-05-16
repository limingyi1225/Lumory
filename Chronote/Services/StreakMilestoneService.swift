import Foundation
import CoreData

/// **Streak milestone 庆祝**
///
/// 用户 save 一篇日记 → fire-and-forget evaluate → 如果 currentStreak 命中 milestone 且**之前
/// 没庆祝过**,set `pendingMilestone`,UI 顶层 overlay 渲染 `StreakMilestoneCelebration`。
///
/// **Milestones**:7 / 14 / 30 / 60 / 100,然后每加 100 一档(200 / 300 / ...)。
///
/// **去重**:`UserDefaults` 持久化已庆祝过的 milestone 集合 — 删日记导致 streak 跌回再升,
/// 同一个 milestone **不再 fire**。
///
/// **触发**:
///   - HomeView.addEntry save 成功后(主路径)
///   - DiaryDetailView edit save 成功后(改 date 可能让 streak 变化)
///
/// **不打断流**:Service 是 fire-and-forget,UI overlay 是 non-modal,任意 tap / 3s 自动 fade。
///
/// **`AppGroup.userDefaults` 持久化**(跟 widget 同 store)— 与 widget snapshot 的 streak 看到的是
/// 同一份数据视图。
@MainActor
final class StreakMilestoneService: ObservableObject {
    static let shared = StreakMilestoneService()

    /// 待显示的 milestone(streak 天数 + 当时心情色)。UI 监听这个,非 nil 时渲染 overlay。
    @Published var pendingMilestone: PendingMilestone?

    struct PendingMilestone: Equatable {
        /// 命中的 milestone 天数(7 / 14 / 30 / 60 / 100 / 200 / ...)
        let days: Int
        /// 触发时刻最新一篇 entry 的 mood,用于 overlay 大数字配色 — 跟当天心情同源。
        let moodValue: Double
    }

    private let defaults: UserDefaults
    private let celebratedKey = "lumory.celebratedMilestones.v1"
    private var celebrated: Set<Int>
    /// (2026-05-15 megareview P2-12)持当前 evaluate task,新请求进来就 cancel 老的。
    /// 原 fire-and-forget 让用户连写 3 篇 → 3 个并发 streak fetch 跑全表 dict-fetch,只一个能改 UI
    /// (celebrated.insert 主线程 serialize),其余两个是纯浪费。
    private var evaluateTask: Task<Void, Never>?

    private init(defaults: UserDefaults = AppGroup.userDefaults) {
        self.defaults = defaults
        if let arr = defaults.array(forKey: celebratedKey) as? [Int] {
            self.celebrated = Set(arr)
        } else {
            self.celebrated = []
        }
    }

    /// 主路径调用入口。fire-and-forget — 内部跑后台 fetch 算 streak,主线程 set pendingMilestone。
    /// 调用方负责 `viewContext.save()` 已成功 + 传当时 entry 的 moodValue(用于 overlay 配色)。
    /// `persistence` 取一次 streak 比单纯传值更稳:多端同步 / 删除编辑等 race 时 streak 应基于真实
    /// CoreData 状态算,不能信调用方传进来的 stale 值。
    func evaluateAfterSave(persistence: PersistenceController, latestEntryMood: Double) {
        // Cancel-and-replace:连写多篇时只有最新一次 evaluate 算到完。
        // (2026-05-15 megareview P2-12)
        // (2026-05-15 superreview-4 P2)`self` 是 `static let shared` singleton 永不释放,
        // 移除原 `[weak self]` + `guard let self else { return }` —— 既是 dead code
        // 也会误导后人以为这里有生命周期管理。跟 `OpenAIService+OneShotAI` 同 idiom。
        evaluateTask?.cancel()
        evaluateTask = Task {
            let streak = await Self.computeCurrentStreak(persistence: persistence)
            // 取消的 task 不写 UI(已被新 evaluate 替换,streak 算到一半的数据无意义)。
            guard !Task.isCancelled else { return }
            self.handleStreak(streak, moodValue: latestEntryMood)
        }
    }

    private func handleStreak(_ streak: Int, moodValue: Double) {
        #if DEBUG
        commitObservationsForTesting.append((streak: streak, moodValue: moodValue))
        #endif
        guard let milestone = Self.milestoneFor(streak: streak) else { return }
        guard !celebrated.contains(milestone) else { return }
        celebrated.insert(milestone)
        defaults.set(Array(celebrated).sorted(), forKey: celebratedKey)
        pendingMilestone = PendingMilestone(days: milestone, moodValue: moodValue)
    }

    /// UI overlay tap 或 auto-fade 完调,清掉触发 SwiftUI 自动 dismiss。
    func dismiss() {
        pendingMilestone = nil
    }

    /// **测试 seam** — 让单测能 inject "已庆祝过" 集合 / 重置 / 直接 evaluate。
    /// `private(set)` `celebrated` 加显式 reset/set 接口,不让 production 代码绕过 milestone 算法。
    #if DEBUG
    /// 测试 spy:`handleStreak` 每次被调时记一条 `(streak, moodValue)`。
    /// 用来锁住 cancel-and-replace 的真契约:被 cancel 的 task 不应跑到 handleStreak。
    /// 老 `firstTask?.isCancelled == true` 断言是 tautology(cancel() 调过 flag 必 true,
    /// 不证明 handleStreak 没跑)。spy 直接观察 commit 次数 + 顺序就明确。
    var commitObservationsForTesting: [(streak: Int, moodValue: Double)] = []

    func resetCelebratedForTesting() {
        celebrated.removeAll()
        commitObservationsForTesting.removeAll()
        defaults.removeObject(forKey: celebratedKey)
    }

    func evaluateForTesting(streak: Int, moodValue: Double) {
        handleStreak(streak, moodValue: moodValue)
    }

    /// 测试 seam:让单测能 await 当前在飞 evaluate task 完成。
    /// (老 `inFlightEvaluateTaskForTesting` 已删 — 暴露 Task ivar 让 test 用
    /// `firstTask?.isCancelled` 锁死 implementation 策略,改世代号模式时 test 会废。
    /// 现在用 `commitObservationsForTesting` spy 测对外可观察契约,跟实现解耦。)
    func drainEvaluateTaskForTesting() async {
        await evaluateTask?.value
    }
    #endif

    /// 给 streak 数判断是否是 milestone。**纯函数**,easy to unit-test。
    /// 7 / 14 / 30 / 60 / 100 是入门档;100+ 每加 100 一档(200 / 300 / 400 / ...)。
    /// 1000 / 2000 / ... 也都自动覆盖(都是 100 倍数)。
    nonisolated static func milestoneFor(streak: Int) -> Int? {
        let fixed: Set<Int> = [7, 14, 30, 60, 100]
        if fixed.contains(streak) { return streak }
        if streak > 100 && streak.isMultiple(of: 100) { return streak }
        return nil
    }

    /// 抓最新 streak。dict-fetch only,不 hydrate NSManagedObject(跟 WidgetSnapshotService 同 idiom)。
    /// 基于 `InsightsEngine.computeStreaks` 复用算法。
    private static func computeCurrentStreak(persistence: PersistenceController) async -> Int {
        let now = Date()
        return await persistence.container.performBackgroundTask { context in
            let request = NSFetchRequest<NSDictionary>(entityName: "DiaryEntry")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["date"]
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
            // 跟 widget 同 predicate — 未来日期(CK 同步 / 用户手动)不 polluate streak
            request.predicate = NSPredicate(format: "date <= %@", now as NSDate)
            let dicts: [NSDictionary]
            do {
                dicts = try context.fetch(request)
            } catch {
                Log.warning("[StreakMilestone] fetch failed: \(error)", category: .persistence)
                return 0
            }
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: now)
            var uniqueDaysDesc: [Date] = []
            uniqueDaysDesc.reserveCapacity(min(dicts.count, 4096))
            for dict in dicts {
                guard let date = dict["date"] as? Date else { continue }
                let day = calendar.startOfDay(for: date)
                if uniqueDaysDesc.last != day { uniqueDaysDesc.append(day) }
            }
            let (current, _) = InsightsEngine.computeStreaks(
                uniqueDaysDesc: uniqueDaysDesc,
                today: today,
                calendar: calendar
            )
            return current
        }
    }
}
