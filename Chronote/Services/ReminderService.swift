import Foundation
import CoreData
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - ReminderNotificationRouter

#if canImport(UserNotifications)
final class ReminderNotificationRouter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = ReminderNotificationRouter()

    static let categoryIdentifier = "lumory.reminder.compose"
    static let composeIntentKey = "lumory.intent"
    static let composeIntentValue = "compose"

    @Published private(set) var composeFocusRequestID: UUID?

    static func shouldFocusComposer(
        identifier: String,
        categoryIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> Bool {
        if identifier.hasPrefix("lumory.reminder.") { return true }
        if categoryIdentifier == Self.categoryIdentifier { return true }
        return userInfo[Self.composeIntentKey] as? String == Self.composeIntentValue
    }

    @MainActor
    func consumeComposeFocusRequest() -> UUID? {
        let requestID = composeFocusRequestID
        composeFocusRequestID = nil
        return requestID
    }

    /// 共享 focus 入口:reminder 通知点击和 widget URL (`lumory://compose`) 都走这里。
    /// 唯一一条 focus 通路 —— 新功能想触发 composer 都从这进。
    nonisolated func requestComposeFocus() {
        Task { @MainActor in
            self.composeFocusRequestID = UUID()
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let request = response.notification.request
        if Self.shouldFocusComposer(
            identifier: request.identifier,
            categoryIdentifier: request.content.categoryIdentifier,
            userInfo: request.content.userInfo
        ) {
            requestComposeFocus()
        }
        completionHandler()
    }

    /// 前台收到通知时,iOS 默认**完全压制**(无 banner / 无 sound / 无 list)。
    /// 我们手动放行 reminder 类通知,让用户即使打开 App 也能看到提醒动作 +
    /// 听到 sound,与 ReminderService.swift 中 `content.sound = .default` 对齐。
    /// 非 reminder(理论上目前没有,但为防 future 代码 schedule 别的通知误伤)→ 沿用默认压制。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let request = notification.request
        if Self.shouldFocusComposer(
            identifier: request.identifier,
            categoryIdentifier: request.content.categoryIdentifier,
            userInfo: request.content.userInfo
        ) {
            completionHandler([.banner, .list, .sound])
        } else {
            completionHandler([])
        }
    }
}
#else
final class ReminderNotificationRouter: ObservableObject {
    static let shared = ReminderNotificationRouter()
    @Published private(set) var composeFocusRequestID: UUID?

    static func shouldFocusComposer(
        identifier: String,
        categoryIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> Bool {
        identifier.hasPrefix("lumory.reminder.")
            || categoryIdentifier == "lumory.reminder.compose"
            || userInfo["lumory.intent"] as? String == "compose"
    }

    @MainActor
    func consumeComposeFocusRequest() -> UUID? {
        nil
    }

    nonisolated func requestComposeFocus() {}
}
#endif

// MARK: - ReminderService
//
// "周期性写日记"提醒。完全本地通知,不走推送。
//
// 模型:**固定周期 + 锚点对齐**(fixed cycles aligned to anchor date)。
//   - 用户选频率:每天 / 每 3 天 / 每周(`ReminderFrequency`)
//   - 锚点(anchorDate):reminder 首次开启的那一天的 startOfDay,持久化、不重置。
//   - 周期是从锚点开始的固定 N 天块。例如锚点 2024-01-01 + 每周 = [01-01..01-07],
//     [01-08..01-14], ... 周期 1 / 2 / 3 ...
//   - 每个周期要求至少 1 篇日记。
//   - 周期内若有日记 → 周期已完成,**最后一天**不提醒。
//   - 周期内若无日记 → **最后一天**提醒(若已过当天 hour:minute,则不补发,避免半夜响)。
//
// 用户的例子(每周):
//   - day 1-7 = 周期 1。day 2 写了 → 周期 1 完成,无提醒。
//   - day 8-14 = 周期 2。若到 day 14 没写 → day 14 hour:minute 提醒。
//   - 从 day 2 写到 day 14 提醒之间:silent days 3-13 = 11 天("剩下5天 + 下周期6天")。
//
// 触发 reschedule 的时机:
//   - App 进入 active(scenePhase)
//   - 用户写完一篇日记 / 删除一篇
//   - Settings 改 frequency / hour:minute / toggle
//
// 持久化:UserDefaults 6 个 key(enabled / hour / minute / frequency / anchorDate / contextualBody)。
// 旧 weeklyTargetDays 一次性迁移(5-7 → daily,2-4 → every3Days,其他 → weekly)。
// 本地通知是设备本地的,不走 iCloud,卸载重装会丢。

/// 用户可选的提醒频率。
enum ReminderFrequency: Int, Codable, CaseIterable, Sendable {
    case daily = 1
    case every3Days = 3
    case weekly = 7

    var localizedLabel: String {
        switch self {
        case .daily: return NSLocalizedString("每天", comment: "Reminder freq daily")
        case .every3Days: return NSLocalizedString("每 3 天", comment: "Reminder freq 3 days")
        case .weekly: return NSLocalizedString("每周", comment: "Reminder freq weekly")
        }
    }

    /// 周期长度(天)
    var cycleDays: Int { rawValue }
}

@MainActor
final class ReminderService: ObservableObject {
    static let shared = ReminderService()

    // MARK: - Persisted state

    @Published private(set) var isEnabled: Bool
    @Published private(set) var hour: Int
    @Published private(set) var minute: Int
    @Published private(set) var frequency: ReminderFrequency
    @Published private(set) var authorizationStatus: AuthorizationStatus = .notDetermined

    /// 用 PromptSuggestionEngine 的 homePlaceholder 作通知 body(否则走 generic 模板)。
    /// 默认 on:reminder 是高 engagement 表面,主题词文案显著优于 "已经 N 天没记了"。
    /// 用户可在 Settings 关掉,关了即用 generic 模板。
    /// 拉 placeholder 在 schedule 时刻(同步,不发网络),pool 空 → 自动 fallback。
    @Published private(set) var useContextualBody: Bool

    /// 当前周期是否已被一篇日记 fulfill —— Settings 进度行用。reschedule() 内部更新。
    @Published private(set) var wroteCurrentCycle: Bool = false
    /// 上次写日记的日期(date 字段;cap 在 now 之前防御未来日期)。Settings 显示"上次记录:N 天前"。
    @Published private(set) var lastEntryDate: Date?

    enum AuthorizationStatus {
        case notDetermined
        case denied
        case authorized
        case provisional
    }

    private let identifierPrefix = "lumory.reminder."
    private let identifierToday = "lumory.reminder.today"
    /// 未来 cycle-end 兜底通知的 identifier 前缀(每条挂一个 `cycleEnd.0`、`cycleEnd.1`...)。
    /// **挂多条**而不是只一条:`repeats: false` + OS 不主动唤醒 App,用户连续不开 App 时,
    /// 单条挂完 fire 一次后就再无 reminder 了。挂未来 N 条 → 用户即使连续 N 个 cycle 不开 App
    /// 仍能收到 reminder。N=8 的覆盖能力:daily 8 天 / 3-day 24 天 / weekly 8 周。
    /// reschedule 时 `identifierPrefix` 前缀 cancel 全清,然后重新挂,保证幂等。
    /// identifier 会带上 generation,防止 stale reschedule task add 完成后误删新一代通知。
    private let identifierCycleEndPrefix = "lumory.reminder.cycleEnd"
    /// 未来 cycle-end 通知挂多少条。iOS UN 限 64 pending/app,8 是安全又够用的折中。
    private let maxFutureFallbacks = 8

    private let defaults = UserDefaults.standard
    private let enabledKey = "lumory.reminder.enabled"
    private let hourKey = "lumory.reminder.hour"
    private let minuteKey = "lumory.reminder.minute"
    private let frequencyKey = "lumory.reminder.frequency"
    private let legacyWeeklyTargetKey = "lumory.reminder.weeklyTargetDays"
    private let anchorDateKey = "lumory.reminder.anchorDate"
    private let useContextualBodyKey = "lumory.reminder.useContextualBody"

    /// 持久化的周期锚点。startOfDay。固定周期对齐用。**首次 enable 时**才落盘 ——
    /// 用户从未启用提醒前 anchorDate 仅作内存占位(用今天),scenePhase=active 触发的
    /// `ReminderService.shared` 初始化不会污染锚点。
    private var anchorDate: Date

    /// 锚点是否已落盘。enable() 第一次成功后置 true 并 persist。
    private var anchorIsPersisted: Bool

    /// 串行化 reschedule —— App active + 写日记 + Settings 改值 可能并发触发。
    /// 用**显式 generation 号**替代单纯 `Task.isCancelled` 检查:UN* API 不响应 task
    /// cancellation,被 cancel 的老 task 仍可能在 await 后写入状态/通知。每次 reschedule
    /// 入口先 `currentRescheduleGen += 1`,后续 await 节点 `guard myGen == currentRescheduleGen`
    /// 兜底,避免老 task 用 stale 状态覆盖新 task 已写好的结果(codex P1 #5 fix)。
    private var rescheduleTask: Task<Void, Never>?
    private var currentRescheduleGen: Int = 0

    private init() {
        self.hour = (defaults.object(forKey: hourKey) as? Int) ?? 21
        self.minute = (defaults.object(forKey: minuteKey) as? Int) ?? 0
        self.isEnabled = defaults.bool(forKey: enabledKey)
        self.frequency = Self.loadFrequency(from: defaults, legacyKey: legacyWeeklyTargetKey, key: frequencyKey)
        self.useContextualBody = Self.loadUseContextualBody(from: defaults, key: useContextualBodyKey)
        // 锚点:**仅在已落盘时读出**。从未 enable 过 → 用今天作内存占位,**不**写盘 ——
        // 等用户首次 enable 时再 persist。否则 cold launch 那天就钉死了 cycle 锚点,
        // 几天后才 enable 的用户拿到的是"安装日"周期而非"启用日"周期(codex P0 fix)。
        if let stored = defaults.object(forKey: anchorDateKey) as? Date {
            self.anchorDate = stored
            self.anchorIsPersisted = true
        } else {
            self.anchorDate = Calendar.current.startOfDay(for: Date())
            self.anchorIsPersisted = false
        }
    }

    /// 旧 weeklyTargetDays 一次性迁移到新 frequency。
    /// - 5-7 → daily(老用户每周想写 5+ 天 → 每天提醒最匹配)
    /// - 2-4 → every3Days
    /// - 其他 → weekly
    /// 迁移成功后**清掉 legacy key**,避免之后再走这条路径(codex P2 #17 fix)。
    /// `internal` 仅为 unit test 可见(`@testable import`) —— 产品代码走 init() 即可。
    /// `nonisolated`:纯函数,只读传入的 defaults。`ReminderService` 是 @MainActor,
    /// 不加 nonisolated 时单测从 non-MainActor scope 调会编不过(CLAUDE.md 标过的坑)。
    nonisolated static func loadFrequency(
        from defaults: UserDefaults,
        legacyKey: String,
        key: String
    ) -> ReminderFrequency {
        if let raw = defaults.object(forKey: key) as? Int,
           let f = ReminderFrequency(rawValue: raw) {
            // 新 key 已存在 → 旧 key 不再有用,清掉防止下次启动 dead-code 路径
            if defaults.object(forKey: legacyKey) != nil {
                defaults.removeObject(forKey: legacyKey)
            }
            return f
        }
        if let oldTarget = defaults.object(forKey: legacyKey) as? Int {
            let migrated: ReminderFrequency = {
                switch oldTarget {
                case 5...7: return .daily
                case 2...4: return .every3Days
                default: return .weekly
                }
            }()
            // 落新 key + 清旧 key
            defaults.set(migrated.rawValue, forKey: key)
            defaults.removeObject(forKey: legacyKey)
            return migrated
        }
        return .weekly
    }

    /// `useContextualBody` **新装机默认 false**(privacy-first)—— AI 生成的 placeholder 短句
    /// 会嵌入真实主题词(妈妈/前任/Abby),挂到通知 body 后 iOS 默认在锁屏上完整显示,
    /// 等于把个人内容暴露给肩窥 / 借出去的手机。改成默认 off,让用户在 Settings 主动 opt-in。
    ///
    /// **legacy 用户保护**:旧版本默认是 true 但**没有把 true 显式写到盘**(代码读 `bool(forKey:)`
    /// 缺省返 false,旧版用 `?? true` 默认值合成)。直接改默认 false 会让所有老用户静默丢失
    /// contextual body 体验。`enabledKey` 用作"激活过 reminder feature"的存在性指标 ——
    /// 若 `enabledKey` 被写过(any value:true 表示当前开,false 表示用户主动关过)且
    /// `useContextualBodyKey` 缺失 → 老用户 → 显式写一次 true 锁住旧体验。
    /// 完全新装机(两个 key 都缺) → 走 false 隐私默认。
    /// 写一次后这函数后续都走"显式值"分支,不再走迁移逻辑(幂等)。
    ///
    /// `internal` 仅为 unit test canary;产品代码走 init() 即可。
    /// `nonisolated`:同 loadFrequency,纯函数,跨 actor 调用不需要 hop。
    nonisolated static func loadUseContextualBody(from defaults: UserDefaults, key: String) -> Bool {
        if let stored = defaults.object(forKey: key) as? Bool {
            return stored  // 显式值,走用户当前选择
        }
        // 缺失 + reminder 系统已激活过(enabledKey 写过任意值)→ legacy 用户保护:写 true 锁住旧体验。
        // 完全新装机 → 走 false 隐私默认。
        let enabledKey = "lumory.reminder.enabled"
        if defaults.object(forKey: enabledKey) != nil {
            defaults.set(true, forKey: key)
            return true
        }
        return false
    }

    // MARK: - Public API

    /// Settings / app lifecycle 调,把 OS 当前权限同步到 @Published。
    func refreshAuthorizationStatus() async {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .denied:
            authorizationStatus = .denied
        case .authorized:
            authorizationStatus = .authorized
        case .provisional, .ephemeral:
            authorizationStatus = .provisional
        case .notDetermined:
            authorizationStatus = .notDetermined
        @unknown default:
            authorizationStatus = .notDetermined
        }

        // 系统层面权限被撤销 → 自动把 enabled 落回 false + **直接 cancel 已挂的 pending**。
        // **不调 `requestReschedule()`** —— 那条路径会绕去 doReschedule(自身 await 这个函数,
        // 制造递归),靠世代号兜住但模式脆弱。
        // **但 cancel side-effect 必须保留**:之前 reviewer 抓到的 regression — Settings.task 路径调用
        // 这个函数时如果不 cancel,旧的 lumory.reminder.* 一次性请求留在 UN center,用户后来
        // 在 iOS 设置里再开通知权限、还没打开 Lumory → 旧 reminder 仍然响,App toggle 是 off
        // 但通知照发,严重不一致。
        if isEnabled, authorizationStatus == .denied {
            isEnabled = false
            defaults.set(false, forKey: enabledKey)
            // 不绕 reschedule,直接 cancel(等价于 disable() 的 cancel-only 逻辑)。
            await cancelAllPendingReminderNotifications()
        }
        #endif
    }

    /// Prefix-cancel 所有 `lumory.reminder.*` pending **和** delivered 通知。
    /// 给 `disable()` 和 `refreshAuthorizationStatus`(权限被撤后)用。
    /// - **pending**:还没 fire 的 one-shot,清掉防止未来 fire。
    /// - **delivered**:已经 fire 落在通知中心 / 锁屏摘要里的,清掉防止用户关 reminder 后通知中心
    ///   里还堆着旧 reminder 一直能看到。`removePendingNotificationRequests` 不清这个 list。
    private func cancelAllPendingReminderNotifications() async {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let toCancel = pending.compactMap { req -> String? in
            req.identifier.hasPrefix(identifierPrefix) ? req.identifier : nil
        }
        if !toCancel.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: toCancel)
        }
        let delivered = await center.deliveredNotifications()
        let toRemoveDelivered = delivered.compactMap { notif -> String? in
            notif.request.identifier.hasPrefix(identifierPrefix) ? notif.request.identifier : nil
        }
        if !toRemoveDelivered.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: toRemoveDelivered)
        }
        if !toCancel.isEmpty || !toRemoveDelivered.isEmpty {
            Log.info(
                "[ReminderService] cleared pending=\(toCancel.count), delivered=\(toRemoveDelivered.count)",
                category: .general
            )
        }
        #endif
    }

    /// 开 toggle:requestAuthorization + 落 schedule。返回 false 表示权限被拒。
    @discardableResult
    func enable() async -> Bool {
        #if canImport(UserNotifications)
        // Screenshot mode 早返:任何 UI test / 截图流程意外触发 reminder toggle,
        // 系统通知权限弹窗会盖在 Home 上把首屏截烂。跟 ChronoteApp.requestPermissions()
        // 同样的守卫。
        #if DEBUG
        if UITestSampleData.isActive { return false }
        #endif
        let center = UNUserNotificationCenter.current()
        do {
            // 不请求 .badge —— 我们从不在 UNMutableNotificationContent.badge 里设值
            // (CLAUDE.md 已决定不维护 badge counter)。
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            await refreshAuthorizationStatus()
            if !granted { return false }
        } catch {
            Log.error("[ReminderService] requestAuthorization failed: \(error)", category: .general)
            return false
        }
        isEnabled = true
        defaults.set(true, forKey: enabledKey)
        // **首次** enable:此刻才把 anchorDate 钉死(startOfDay)+ persist。
        // 后续 disable/enable 不重置(用户可能只是临时关掉)。
        if !anchorIsPersisted {
            let today = Calendar.current.startOfDay(for: Date())
            anchorDate = today
            defaults.set(today, forKey: anchorDateKey)
            anchorIsPersisted = true
        }
        requestReschedule()
        return true
        #else
        return false
        #endif
    }

    // 以下 3 个 update*/disable 函数 update* 内部 0 await,sync。disable 因为要**同步等清理完成**(否则
    // fire-and-forget 模式下用户关 toggle 立即切后台,iOS suspend 进程时 cancel Task 可能还没跑,
    // 已挂的 cycleEnd.0..7 多条未来 one-shot 仍会按计划 fire 出去)所以是 async。
    // SettingsView 的 Binding setter 在 `Task { @MainActor in ... }` 里,可以 await。

    /// 关 reminder。**必须 await** —— caller 不能 fire-and-forget,清理工作要保证完成。
    /// 步骤(两步式 cancel,防 in-flight race):
    /// 1. 标 isEnabled=false + persist + bump gen,任何后续 reschedule 入口都被 `guard isEnabled` 挡掉。
    /// 2. **第一次** await prefix 清 pending + delivered —— 抓存量。如果用户切后台 / 杀进程导致
    ///    后续步骤跑不完,至少这一次清掉了大头。
    /// 3. await 老 reschedule task `.value`,等它跑完 —— 它可能正卡在 `await center.add(...)`,
    ///    add 完成那一瞬间又往 UN center 添一条新 pending(race 窗口)。
    /// 4. **第二次** await prefix 清 pending + delivered —— 抓 race 新增。
    func disable() async {
        isEnabled = false
        defaults.set(false, forKey: enabledKey)
        let oldTask = rescheduleTask
        rescheduleTask?.cancel()
        currentRescheduleGen &+= 1
        await cancelAllPendingReminderNotifications()  // 1) 存量
        await oldTask?.value  // Task<Void, Never>:cancel 后 await .value 仍等到 Task 退出
        await cancelAllPendingReminderNotifications()  // 2) race 新增
    }

    func updateTime(hour newHour: Int, minute newMinute: Int) {
        let validHour = max(0, min(23, newHour))
        let validMinute = max(0, min(59, newMinute))
        guard validHour != hour || validMinute != minute else { return }
        hour = validHour
        minute = validMinute
        defaults.set(validHour, forKey: hourKey)
        defaults.set(validMinute, forKey: minuteKey)
        if isEnabled { requestReschedule() }
    }

    func updateFrequency(_ newFrequency: ReminderFrequency) {
        guard newFrequency != frequency else { return }
        frequency = newFrequency
        defaults.set(newFrequency.rawValue, forKey: frequencyKey)
        if isEnabled { requestReschedule() }
    }

    func updateUseContextualBody(_ enabled: Bool) {
        guard enabled != useContextualBody else { return }
        useContextualBody = enabled
        defaults.set(enabled, forKey: useContextualBodyKey)
        if isEnabled { requestReschedule() }
    }

    /// 外部触发点(App active / 写完日记 / 删除日记 / Settings 改值)调。
    /// task cancel + replace,频繁触发不会堆 task。配 generation 号兜底
    /// (UN API 不响应 task cancellation,光靠 Task.isCancelled 不可靠)。
    func requestReschedule() {
        rescheduleTask?.cancel()
        currentRescheduleGen &+= 1
        let myGen = currentRescheduleGen
        rescheduleTask = Task { [weak self] in
            await self?.doReschedule(gen: myGen)
        }
    }

    /// 不依赖 isEnabled,任何时候都更新本周期写过状态(给 Settings 进度行用)。
    func refreshProgress() async {
        let info = await computeCycleInfo()
        await applyComputedInfo(info)
    }

    /// "下次提醒"时间。Settings UI 显示用。
    ///
    /// **不读 UNUserNotificationCenter pending list** —— 那条路径有竞态:用户切 frequency picker 时,
    /// `updateFrequency` 调 `requestReschedule()` 是 fire-and-forget Task,**还没跑完**。
    /// SettingsView `.onChange(of: reminderService.frequency)` 同帧 fire,如果这一刻 peek 读 pending list,
    /// 拿到的还是上一个 frequency 的 stale 通知,UI 显示一个错的"下次时间"且来回拨 picker 会漂。
    ///
    /// 改成 **纯函数**:基于当前 `frequency` / `hour` / `minute` / `anchorDate` 直接算。这跟 schedule
    /// 路径用同一份 `cycleBounds`,语义一致但不依赖异步 reschedule 完成。
    func peekNextFireDate() -> Date? {
        guard isEnabled else { return nil }
        return Self.nextFireDate(
            isEnabled: true,
            frequency: frequency,
            hour: hour,
            minute: minute,
            anchor: anchorDate,
            referenceDate: Date(),
            calendar: Calendar.current
        )
    }

    /// 纯函数版本 — 给 UI 同步算 + 给单测注入 referenceDate / calendar。
    /// 对单测的 fixture 必须用 `nonisolated static`,这里给统一入口。
    ///
    /// **算法**:从 referenceDate 所在的 cycle 起,逐 cycle 找一个 fireTime > referenceDate。
    /// fireTime = "cycle 最后一天" hour:minute(因为 cycleEnd 是 exclusive 上界,真正"该日"是 end-1)。
    /// **不查 wroteCurrentCycle** —— 那个状态会因为 reschedule 异步而 stale,且用户在 Settings 看到
    /// "下次提醒 周三 21:00"是个 *计划* 而非保证,跟实际"今天写过就 skip"的 schedule 行为有 1-cycle 偏差是
    /// 可接受的(用户期望的是 picker 立刻反映新值)。
    nonisolated static func nextFireDate(
        isEnabled: Bool,
        frequency: ReminderFrequency,
        hour: Int,
        minute: Int,
        anchor: Date,
        referenceDate: Date,
        calendar: Calendar
    ) -> Date? {
        guard isEnabled else { return nil }
        var bounds = cycleBounds(referenceDate: referenceDate, anchor: anchor, frequency: frequency, calendar: calendar)
        // 安全 cap:理论上当前 cycle fireTime 不行就跳到下个 cycle 必然 fire(同 hour:minute 在未来必定大于 now)。
        // cap 32 防 calendar.date 失败时死循环。
        for _ in 0..<32 {
            let lastDay = calendar.date(byAdding: .day, value: -1, to: bounds.end) ?? bounds.end
            var comps = calendar.dateComponents([.year, .month, .day], from: lastDay)
            comps.hour = hour
            comps.minute = minute
            if let fire = calendar.date(from: comps), fire > referenceDate {
                return fire
            }
            // 该 cycle 的 fireTime 已过 → 跳到下一个 cycle
            guard
                let nextStart = calendar.date(byAdding: .day, value: frequency.cycleDays, to: bounds.start),
                let nextEnd = calendar.date(byAdding: .day, value: frequency.cycleDays, to: nextStart)
            else { return nil }
            bounds = (nextStart, nextEnd)
        }
        return nil
    }

    // MARK: - Reschedule core

    private func doReschedule(gen: Int) async {
        // 多入口快速并发触发时,被 cancel 的老 task 仍会继续执行(因为
        // UNUserNotificationCenter 的方法不响应 Task.isCancelled)。每个 await 后用 gen 兜底。
        guard gen == currentRescheduleGen else { return }

        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        guard gen == currentRescheduleGen else { return }
        let toCancel = pending.compactMap { req -> String? in
            req.identifier.hasPrefix(identifierPrefix) ? req.identifier : nil
        }
        if !toCancel.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: toCancel)
        }
        #endif

        // disabled 时:pending 已 cancel 即可结束。
        // CoreData fetch / auth check / UI state 都不需要,省掉冷启动期 backfill 竞争。
        // 注意:不能在 doReschedule 入口 early-return,因为 `disable()` 也走这条路 cancel 通知。
        guard isEnabled else { return }

        let info = await computeCycleInfo()
        guard gen == currentRescheduleGen else { return }
        await applyComputedInfo(info)

        await refreshAuthorizationStatus()
        guard gen == currentRescheduleGen else { return }
        guard authorizationStatus == .authorized || authorizationStatus == .provisional else { return }

        // 决定 reminder 挂在哪些日期。两类 trigger:
        //   (1) Today reminder —— 今天 = current cycle 最后一天 且 本周期未写。
        //       用户在 cycle 最后一天打开 App 的 hot path,fireTime > now 才挂。
        //   (2) Cycle-end fallback —— 找**最近一个未来 cycle 末**且该 cycle 未被写过 + fireTime > now,
        //       挂一发 one-shot。
        //       - 当前 cycle 已写 → 跳到下一个 cycle 末(原本只在"未写时"挂的逻辑会让 daily 用户写完
        //         今天就再无任何 reminder,直到下次开 App。codex P1 fix)
        //       - 当前 cycle 未写但 fireTime 已过(例:每天 21:00 提醒,用户 22:00 打开) →
        //         往后跳到下一个 cycle 末
        //       - 当 (1) 已覆盖今天 → 跳过当天,挂下一个 cycle 末(避免同 fireTime 两条通知)
        let now = Date()
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)

        let needsToday = info.todayIsCycleEnd && !info.wroteCurrentCycle
        if needsToday {
            var todayComps = calendar.dateComponents([.year, .month, .day], from: startOfToday)
            todayComps.hour = hour
            todayComps.minute = minute
            if let fireTime = calendar.date(from: todayComps), fireTime > now {
                await scheduleOneShot(
                    at: fireTime,
                    identifier: generationScopedIdentifier(identifierToday, gen: gen),
                    daysSilent: info.daysSinceLastEntry,
                    gen: gen
                )
                guard gen == currentRescheduleGen else { return }
            }
        }

        // Cycle-end fallback:挂**多条**未来 cycle 末通知(不只一条),覆盖
        // "用户连续 N 个 cycle 都不开 App" 的 case —— `repeats: false` + OS 不会唤醒 App
        // 重排,所以单条挂完一次就断;多挂几条能让 reminder 链延续(codex P1 fix)。
        // 跳过条件:(a) fireTime 已过 (b) 当前 cycle 已写 (c) 与 today branch 撞日。
        // cap = maxFutureFallbacks。reschedule 入口已 prefix-cancel 全清,挂完保证幂等。
        let cycleLength = frequency.cycleDays
        var targetCycleEnd = info.cycleEnd
        // 只有"当前 cycle"才可能"已写";未来 cycle 还没开始,定义上不可能 fulfilled。
        var currentCycleWritten = info.wroteCurrentCycle
        var scheduledCount = 0

        // 外层 loop cap:32 次足以为 maxFutureFallbacks=8 找到 8 个有效 slot
        // (考虑跳过当天 / 已写 cycle 的迭代浪费)。
        for _ in 0..<32 {
            if scheduledCount >= maxFutureFallbacks { break }

            let lastDay = calendar.date(byAdding: .day, value: -1, to: targetCycleEnd) ?? targetCycleEnd
            var fbComps = calendar.dateComponents([.year, .month, .day], from: lastDay)
            fbComps.hour = hour
            fbComps.minute = minute

            let isCurrentCycle = (targetCycleEnd == info.cycleEnd)
            let coveredByToday = needsToday && calendar.isDate(lastDay, inSameDayAs: startOfToday)

            if let fireTime = calendar.date(from: fbComps),
               fireTime > now,
               !(isCurrentCycle && currentCycleWritten),
               !coveredByToday {
                // daysSilent 用 cached lastEntryDate 算,省一次 background fetch
                let daysSilent: Int? = {
                    guard let last = info.lastEntryDate else { return nil }
                    let lastDayOfEntry = calendar.startOfDay(for: last)
                    return calendar.dateComponents([.day], from: lastDayOfEntry, to: lastDay).day
                }()
                await scheduleOneShot(
                    at: fireTime,
                    identifier: "\(generationScopedIdentifier(identifierCycleEndPrefix, gen: gen)).\(scheduledCount)",
                    daysSilent: daysSilent,
                    gen: gen
                )
                scheduledCount += 1
                guard gen == currentRescheduleGen else { return }
            }

            // 总是 advance(无论是否 schedule),否则空转死循环
            targetCycleEnd = calendar.date(byAdding: .day, value: cycleLength, to: targetCycleEnd) ?? targetCycleEnd
            currentCycleWritten = false  // future cycles haven't started — definitely unwritten
        }

        Log.info(
            """
            [ReminderService] reschedule: freq=\(frequency.rawValue), \
            wroteCurrentCycle=\(info.wroteCurrentCycle), todayCycleEnd=\(info.todayIsCycleEnd), \
            today=\(needsToday), cycleEndFallbacks=\(scheduledCount)
            """,
            category: .general
        )
    }

    private func scheduleOneShot(at fireTime: Date, identifier: String, daysSilent: Int?, gen: Int) async {
        #if canImport(UserNotifications)
        guard gen == currentRescheduleGen else { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("Lumory", comment: "Reminder title")
        // 主题词文案 vs 通用模板:开关 + cache 命中时用 placeholder,否则 fallback。
        // randomHomePlaceholder() 是同步纯函数,不发网络;cache 由 HomeView/AskPast 进入
        // 时通过 PromptSuggestionEngine.refreshIfNeeded 自然刷新。
        let contextualBody: String? = useContextualBody
            ? PromptSuggestionEngine.shared.randomHomePlaceholder()
            : nil
        content.body = contextualBody ?? Self.notificationBody(frequency: frequency, daysSilent: daysSilent)
        content.sound = .default
        content.categoryIdentifier = ReminderNotificationRouter.categoryIdentifier
        content.userInfo = [
            ReminderNotificationRouter.composeIntentKey: ReminderNotificationRouter.composeIntentValue
        ]

        let triggerComps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: fireTime
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: triggerComps, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        do {
            try await center.add(request)
            if gen != currentRescheduleGen {
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
            }
        } catch {
            Log.error("[ReminderService] schedule failed (\(identifier)): \(error)", category: .general)
        }
        #endif
    }

    private func generationScopedIdentifier(_ base: String, gen: Int) -> String {
        "\(base).gen\(gen)"
    }

    /// 通知文案根据 frequency + daysSilent 动态化。
    /// daysSilent 来自 lastEntryDate 到今天的整数天差。nil 表示从未写过。
    static func notificationBody(frequency: ReminderFrequency, daysSilent: Int?) -> String {
        switch frequency {
        case .daily:
            if let days = daysSilent, days >= 2 {
                return String(format: NSLocalizedString("已经 %d 天没记了,今天写一笔?", comment: "Reminder body daily silent"), days)
            }
            return NSLocalizedString("今天的故事记一笔吧", comment: "Reminder body daily fresh")
        case .every3Days:
            if let days = daysSilent, days >= 1 {
                return String(format: NSLocalizedString("已经 %d 天没记了,记一笔吧", comment: "Reminder body 3-day"), days)
            }
            return NSLocalizedString("过去几天有什么想写下来的吗?", comment: "Reminder body 3-day fresh")
        case .weekly:
            if let days = daysSilent, days >= 1 {
                return String(format: NSLocalizedString("本周还没记呢,已经 %d 天没写了", comment: "Reminder body weekly silent"), days)
            }
            return NSLocalizedString("本周还没记呢,今天写一笔吧", comment: "Reminder body weekly fresh")
        }
    }

    // MARK: - Cycle math

    /// 周期信息快照。在 main actor 上算完一次,reschedule 和 refreshProgress 共用。
    struct CycleInfo: Sendable {
        let cycleStart: Date
        let cycleEnd: Date  // exclusive
        let todayIsCycleEnd: Bool
        let wroteCurrentCycle: Bool
        let lastEntryDate: Date?
        let daysSinceLastEntry: Int?
    }

    /// 给定参考日期,算 cycle 边界 + 写状态。referenceDate 默认 = 今天。
    private func computeCycleInfo(referenceDate: Date = Date()) async -> CycleInfo {
        let bounds = cycleBounds(for: referenceDate)
        let lastEntry = await fetchLastEntryDate()  // 已 cap at now
        let calendar = Calendar.current
        let startOfRef = calendar.startOfDay(for: referenceDate)
        let lastDayOfCycle = calendar.date(byAdding: .day, value: -1, to: bounds.end) ?? bounds.start
        let isLastDay = calendar.isDate(startOfRef, inSameDayAs: lastDayOfCycle)
        let wrote: Bool = {
            guard let lastEntry else { return false }
            return lastEntry >= bounds.start && lastEntry < bounds.end
        }()
        let daysSince: Int? = {
            guard let lastEntry else { return nil }
            let lastDay = calendar.startOfDay(for: lastEntry)
            return calendar.dateComponents([.day], from: lastDay, to: startOfRef).day
        }()
        return CycleInfo(
            cycleStart: bounds.start,
            cycleEnd: bounds.end,
            todayIsCycleEnd: isLastDay,
            wroteCurrentCycle: wrote,
            lastEntryDate: lastEntry,
            daysSinceLastEntry: daysSince
        )
    }

    private func applyComputedInfo(_ info: CycleInfo) async {
        wroteCurrentCycle = info.wroteCurrentCycle
        lastEntryDate = info.lastEntryDate
    }

    /// 给定 date,返回它所在 cycle 的 [start, end)。cycle 长度 = frequency.cycleDays,
    /// 对齐到 anchorDate(startOfDay)。
    private func cycleBounds(for date: Date) -> (start: Date, end: Date) {
        Self.cycleBounds(referenceDate: date, anchor: anchorDate, frequency: frequency, calendar: Calendar.current)
    }

    /// 周期边界纯函数。给单测用 —— 注入 calendar(timezone-explicit)+ 任意 anchor / frequency,
    /// 不需要构造整个 `@MainActor ReminderService`。
    /// 返回 `[start, end)`,start = anchor 起算的某倍 cycleDays、end = start + cycleDays。
    nonisolated static func cycleBounds(
        referenceDate: Date,
        anchor: Date,
        frequency: ReminderFrequency,
        calendar: Calendar
    ) -> (start: Date, end: Date) {
        let anchorDay = calendar.startOfDay(for: anchor)
        let startOfDay = calendar.startOfDay(for: referenceDate)
        let cycleLength = frequency.cycleDays

        let daysFromAnchor = calendar.dateComponents([.day], from: anchorDay, to: startOfDay).day ?? 0
        // 如果 referenceDate 在 anchor 之前(理论上不该发生,除非用户系统时间倒拨)→ 当作 cycle 0 含 anchor 那天。
        let cycleIndex = max(0, daysFromAnchor) / cycleLength
        let cycleStart = calendar.date(byAdding: .day, value: cycleIndex * cycleLength, to: anchorDay) ?? anchorDay
        let cycleEnd = calendar.date(byAdding: .day, value: cycleLength, to: cycleStart) ?? cycleStart
        return (cycleStart, cycleEnd)
    }

    /// 获取最近一篇 entry 的日期。**date 上限 cap 在 now**(防御 codex P1 #2:
    /// 用户导入或手动编辑造成的未来日期会让 wroteCurrentCycle 误判)。
    /// nil = 没有任何 entry;fetch 失败会 log 后保守返回 nil。
    private func fetchLastEntryDate() async -> Date? {
        await PersistenceController.shared.container.performBackgroundTask { context in
            let request: NSFetchRequest<NSDictionary> = NSFetchRequest(entityName: "DiaryEntry")
            let now = Date()
            request.predicate = NSPredicate(format: "date != nil AND date <= %@", now as NSDate)
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["date"]
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
            request.fetchLimit = 1
            let rows: [NSDictionary]
            do {
                rows = try context.fetch(request)
            } catch {
                Log.warning("[ReminderService] fetchLastEntryDate failed: \(error)", category: .general)
                return nil
            }
            guard let row = rows.first,
                  let date = row["date"] as? Date else { return nil }
            return date
        }
    }
}
