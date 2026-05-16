//
//  ReminderNotificationCenter.swift
//  Chronote
//
//  `UNUserNotificationCenter` 的可注入 wrapper(megareview OPT-HIGH H4 / CLAUDE.md backlog)。
//
//  生产代码用 `UNUserNotificationCenterAdapter`,行为字节级等价直接调 `UNUserNotificationCenter.current()`。
//  单测注入 mock 验证 `ReminderService` imperative API 的副作用契约(enable / disable / requestReschedule /
//  cancelAllPendingReminderNotifications / scheduleOneShot 的调用序列、参数、世代号 race 等),
//  不需要装 `UNUserNotificationCenter` 真实实例避免 sandbox / 权限弹窗污染测试 simulator。
//
//  返 `UNAuthorizationStatus`(enum)而非 `UNNotificationSettings`(framework class,不可直接构造) —
//  ReminderService 只需要 authorizationStatus 一个字段,缩窄 protocol 表面让 mock 实现简单。

import Foundation
import UserNotifications

@MainActor
protocol ReminderNotificationCenter: Sendable {
    func currentAuthorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func pendingNotificationRequests() async -> [UNNotificationRequest]
    func removePendingNotificationRequests(withIdentifiers ids: [String])
    /// 返**已 delivered** 通知的 identifier 列表。原生 API 返 `[UNNotification]`,但 ReminderService
    /// 只 care `notif.request.identifier`(过滤 `lumory.reminder.` prefix)。protocol 直接收窄到 `[String]`,
    /// 让 mock 可以构造 — `UNNotification` 没有公开 init,直接 mock 不可行(megareview OPT-HIGH H4
    /// codex follow-up:之前 mock 永远返 `[]` 让 delivered cleanup 路径不可测)。
    func deliveredNotificationIdentifiers() async -> [String]
    func removeDeliveredNotifications(withIdentifiers ids: [String])
    func add(_ request: UNNotificationRequest) async throws
}

/// 生产 default impl,1:1 forward 到 `UNUserNotificationCenter.current()`。无逻辑。
@MainActor
struct UNUserNotificationCenterAdapter: ReminderNotificationCenter {
    func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: options)
    }

    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        await UNUserNotificationCenter.current().pendingNotificationRequests()
    }

    func removePendingNotificationRequests(withIdentifiers ids: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    func deliveredNotificationIdentifiers() async -> [String] {
        await UNUserNotificationCenter.current().deliveredNotifications().map { $0.request.identifier }
    }

    func removeDeliveredNotifications(withIdentifiers ids: [String]) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }
}
