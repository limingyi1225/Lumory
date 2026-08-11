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

// MARK: - App 背景(玻璃的折射源)

/// App 级背景 —— **只挂在 NavigationStack 的根页面**(HomeView / SettingsView 这类)。
///
/// 存在理由不是装饰,是让 `glassEffect` 有东西可折射。glass 渲染的是"背后像素被折射 / 模糊
/// 后的结果":背后若是**均匀不透明纯色**,折射输出 == 同一个纯色,玻璃就只剩边缘那圈 rim。
/// 2026-08-11 用户在 iOS 27 上报的"首页日记卡片边缘和背景融为一体"就是这个链条的终点
/// (rim 又被 `moodAccentBar` 的 clipShape 裁掉 → 卡片 0 对比度)。给一层极淡但**全高非均匀**
/// 的底,玻璃才折得出层次。
///
/// ⚠️ **sub-page 不要再挂一次**:NavigationStack push/pop transition 的中间帧会把两层 alpha
/// 叠加,视觉上"暗一闪"(`views-design-tokens.md` 记过这个坑)。parent 挂,child 透出来。
private struct LumoryAppBackgroundModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.background(background.ignoresSafeArea())
    }

    private var background: some View {
        ZStack {
            baseBackgroundColor
            // 全高渐变(不是 top→center 的半屏 wash)—— 屏幕下半部分的卡片同样需要
            // 非均匀 backdrop,否则滚到下面的日记卡又会退化成"纯色上的玻璃"。
            //
            // **色相中性、极淡**:2026-08-11 第一版用 `Color.accentColor.opacity(0.10)`,
            // 用户反馈"背景一个大蓝色,看起来很廉价"。现在用 `Color.primary` 的极低 alpha
            // (亮色 0.022 / 暗色 0.030),只提供玻璃折射需要的那点明度梯度,不引入任何色相。
            // 想再动这个值先看真机:超过 ~0.04 就开始"脏"。
            LinearGradient(
                colors: [
                    Color.primary.opacity(0),
                    Color.primary.opacity(colorScheme == .dark ? 0.030 : 0.022)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

/// 平台中性的不透明底色 — iOS 用 `UIColor.systemBackground`,macOS 落 `.white`。
///
/// **不要改成 `systemGroupedBackground`(浅灰)** —— 2026-08-11 试过"灰底 + 实体白卡"那一版,
/// 用户否掉了(见 `lumoryAccentCard` 注释)。底色保持纯白/纯黑。
private var baseBackgroundColor: Color {
    #if canImport(UIKit)
    return Color(UIColor.systemBackground)
    #else
    return Color.white
    #endif
}

extension Color {
    /// Settings 根页和 push 子页共用的不透明 grouped 底色。
    static var lumorySettingsGroupedBackground: Color {
        #if canImport(UIKit)
        return Color(UIColor.systemGroupedBackground)
        #else
        return Color(white: 0.95)
        #endif
    }
}

// MARK: - Liquid Glass View Extensions

extension View {
    /// 见 `LumoryAppBackgroundModifier` 的文档 —— 只挂 root 页面。
    func lumoryAppBackground() -> some View {
        modifier(LumoryAppBackgroundModifier())
    }

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

    /// Insights dashboard module card — consistent corner radius.
    ///
    /// 2026-08-11:去掉了原来叠在 `liquidGlassCard` 之上的
    /// `.shadow(color: .primary.opacity(0.05), radius: 8, y: 3)`。系统 Liquid Glass 自带边缘
    /// 高光 + 接触阴影,外面再糊一层 SwiftUI shadow 会和它叠成一圈脏的双边(iOS 27 把 glass
    /// 自身的 rim 加重之后尤其明显)。要层次感靠 glass 自己,不要手加 shadow。
    func insightsCard(cornerRadius: CGFloat = LumoryCornerRadius.card) -> some View {
        self.liquidGlassCard(cornerRadius: cornerRadius)
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

    /// §4.6 (2026-05-19) — 带心情色 accent bar 的**内容层**卡:HomeTimelineCard /
    /// OnThisDaySection / DiaryPreviewView 三处共用。
    /// **注**:不是 mood-tinted card(那是 DiaryEntryRow 独自的 `tint + tintStrength` 写法,
    /// accent bar 和 tint 是两种 mood 信号)。这条只覆盖 "accent bar" 流。
    ///
    /// **2026-08-11 保持玻璃,不要改成实体 surface。** 这天试过一版"灰底 + 实体白卡"
    /// (`systemGroupedBackground` + `secondarySystemGroupedBackground`),本体对比度确实
    /// 从 ~3/255 提到 ~13/255,但**用户明确否掉**:"背景一个大蓝色看起来很廉价,而且没有玻璃了
    /// 不好看"。真正解决"卡片边缘和背景融为一体"的是 `moodAccentBar` 里那句 `clipShape` 的移除
    /// (边缘 10/255 → 27/255),不是换材质。**别再提"内容层不该用玻璃"来重开这个改动** ——
    /// 产品上已经拍板:玻璃观感 > 本体对比度。
    func lumoryAccentCard(mood: Color, cornerRadius: CGFloat = LumoryCornerRadius.card, interactive: Bool = true) -> some View {
        self
            .liquidGlassCard(cornerRadius: cornerRadius, interactive: interactive)
            .moodAccentBar(mood, cornerRadius: cornerRadius)
    }

    /// Left accent bar — a narrow colored strip inset inside the card shape.
    ///
    /// **绝对不要在这里加 `.clipShape(卡片形状)`**(2026-08-11 修复,iOS 27 上是致命的)。
    /// 历史上这个函数结尾有一句 `.clipShape(RoundedRectangle(cornerRadius: cornerRadius))`,
    /// 名义上是"把 accent bar 裁进圆角内",实际后果是**把它下面那层 `glassEffect` 的边缘高光
    /// 一起裁掉了** —— glass 的镜面 rim 会溢出 shape 边界一点点,clip 到 content bounds 就没了。
    /// 在纯色不透明背景上,那圈 rim 是玻璃唯一会渲染出来的东西(背后没有可折射的内容),
    /// 裁掉就等于把卡片仅有的边界也抹了。实测 iOS 27.0 + iOS 27 SDK,日记卡右缘最大亮度
    /// 跳变:**带 clip 10/255 → 去掉 clip 27/255**(2.7x)。同屏只走 `liquidGlassCard`、
    /// 没有这层 clip 的 composer 卡是 97/255。用户报的"卡片边缘和背景融为一体"里,
    /// 这一层贡献了边缘那部分。
    ///
    /// **注意:去掉 clip 只解决"边",没解决"面"** —— 玻璃在不透明纯色底上的本体明度和背景
    /// 只差 0.5~3.5/255,内容层卡片要真正立起来必须自己有 surface fill,不能指望 glassEffect。
    /// 别把这条注释当成"clip 删了就完事了"。
    ///
    /// clip 本身也是多余的:bar 宽 3pt、leading inset 6pt、vertical inset 10pt,而圆角在
    /// y=10 处向内缩进量 = r - sqrt(r² - (r-10)²),对现有全部 token(inline 12 / nestedRow 14 /
    /// card 16 / chip 22)最大只有 3.56pt(r=22)< 6pt。bar 在任何一档下都已经落在圆角内部,
    /// 不需要裁。新增更大圆角 token 时重算一遍这个式子,别直接把 clipShape 加回来。
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
        } else {
            self
        }
    }
}
