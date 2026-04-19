import SwiftUI
import CoreData

// MARK: - SearchView
//
// 极简关键词搜索：单一输入框，200ms 防抖，后台线程 fetch，上限 50 条。
// 不暴露搜索模式选择；语义搜索留给 AskPastView。

struct SearchView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var results: [DiaryEntry] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(NSLocalizedString("搜索", comment: "Search"))
                #if canImport(UIKit)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .searchable(
                    text: $query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: NSLocalizedString("搜索日记", comment: "Search field prompt")
                )
                .onChange(of: query) { _, newValue in
                    scheduleSearch(for: newValue)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(NSLocalizedString("关闭", comment: "Close")) { dismiss() }
                    }
                }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            EmptyStateView(
                systemImage: "magnifyingglass",
                title: NSLocalizedString("搜索你的日记", comment: "Search prompt title"),
                message: NSLocalizedString("按标题、正文或主题匹配", comment: "Search hint")
            )
        } else if results.isEmpty && !isSearching {
            EmptyStateView(
                systemImage: "doc.text.magnifyingglass",
                title: NSLocalizedString("没有匹配的日记", comment: "No results title"),
                message: NSLocalizedString("换一个关键词试试", comment: "No results hint")
            )
        } else {
            resultsList
        }
    }

    private var resultsList: some View {
        List(results, id: \.objectID) { entry in
            NavigationLink(value: entry) {
                DiaryEntryRow(entry: entry)
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .navigationDestination(for: DiaryEntry.self) { entry in
            DiaryDetailView(entry: entry, startInEditMode: false)
        }
    }

    // MARK: Search pipeline

    /// 180ms 防抖，单管道关键词 fetch，结果全程不阻塞主线程。
    private func scheduleSearch(for text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            let hits = await keywordHits(for: trimmed)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.results = hits
                self.isSearching = false
            }
        }
    }

    private func keywordHits(for text: String) async -> [DiaryEntry] {
        let objectIDs: [NSManagedObjectID] = await PersistenceController.shared.container
            .performBackgroundTask { context in
                let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
                request.predicate = NSPredicate(
                    format: "text CONTAINS[cd] %@ OR summary CONTAINS[cd] %@ OR themes CONTAINS[cd] %@",
                    text, text, text
                )
                request.sortDescriptors = [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)]
                request.fetchLimit = 50
                request.propertiesToFetch = ["id"]
                guard let entries = try? context.fetch(request) else { return [] }
                return entries.map { $0.objectID }
            }
        return await MainActor.run {
            // existingObject：CloudKit 同步删除或用户侧滑删除后首访不会抛 Obj-C 异常。
            objectIDs.compactMap { try? viewContext.existingObject(with: $0) as? DiaryEntry }
        }
    }
}
