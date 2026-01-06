import SwiftUI

/// 简化的5档位情绪选择器（用于替代连续滑块）
struct SimplifiedMoodPicker: View {
    @Binding var moodValue: Double
    let isEnabled: Bool

    // 5个档位：😢极消极、😞消极、😐中性、😊积极、😄极积极
    private let moodLevels: [(value: Double, emoji: String, label: String)] = [
        (0.0, "😢", NSLocalizedString("极消极", comment: "Mood label")),
        (0.25, "😞", NSLocalizedString("消极", comment: "Mood label")),
        (0.5, "😐", NSLocalizedString("中性", comment: "Mood label")),
        (0.75, "😊", NSLocalizedString("积极", comment: "Mood label")),
        (1.0, "😄", NSLocalizedString("极积极", comment: "Mood label"))
    ]

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                ForEach(moodLevels.indices, id: \.self) { index in
                    moodButton(for: index)
                }
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func moodButton(for index: Int) -> some View {
        let level = moodLevels[index]
        let isSelected = abs(moodValue - level.value) < 0.13 // 容差范围
        let moodColor = Color.moodSpectrum(value: level.value)

        Button(action: {
            guard isEnabled else { return }

            #if canImport(UIKit)
            HapticManager.shared.click()
            #endif

            withAnimation(AnimationConfig.gentleSpring) {
                moodValue = level.value
            }
        }) {
            VStack(spacing: 4) {
                ZStack {
                    // 背景圆圈
                    Circle()
                        .fill(moodColor.opacity(isSelected ? 1.0 : 0.3))
                        .frame(width: isSelected ? 54 : 48, height: isSelected ? 54 : 48)

                    // 边框
                    Circle()
                        .strokeBorder(
                            isSelected ? moodColor : Color.clear,
                            lineWidth: isSelected ? 3 : 1
                        )
                        .frame(width: isSelected ? 54 : 48, height: isSelected ? 54 : 48)

                    // Emoji
                    Text(level.emoji)
                        .font(.system(size: isSelected ? 28 : 24))
                }

                // 标签（仅选中时显示）
                if isSelected {
                    Text(level.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.primary)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.5)
        .scaleEffect(isSelected ? 1.0 : 0.95)
        .animation(AnimationConfig.gentleSpring, value: isSelected)
        .animation(AnimationConfig.gentleSpring, value: isEnabled)
    }
}

#Preview {
    VStack(spacing: 30) {
        Text("Enabled")
            .font(.headline)
        SimplifiedMoodPicker(
            moodValue: .constant(0.5),
            isEnabled: true
        )

        Text("Disabled")
            .font(.headline)
        SimplifiedMoodPicker(
            moodValue: .constant(0.75),
            isEnabled: false
        )
    }
    .padding()
}
