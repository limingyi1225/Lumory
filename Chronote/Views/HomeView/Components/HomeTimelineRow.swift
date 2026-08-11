import SwiftUI
import CoreData

/// 主时间线单行容器。包 `HomeTimelineCard` 加 tap / contextMenu / swipe + list-row 修饰。
/// **不**复用旧 `DiaryEntryRow` —— 视觉结构不同;`DiaryEntryRow` 当前只保留作参考/Preview。
@available(iOS 17.0, *)
struct HomeTimelineRow: View {
    let entry: DiaryEntry
    let appLanguage: String
    let onTap: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        // **这里故意不用 `Button`**(2026-08-11 用户报"从左往右滑会打开日记详情")。
        //
        // SwiftUI 的 `Button` 只要手指没离开自己的 bounds 就保持 armed,抬手即触发,
        // **不关心中间横向移动了多远**。往左滑之所以不误触发,是因为下面
        // `.swipeActions(edge: .trailing)` 的识别器抢走了向左的拖动并取消按压;而没有
        // leading swipeActions,向右的拖动没人接,手指全程在卡内 → 抬手 = 打开详情。
        // 纵向滚动时手指落在卡上同理会误触(`views-design-tokens.md` 里 toast 距底部那条
        // 注释记的"拇指穿透进 detail" 是同一根因)。
        //
        // `TapGesture` 自带位移容差,手指移动超过阈值就不触发,正好是要的语义。
        //
        // ⚠️ **不要改回 `Button` + `simultaneousGesture(DragGesture)` 去拦**:那版试过,
        // `simultaneous` 名义并行,实际仍会把 List 的 pan 抢走 —— 手指起点落在日记卡上时
        // **整个列表滑不动**,必须从卡片外面起手。任何往 row 上挂 DragGesture 的方案都会踩这个。
        //
        // 代价:失去 `PressableScaleButtonStyle` 的按下缩放(ButtonStyle 只对 Button 生效),
        // 按下反馈现在只剩 haptic。要把缩放找回来只能挂 gesture,又会回到上面那条,
        // 所以这是有意识的取舍,不是漏做。
        HomeTimelineCard(entry: entry, appLanguage: appLanguage)
            .contentShape(
                .contextMenuPreview,
                RoundedRectangle(cornerRadius: LumoryCornerRadius.card, style: .continuous)
            )
            .padding(.bottom, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                // P1-T5 主入口 haptic — 日记卡 tap 是高频主入口,自定义 Button-shape detail 卡
                // 统一 .light impact(规则见 CLAUDE.md)。
                #if canImport(UIKit)
                HapticManager.shared.impact(.light)
                #endif
                onTap()
            }
            // Button 没了要自己补 a11y:合并子元素 + 显式 button trait + 可执行动作,
            // 否则 VoiceOver 只会读到一堆散落的 text,也点不动。
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onTap() }
            .contextMenu {
                Button {
                    onEdit()
                } label: {
                    Label(NSLocalizedString("编辑", comment: "Edit"), systemImage: "pencil")
                }
                // 删除直接执行 — 4 秒撤销 toast 替代了 confirmation alert。
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label(NSLocalizedString("删除", comment: "Delete"), systemImage: "trash")
                }
            } preview: {
                DiaryPreviewView(entry: entry, appLanguage: appLanguage) {
                    onTap()
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                // 删除直接执行 — 4 秒撤销 toast 替代了 confirmation alert。
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label(NSLocalizedString("删除", comment: "Delete"), systemImage: "trash")
                }
                Button {
                    HapticManager.shared.click()
                    onEdit()
                } label: {
                    Label(NSLocalizedString("编辑", comment: "Edit"), systemImage: "pencil")
                }
                .tint(.blue)
            }
            // §4.4 (2026-05-19) — 三件套(hidden separator + clear bg + 16/16 inset)走共享 modifier。
            .lumoryGlassListRow()
    }
}
