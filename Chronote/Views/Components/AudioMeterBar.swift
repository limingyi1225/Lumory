import SwiftUI

// MARK: - AudioMeterBar
//
// **P1-Home-1 录音电平可视化**。把 `AudioRecorder.amplitude`(0~1)映射成 N 根 Capsule 高度,
// 形成"实时音量条"。
//
// 设计:
// - 内部维护一个 N-长 `@State` 滚动缓冲(history),每次外部 amplitude 变化 push 到队尾,
//   弹掉队头。bar 0 ~ bar N-1 对应最旧→最新,从左到右渲染。
// - 每个 bar 高度 = `lerp(minHeight, maxHeight, history[i])`;static cap 4 防卡顿。
// - 没在录音时 history 全 0,bar 显示 minHeight 不全消失(给 UI 留视觉锚)。
// - tint 走 `.red`(跟录音中色温一致),不同 bar 用 0.4 ~ 1.0 alpha 渐变让最新最亮。
//
// 不接 `recorder.amplitude` 的 ObservableObject 直接观察,而是让 caller 传 `amplitude: Float` —
// 解耦,测试可以注入静态值。
//
// 用法:
//   AudioMeterBar(amplitude: recorder.amplitude, isActive: recorder.isRecording)

struct AudioMeterBar: View {
    /// 当前实时电平,0~1。caller 从 AudioRecorder.amplitude 拿。
    let amplitude: Float
    /// 是否在录音 — 决定 history 是否更新(停录后历史保留 ~1s 衰减后归零)。
    let isActive: Bool

    /// 可视化参数 — 12 根 bar,每根 3pt 宽,bar 间 2pt 间距 = 总宽 ~58pt(在 inline toolbar 里舒适)。
    private static let barCount: Int = 12
    private static let barWidth: CGFloat = 3
    private static let barSpacing: CGFloat = 2
    private static let minBarHeight: CGFloat = 3
    private static let maxBarHeight: CGFloat = 18

    /// 滚动缓冲。最新的在 last,最旧在 first。`@State` 让 SwiftUI 自己管 update。
    @State private var history: [Float] = Array(repeating: 0, count: AudioMeterBar.barCount)

    var body: some View {
        HStack(spacing: Self.barSpacing) {
            ForEach(0..<Self.barCount, id: \.self) { idx in
                let level = history[idx]
                let height = Self.minBarHeight + CGFloat(level) * (Self.maxBarHeight - Self.minBarHeight)
                // 越靠右 alpha 越高,营造"最新最亮"。idx 0 = 最旧 = 0.4,idx N-1 = 最新 = 1.0。
                let alpha = 0.4 + 0.6 * (Double(idx) / Double(max(1, Self.barCount - 1)))
                Capsule()
                    .fill(Color.red.opacity(alpha))
                    .frame(width: Self.barWidth, height: height)
            }
        }
        .frame(height: Self.maxBarHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NSLocalizedString("录音电平", comment: "Audio meter level"))
        .accessibilityValue(String(format: "%.0f%%", Double(amplitude) * 100))
        .onChange(of: amplitude) { _, newValue in
            guard isActive else { return }
            pushSample(newValue)
        }
        .onChange(of: isActive) { _, active in
            if !active {
                // 停录后清空 history,让 bar 收回 minHeight,不挂"幽灵电平"。
                history = Array(repeating: 0, count: Self.barCount)
            }
        }
    }

    private func pushSample(_ level: Float) {
        // O(N) shift。N=12,配合 AudioRecorder 20Hz publish = 240 ops/s。
        var next = history
        next.removeFirst()
        next.append(level)
        // **interactiveSpring 替 .linear**(2026-05-05 用户反馈卡顿):
        // .linear(0.06) + 30Hz publish = 永远两个 in-flight transition 同时插值,12 capsule × 30 帧 ≈
        // 400 layout pass/s,Pro 机器无感低端卡顿。spring 是 over-damped,新 sample 来时 SwiftUI 自动
        // merge transition target 不重启动画 — Apple 推荐的高频 binding 改 sprung 不改 linear。
        withAnimation(.interactiveSpring(response: 0.12, dampingFraction: 0.85)) {
            history = next
        }
    }
}

#Preview {
    AudioMeterBar(amplitude: 0.5, isActive: true)
        .padding()
}
