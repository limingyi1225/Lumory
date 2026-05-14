import SwiftUI
import CoreData

/// 主时间线 list 内容。`ForEach` 输出多行,每行自带 list-row 修饰器(在 `HomeTimelineRow` 内)。
/// 由调用方放在 `List { ... }` 内,parent 把 `@FetchedResults` 转 `[DiaryEntry]` 喂下去。
@available(iOS 17.0, *)
struct HomeTimelineList: View {
    let entries: [DiaryEntry]
    let appLanguage: String
    let onTap: (DiaryEntry) -> Void
    let onEdit: (DiaryEntry) -> Void
    let onDelete: (DiaryEntry) -> Void

    var body: some View {
        // 用 objectID 作稳定 identity,List 能识别单行 delete 播原生 row-removal 动画;
        // 同时 `@FetchRequest` 已关 animation,parent 的 `withAnimation { delete }` 独立生效。
        ForEach(entries, id: \.objectID) { entry in
            HomeTimelineRow(
                entry: entry,
                appLanguage: appLanguage,
                onTap: { onTap(entry) },
                onEdit: { onEdit(entry) },
                onDelete: { onDelete(entry) }
            )
        }
    }
}

/// 时间线为空时的占位。冷启动 `@FetchRequest` 还没拉完时不显示(parent 用 `hasLoadedOnce` 守门)。
@available(iOS 17.0, *)
struct HomeTimelineEmptyState: View {
    var body: some View {
        Section {
            // 共享 EmptyStateView —— 只留图标 + 标题。原副标题("点下方输入框写一句…")
            // 按用户要求移除:输入框 / 麦克风入口本身已经在屏上,提示行属冗余引导。
            EmptyStateView(
                systemImage: "book.closed",
                title: NSLocalizedString("暂无日记，快去记录吧～", comment: "Empty timeline title")
            )
            .frame(minHeight: 320)
        }
        .listRowSeparator(.hidden)
        .listSectionSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowBackground(Color.clear)
    }
}
