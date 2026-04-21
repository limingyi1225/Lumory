import SwiftUI

// MARK: - Spectrum显示状态
enum SpectrumDisplayState {
    case idle           // 空闲
    case analyzing      // 分析中，呼吸效果
    case revealed       // 结果揭示
}

/// iOS 26 Liquid Glass 心情光谱条。完整光谱压在玻璃胶囊下，揭示态聚光+色晕。
struct MoodSpectrumBar: View {
    @Environment(\.colorScheme) var colorScheme
    let moodValue: Double
    let displayState: SpectrumDisplayState

    // 动画状态
    @State private var breathPhase: CGFloat = 0
    @State private var revealProgress: CGFloat = 0
    @State private var glowPulse: CGFloat = 0
    @State private var animatedOpacity: CGFloat = 0.32
    @State private var isAnimating: Bool = false
    // 反复开/关动画的 Task 必须能取消——不然延迟启动的 `repeatForever` 会在状态已经切走后启动，
    // 进入无法被 stopAllAnimations 终止的"幽灵动画"态（pulse 永不停）。
    @State private var glowTask: Task<Void, Never>?
    @State private var breathTask: Task<Void, Never>?

    private let barHeight: CGFloat = 32

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack {
                spectrumFill
                    .mask(Capsule().padding(2))
                    .opacity(displayState == .revealed ? Double(0.3 * (1.0 - revealProgress * 0.4)) : animatedOpacity)

                if displayState == .revealed {
                    spotlightSpectrum(width: width)
                    spotlightGlow(width: width)
                    positionMarker(width: width)
                }

                if displayState == .analyzing {
                    breathingGlow
                }
            }
            // 玻璃材质带 18% 白 tint —— 让胶囊整体偏白透,边缘的玻璃折射感更明显。
            .liquidGlassCapsule(tint: .white)
            // 0.5pt 白 inset 描边 —— 给胶囊一个清晰的边缘高光,玻璃片"翘起来"的感觉更强。
            .overlay {
                Capsule()
                    .strokeBorder(Color.white.opacity(0.55), lineWidth: 0.5)
            }
        }
        .frame(height: barHeight)
        .onAppear {
            isAnimating = true
            animatedOpacity = targetOpacity
            if displayState == .analyzing {
                startBreathingAnimation()
            }
        }
        .onDisappear {
            isAnimating = false
            stopAllAnimations()
        }
        .onChange(of: displayState) { _, newState in
            handleStateChange(newState)
        }
    }

    // MARK: - 目标透明度

    /// idle 态故意压低饱和度,让外层 liquidGlassCapsule 的材质主导视觉,
    /// 和 Insights 的玻璃元素气质对齐;analyzing/revealed 仍保持饱满,因为
    /// 情绪反馈那一下需要视觉冲击。
    private var targetOpacity: Double {
        switch displayState {
        case .idle:       return 0.32
        case .analyzing:  return 0.85
        case .revealed:   return 1.0
        }
    }

    // MARK: - 共用渲染片段

    private var spectrumFill: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [
                        Color.moodSpectrum(value: 0.0),
                        Color.moodSpectrum(value: 0.25),
                        Color.moodSpectrum(value: 0.5),
                        Color.moodSpectrum(value: 0.75),
                        Color.moodSpectrum(value: 1.0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .overlay(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.06), .white.opacity(0.0)],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .padding(3)
            )
    }

    @ViewBuilder
    private func spotlightSpectrum(width: CGFloat) -> some View {
        let spotCenter = moodValue
        let spotWidth: CGFloat = 0.25
        spectrumFill
            .mask(
                GeometryReader { _ in
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: max(0, spotCenter - spotWidth)),
                            .init(color: .white, location: max(0, spotCenter - spotWidth * 0.3)),
                            .init(color: .white, location: min(1, spotCenter + spotWidth * 0.3)),
                            .init(color: .clear, location: min(1, spotCenter + spotWidth))
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
            )
            .mask(Capsule().padding(3))
            .opacity(revealProgress)
    }

    private var breathingGlow: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [
                        Color.moodSpectrum(value: 0.0).opacity(0.3),
                        Color.moodSpectrum(value: 0.5).opacity(0.3),
                        Color.moodSpectrum(value: 1.0).opacity(0.3)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .blur(radius: 8 + breathPhase * 4)
            .scaleEffect(1.0 + breathPhase * 0.05)
            .opacity(0.5 + breathPhase * 0.3)
    }

    @ViewBuilder
    private func spotlightGlow(width: CGFloat) -> some View {
        let position = width * CGFloat(moodValue)
        let moodColor = Color.moodSpectrum(value: moodValue)
        Ellipse()
            .fill(
                RadialGradient(
                    colors: [
                        moodColor.opacity(0.6),
                        moodColor.opacity(0.3),
                        moodColor.opacity(0.1),
                        .clear
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: barHeight * 1.5
                )
            )
            .frame(width: barHeight * 3, height: barHeight * 2)
            .blur(radius: 8 + glowPulse * 4)
            .scaleEffect(1.0 + glowPulse * 0.15)
            .opacity(revealProgress * (0.7 + glowPulse * 0.3))
            .position(x: position, y: barHeight / 2 + barHeight * 0.3)
    }

    @ViewBuilder
    private func positionMarker(width: CGFloat) -> some View {
        let position = width * CGFloat(moodValue)
        let moodColor = Color.moodSpectrum(value: moodValue)
        Circle()
            .fill(
                RadialGradient(
                    colors: [.white, .white.opacity(0.9), moodColor.opacity(0.5)],
                    center: .center,
                    startRadius: 0,
                    endRadius: 5
                )
            )
            .frame(width: 8, height: 8)
            .shadow(color: moodColor.opacity(0.8), radius: 6)
            .shadow(color: .white.opacity(0.6), radius: 2)
            .scaleEffect(0.3 + revealProgress * 0.7)
            .opacity(revealProgress)
            .position(x: position, y: barHeight / 2)
    }

    // MARK: - 状态机

    private func handleStateChange(_ newState: SpectrumDisplayState) {
        // 切状态时先取消所有延迟启动的 Task，避免 stale task 把动画重启到"幽灵态"。
        glowTask?.cancel()
        breathTask?.cancel()

        if newState == .revealed {
            triggerRevealAnimation()
        } else if newState == .analyzing {
            withAnimation(.easeInOut(duration: 1.2)) {
                animatedOpacity = 1.0
            }
            breathTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if Task.isCancelled { return }
                guard isAnimating, displayState == .analyzing else { return }
                startBreathingAnimation()
            }
        } else {
            stopAllAnimations()
            revealProgress = 0
            withAnimation(.easeInOut(duration: 1.2)) {
                animatedOpacity = 0.32
            }
        }
    }

    private func startBreathingAnimation() {
        guard isAnimating else { return }
        breathPhase = 0
        withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
            breathPhase = 1.0
        }
    }

    private func triggerRevealAnimation() {
        guard isAnimating else { return }
        revealProgress = 0
        glowPulse = 0
        withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
            revealProgress = 1.0
        }
        glowTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            // 三重保护：task 取消 / 组件不再动画 / 状态已经从 revealed 切走
            if Task.isCancelled { return }
            guard isAnimating, displayState == .revealed else { return }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                glowPulse = 1.0
            }
        }
        #if canImport(UIKit)
        HapticManager.shared.notification(.success)
        #endif
    }

    private func stopAllAnimations() {
        glowTask?.cancel()
        breathTask?.cancel()
        withAnimation(nil) {
            breathPhase = 0
            glowPulse = 0
        }
    }
}

// MARK: - 兼容旧API的包装器（用于DiaryDetailView等需要可拖动的场景）
struct EditableMoodSpectrumBar: View {
    @Environment(\.colorScheme) var colorScheme
    @Binding var moodValue: Double
    let isEnabled: Bool

    private let barHeight: CGFloat = 28

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let position = width * CGFloat(moodValue)
            let moodColor = Color.moodSpectrum(value: moodValue)

            ZStack(alignment: .leading) {
                // 填充部分
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.moodSpectrum(value: 0.0),
                                Color.moodSpectrum(value: moodValue)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(barHeight, position + barHeight/2))
                    .overlay(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.4), .clear],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                    )
                    .mask(Capsule().padding(2))
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: moodValue)

                // 拖动指示器
                Circle()
                    .fill(moodColor)
                    .frame(width: barHeight - 6, height: barHeight - 6)
                    .overlay(
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [.white.opacity(0.6), .clear],
                                    center: .topLeading,
                                    startRadius: 0,
                                    endRadius: barHeight/2
                                )
                            )
                    )
                    .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 2))
                    .shadow(color: moodColor.opacity(0.5), radius: 4)
                    .offset(x: max(3, min(position - barHeight/2 + 3, width - barHeight + 3)))
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: moodValue)
            }
            .contentShape(Capsule())
            .liquidGlassCapsule(interactive: true)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isEnabled else { return }
                        let newValue = Double(value.location.x / width)
                        moodValue = min(max(0, newValue), 1)
                    }
            )
        }
        .frame(height: barHeight)
        .opacity(isEnabled ? 1.0 : 0.6)
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.15).ignoresSafeArea()
        VStack(spacing: 20) {
            Text("idle").font(.caption).foregroundStyle(.secondary)
            MoodSpectrumBar(moodValue: 0.5, displayState: .idle)
                .padding(.horizontal)
            Text("analyzing").font(.caption).foregroundStyle(.secondary)
            MoodSpectrumBar(moodValue: 0.5, displayState: .analyzing)
                .padding(.horizontal)
            Text("revealed").font(.caption).foregroundStyle(.secondary)
            MoodSpectrumBar(moodValue: 0.15, displayState: .revealed).padding(.horizontal)
            MoodSpectrumBar(moodValue: 0.5, displayState: .revealed).padding(.horizontal)
            MoodSpectrumBar(moodValue: 0.85, displayState: .revealed).padding(.horizontal)
        }
        .padding()
    }
}
