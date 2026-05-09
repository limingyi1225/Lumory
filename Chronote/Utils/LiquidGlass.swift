import SwiftUI

// MARK: - Liquid Glass tokens
//
// P1-T2:跨 view 圆角 14/16/18/22 散布,reviewer 抓到同 view 内多种圆角并存。
// 统一规则:**内容卡 16,toast / overlay 系统级 chip 22**。新代码必须从这里拿,不要再写 14/18。

enum LumoryCornerRadius {
    /// 内容卡(timeline row、settings row、insights module、TextEditor 玻璃化等)
    static let card: CGFloat = 16
    /// toast / overlay 系统级 chip(底部 capsule、popover-style 浮层)
    static let chip: CGFloat = 22
    /// inline banner 类(略小于 card,跟 card 视觉层级有 4pt 差)— 错误 / 警告 / 不完整提示条
    static let inline: CGFloat = 12
}

// MARK: - Liquid Glass View Extensions

extension View {
    /// iOS 26 Liquid Glass card background. Used for input container and
    /// timeline cards. Optional `tint` for mood-aware surfaces.
    /// Set `interactive: true` only for tap-target cards (list rows, CTA cards)
    /// — Apple's guidance reserves `.interactive()` for elements that respond
    /// to touch/pointer.
    func liquidGlassCard(
        cornerRadius: CGFloat = 16,
        tint: Color? = nil,
        tintStrength: Double = 0.16,
        interactive: Bool = false
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        var style: Glass = .regular
        if let tint {
            style = style.tint(tint.opacity(tintStrength))
        }
        if interactive {
            style = style.interactive()
        }
        return self.glassEffect(style, in: shape)
    }

    /// Capsule-shaped glass (used by spectrum and pill buttons).
    func liquidGlassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        var style: Glass = .regular
        if let tint {
            style = style.tint(tint.opacity(0.18))
        }
        if interactive {
            style = style.interactive()
        }
        return self.glassEffect(style, in: Capsule())
    }

    /// 圆形 glass(日历日期格、圆形 chip 用)。
    func liquidGlassCircle(
        tint: Color? = nil,
        tintStrength: Double = 0.32,
        interactive: Bool = false
    ) -> some View {
        var style: Glass = .regular
        if let tint {
            style = style.tint(tint.opacity(tintStrength))
        }
        if interactive {
            style = style.interactive()
        }
        return self.glassEffect(style, in: Circle())
    }

    /// Insights dashboard module card — consistent corner radius + subtle shadow.
    func insightsCard(cornerRadius: CGFloat = 18) -> some View {
        self.liquidGlassCard(cornerRadius: cornerRadius)
            .shadow(color: Color.primary.opacity(0.05), radius: 8, x: 0, y: 3)
    }

    /// Left accent bar — a narrow colored strip clipped inside the card shape.
    @ViewBuilder
    func moodAccentBar(_ color: Color, cornerRadius: CGFloat = 16, visible: Bool = true) -> some View {
        if visible {
            self.overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.95), color.opacity(0.55)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 3)
                    .padding(.vertical, 10)
                    .padding(.leading, 6)
                    .shadow(color: color.opacity(0.5), radius: 4, y: 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
        }
    }
}
