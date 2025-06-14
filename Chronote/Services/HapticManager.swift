#if canImport(UIKit)
import UIKit

/// 统一管理应用内的点击震动反馈
final class HapticManager {
    /// 单例实例
    static let shared = HapticManager()
    private let feedbackGenerator: UIImpactFeedbackGenerator

    private init() {
        // 使用中等强度的冲击样式作为统一点击反馈
        feedbackGenerator = UIImpactFeedbackGenerator(style: .medium)
        feedbackGenerator.prepare()
    }

    /// 触发一次点击震动
    func click() {
        #if !targetEnvironment(macCatalyst)
        feedbackGenerator.impactOccurred()
        feedbackGenerator.prepare()
        #endif
    }
}
#else
// macOS doesn't support haptic feedback
final class HapticManager {
    static let shared = HapticManager()
    
    private init() {}
    
    func click() {
        // No-op on macOS
    }
}
#endif 