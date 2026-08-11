import SwiftUI

// 插入录音行子视图以简化列表项
struct RecordingRow: View {
    let recording: Recording
    @ObservedObject var controller: AudioPlaybackController
    let isTranscribing: Bool
    let isRecording: Bool
    let onPlay: () -> Void
    let onPrepareError: (Error) -> Void
    let onDelete: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// 进度条拖动态(非 nil = 手指按在进度条上)。见 `AudioScrubber`。
    @State private var scrubFraction: Double?

    private var isCurrent: Bool {
        controller.currentPlayingFileName == recording.fileName
    }
    private var isPlayingThis: Bool {
        isCurrent && controller.isPlaying
    }
    /// 转写中 / 录音中不让拖 —— 跟播放按钮的 disabled 条件保持一致。
    private var isInteractionBlocked: Bool {
        isTranscribing || isRecording
    }

    // 2026-08-11 **这一行故意没有时间读数**。历史上依次是 `00:14 / 01:23` 合并串 →
    // 单个已播秒数(丢了总长)→ `0:14 / 1:23`,最后一版把进度条挤到没法拖(用户:"太拥挤了")。
    // 结论:composer 这行宽度就那么点,塞不下 44pt 播放钮 + 波形 + 可拖进度条 + 等宽数字。
    // 进度条本身已经表达位置,**秒数留给日记详情页的播放器**(那里有整卡宽度,已播 / 剩余两端都放得下)。
    // 想加回来之前先想清楚砍谁 —— 别默认砍进度条宽度。
    // 时长仍然通过 `AudioScrubber` 的 `accessibilityValue` 透给 VoiceOver,不是纯丢失。

    var body: some View {
        HStack(spacing: 10) {
            // 2026-08-11 拆掉图标外面那圈 accent 圆填充(用户:"能否进一步更简洁")。
            // 裸符号少一层形状,跟右侧 ghost 删除钮同构;为了在没有底衬时仍有足够视觉重量,
            // 字号从 10 提到 13 并保持 accent 实色(删除钮是 secondary,主次仍然分得开)。
            Button {
                #if canImport(UIKit)
                HapticManager.shared.impact(.light)
                #endif
                onPlay()
            } label: {
                Image(systemName: isPlayingThis ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(AnimationConfig.gentleSpring, value: isPlayingThis)
            }
            .buttonStyle(PressableScaleButtonStyle())
            // 视觉是裸符号，Button 本身保留完整 44pt 命中区。
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .disabled(isTranscribing || isRecording)
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

            // 2026-08-11 —— 原来这里只有一个时长读数,进度是整条 capsule 的背景填充,
            // 纯展示不能拖。换成共享的 `AudioScrubber`,跟日记详情同一个组件。
            // 转写 / 录音中禁用交互,但仍然显示(灰着),避免布局跳动。
            AudioScrubber(
                scrubFraction: $scrubFraction,
                progress: isCurrent ? controller.progress : 0,
                duration: recording.duration,
                tint: Color.accentColor.opacity(isInteractionBlocked ? 0.35 : 1),
                trackHeight: 4,
                hitHeight: 20,
                onScrubBegin: {
                    // 没播过的录音先建 player,否则 seek 无处可去。
                    // `Recording` 只存 fileName,URL 走跟 `HomeView.resolvedAudioURL` 同一个
                    // 三层 fallback 解析器;**文件已丢失**时静默不 prepare,拖动就是无效操作
                    // (丢失提示留给 play 路径,不在拖动时弹 banner 打断)。
                    // 但文件在、`AVAudioPlayer` 解不开时,`prepare` 显式抛错给 parent —— 不能依赖
                    // `controller.onPlayError`,那个 callback 只在用户按下播放时才装。
                    guard let url = LumoryAttachmentPaths.existingAudioURL(fileName: recording.fileName) else { return }
                    do {
                        try controller.prepare(url: url, fileName: recording.fileName)
                    } catch {
                        onPrepareError(error)
                    }
                },
                onSeek: { controller.seek(to: $0) }
            )
            .disabled(isInteractionBlocked)
            .layoutPriority(1)

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
            }
            .buttonStyle(.plain)
            // 视觉仍是 ghost icon，Button 本身保留完整 44pt 命中区。
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel(NSLocalizedString("删除录音", comment: "Delete recording"))
        }
        .padding(.horizontal, 10)
        .background {
            // 卡内 row 用半透明实体 fill；外层 composer 才是唯一 glass surface。
            // 2026-08-11:原来这里还叠了一层"整条 capsule 按进度填充"的伪进度条,
            // 现在进度由 `AudioScrubber` 明确表达,底色回归单纯的 row 背景 —— 两套进度视觉
            // 并存会让人分不清哪个才是可拖的。
            Capsule()
                .fill(Color.secondary.opacity(colorScheme == .dark ? 0.14 : 0.08))
                // 视觉胶囊保持 36pt 的轻薄感，透明的上下区域留给 44pt 触控目标。
                .frame(height: 36)
        }
    }
}
