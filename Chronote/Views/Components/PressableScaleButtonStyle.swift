import SwiftUI

/// 在按下时微缩按钮的通用样式
struct PressableScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(AnimationConfig.gentleSpring,
                       value: configuration.isPressed)
    }
}
