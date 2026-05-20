import SwiftUI

// 插入录音行子视图以简化列表项
struct RecordingRow: View {
    let recording: Recording
    @ObservedObject var controller: AudioPlaybackController
    let isTranscribing: Bool
    let onPlay: () -> Void
    let onDelete: () -> Void

    private var isCurrent: Bool {
        controller.currentPlayingFileName == recording.fileName
    }
    private var isPlayingThis: Bool {
        isCurrent && controller.isPlaying
    }

    var body: some View {
        HStack(spacing: 10) {
            // 左侧 mini 播放/暂停按钮 —— 单层 glass,小尺寸,贴合输入卡的玻璃语言
            Button {
                #if canImport(UIKit)
                HapticManager.shared.impact(.light)
                #endif
                onPlay()
            } label: {
                Image(systemName: isPlayingThis ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.glass)
            .disabled(isTranscribing)
            .accessibilityLabel(isPlayingThis
                ? NSLocalizedString("暂停", comment: "Pause")
                : NSLocalizedString("播放", comment: "Play"))

            // (2026-05-19) 转写中走 iOS 26 风格的 SF Symbol `.variableColor.iterative` 动画 —
            // waveform 图标本身一直在,只是色彩从尾部向头部反复填充,告诉用户"转写正在进行"
            // 而不需要任何文字。波形 + 计时区切到全 secondary,跟"已停止 / 等待落字"区分开。
            Image(systemName: "waveform")
                .font(.footnote)
                .foregroundStyle(isTranscribing
                    ? Color.accentColor
                    : Color.accentColor.opacity(0.85))
                .symbolEffect(
                    .variableColor.iterative.reversing,
                    options: .repeat(.continuous),
                    isActive: isTranscribing
                )

            Text(formattedDuration(
                currentTime: isCurrent ? controller.currentTime : 0,
                totalDuration: recording.duration
            ))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.primary.opacity(isTranscribing ? 0.45 : 0.85))

            Spacer(minLength: 4)

            // 右侧 ghost 删除钮 —— 不抢眼,但 hit area 够大
            Button {
                #if canImport(UIKit)
                HapticManager.shared.impact(.light)
                #endif
                onDelete()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("删除录音", comment: "Delete recording"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            // 玻璃胶囊背景 + 播放进度作为 accent 色 capsule overlay,
            // 比之前的实色灰底 + 蓝条柔和很多。
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.clear)
                    .liquidGlassCapsule()
                if isCurrent && recording.duration > 0 {
                    GeometryReader { geo in
                        Capsule()
                            .fill(Color.accentColor.opacity(0.18))
                            .frame(width: geo.size.width * controller.progress)
                    }
                    .clipShape(Capsule())
                    .allowsHitTesting(false)
                }
            }
        }
    }
}
