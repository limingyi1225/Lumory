import SwiftUI

// MARK: - Animation Configuration
// Centralized animation settings for consistent performance

struct AnimationConfig {
    // MARK: - Standard Animations

    /// Fast response for immediate feedback - optimized for Mac Catalyst
    static let fastResponse = Animation.easeOut(duration: 0.1)

    /// Standard response for most interactions - optimized for Mac Catalyst
    static let standardResponse = Animation.easeInOut(duration: 0.15)

    /// Smooth transitions for larger UI changes - optimized for Mac Catalyst
    static let smoothTransition = Animation.easeInOut(duration: 0.2)

    /// Gentle spring for button presses and small interactions - Mac optimized
    static let gentleSpring = Animation.spring(
        response: 0.2,
        dampingFraction: 0.85
    )

    /// Stiff spring for quick, snappy animations - Mac optimized
    static let stiffSpring = Animation.interpolatingSpring(
        stiffness: 300,
        damping: 30
    )

    // MARK: - P1-T3 收编 token
    //
    // 命名按"用途"而非"数值",改用途容易找。手贴 spring 数值要先在这里加 token。
    // 历史上还有 `modalScale / scrollSnap / itemRemoval` 3 个预留 token,2026-05 删除时
    // 全仓 0 caller — 待真要做 modal / scroll / list-row 一致性收编时再加回。

    /// Toast 出现 / 消失 — 跟 InsightsView 旧 toast 实现等价(0.34/0.86)。
    static let toast = Animation.spring(response: 0.34, dampingFraction: 0.86)

    /// Banner 展开(出现) — 跟 ThemeAliasBanner 等价(0.42/0.86)。
    static let bannerAppear = Animation.spring(response: 0.42, dampingFraction: 0.86)

    /// Banner 折叠(收起) — 0.32/0.9 比 appear 略快+更刚,符合"收起感觉比出现快"直觉。
    static let bannerCollapse = Animation.spring(response: 0.32, dampingFraction: 0.9)
}

// MARK: - CADisplayLink Frame Rate Helper

extension CAFrameRateRange {
    /// Optimized frame rate for UI updates (30fps for most cases)
    static let uiUpdates = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
}
