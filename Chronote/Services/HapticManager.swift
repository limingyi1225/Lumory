import UIKit

/// 统一管理应用内的点击震动反馈
final class HapticManager {
    static let shared = HapticManager()
    private let feedbackGenerator: UIImpactFeedbackGenerator
    private let notificationGenerator: UINotificationFeedbackGenerator

    private init() {
        feedbackGenerator = UIImpactFeedbackGenerator(style: .medium)
        feedbackGenerator.prepare()

        notificationGenerator = UINotificationFeedbackGenerator()
        notificationGenerator.prepare()
    }

    /// 触发一次点击震动
    func click() {
        feedbackGenerator.impactOccurred()
        feedbackGenerator.prepare()
    }

    /// 触发通知类型震动（成功/警告/错误）
    func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        notificationGenerator.notificationOccurred(type)
        notificationGenerator.prepare()
    }
}
