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
    @State private var entryToDelete: DiaryEntry?
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
            .accessibilityIdentifier("pointDetailEntryList")
            .overlay {
                if entries.isEmpty {
                    Text(NSLocalizedString("该时段没有日记", comment: "No entries for bucket"))
                        .foregroundColor(.secondary)
                }
            }
            .lumoryReadableContent(maxWidth: LumoryAdaptivePresentation.listContentMaxWidth)
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

    /// 跟 ThemeFilteredEntriesView / HomeView 同 pattern。
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
            Task.detached(priority: .utility) {
                for fn in imageFileNames {
                    do { try DiaryEntry.deleteImageFromDocuments(fn) } catch { Log.error("[PointDetail] image cleanup: \(error)", category: .ui) }
                }
                if let af = audioFileName, !af.isEmpty {
                    DiaryEntry.deleteAudioFromDocuments(af)
                }
            }
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
