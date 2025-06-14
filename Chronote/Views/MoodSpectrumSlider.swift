import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 连续心情光谱滑块：紫色(0) -> 红色(1) - Apple风格设计
struct MoodSpectrumSlider: View {
    @Binding var moodValue: Double // 0~1
    var showKnob: Bool = true
    
    @State private var isDragging: Bool = false
    @State private var dragOffset: CGFloat = 0
    @State private var animatedProgress: Double = 0.0
    @State private var updateTask: Task<Void, Never>? = nil
    @State private var cachedGradient: LinearGradient? = nil
    @State private var lastGradientValue: Double = -1
    
    // Platform-specific color
    private var systemGray5Color: Color {
        #if canImport(UIKit)
        return Color(UIColor.systemGray5)
        #else
        return Color(NSColor.unemphasizedSelectedContentBackgroundColor)
        #endif
    }
    
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let trackHeight: CGFloat = 6
            let progressWidth = width * CGFloat(animatedProgress)

            ZStack(alignment: .leading) {
                // 背景轨道（始终显示灰色）
                Capsule()
                    .fill(systemGray5Color)
                    .frame(height: trackHeight)
                
                // 心情光谱进度条（从左侧填充，只显示到当前心情值的颜色）
                if showKnob && animatedProgress > 0 {
                    Capsule()
                        .fill(currentGradient)
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
                        isDragging = true
                        let raw = value.location.x
                        let newValue = Double(raw / width)
                        let clamped = min(max(0, newValue), 1)
                        moodValue = clamped
                        // Direct update during drag for immediate feedback
                        animatedProgress = clamped
                        updateGradientIfNeeded()
                    }
                    .onEnded { _ in
                        isDragging = false
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
            // Only animate if the change is significant and not from dragging
            if !isDragging && abs(newValue - oldValue) > 0.01 {
                withAnimation(AnimationConfig.bouncySpring) {
                    animatedProgress = newValue
                }
                updateGradientIfNeeded()
            }
        }
        .onAppear {
            if showKnob {
                animatedProgress = moodValue
                updateGradientIfNeeded()
            }
        }
        .onDisappear {
            updateTask?.cancel()
            updateTask = nil
        }
    }
    
    /// 获取当前渐变，使用缓存避免重复计算
    private var currentGradient: LinearGradient {
        if let cached = cachedGradient, abs(lastGradientValue - animatedProgress) < 0.05 {
            return cached
        }
        return LinearGradient(
            gradient: Gradient(colors: generateProgressColors()),
            startPoint: .leading,
            endPoint: .trailing
        )
    }
    
    /// 更新渐变缓存
    private func updateGradientIfNeeded() {
        if abs(lastGradientValue - animatedProgress) >= 0.05 {
            lastGradientValue = animatedProgress
            cachedGradient = LinearGradient(
                gradient: Gradient(colors: generateProgressColors()),
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }
    
    /// 生成从0到当前心情值的颜色渐变
    private func generateProgressColors() -> [Color] {
        // Optimize by reducing color steps for better performance
        let steps = max(2, min(8, Int(animatedProgress * 8))) // Reduced to 8 color points max
        var colors: [Color] = []
        colors.reserveCapacity(steps) // Pre-allocate array capacity
        
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