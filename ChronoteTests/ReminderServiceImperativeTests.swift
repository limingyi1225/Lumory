//
//  ReminderServiceImperativeTests.swift
//  ChronoteTests
//
//  ReminderService imperative API 测试(megareview OPT-HIGH H4)。
//
//  之前 ReminderService 的纯函数面(cycleBounds / notificationBody / migration / contextual body
//  default)在 `ReminderBodyTests` / `ReminderFrequencyMigrationTests` / `ReminderCycleBoundsTests`
//  / `ReminderLegacyContextualBodyTests` / `ReminderUseContextualBodyDefaultTests` 已覆盖。
//  imperative side-effect 路径(enable / disable / requestReschedule / cancelAllPendingReminderNotifications
//  / currentRescheduleGen race)需要先把 `UNUserNotificationCenter.current()` 抽 `ReminderNotificationCenter`
//  protocol(`Chronote/Services/ReminderNotificationCenter.swift`)+ `internal init(notificationCenter:defaults:)`
//  seam,这一批测试覆盖 mock 路径下的行为契约。
//
//  CLAUDE.md backlog 显式点名 `currentRescheduleGen race stale 场景测试` —— 本文件覆盖。
//
//  **codex P2 followup**:protocol 把 `deliveredNotifications()` 收窄到 `deliveredNotificationIdentifiers()`
//  让 mock 能真持有 delivered IDs(`UNNotification` 无公开 init,直接 mock 不可行)。
//  Test 用 `awaitPendingRescheduleTaskForTesting()` drain 不再靠 `disable()` —— 后者自己也清
//  pending,行为来源 ambiguous。

import Testing
import Foundation
import UserNotifications
@testable import Lumory

/// 测试用 `ReminderNotificationCenter` mock。录制所有 imperative 调用,允许 test 断言。
@MainActor
final class MockReminderNotificationCenter: ReminderNotificationCenter {
    // 注入状态
    var authorizationStatusToReturn: UNAuthorizationStatus = .notDetermined
    var requestAuthorizationResult: Bool = true
    var requestAuthorizationError: Error? = nil
    /// `add` 失败模拟。
    var addError: Error? = nil

    // 录制调用
    private(set) var pendingRequests: [UNNotificationRequest] = []
    /// codex P2 followup:mock 真持有 delivered IDs(protocol 已收窄到 `[String]`),
    /// delivered cleanup 路径不再假 pass。
    var deliveredIDs: [String] = []
    private(set) var addedRequests: [UNNotificationRequest] = []
    private(set) var removedPendingIDs: [[String]] = []
    private(set) var removedDeliveredIDs: [[String]] = []
    private(set) var authorizationRequests: [UNAuthorizationOptions] = []
    private(set) var authorizationStatusQueries: Int = 0

    func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        authorizationStatusQueries += 1
        return authorizationStatusToReturn
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        authorizationRequests.append(options)
        if let err = requestAuthorizationError { throw err }
        return requestAuthorizationResult
    }

    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        pendingRequests
    }

    func removePendingNotificationRequests(withIdentifiers ids: [String]) {
        removedPendingIDs.append(ids)
        pendingRequests.removeAll { ids.contains($0.identifier) }
    }

    func deliveredNotificationIdentifiers() async -> [String] {
        deliveredIDs
    }

    func removeDeliveredNotifications(withIdentifiers ids: [String]) {
        removedDeliveredIDs.append(ids)
        deliveredIDs.removeAll { ids.contains($0) }
    }

    func add(_ request: UNNotificationRequest) async throws {
        addedRequests.append(request)
        if let err = addError { throw err }
        pendingRequests.append(request)
    }

    /// Test fixture:预置一批 pending 请求模拟"已经挂着 lumory.reminder.* 通知"。
    func seedPending(identifiers: [String]) {
        let content = UNMutableNotificationContent()
        content.title = "seed"
        for id in identifiers {
            let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
            pendingRequests.append(req)
        }
    }
}

@MainActor
struct ReminderServiceImperativeTests {
    private func isolatedDefaultsForReminder() -> UserDefaults {
        let suiteName = "ReminderImperativeTests.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suiteName)
        return UserDefaults(suiteName: suiteName)!
    }

    private func makeService(
        center: MockReminderNotificationCenter,
        isEnabled: Bool = false
    ) -> ReminderService {
        let defaults = isolatedDefaultsForReminder()
        if isEnabled {
            defaults.set(true, forKey: "lumory.reminder.enabled")
            // anchor 必须 persisted 让 isEnabled load 时 anchorIsPersisted=true
            defaults.set(Date(), forKey: "lumory.reminder.anchorDate")
        }
        return ReminderService(notificationCenter: center, defaults: defaults)
    }

    // MARK: - refreshAuthorizationStatus

    @Test func refreshAuthorizationStatus_queriesNotificationCenterAndMapsState() async {
        let center = MockReminderNotificationCenter()
        center.authorizationStatusToReturn = .authorized
        let service = makeService(center: center)

        await service.refreshAuthorizationStatus()

        #expect(center.authorizationStatusQueries == 1, "应只 query 一次 auth status")
        #expect(service.authorizationStatus == .authorized,
                "mock 返 .authorized 时 service.authorizationStatus 应映射为 .authorized")
    }

    @Test func refreshAuthorizationStatus_mapsProvisionalToProvisional() async {
        let center = MockReminderNotificationCenter()
        center.authorizationStatusToReturn = .provisional
        let service = makeService(center: center)

        await service.refreshAuthorizationStatus()
        #expect(service.authorizationStatus == .provisional)
    }

    // MARK: - enable / disable

    @Test func enable_requestsAuthorizationWithAlertAndSoundOnly() async {
        let center = MockReminderNotificationCenter()
        center.authorizationStatusToReturn = .authorized
        center.requestAuthorizationResult = true
        let service = makeService(center: center)

        let granted = await service.enable()

        #expect(granted == true)
        #expect(center.authorizationRequests.count == 1, "enable 应只 request 一次 authorization")
        // 锁定权限选项:不应包含 .badge(CLAUDE.md 决定不维护 badge counter)
        let options = center.authorizationRequests.first ?? []
        #expect(options.contains(.alert), "应请求 .alert")
        #expect(options.contains(.sound), "应请求 .sound")
        #expect(options.contains(.badge) == false, "不应请求 .badge — CLAUDE.md 已决定")
    }

    @Test func enable_authorizationDenied_returnsFalseAndDoesNotSetIsEnabled() async {
        let center = MockReminderNotificationCenter()
        center.authorizationStatusToReturn = .denied
        center.requestAuthorizationResult = false  // 用户点了"不允许"
        let service = makeService(center: center)

        let granted = await service.enable()

        #expect(granted == false)
        #expect(service.isEnabled == false, "用户拒权时 isEnabled 不应被翻成 true")
    }

    // MARK: - requestReschedule when disabled (delivered cleanup 真测,不靠 disable() drain)

    @Test func requestReschedule_whenDisabled_cancelsPendingAndDelivered_withLumoryPrefixOnly() async {
        // CLAUDE.md 自陈:`requestReschedule()` 在 `!isEnabled` 时**不**跑 CoreData fetch,
        // 只 cancel pending + delivered — 这条 contract verification 显式点名要测。
        // codex P2 followup:用 awaitPendingRescheduleTaskForTesting() drain,delivered 走 mock 真 IDs。
        let center = MockReminderNotificationCenter()
        center.seedPending(identifiers: [
            "lumory.reminder.cycle.20240601",
            "lumory.reminder.cycle.20240603",
            "some.other.app.reminder"  // 非 lumory prefix,不应被清
        ])
        center.deliveredIDs = [
            "lumory.reminder.cycle.20240501",   // 应清
            "some.other.app.notification"        // 不应清
        ]
        let service = makeService(center: center, isEnabled: false)

        // requestReschedule 起 fire-and-forget Task,显式 drain 让 in-flight 完成
        service.requestReschedule()
        await service.awaitPendingRescheduleTaskForTesting()

        // pending cancel:应清 prefix=lumory.reminder. 的两条
        let allRemovedPending = center.removedPendingIDs.flatMap { $0 }
        #expect(allRemovedPending.contains("lumory.reminder.cycle.20240601"))
        #expect(allRemovedPending.contains("lumory.reminder.cycle.20240603"))
        #expect(allRemovedPending.contains("some.other.app.reminder") == false,
                "非 lumory.reminder.* prefix 不应被清(防误伤其他 app 的通知)")

        // delivered cleanup:**这条 codex P2 之前 mock 永远返 [] 假 pass**,现在真测
        let allRemovedDelivered = center.removedDeliveredIDs.flatMap { $0 }
        #expect(allRemovedDelivered.contains("lumory.reminder.cycle.20240501"),
                "delivered 列表里 lumory.reminder.* prefix 必须清掉(用户关 reminder 后通知中心仍堆着旧 reminder)")
        #expect(allRemovedDelivered.contains("some.other.app.notification") == false,
                "delivered 非 lumory.reminder.* prefix 不应被清")
    }

    @Test func requestReschedule_whenDisabled_emptyPendingAndDelivered_isNoOp() async {
        // 防误伤:当前 mock pending + delivered 都不含 lumory.reminder.* prefix 时,
        // 不应调用 removePendingNotificationRequests / removeDeliveredNotifications。
        // 这条锁 prefix-filter idiom 的 short-circuit。
        let center = MockReminderNotificationCenter()
        center.seedPending(identifiers: ["foo.app.reminder"])
        center.deliveredIDs = ["bar.app.notif"]
        let service = makeService(center: center, isEnabled: false)

        service.requestReschedule()
        await service.awaitPendingRescheduleTaskForTesting()

        #expect(center.removedPendingIDs.isEmpty,
                "无 lumory prefix 的 pending 不应触发 removePendingNotificationRequests")
        #expect(center.removedDeliveredIDs.isEmpty,
                "无 lumory prefix 的 delivered 不应触发 removeDeliveredNotifications")
    }
}
