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

    // MARK: - P1-T3 收编 token(reviewer 实测 33 处手贴 spring 数值,差别 ±0.02 但全不一致)
    //
    // 命名按"用途"而非"数值",改用途容易找。手贴 spring 已被 reviewer 抓两次,新代码必须从这里拿。

    /// Toast 出现 / 消失 — 跟 InsightsView 旧 toast 实现等价(0.34/0.86)。
    static let toast = Animation.spring(response: 0.34, dampingFraction: 0.86)

    /// Banner 展开(出现) — 跟 ThemeAliasBanner 等价(0.42/0.86)。
    static let bannerAppear = Animation.spring(response: 0.42, dampingFraction: 0.86)

    /// Banner 折叠(收起) — 0.32/0.9 比 appear 略快+更刚,符合"收起感觉比出现快"直觉。
    static let bannerCollapse = Animation.spring(response: 0.32, dampingFraction: 0.9)

    /// Modal 缩放 / sheet 内 mini 弹层(picker 之类),0.36/0.85。
    static let modalScale = Animation.spring(response: 0.36, dampingFraction: 0.85)

    /// 滚动 snap / paged 切换。
    static let scrollSnap = Animation.smooth(duration: 0.35)

    /// 列表 row 移除 — 跟 List 原生 row-removal 节奏对齐,稍慢的 ease 防卡顿感。
    static let itemRemoval = Animation.easeOut(duration: 0.28)
}

// MARK: - CADisplayLink Frame Rate Helper

extension CAFrameRateRange {
    /// Optimized frame rate for UI updates (30fps for most cases)
    static let uiUpdates = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
}
