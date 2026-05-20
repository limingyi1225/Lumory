import SwiftUI

// MARK: - InlineWarningBanner
//
// §4.3 (2026-05-19) — 收编 3 处几乎一字不差的 inline warning 横幅:
//   - HomeComposerCard 录音播放错误 banner
//   - HomeComposerCard 图片压缩失败 banner
//   - AskPastView incompleteBanner(orange tint 略不同但骨架一致)
// 转写失败 banner 因 waveform 图标、描边、retry button 和紧凑 padding 保持独立。
//
// 公共模式:warning 三角图标 + 文字(.footnote secondary)+ 可选 close X +
// `padding(.horizontal, 12)` / `padding(.vertical, 8)` +
// `Color.orange.opacity(0.08)` 背景 + `LumoryCornerRadius.inline` 圆角。
//
// **使用约定**:
//   - 普通错误 toast / 状态消息走 LumoryToastCenter,**不要**走这条 inline banner;
//   - banner 用在"页面上某一行常驻提示" — 用户需要看到状态而不是被弹出打断;
//   - 有 close X(`onClose` 非 nil)= 用户能主动 dismiss;无 close = 状态结束自动消失。

struct InlineWarningBanner: View {
    let message: String
    let tint: Color
    let tintOpacity: Double
    let onClose: (() -> Void)?

    init(
        message: String,
        tint: Color = .orange,
        tintOpacity: Double = 0.08,
        onClose: (() -> Void)? = nil
    ) {
        self.message = message
        self.tint = tint
        self.tintOpacity = tintOpacity
        self.onClose = onClose
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
                .font(.footnote)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(NSLocalizedString("关闭", comment: "Dismiss"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(tintOpacity), in: RoundedRectangle(cornerRadius: LumoryCornerRadius.inline))
    }
}
