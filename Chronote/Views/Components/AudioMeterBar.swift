import SwiftUI

// MARK: - AudioMeterBar
//
// **P1-Home-1 录音电平可视化**。把 `AudioRecorder.amplitude`(0~1)映射成 N 根 Capsule 高度,
// 形成"实时音量条"。
//
// **2026-05-05 重写**:之前用 HStack + ForEach + transition 每 0.05s insert/remove 一根 bar。
// 这种做法会让 SwiftUI 每 tick 都做 layout transition,旁边的计时 Text / toolbar 也会被拖着重排,
// 观感像"一格一格跳"。现在改成固定尺寸 Canvas:
// - sample 仍按 10Hz 进入 history;
// - TimelineView 在两次 sample 中间按帧推进 x offset;
// - Canvas 只画 path,不 insert/remove SwiftUI 子树,所以移动连续且成本稳定。
//
// 不接 `recorder.amplitude` 的 ObservableObject 直接观察,而是让 caller 传 snapshot —
// 解耦,也避免整页被高频 objectWillChange 拖着重绘。
//
// 用法:
//   AudioMeterBar(amplitude: level, sampleID: tick, isActive: true)

struct AudioMeterBar: View {
    /// 当前实时电平,0~1。caller 从 AudioRecorder.amplitude 拿。
    let amplitude: Float
    /// 每次采样递增一次。即便 amplitude 连续相同,波形也继续平滑流动。
    let sampleID: Int
    /// 是否在录音 — 决定 history 是否更新；停录时由父视图移除并清空 history。
    let isActive: Bool

    /// 可视化参数 — 12 根 bar,每根 3pt 宽,bar 间 2pt 间距 = 总宽 ~58pt(在 inline toolbar 里舒适)。
    private static let barCount: Int = 12
    private static let historyCount: Int = 14
    private static let barWidth: CGFloat = 3
    private static let barSpacing: CGFloat = 2
    private static let sampleStride: CGFloat = barWidth + barSpacing
    private static let minBarHeight: CGFloat = 3
    private static let maxBarHeight: CGFloat = 18
    private static let sampleInterval: TimeInterval = 0.1
    private static let totalWidth: CGFloat = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing

    @State private var samples: [Float] = Array(repeating: 0, count: AudioMeterBar.historyCount)
    @State private var lastSampleDate = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isActive)) { timeline in
            Canvas { context, size in
                drawBars(in: &context, size: size, date: timeline.date)
            }
        }
        .frame(width: Self.totalWidth, height: Self.maxBarHeight)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NSLocalizedString("录音电平", comment: "Audio meter level"))
        .accessibilityValue(String(format: "%.0f%%", Double(amplitude) * 100))
        .onAppear {
            resetSamples()
            if isActive {
                pushSample(amplitude)
            }
        }
        .onChange(of: sampleID) { _, _ in
            guard isActive else { return }
            pushSample(amplitude)
        }
        .onChange(of: isActive) { _, active in
            if !active {
                resetSamples()
            } else {
                pushSample(amplitude)
            }
        }
    }

    private func drawBars(in context: inout GraphicsContext, size: CGSize, date: Date) {
        let progress = isActive ? sampleProgress(at: date) : 0
        let cornerRadius = Self.barWidth / 2

        for index in samples.indices {
            let age = CGFloat(samples.count - 1 - index) + progress
            let x = size.width - Self.barWidth - age * Self.sampleStride
            guard x > -Self.barWidth, x < size.width else { continue }

            let level = max(0, min(1, CGFloat(samples[index])))
            let height = Self.minBarHeight + level * (Self.maxBarHeight - Self.minBarHeight)
            let y = (size.height - height) / 2
            let alphaProgress = max(0, min(1, (x + Self.barWidth) / max(size.width, 1)))
            let alpha = 0.35 + 0.65 * Double(alphaProgress)
            let rect = CGRect(x: x, y: y, width: Self.barWidth, height: height)
            let path = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: rect)
            context.fill(path, with: .color(Color.red.opacity(alpha)))
        }
    }

    private func sampleProgress(at date: Date) -> CGFloat {
        let elapsed = date.timeIntervalSince(lastSampleDate)
        return CGFloat(max(0, min(1, elapsed / Self.sampleInterval)))
    }

    private func pushSample(_ level: Float) {
        samples.removeFirst()
        samples.append(max(0, min(1, level)))
        lastSampleDate = Date()
    }

    private func resetSamples() {
        samples = Array(repeating: 0, count: Self.historyCount)
        lastSampleDate = Date()
    }
}

@MainActor
struct RecordingLiveStatusView: View {
    let recorder: AudioRecorder

    @State private var amplitude: Float = 0
    @State private var elapsed: TimeInterval = 0
    @State private var sampleID: Int = 0

    var body: some View {
        HStack(spacing: 8) {
            AudioMeterBar(amplitude: amplitude, sampleID: sampleID, isActive: true)
            Text(recordingDurationText)
                .font(.footnote.weight(.medium).monospacedDigit())
                .foregroundColor(.red)
        }
        .task {
            await refreshWhileRecording()
        }
        .onDisappear {
            amplitude = 0
            elapsed = 0
            sampleID &+= 1
        }
    }

    private func refreshWhileRecording() async {
        while !Task.isCancelled, recorder.isRecording {
            amplitude = recorder.amplitude
            elapsed = recorder.duration
            sampleID &+= 1
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private var recordingDurationText: String {
        formattedDuration(currentTime: elapsed, totalDuration: 0)
    }
}

#Preview {
    AudioMeterBar(amplitude: 0.5, sampleID: 0, isActive: true)
        .padding()
}
