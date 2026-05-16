//
//  HomeView+Search.swift
//  Lumory
//
//  HomeView 的 inline search 入口 + 渲染。从主文件抽出来,主文件只保留 state 声明
//  (`searchQuery` / `searchResults` / `semanticAuxResults` 等)+ `.searchable` 挂钩,
//  本扩展承担 query 变化的双引擎(keyword / semantic)调度 + 结果 list 渲染。
//
//  wave14 "无感"融合:keyword 立刻出(180ms debounce)+ semantic 600ms 后后台补,
//  没有 SearchMode picker。embed 失败 silent(toast 一次性,不挡视野)。
//
//  保留在 HomeView 主文件:
//   - `@State` 声明(SwiftUI 限制 stored prop 必须在主 struct)
//   - `.searchable` modifier + `onChange(of: searchQuery)`(view tree 生命周期相关)
//

import SwiftUI
import CoreData

extension HomeView {
    /// wave14 — query 变化的统一入口。keyword 180ms debounce 立刻出;query 稳定 600ms 后
    /// 后台跑 semantic;短查询(< 2 字符)不触发 semantic 防止过宽 + 浪费 embed。
    /// embed 失败静默,UI 不显示 banner。
    func handleSearchQueryChange(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespaces)

        keywordSearchTask?.cancel()
        semanticSearchTask?.cancel()
        semanticAuxResults = []
        semanticSearchPending = false
        semanticSearchFailureNotifiedFor = nil
        keywordSearchSettled = false
        semanticSearchGen &+= 1
        let myGen = semanticSearchGen

        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }
        searchResults = []

        // keyword: 180ms debounce 立刻出。
        keywordSearchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            let hits = await keywordHits(for: trimmed)
            guard !Task.isCancelled else { return }
            self.searchResults = hits
            self.keywordSearchSettled = true
        }

        // semantic: 短查询不触发 — 1 字符的"快"对中文是无意义索引基准,会把
        // top-K 全占了。≥ 2 字符才进队。
        guard trimmed.count >= 2 else { return }
        semanticSearchPending = true
        semanticSearchTask = Task { @MainActor in
            // 600ms debounce 期间 semanticSearchPending 已 true → UI 显示"正在扩展搜索…"
            // 不会在空窗里先闪"没有匹配"。
            defer {
                if semanticSearchGen == myGen { semanticSearchPending = false }
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, semanticSearchGen == myGen else { return }
            let result = await InsightsEngine.shared.searchSemantic(query: trimmed, topK: 20)
            guard !Task.isCancelled, semanticSearchGen == myGen else { return }
            // queryEmbedded == false → embed 失败,result.ids 已 fallback 到时间倒序兜底,
            // 但那不是"语义补充"语义。静默丢弃,不污染 aux section。
            guard result.queryEmbedded else {
                semanticAuxResults = []
                if semanticSearchFailureNotifiedFor != trimmed {
                    semanticSearchFailureNotifiedFor = trimmed
                    LumoryToastCenter.shared.show(
                        NSLocalizedString("search.semanticUnavailable", comment: "Semantic search unavailable toast"),
                        severity: .info
                    )
                }
                return
            }
            semanticAuxResults = result.ids.compactMap {
                try? viewContext.existingObject(with: $0) as? DiaryEntry
            }
        }
    }

    /// 删除某条 entry 后,从两个 search 结果列表里同步清掉(防止用户在搜索结果里点开已删条目)。
    /// `internal` (默认) 让 `HomeView+Entry.swift` 的 `deleteEntry` 跨 extension 调到。
    func removeDeletedEntryFromSearchResults(_ objectID: NSManagedObjectID) {
        searchResults.removeAll { $0.objectID == objectID }
        semanticAuxResults.removeAll { $0.objectID == objectID }
    }

    @ViewBuilder
    var searchResultsList: some View {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespaces)
        searchResultsBody(trimmed: trimmed)
    }

    @ViewBuilder
    private func searchResultsBody(trimmed: String) -> some View {
        // wave14 — 渲染时实时 dedup:semantic aux 中已被 keyword 命中的去掉,避免两 section
        // 出现重复条目。即便 keyword 在 semantic 后到达,view 层 filter 也能正确响应。
        let keywordIds = Set(searchResults.map { $0.objectID })
        let displayedAux = semanticAuxResults.filter { !keywordIds.contains($0.objectID) }

        if trimmed.isEmpty {
            Spacer(minLength: 0)
            Text(NSLocalizedString("按标题、正文或主题匹配", comment: "Search hint"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Spacer(minLength: 0)
        } else if searchResults.isEmpty && displayedAux.isEmpty {
            if !keywordSearchSettled {
                // keyword 还在 180ms debounce 或 bg fetch — 静默空白,让用户感觉 keyword 立刻出。
                // 不在键入瞬间就闪 "正在扩展搜索…",那个 loading 是 keyword 真的为空时才有意义。
                Spacer(minLength: 0)
                Spacer(minLength: 0)
            } else if semanticSearchPending {
                // keyword 已 settle 但命中 0 + semantic 还在跑 → 显示"正在扩展搜索…"。
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text(NSLocalizedString("search.expanding", comment: "Semantic expanding"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        // **P2 fix (2026-05-13 superreview)**:硬编码 28 → 语义 `.title`(28pt)
                        // 走 Dynamic Type。
                        .font(.title.weight(.light))
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text(NSLocalizedString("没有匹配的日记", comment: "No results"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Spacer(minLength: 0)
            }
        } else {
            List {
                Section {
                    ForEach(searchResults, id: \.objectID) { entry in
                        searchResultRow(entry)
                    }
                }
                if !displayedAux.isEmpty {
                    Section {
                        ForEach(displayedAux, id: \.objectID) { entry in
                            searchResultRow(entry)
                        }
                    } header: {
                        Text(NSLocalizedString("search.relatedEntries.section", comment: "Related entries section"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .optimizedList()
            .scrollDismissesKeyboard(.interactively)
        }
    }

    @ViewBuilder
    private func searchResultRow(_ entry: DiaryEntry) -> some View {
        Button {
            shouldStartEditing = false
            selectedEntry = entry
        } label: {
            HomeTimelineCard(entry: entry, appLanguage: appLanguage)
                .padding(.bottom, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }

    @MainActor
    func keywordHits(for text: String) async -> [DiaryEntry] {
        // 函数整体 @MainActor：跨 await 返回 [DiaryEntry] (NSManagedObject) 在 Swift 6
        // 严格并发下不 Sendable，把 receiver 锁定到 main 上避免跨 actor。
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
        // 用 existingObject 而不是 object(with:)：后者返回未验证 fault，
        // 若该条目在 fetch→access 之间被 CloudKit tombstone / 用户侧滑删除，
        // 属性首访会抛 NSObjectInaccessibleException（Obj-C 异常，Swift try/catch 接不住）。
        // existingObject 抛 Swift-catchable 错误，try? 安静降级即可。
        return objectIDs.compactMap { try? viewContext.existingObject(with: $0) as? DiaryEntry }
    }
}
