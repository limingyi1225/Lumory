import Foundation
import UserNotifications

// MARK: - ReminderNotificationRouter
//
// 全局 `UNUserNotificationCenterDelegate` 单例,在 `ChronoteApp.init` 设置。
// 接管 App 内所有通知点击和前台展示:
//   - `didReceive`(用户点击)→ `shouldFocusComposer` 判定后 hop main 把 composeFocusRequestID
//     置成新 UUID,HomeView 通过 `consumeComposeFocusRequest` 单次消费触发清屏 + 焦点写日记。
//   - `willPresent`(前台收到)→ reminder 类放行 `[.banner, .list, .sound]`,非 reminder 沿用默认
//     压制 `[]`。没有 `willPresent` = 前台通知完全不显示(无 banner / 无声音)。
//
// 共享 focus 入口:reminder 通知点击 **和** widget URL `lumory://compose` 都走 `requestComposeFocus()`。

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
