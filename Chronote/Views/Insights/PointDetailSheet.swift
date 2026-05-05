import SwiftUI
import CoreData

// MARK: - Point detail sheet (点击图表点时弹出)

struct PointDetailSheet: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    let point: InsightsEngine.MoodPoint
    let bucket: InsightsEngine.Bucket
    let onEntryDeleted: (() -> Void)?

    @State private var entries: [DiaryEntry] = []
    // entryToDelete 已移除 — 删除走 4 秒撤销 toast。
    @State private var deleteFailureMessage: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(entries, id: \.objectID) { entry in
                    NavigationLink(value: entry) {
                        DiaryEntryRow(entry: entry)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
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
            .accessibilityIdentifier("pointDetailEntryList")
            .overlay {
                if entries.isEmpty {
                    Text(NSLocalizedString("该时段没有日记", comment: "No entries for bucket"))
                        .foregroundColor(.secondary)
                }
            }
            .lumoryReadableContent(maxWidth: LumoryAdaptivePresentation.listContentMaxWidth)
            // 嵌套 sheet,root / parent overlay 看不见,在这层兜一份给删除 toast。
            .lumoryToastOverlay()
            .navigationTitle(dateLabel)
            .navigationDestination(for: DiaryEntry.self) { entry in
                DiaryDetailView(entry: entry, startInEditMode: false)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("关闭", comment: "Close")) { dismiss() }
                }
            }
            .task { await fetch() }
            // 删除 confirmation 已移除 — 4 秒撤销 toast 替代。
            .alert(
                NSLocalizedString("删除失败", comment: "Delete failed alert title"),
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

    /// 跟 HomeView / DiaryDetailView / ThemeFilteredEntriesView 同 pattern — 4 秒撤销窗口。
    /// attachment 文件清理由 EntryDeletionUndoService 在窗口结束时跑,撤销期内还在原位。
    private func deleteEntry(_ entry: DiaryEntry) {
        let snapshot = EntryDeletionSnapshot(entry: entry)
        let entryObjectID = entry.objectID

        viewContext.delete(entry)
        do {
            try viewContext.save()
            HapticManager.shared.impact(.medium)
            EntryWipeOrchestrator.performSingleDeleteCleanup()
            withAnimation { entries.removeAll { $0.objectID == entryObjectID } }
            onEntryDeleted?()

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
                        onEntryDeletedRef?()
                    }
                }
            )
        } catch {
            viewContext.rollback()
            Log.error("[PointDetailSheet] 删除日记失败: \(error)", category: .ui)
            deleteFailureMessage = (error as NSError).localizedDescription
        }
    }

    private var dateLabel: String {
        point.date.formatted(date: .abbreviated, time: .omitted)
    }

    @MainActor
    private func fetch() async {
        let calendar = Calendar.current
        let bucketStart = InsightsEngine.startOfBucket(point.date, bucket: bucket, calendar: calendar)
        let component: Calendar.Component = {
            switch bucket {
            case .day: return .day
            case .week: return .weekOfYear
            case .month: return .month
            }
        }()
        guard let bucketEnd = calendar.date(byAdding: component, value: 1, to: bucketStart) else { return }
        // 走 SearchView/HomeView.keywordHits 同 idiom:bg fetch [NSManagedObjectID] → main `existingObject`。
        // 主线程 `viewContext.fetch` 在 sheet 出场动画里会卡几十 ms,~200 entries × CK pull 中时尤其。
        let objectIDs: [NSManagedObjectID] = await PersistenceController.shared.container
            .performBackgroundTask { context in
                let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
                request.predicate = NSPredicate(
                    format: "date >= %@ AND date < %@",
                    bucketStart as NSDate,
                    bucketEnd as NSDate
                )
                request.sortDescriptors = [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)]
                request.propertiesToFetch = ["id"]
                guard let rows = try? context.fetch(request) else { return [] }
                return rows.map { $0.objectID }
            }
        entries = objectIDs.compactMap { try? viewContext.existingObject(with: $0) as? DiaryEntry }
    }
}
