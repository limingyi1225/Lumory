import SwiftUI

/// 可拖动的音频进度条。**日记详情 `audioBlock` 和首页 `RecordingRow` 共用同一个实现**,
/// 别再各写一份 —— 这两处历史上各有一条纯展示的 Capsule,都不能拖(2026-08-11 用户报的)。
///
/// 设计要点:
/// - **没有圆点 thumb**(2026-08-11 用户:"不够简洁")。只有一条轨道 + 已播填充,
///   按住时轨道加粗(`activeTrackHeight`)—— 这是去掉圆点后**唯一**的"我抓住了"反馈,
///   要再删就等于拖动完全无触觉外的确认,别删。
/// - **拖动态由 caller 持有**(`scrubFraction` binding,非 nil = 正在拖)。caller 需要用它
///   覆盖时间读数,让"已播 / 剩余"跟着手指走而不是跟着播放头走。
/// - `onScrubBegin` 给 caller 一个钩子做**首次拖动前的播放器预加载** —— 没播过的录音
///   `AVAudioPlayer` 还没建,`seek` 无处可去,拖了不动。见 `AudioPlaybackController.prepare`。
/// - 没有 thumb 之后落点就是纯 `x / width`,不再需要减半个圆点宽度做中心补偿。
///
/// ⚠️ 这是个 slider,`DragGesture` 会捕获落在轨道上的纵向拖动 —— 在 ScrollView 里,手指正好
/// 起于轨道时那一下滑不动页面。系统 `Slider` 行为完全一致,属于平台惯例,不是 bug。
/// 所以 hit area 保持在 26pt,别为了"更好拖"随手加高。
struct AudioScrubber: View {
    /// 非 nil = 正在拖,值为 0...1。caller 用它覆盖时间读数。
    @Binding var scrubFraction: Double?
    /// 播放进度 0...1(非拖动时的显示来源)
    let progress: Double
    let duration: TimeInterval
    let tint: Color
    var trackHeight: CGFloat = 5
    /// 手势命中高度。**这是可拖动区域的实际高度,不只是视觉**,调小直接让进度条更难拖到。
    /// 详情页用默认 26;首页 composer 行空间紧、要求更细,用 20(2026-08-11 用户要求"弄细点")。
    /// 别再往下调了 —— 低于 ~18 拇指基本按不准。
    var hitHeight: CGFloat = 26
    /// 拖动开始。caller 在这里 `prepare` 播放器。
    var onScrubBegin: () -> Void = {}
    /// 抬手落定,参数是目标秒数。
    let onSeek: (TimeInterval) -> Void

    private var displayedFraction: Double {
        min(max(scrubFraction ?? progress, 0), 1)
    }

    private var isScrubbing: Bool { scrubFraction != nil }

    /// 按住时轨道加粗。取代原来"圆点放大 1.35x"的抓握反馈。
    private var activeTrackHeight: CGFloat {
        isScrubbing ? trackHeight * 1.8 : trackHeight
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let fraction = displayedFraction

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))

                Capsule()
                    .fill(tint)
                    .frame(width: width * fraction)
            }
            .frame(height: activeTrackHeight)
            .animation(AnimationConfig.gentleSpring, value: isScrubbing)
            // 轨道在 hit area 里垂直居中,剩下的空白仍然接手势。
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if scrubFraction == nil {
                            onScrubBegin()
                            #if canImport(UIKit)
                            HapticManager.shared.impact(.light)
                            #endif
                        }
                        scrubFraction = min(max(value.location.x / width, 0), 1)
                    }
                    .onEnded { _ in
                        if let fraction = scrubFraction, duration > 0 {
                            onSeek(fraction * duration)
                        }
                        scrubFraction = nil
                    }
            )
        }
        .frame(height: hitHeight)
        .accessibilityElement()
        .accessibilityLabel(NSLocalizedString("播放进度", comment: "Audio scrubber a11y label"))
        .accessibilityValue(formattedTimestamp(displayedFraction * duration))
        // VoiceOver 用户没法拖,给上下滑 ±5 秒的 adjustable action。
        .accessibilityAdjustableAction { direction in
            guard duration > 0 else { return }
            // Home 的录音不像详情页那样自动预加载。VoiceOver 首次调节时也必须先
            // prepare，否则 controller 里还没有 player，后面的 seek 会静默无效。
            onScrubBegin()
            let current = displayedFraction * duration
            let step: TimeInterval = 5
            switch direction {
            case .increment: onSeek(min(duration, current + step))
            case .decrement: onSeek(max(0, current - step))
            @unknown default: break
            }
        }
    }
}
