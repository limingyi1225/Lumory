import SwiftUI

/// 连续心情光谱滑块：紫色(0) -> 红色(1) - Apple风格设计
struct MoodSpectrumSlider: View {
    @Binding var moodValue: Double // 0~1
    var showKnob: Bool = true
    
    @State private var isDragging: Bool = false
    @State private var dragOffset: CGFloat = 0
    @State private var animatedProgress: Double = 0.0
    @State private var updateTask: Task<Void, Never>? = nil
    
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let trackHeight: CGFloat = 6
            let progressWidth = width * CGFloat(animatedProgress)

            ZStack(alignment: .leading) {
                // 背景轨道（始终显示灰色）
                Capsule()
                    .fill(Color(.systemGray5))
                    .frame(height: trackHeight)
                
                // 心情光谱进度条（从左侧填充，只显示到当前心情值的颜色）
                if showKnob && animatedProgress > 0 {
                    Capsule()
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: generateProgressColors()),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: progressWidth, height: trackHeight)
                        .animation(AnimationConfig.bouncySpring, value: animatedProgress)
                }
            }
            // 让整个轨道响应手势，并使用实际宽度计算心情值
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard showKnob else { return }
                        let raw = value.location.x
                        let newValue = Double(raw / width)
                        moodValue = min(max(0, newValue), 1)
                        animatedProgress = moodValue
                    }
            )
            .onTapGesture { location in
                guard showKnob else { return }
                let raw = location.x
                let newValue = Double(raw / width)
                let clamped = min(max(0, newValue), 1)
                withAnimation(AnimationConfig.gentleSpring) {
                    moodValue = clamped
                }
            }
        }
        .frame(height: 40)
        .shadow(color: Color.primary.opacity(0.1), radius: 1, x: 0, y: 1)
        .onChange(of: showKnob) { oldValue, newValue in
            if newValue && !oldValue {
                // 从无心情到有心情：进度条填充动画
                withAnimation(AnimationConfig.bouncySpring.delay(0.1)) {
                    animatedProgress = moodValue
                }
            } else if !newValue && oldValue {
                // 从有心情到无心情：进度条清空
                withAnimation(AnimationConfig.smoothTransition) {
                    animatedProgress = 0.0
                }
            }
        }
        .onChange(of: moodValue) { oldValue, newValue in
            guard showKnob else { return }
            // 取消之前的更新任务，避免冲突
            updateTask?.cancel()
            updateTask = Task {
                // 延迟0.5秒后再进行更新
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
                // 只有变化大于0.2（100分制里的20）才执行更新
                if abs(newValue - oldValue) > 0.1 {
                    await MainActor.run {
                        withAnimation(AnimationConfig.bouncySpring) {
                            animatedProgress = newValue
                        }
                    }
                }
            }
        }
        .onAppear {
            if showKnob {
                animatedProgress = moodValue
            }
        }
    }
    
    /// 生成从0到当前心情值的颜色渐变
    private func generateProgressColors() -> [Color] {
        // Optimize by reducing color steps for better performance
        let steps = max(2, min(10, Int(animatedProgress * 10))) // Limit to 10 color points max
        var colors: [Color] = []
        
        for i in 0..<steps {
            let value = Double(i) / Double(steps - 1) * animatedProgress
            colors.append(Color.moodSpectrum(value: value))
        }
        
        return colors
    }
}

#Preview {
    StatefulPreviewWrapper(0.5) { binding in
        MoodSpectrumSlider(moodValue: binding)
            .padding()
    }
}

// MARK: - Preview Wrapper
fileprivate struct StatefulPreviewWrapper<Value, Content: View>: View {
    @State var value: Value
    var content: (Binding<Value>) -> Content

    init(_ value: Value, content: @escaping (Binding<Value>) -> Content) {
        _value = State(initialValue: value)
        self.content = content
    }

    var body: some View {
        content($value)
    }
} 