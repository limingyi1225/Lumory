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
    /// Button row tap 后塞这个,.navigationDestination(item:) 接住推到 DiaryDetailView。
    /// wave17 改 Button + item-driven destination 是为了去掉 NavigationLink 自带 chevron(用户反馈"杂乱")。
    @State private var selectedEntry: DiaryEntry?
    // entryToDelete 已移除 — 删除走 4 秒撤销 toast,直接调 deleteEntry,不再 stage。

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
                            Button {
                                HapticManager.shared.impact(.light)
                                selectedEntry = entry
                            } label: {
                                DiaryEntryRow(entry: entry)
                            }
                            .buttonStyle(PressableScaleButtonStyle())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            // 二级列表跟 HomeView 主时间线一致 — 左划删 / 长按弹菜单。
                            // P1-T8 完全对齐(添加 contextMenu 内 Edit 入口)需要独立 navigation
                            // destination,跨结构改动大,留 P3 epic。当前左划删除 + 长按删除已涵盖
                            // 90% 用户场景。
                            // 删除直接执行 — 4 秒撤销 toast 替代 confirmation alert。
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    deleteEntry(entry)
                                } label: {
                                    Label(NSLocalizedString("删除", comment: "Delete"), systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    deleteEntry(entry)
                                } label: {
                                    Label(NSLocalizedString("删除", comment: "Delete"), systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .navigationDestination(item: $selectedEntry) { entry in
                        let entryObjectID = entry.objectID
                        DiaryDetailView(
                            entry: entry,
                            startInEditMode: false,
                            onDeleted: {
                                withAnimation {
                                    entries.removeAll { $0.objectID == entryObjectID }
                                }
                                if selectedEntry?.objectID == entryObjectID {
                                    selectedEntry = nil
                                }
                                onEntryDeleted?()
                            }
                        )
                    }
                }
            }
            .lumoryReadableContent(maxWidth: LumoryAdaptivePresentation.listContentMaxWidth)
            // 此 sheet 嵌在 InsightsView sheet 之上(2 层深),root + parent 的 overlay 都被压住,
            // 删除 toast 必须在这层兜一份。
            .lumoryToastOverlay()
            .accessibilityIdentifier("themeFilteredEntriesContent")
            .navigationTitle(theme.name)
            .navigationBarTitleDisplayMode(.inline)
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
            // 删除 confirmation 已移除 — 4 秒撤销 toast 替代。entryToDelete state 也跟着废,
            // contextMenu / swipeActions 直接调 deleteEntry(entry)。
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
    /// 单条删除走 4 秒撤销窗口(跟 HomeView / DiaryDetailView 同 pattern)。
    /// 失败 rollback + 显示 banner;成功后从本地 entries 列表移除避免动画抽搐。
    /// **attachment 清理交给 EntryDeletionUndoService 4 秒后做**(撤销窗口内文件还在,可还原)。
    private func deleteEntry(_ entry: DiaryEntry) {
        // P1-Home-6 撤销 — 必须在 viewContext.delete 之前抓 snapshot。
        let snapshot = EntryDeletionSnapshot(entry: entry)
        let entryObjectID = entry.objectID

        viewContext.delete(entry)
        do {
            try viewContext.save()
            HapticManager.shared.impact(.medium)
            EntryWipeOrchestrator.performSingleDeleteCleanup()
            withAnimation { entries.removeAll { $0.objectID == entryObjectID } }
            // selectedEntry 可能指向被删 entry — DiaryDetailView 内部 swipe 删除完 pop 回来后
            // `.navigationDestination(item:)` 重 evaluate 引用 tombstoned MO 会 CoreData abort。
            // HomeView 1056 行同 pattern。
            if selectedEntry?.objectID == entryObjectID { selectedEntry = nil }
            onEntryDeleted?()

            // 注册到 undo service + 弹带"撤销"按钮 toast。撤销时把 entry 加回 entries 列表。
            let viewContextRef = viewContext
            let onEntryDeletedRef = onEntryDeleted
            EntryDeletionUndoService.shared.register(snapshot: snapshot)
            LumoryToastCenter.shared.show(
                NSLocalizedString("已删除", comment: "Toast after entry deletion"),
                severity: .success,
                duration: EntryDeletionUndoService.undoWindow,
                action: LumoryToastCenter.Action(
                    label: NSLocalizedString("撤销", comment: "Undo delete action")
                ) {
                    if let restoredEntry = EntryDeletionUndoService.shared.undo(into: viewContextRef) {
                        #if canImport(UIKit)
                        HapticManager.shared.notification(.success)
                        #endif
                        // 本 sheet 用 `@State [DiaryEntry]` 缓存,不会自动响应 CoreData;手工 splice
                        // 回去 — 不然撤销 toast 给了 success haptic 但用户在这页里看不到那条回来。
                        // 按 `entry.date` desc 排序对齐 fetch() 的 sortDescriptor。
                        withAnimation {
                            entries.append(restoredEntry)
                            entries.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
                        }
                        // 父级聚合刷新(InsightsView aggregate),保持 P0-2 的 4-callsite 一致性。
                        onEntryDeletedRef?()
                    }
                }
            )
        } catch {
            viewContext.rollback()
            Log.error("[ThemeFilteredEntriesView] 删除日记失败: \(error)", category: .ui)
            deleteFailureMessage = NSLocalizedString("删除失败,可能是磁盘空间不足或同步冲突。请稍后重试。", comment: "Generic delete failure fallback")
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
