import SwiftUI

/// **Streak milestone 庆祝 overlay**
///
/// HomeView 顶层 ZStack 渲染。`StreakMilestoneService.shared.pendingMilestone` 非 nil 触发,
/// service 跟 UI 通过 published 解耦。
///
/// **设计原则**:
///   - 非模态。任意 tap 立即 fade 关。
///   - ~3 秒自动 fade out。期间用户在背后做事(哪怕已开始下一篇)不被打断。
///   - 大数字用当天 mood 色 — 跟 DiaryDetail 主题色 + Home accent bar 同源。
///   - 触觉只 fire 一次 `.notification(.success)`,不重复。
///   - 不要 confetti / 撒花 / 声音 — Lumory 整体安静。
struct StreakMilestoneCelebration: View {
    let milestone: StreakMilestoneService.PendingMilestone
    let onDismiss: () -> Void

    @State private var phase: AnimationPhase = .entering
    @State private var fadeTask: Task<Void, Never>?

    private enum AnimationPhase { case entering, visible, leaving }

    /// 自动消失的总时长(秒)。tap 走 leave 动画即可,不用打断 task。
    private static let visibleSeconds: Double = 3.0
    private static let fadeDuration: Double = 0.4

    var body: some View {
        let moodColor = Color.moodSpectrum(value: milestone.moodValue)
        ZStack {
            Color.black
                .opacity(phase == .visible ? 0.45 : 0)
                .ignoresSafeArea()
                .onTapGesture { startLeaving() }

            VStack(spacing: 18) {
                Text(verbatim: "\(milestone.days)")
                    .font(.system(size: 132, weight: .bold, design: .rounded))
                    .foregroundStyle(moodColor)
                    .shadow(color: moodColor.opacity(0.45), radius: 24)
                    .scaleEffect(phase == .entering ? 0.7 : 1)
                    .opacity(phase == .visible ? 1 : 0)

                VStack(spacing: 6) {
                    Text(NSLocalizedString("milestone.subtitle.streak", comment: "Streak milestone subtitle"))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(milestoneTagline(days: milestone.days))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .opacity(phase == .visible ? 1 : 0)
                .offset(y: phase == .entering ? 12 : 0)
            }
            .scaleEffect(phase == .leaving ? 0.92 : 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(milestoneAccessibilityLabel(days: milestone.days))
        .task {
            // 入场 spring → visible → 3s 后自动 leave。
            HapticManager.shared.notification(.success)
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) {
                phase = .visible
            }
            fadeTask?.cancel()
            fadeTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Self.visibleSeconds * 1_000_000_000))
                if !Task.isCancelled, phase == .visible {
                    startLeaving()
                }
            }
        }
        .onDisappear {
            fadeTask?.cancel()
            fadeTask = nil
        }
    }

    private func startLeaving() {
        guard phase != .leaving else { return }
        fadeTask?.cancel()
        withAnimation(.easeOut(duration: Self.fadeDuration)) {
            phase = .leaving
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.fadeDuration * 1_000_000_000))
            onDismiss()
        }
    }

    private func milestoneTagline(days: Int) -> String {
        // **localizedStringWithFormat 缺中文 plural 概念**,直接按档位选不同 key 简单。
        switch days {
        case 7: return NSLocalizedString("milestone.tagline.7", comment: "7-day milestone tagline")
        case 14: return NSLocalizedString("milestone.tagline.14", comment: "14-day milestone tagline")
        case 30: return NSLocalizedString("milestone.tagline.30", comment: "30-day milestone tagline")
        case 60: return NSLocalizedString("milestone.tagline.60", comment: "60-day milestone tagline")
        case 100: return NSLocalizedString("milestone.tagline.100", comment: "100-day milestone tagline")
        default:
            // 200, 300, ...:统一文案 + 拼具体数字。
            return String(
                format: NSLocalizedString("milestone.tagline.century_plus", comment: "100+ milestone tagline (with %d)"),
                days
            )
        }
    }

    private func milestoneAccessibilityLabel(days: Int) -> String {
        String(
            format: NSLocalizedString("milestone.accessibility", comment: "Milestone VoiceOver label (with %d)"),
            days
        )
    }
}
