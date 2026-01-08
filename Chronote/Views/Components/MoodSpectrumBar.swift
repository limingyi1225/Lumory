import SwiftUI

// MARK: - Spectrum显示状态
enum SpectrumDisplayState {
    case idle           // 空闲，不显示
    case analyzing      // 分析中，完整光谱+呼吸效果
    case revealed       // 结果揭示，聚光灯效果
}

/// iOS 26 Liquid Glass风格的心情光谱条
/// 特点：
/// - 完整显示整个光谱渐变（不可拖动，无knob）
/// - 呼吸效果表示"正在分析"
/// - 发送后使用聚光灯效果，让情绪颜色从光谱中"浮现"
struct MoodSpectrumBar: View {
    @Environment(\.colorScheme) var colorScheme
    let moodValue: Double
    let displayState: SpectrumDisplayState

    // 动画状态
    @State private var breathPhase: CGFloat = 0
    @State private var revealProgress: CGFloat = 0
    @State private var glowPulse: CGFloat = 0
    @State private var animatedOpacity: CGFloat = 0.3
    @State private var isAnimating: Bool = false

    // 尺寸
    private let barHeight: CGFloat = 32
    private let spotlightWidth: CGFloat = 0.25  // 聚光区域宽度（占总宽度的比例）

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width

            ZStack {
                // 1. Liquid Glass容器
                liquidGlassContainer

                // 2. 背景光谱（淡出效果）
                fullSpectrumGradient
                    .mask(Capsule().padding(3))
                    .opacity(displayState == .revealed ? Double(0.25 * (1.0 - revealProgress * 0.5)) : animatedOpacity)

                // 3. 聚光区域的光谱（揭示时显示）
                if displayState == .revealed {
                    spotlightSpectrum(width: width)
                }

                // 4. 呼吸光晕效果（分析中）
                if displayState == .analyzing {
                    breathingGlow
                }

                // 5. 底部柔和光晕（揭示后）
                if displayState == .revealed {
                    spotlightGlow(width: width)
                }

                // 6. 位置标记（揭示后）
                if displayState == .revealed {
                    positionMarker(width: width)
                }
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
            // Stop all animations when view disappears
            isAnimating = false
            stopAllAnimations()
        }
        .onChange(of: displayState) { _, newState in
            if newState == .revealed {
                triggerRevealAnimation()
            } else if newState == .analyzing {
                withAnimation(.easeInOut(duration: 1.2)) {
                    animatedOpacity = 1.0
                }
                // Use Task instead of DispatchQueue for cancellable delay
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_200_000_000) // 1.2s
                    guard isAnimating, displayState == .analyzing else { return }
                    startBreathingAnimation()
                }
            } else {
                stopAllAnimations()
                revealProgress = 0
                withAnimation(.easeInOut(duration: 1.2)) {
                    animatedOpacity = 0.3
                }
            }
        }
    }

    // MARK: - 目标透明度
    private var targetOpacity: Double {
        switch displayState {
        case .idle:
            return 0.3
        case .analyzing:
            return 0.7
        case .revealed:
            return 1.0
        }
    }

    // MARK: - Liquid Glass容器
    private var liquidGlassContainer: some View {
        Capsule()
            .fill(.ultraThinMaterial)
            .overlay(
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.6),
                                .white.opacity(0.1),
                                .white.opacity(0.3)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: colorScheme == .dark ? 0 : 1
                    )
            )
    }

    // MARK: - 完整光谱渐变
    private var fullSpectrumGradient: some View {
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
                            colors: [
                                .white.opacity(0.15),
                                .white.opacity(0.0)
                            ],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .padding(3)
            )
    }

    // MARK: - 聚光区域光谱
    @ViewBuilder
    private func spotlightSpectrum(width: CGFloat) -> some View {
        // 使用渐变掩码创建聚光效果
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
                // 顶部玻璃高光
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.3),
                                .white.opacity(0.0)
                            ],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .padding(3)
            )
            .mask(
                // 聚光掩码：中心亮，两侧渐变淡出
                GeometryReader { geo in
                    let spotCenter = moodValue
                    let spotWidth = spotlightWidth
                    
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

    // MARK: - 呼吸光晕效果
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

    // MARK: - 聚光光晕效果
    @ViewBuilder
    private func spotlightGlow(width: CGFloat) -> some View {
        let position = width * CGFloat(moodValue)
        let moodColor = Color.moodSpectrum(value: moodValue)

        // 柔和的底部扩散光晕
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

    // MARK: - 位置标记
    @ViewBuilder
    private func positionMarker(width: CGFloat) -> some View {
        let position = width * CGFloat(moodValue)
        let moodColor = Color.moodSpectrum(value: moodValue)

        // 优雅的小标记点
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        .white,
                        .white.opacity(0.9),
                        moodColor.opacity(0.5)
                    ],
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

    // MARK: - 动画
    private func startBreathingAnimation() {
        guard isAnimating else { return }
        breathPhase = 0
        withAnimation(
            .easeInOut(duration: 2.0)
            .repeatForever(autoreverses: true)
        ) {
            breathPhase = 1.0
        }
    }

    private func triggerRevealAnimation() {
        guard isAnimating else { return }
        revealProgress = 0
        glowPulse = 0

        // 主揭示动画
        withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
            revealProgress = 1.0
        }

        // 延迟启动脉冲光晕 (check if still animating)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
            guard isAnimating else { return }
            withAnimation(
                .easeInOut(duration: 1.5)
                .repeatForever(autoreverses: true)
            ) {
                glowPulse = 1.0
            }
        }

        // 触觉反馈
        #if canImport(UIKit)
        HapticManager.shared.notification(.success)
        #endif
    }

    private func stopAllAnimations() {
        // Reset animation states without animation to stop repeatForever loops
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

    @State private var breathPhase: CGFloat = 0

    private let barHeight: CGFloat = 28

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let position = width * CGFloat(moodValue)
            let moodColor = Color.moodSpectrum(value: moodValue)

            ZStack(alignment: .leading) {
                // 玻璃容器
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(0.5),
                                        .white.opacity(0.1),
                                        .white.opacity(0.3)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: colorScheme == .dark ? 0 : 1
                            )
                    )

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
        Color.gray.opacity(0.2).ignoresSafeArea()

        VStack(spacing: 30) {
            Group {
                Text("Idle State")
                    .font(.caption)
                MoodSpectrumBar(moodValue: 0.5, displayState: .idle)
                    .padding(.horizontal)
            }

            Group {
                Text("Analyzing State")
                    .font(.caption)
                MoodSpectrumBar(moodValue: 0.5, displayState: .analyzing)
                    .padding(.horizontal)
            }

            Divider()

            Group {
                Text("Revealed: Negative (0.1)")
                    .font(.caption)
                MoodSpectrumBar(moodValue: 0.1, displayState: .revealed)
                    .padding(.horizontal)
            }

            Group {
                Text("Revealed: Neutral (0.5)")
                    .font(.caption)
                MoodSpectrumBar(moodValue: 0.5, displayState: .revealed)
                    .padding(.horizontal)
            }

            Group {
                Text("Revealed: Positive (0.85)")
                    .font(.caption)
                MoodSpectrumBar(moodValue: 0.85, displayState: .revealed)
                    .padding(.horizontal)
            }

            Divider()

            Group {
                Text("Editable (for DiaryDetail)")
                    .font(.caption)
                EditableMoodSpectrumBar(moodValue: .constant(0.6), isEnabled: true)
                    .padding(.horizontal)
            }
        }
        .padding()
    }
}
