import SwiftUI

/// 在按下时微缩按钮的通用样式。
///
/// **P1-T6 双轴反馈**:scale(0.95) + opacity(0.8)。单 scale 在浅色玻璃卡上反馈不强,叠 opacity
/// 让被按的卡明显"暗一拍",触觉 + 视觉一致。
///
/// 用法约定(写进 CLAUDE.md):
/// - **所有 liquidGlassCard + Button 组合**默认套这个 style
/// - 系统 Form 内置 row、NavigationLink 默认 cell highlight 不动
/// - destructive button 不套(系统红色 prominent 自带反馈,叠加显得肉)
struct PressableScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(AnimationConfig.gentleSpring,
                       value: configuration.isPressed)
    }
}
