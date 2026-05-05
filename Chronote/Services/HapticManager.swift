import UIKit

/// 统一管理应用内的震动反馈。
/// 历史只暴露了 medium impact + notification,导致项目里 7 处场景需要 light/soft/medium 不同强度时
/// 直接 `UIImpactFeedbackGenerator(style:).impactOccurred()`,绕过本 manager 也丢了 prepare 复用优化。
/// 现扩成全 style 都走这里。
@MainActor
final class HapticManager {
    static let shared = HapticManager()

    /// 历史 `.click()` 是 medium impact;新代码请用 `impact(.light/.soft/.medium/...)`。
    private let mediumGenerator: UIImpactFeedbackGenerator
    private let lightGenerator: UIImpactFeedbackGenerator
    private let softGenerator: UIImpactFeedbackGenerator
    private let rigidGenerator: UIImpactFeedbackGenerator
    private let heavyGenerator: UIImpactFeedbackGenerator
    private let notificationGenerator: UINotificationFeedbackGenerator

    private init() {
        mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
        lightGenerator = UIImpactFeedbackGenerator(style: .light)
        softGenerator = UIImpactFeedbackGenerator(style: .soft)
        rigidGenerator = UIImpactFeedbackGenerator(style: .rigid)
        heavyGenerator = UIImpactFeedbackGenerator(style: .heavy)
        notificationGenerator = UINotificationFeedbackGenerator()

        mediumGenerator.prepare()
        lightGenerator.prepare()
        softGenerator.prepare()
        notificationGenerator.prepare()
    }

    /// 触发一次 medium impact 震动（旧 API,保留兼容）
    func click() {
        impact(.medium)
    }

    /// 任意 style 的 impact 震动 — fire 后立刻 prepare 复用
    func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let gen: UIImpactFeedbackGenerator
        switch style {
        case .light: gen = lightGenerator
        case .soft: gen = softGenerator
        case .medium: gen = mediumGenerator
        case .rigid: gen = rigidGenerator
        case .heavy: gen = heavyGenerator
        @unknown default: gen = mediumGenerator
        }
        gen.impactOccurred()
        gen.prepare()
    }

    /// 触发通知类型震动（成功/警告/错误）
    func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        notificationGenerator.notificationOccurred(type)
        notificationGenerator.prepare()
    }
}
