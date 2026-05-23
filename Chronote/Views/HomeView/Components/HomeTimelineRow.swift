import SwiftUI
import CoreData

/// 主时间线单行容器。包 `HomeTimelineCard` 加 tap / contextMenu / swipe + list-row 修饰。
/// **不**复用 Insights / ThemeFiltered 用的 `DiaryEntryRow` —— 视觉结构不同。
@available(iOS 17.0, *)
struct HomeTimelineRow: View {
    let entry: DiaryEntry
    let appLanguage: String
    let onTap: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button {
            // P1-T5 主入口 haptic — 日记卡 tap 是高频主入口,自定义 Button-shape detail 卡
            // 统一 .light impact(规则见 CLAUDE.md)。
            #if canImport(UIKit)
            HapticManager.shared.impact(.light)
            #endif
            onTap()
        } label: {
            HomeTimelineCard(entry: entry, appLanguage: appLanguage)
                .contentShape(
                    .contextMenuPreview,
                    RoundedRectangle(cornerRadius: LumoryCornerRadius.card, style: .continuous)
                )
                .padding(.bottom, 10)
                .contentShape(Rectangle())
        }
        // P1-T6 PressableScaleButtonStyle — liquidGlassCard + 自定义 Button = 统一套这个 style。
        .buttonStyle(PressableScaleButtonStyle())
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
