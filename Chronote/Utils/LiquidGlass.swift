import SwiftUI

// MARK: - Liquid Glass tokens
//
// 语义层级:
// - inline 12:输入框、warning/loading banner、短提示面。
// - nestedRow 14:卡片内部的候选 row / citation row / message bubble。
// - card 16:主内容卡、设置 row、Insights module。
// - chip 22:composer 外壳、toast / overlay / popover-style chip。
// 新代码优先从这里取 token,只有非常小的装饰 shape 才保留裸值。

enum LumoryCornerRadius {
    /// 内容卡(timeline row、settings row、insights module、TextEditor 玻璃化等)
    static let card: CGFloat = 16
    /// 嵌套子行(picker 候选 row / Ask Past message 气泡 / citation row)
    /// — 介于 inline (12) 和 card (16) 之间,事实第 4 档。
    static let nestedRow: CGFloat = 14
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
        cornerRadius: CGFloat = LumoryCornerRadius.card,
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
    func insightsCard(cornerRadius: CGFloat = LumoryCornerRadius.card) -> some View {
        self.liquidGlassCard(cornerRadius: cornerRadius)
            .shadow(color: Color.primary.opacity(0.05), radius: 8, x: 0, y: 3)
    }

    /// §4.4 (2026-05-19) — Form / List 内 liquidGlassCard 行的三件套统一入口:隐分割线 +
    /// 清空 row 背景 + 强制 leading=16 / trailing=16 inset(`views-design-tokens.md` 规则)。
    /// 替 8+ 处 `.listRowSeparator(.hidden) + .listRowBackground(Color.clear) +
    /// .listRowInsets(EdgeInsets(top:_, leading: 16, bottom:_, trailing: 16))` 散布。
    /// `top` / `bottom` 各 callsite 不一(0/6/8/14/28),保留参数。
    func lumoryGlassListRow(top: CGFloat = 0, bottom: CGFloat = 0) -> some View {
        self.listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: top, leading: 16, bottom: bottom, trailing: 16))
    }

    /// §4.6 (2026-05-19) — 带心情色 accent bar 的卡:`.liquidGlassCard + .moodAccentBar` 配对
    /// 在 HomeTimelineCard / OnThisDaySection / DiaryPreviewView 重复 3 次,抽统一入口。
    /// **注**:不是 mood-tinted card(那是 DiaryEntryRow 独自的 `tint + tintStrength` 写法,
    /// accent bar 和 tint 是两种 mood 信号)。这条只覆盖 "accent bar" 流。
    func lumoryAccentCard(mood: Color, cornerRadius: CGFloat = LumoryCornerRadius.card, interactive: Bool = true) -> some View {
        self
            .liquidGlassCard(cornerRadius: cornerRadius, interactive: interactive)
            .moodAccentBar(mood, cornerRadius: cornerRadius)
    }

    /// Left accent bar — a narrow colored strip clipped inside the card shape.
    @ViewBuilder
    func moodAccentBar(_ color: Color, cornerRadius: CGFloat = LumoryCornerRadius.card, visible: Bool = true) -> some View {
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
