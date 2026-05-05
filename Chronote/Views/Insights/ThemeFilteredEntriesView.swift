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
    /// 父视图回调,处理 sheet 内单删 entry 后的聚合刷新。
    let onEntryDeleted: (() -> Void)?

    @State private var entries: [DiaryEntry] = []
    /// merge sheet 的 trigger。`.sheet(item:)` 比 `.sheet(isPresented:)` 抗父级 reload —
    /// alias map 变更通知能让父级 InsightsView 重 evaluate `themeFilter`,sheet item identity
    /// 驱动比 Bool 稳。CLAUDE.md `.sheet` 反复踩坑章节。
    @State private var mergeSubject: InsightsEngine.Theme?
    @State private var showDeleteAlert = false
    @State private var deleteFailureMessage: String?
    /// 单删 entry confirmation。从 swipeAction / contextMenu 触发,跟 HomeView 同 pattern。
    @State private var entryToDelete: DiaryEntry?

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
                            // 二级列表跟 HomeView 主时间线一致 — 左划删 / 长按弹菜单。
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    entryToDelete = entry
                                } label: {
                                    Label(NSLocalizedString("删除", comment: "Delete"), systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    entryToDelete = entry
                                } label: {
                                    Label(NSLocalizedString("删除", comment: "Delete"), systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .navigationDestination(for: DiaryEntry.self) { entry in
                        DiaryDetailView(entry: entry, startInEditMode: false)
                    }
                }
            }
            .lumoryReadableContent(maxWidth: LumoryAdaptivePresentation.listContentMaxWidth)
            .accessibilityIdentifier("themeFilteredEntriesContent")
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
            .task { await fetch() }
            .alert(
                NSLocalizedString("删除日记", comment: "Delete entry"),
                isPresented: Binding(
                    get: { entryToDelete != nil },
                    set: { if !$0 { entryToDelete = nil } }
                )
            ) {
                Button(NSLocalizedString("删除", comment: "Delete"), role: .destructive) {
                    if let entry = entryToDelete {
                        deleteEntry(entry)
                    }
                    entryToDelete = nil
                }
                Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {
                    entryToDelete = nil
                }
            } message: {
                Text(NSLocalizedString("此操作无法撤销。", comment: "Delete confirmation message"))
            }
            .lumoryAdaptiveModal(item: $mergeSubject) { subject in
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

    @MainActor
    /// 单条删除走五件套 orchestrator(跟 HomeView / DiaryDetailView 同 pattern)。失败 rollback +
    /// 显示 banner;成功后从本地 entries 列表移除避免动画抽搐。
    private func deleteEntry(_ entry: DiaryEntry) {
        let imageFileNames = entry.imageFileNameArray
        let audioFileName = entry.audioFileName

        viewContext.delete(entry)
        do {
            try viewContext.save()
            HapticManager.shared.impact(.medium)
            EntryWipeOrchestrator.performSingleDeleteCleanup()
            withAnimation { entries.removeAll { $0.objectID == entry.objectID } }
            onEntryDeleted?()
            // attachment 清理走 fire-and-forget(跟 Home/Detail 同 idiom)
            Task.detached(priority: .utility) {
                for fn in imageFileNames {
                    do { try DiaryEntry.deleteImageFromDocuments(fn) } catch { Log.error("[ThemeFiltered] image cleanup: \(error)", category: .ui) }
                }
                if let af = audioFileName, !af.isEmpty {
                    DiaryEntry.deleteAudioFromDocuments(af)
                }
            }
        } catch {
            viewContext.rollback()
            Log.error("[ThemeFilteredEntriesView] 删除日记失败: \(error)", category: .ui)
            deleteFailureMessage = (error as NSError).localizedDescription
        }
    }

    @MainActor
    private func fetch() async {
        let entryIds = theme.entryIds
        // 走 keywordHits idiom:bg fetch [NSManagedObjectID] → main `existingObject`。
        // theme.entryIds 可能 100+,主线程 `id IN %@` fetch 在 sheet 进入动画里会有感。
        let objectIDs: [NSManagedObjectID] = await PersistenceController.shared.container
            .performBackgroundTask { context in
                let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
                // UUID 不符合 CVarArg；需要桥接成 NSArray 让 Core Data 正确匹配每个 UUID。
                request.predicate = NSPredicate(format: "id IN %@", entryIds as NSArray)
                request.sortDescriptors = [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)]
                request.propertiesToFetch = ["id"]
                guard let rows = try? context.fetch(request) else { return [] }
                return rows.map { $0.objectID }
            }
        entries = objectIDs.compactMap { try? viewContext.existingObject(with: $0) as? DiaryEntry }
    }
}
