import SwiftUI

/// 发送日记时的心情收缩/盖章动画
/// 效果：心情颜色从光谱条位置"凝聚"成一个光球，然后淡出，类似"保存"或"盖章"的感觉
struct MoodSendAnimation: View {
    let moodValue: Double
    @Binding var isShowing: Bool

    // 动画状态
    @State private var scale: CGFloat = 0.2
    @State private var opacity: Double = 0.0
    @State private var blur: CGFloat = 10
    @State private var animationTask: Task<Void, Never>?

    var body: some View {
        let moodColor = Color.moodSpectrum(value: moodValue)
        
        ZStack {
            // 核心光球
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            moodColor,
                            moodColor.opacity(0.5),
                            moodColor.opacity(0.0)
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 60
                    )
                )
                .frame(width: 120, height: 120)
                .scaleEffect(scale)
                .opacity(opacity)
                .blur(radius: blur)
            
            // 晶体核心 (更实一点)
            Circle()
                .fill(moodColor)
                .frame(width: 40, height: 40)
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.8), lineWidth: 2)
                        .blur(radius: 1)
                )
                .shadow(color: moodColor.opacity(0.8), radius: 10, x: 0, y: 0)
                .scaleEffect(scale * 0.8)
                .opacity(opacity)
        }
        .onAppear {
            performAnimation()
        }
        .onDisappear {
            // Cancel any pending animation tasks
            animationTask?.cancel()
            animationTask = nil
        }
    }

    private func performAnimation() {
        // 1. 凝聚出现
        withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
            scale = 1.0
            opacity = 1.0
            blur = 0
        }

        // 2. 震动反馈
        #if canImport(UIKit)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        #endif

        // 3. 使用 Task 进行延迟动画（可取消）
        animationTask = Task { @MainActor in
            // 停留一小会儿后淡出
            try? await Task.sleep(nanoseconds: 1_200_000_000) // 1.2s
            guard !Task.isCancelled else { return }

            withAnimation(.easeOut(duration: 0.5)) {
                opacity = 0.0
                scale = 1.2 // 稍微扩散消失
            }

            // 彻底结束
            try? await Task.sleep(nanoseconds: 600_000_000) // 0.6s
            guard !Task.isCancelled else { return }

            isShowing = false
        }
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        MoodSendAnimation(moodValue: 0.8, isShowing: .constant(true))
    }
}
