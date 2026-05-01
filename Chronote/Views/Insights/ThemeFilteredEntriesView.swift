import SwiftUI
import CoreData

// MARK: - Theme filtered entries sheet
//
// 点击 ThemeCard 后弹出：筛选出该主题的所有日记条目，复用 DiaryEntryRow。

struct ThemeFilteredEntriesView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    let theme: InsightsEngine.Theme
    /// 父视图传入的全部 themes(用来给 merge sheet 列候选,排除自己)
    let allThemes: [InsightsEngine.Theme]
    /// 父视图回调,处理合并成功后的 toast / reload。
    let onMerged: ((_ message: String) -> Void)?
    /// 父视图回调,处理删除主题后的 toast / 关 sheet。
    let onDeleted: ((_ name: String) -> Void)?

    @State private var entries: [DiaryEntry] = []
    /// merge sheet 的 trigger。`.sheet(item:)` 比 `.sheet(isPresented:)` 抗父级 reload —
    /// alias map 变更通知能让父级 InsightsView 重 evaluate `themeFilter`,sheet item identity
    /// 驱动比 Bool 稳。CLAUDE.md `.sheet` 反复踩坑章节。
    @State private var mergeSubject: InsightsEngine.Theme?
    @State private var showDeleteAlert = false
    @State private var deleteFailureMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tag")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text(NSLocalizedString("没有匹配的日记", comment: "No matched entries"))
                            .foregroundColor(.secondary)
                    }
                } else {
                    // .plain + 透明 row + 清空 List 背景 → DiaryEntryRow 自带的 liquidGlassCard
                    // 才能干净地浮在系统的玻璃 sheet 背景上,不被 insetGrouped 的灰底压住。
                    List {
                        ForEach(entries, id: \.objectID) { entry in
                            NavigationLink(value: entry) {
                                DiaryEntryRow(entry: entry)
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .navigationDestination(for: DiaryEntry.self) { entry in
                        DiaryDetailView(entry: entry, startInEditMode: false)
                    }
                }
            }
            .navigationTitle(theme.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("关闭", comment: "Close")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            mergeSubject = theme
                        } label: {
                            Label(
                                NSLocalizedString("合并到其他主题…", comment: "Merge into another theme"),
                                systemImage: "arrow.triangle.merge"
                            )
                        }
                        Button(role: .destructive) {
                            showDeleteAlert = true
                        } label: {
                            Label(
                                NSLocalizedString("删除主题", comment: "Delete theme"),
                                systemImage: "trash"
                            )
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(NSLocalizedString("更多操作", comment: "More actions"))
                }
            }
            .onAppear(perform: fetch)
            .sheet(item: $mergeSubject) { subject in
                ThemeMergeIntoSheet(
                    source: subject,
                    candidates: allThemes.filter { $0.id != subject.id }
                ) { target in
                    let outcome = ThemeAliasResolver.shared.mergeThemes(source: subject.name, into: target.name)
                    switch outcome {
                    case .merged:
                        let resolvedTarget = ThemeAliasResolver.shared.canonicalize(target.name)
                        let message = String(
                            format: NSLocalizedString("已把「%@」合并到「%@」", comment: "Merge toast"),
                            subject.name,
                            resolvedTarget
                        )
                        return .success(
                            title: String(
                                format: NSLocalizedString("已合并到「%@」", comment: "Merged success"),
                                resolvedTarget
                            ),
                            toastMessage: message
                        )
                    case .noop:
                        return .noop(message: NSLocalizedString("它们已经是同一组了", comment: "Merge no-op toast"))
                    }
                } onComplete: { outcome in
                    guard let message = outcome.toastMessage else { return }
                    // 合并后此 filtered view 显示的 theme 已经是别名,关掉让用户看 Insights 重聚合后的 canonical。
                    dismiss()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(160))
                        onMerged?(message)
                    }
                }
            }
            .alert(
                String(format: NSLocalizedString("删除主题「%@」?", comment: "Delete theme alert title"), theme.name),
                isPresented: $showDeleteAlert
            ) {
                Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) { }
                Button(NSLocalizedString("删除", comment: "Delete"), role: .destructive) {
                    Task { await performDelete() }
                }
            } message: {
                Text(NSLocalizedString("将从所有日记里抹掉这个主题(包括它的所有别名)。原日记内容不变。此操作不可撤销。", comment: "Delete theme message"))
            }
            .alert(
                NSLocalizedString("删除失败", comment: "Delete failed"),
                isPresented: Binding(
                    get: { deleteFailureMessage != nil },
                    set: { if !$0 { deleteFailureMessage = nil } }
                )
            ) {
                Button(NSLocalizedString("好", comment: "OK"), role: .cancel) {
                    deleteFailureMessage = nil
                }
            } message: {
                Text(deleteFailureMessage ?? "")
            }
        }
    }

    private func performDelete() async {
        let outcome = await ThemeManagementService.shared.deleteTheme(canonical: theme.name)
        if outcome.succeeded {
            dismiss()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(160))
                onDeleted?(theme.name)
            }
        } else {
            deleteFailureMessage = String(
                format: NSLocalizedString("删除「%@」失败,可能是磁盘空间不足或同步冲突。请稍后重试。", comment: "Delete theme failed"),
                theme.name
            )
        }
    }

    private func fetch() {
        let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
        // UUID 不符合 CVarArg；需要桥接成 NSArray 让 Core Data 正确匹配每个 UUID。
        // 旧代码 `as [CVarArg]` 在运行时会抛 "Could not cast value of type 'UUID' to 'CVarArg'"。
        request.predicate = NSPredicate(format: "id IN %@", theme.entryIds as NSArray)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)]
        entries = (try? viewContext.fetch(request)) ?? []
    }
}
