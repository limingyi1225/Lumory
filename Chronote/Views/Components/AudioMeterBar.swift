import SwiftUI

// MARK: - AudioMeterBar
//
// **P1-Home-1 录音电平可视化**。把 `AudioRecorder.amplitude`(0~1)映射成 N 根 Capsule 高度,
// 形成"实时音量条"。
//
// **2026-05-05 重写**:之前用 `[Float]` array + ForEach `id: \.self` + height withAnimation 的实现
// 视觉上是"12 根 bar 高度同步切换",不是"波从右往左流"。SwiftUI 把 `idx 0` 当成"同一 view"在
// 同一物理位置只换 height,bar 不滑动 — 用户实测在 16 Pro 仍感觉卡,因为不是性能问题,是 visual
// model 错(离散 array shift 没法表达"流过"动画)。
//
// 现在用 `[Sample]` (Sample 含 stable UUID id)+ ForEach `id: \.id` + `.transition(.move)`:
// - removeFirst:最左 sample 离开 → SwiftUI 触发 `.move(edge: .leading)` 滑出左边
// - append:新 sample 进入 → `.move(edge: .trailing)` 从右边滑入
// - 中间 N-2 sample id stable → SwiftUI 自动 layout 它们整体左移 1 格,**真"流"过去**
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

    /// 单个采样,带 stable UUID 让 SwiftUI ForEach 能 track "同一 sample 在移动"。
    private struct Sample: Identifiable, Equatable {
        let id = UUID()
        let level: Float
    }

    /// 可视化参数 — 12 根 bar,每根 3pt 宽,bar 间 2pt 间距 = 总宽 ~58pt(在 inline toolbar 里舒适)。
    private static let barCount: Int = 12
    private static let barWidth: CGFloat = 3
    private static let barSpacing: CGFloat = 2
    private static let minBarHeight: CGFloat = 3
    private static let maxBarHeight: CGFloat = 18

    @State private var samples: [Sample] = (0..<AudioMeterBar.barCount).map { _ in Sample(level: 0) }

    var body: some View {
        HStack(spacing: Self.barSpacing) {
            ForEach(Array(samples.enumerated()), id: \.element.id) { idx, sample in
                let height = Self.minBarHeight + CGFloat(sample.level) * (Self.maxBarHeight - Self.minBarHeight)
                // 越靠右 alpha 越高(idx N-1 = 最新最亮 1.0,idx 0 = 即将滑出最旧 0.4)。
                // alpha 跟 idx 走,sample 移动时它的 alpha 也跟着变 — 自然"褪色出场"效果。
                let alpha = 0.4 + 0.6 * (Double(idx) / Double(max(1, Self.barCount - 1)))
                Capsule()
                    .fill(Color.red.opacity(alpha))
                    .frame(width: Self.barWidth, height: height)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
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
                // 停录后清空 — 给每个 slot fresh UUID 让所有现存 bar 一起 fade 出。
                withAnimation(.easeOut(duration: 0.25)) {
                    samples = (0..<Self.barCount).map { _ in Sample(level: 0) }
                }
            }
        }
    }

    private func pushSample(_ level: Float) {
        // **真"流"动画**:withAnimation 包一次 array 重组(removeFirst + append),SwiftUI 看到
        // 12 个 sample id 中 11 个 stable + 1 个 leave + 1 个 enter,自动给 leaving 跑 .move(.leading)、
        // 给 entering 跑 .move(.trailing)、给中间 11 个跑 layout transition 整体左移。
        // .linear(0.05) 跟 AudioRecorder 的 0.05s publish 间隔严格对齐 — bar 上一帧刚到位,下一个
        // sample 到达,新 transition 接上,无 in-flight 堆叠。
        withAnimation(.linear(duration: 0.05)) {
            samples.removeFirst()
            samples.append(Sample(level: level))
        }
    }
}

#Preview {
    AudioMeterBar(amplitude: 0.5, isActive: true)
        .padding()
}
