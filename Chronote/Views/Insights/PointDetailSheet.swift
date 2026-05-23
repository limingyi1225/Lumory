import SwiftUI
import CoreData

// MARK: - Point detail sheet (点击图表点时弹出)
//
// wave17 (2026-05-13) 改造:
// 1. 删 "关闭" toolbar — 用户从 sheet 边缘下拉关。iPad regular size class 走 fullScreenCover
//    无下拉手势,toolbar 里给一个 hSizeClass == .regular 才显的 close button 兜底。
// 2. 加左右切换"有日记的天" — 顶部 toolbar chevron + 横向 swipe gesture。用户决定:
//    "热力图点日记本来就不精准,所以应该需要有这个功能"。currentDate 跟 toolbar /
//    swipe 走;availableDays 一次性 fetch 完整日子列表(startOfDay 去重 sorted asc)。
// 3. row 去 NavigationLink → Button + .navigationDestination(item:),把 SwiftUI 自带
//    chevron 拿掉(用户反馈"杂乱")。
// 4. (superreview 2026-05-13 P1-7/P1-8)删 `bucket` + `point` 参数 — 历史上 bucket 可
//    `.day/.week/.month`,wave14 之后 caller 只塞 `.day`,导致 switch bucket 三档里两档
//    死代码;`point` 除 `.date` 也只剩 init 一次取值,`mood/entryCount` 0 引用。API 收成
//    `(date: Date, onEntryDeleted:)`,InsightsView 用 PointDetailSubject 包装 Date 作 item id。

/// `.lumoryAdaptiveModal(item:)` 需要 Identifiable;Date 本身不是 Identifiable,用这个
/// 1-field 包装作 item id 同时透传给 PointDetailSheet 的 init。
struct PointDetailSubject: Identifiable {
    let id: Date
    var date: Date { id }
}

struct PointDetailSheet: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @AppStorage("appLanguage", store: AppGroup.userDefaults) private var appLanguage: String = {
        Locale.current.identifier.hasPrefix("zh") ? "zh-Hans" : "en"
    }()
    let onEntryDeleted: (() -> Void)?

    @State private var entries: [DiaryEntry] = []
    @State private var deleteFailureMessage: String?
    /// 当前显示的天(初始 = init date 的 startOfDay)。toolbar / swipe 切换时改它,
    /// .onChange 触发 fetch 重新加载。
    @State private var currentDate: Date
    /// 所有"有日记的天"(startOfDay 去重 sorted asc)。一次性 fetch,用于前后导航边界判定。
    @State private var availableDays: [Date] = []
    /// Button row tap 后塞这个,.navigationDestination(item:) 接住推到 DiaryDetailView。
    /// 用 item: 而非 for: 是为了避免 NavigationLink 自带的 trailing chevron。
    @State private var selectedEntry: DiaryEntry?
    /// fetch() 世代号 — 快速点 chevron 时,老 fetch 完成后不能盖新 fetch 的 entries。
    /// 同 idiom:`ReminderService.currentRescheduleGen` / `ThemeAliasJudgeService.scanGen`。
    @State private var fetchGen: Int = 0
    /// availableDays 也可能被 delete / undo 路径并发刷新,同样需要 stale-write guard。
    @State private var availableDaysGen: Int = 0

    init(date: Date, onEntryDeleted: (() -> Void)?) {
        self.onEntryDeleted = onEntryDeleted
        _currentDate = State(initialValue: Calendar.current.startOfDay(for: date))
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(entries, id: \.objectID) { entry in
                    Button {
                        HapticManager.shared.impact(.light)
                        selectedEntry = entry
                    } label: {
                        HomeTimelineCard(entry: entry, appLanguage: appLanguage)
                            .contentShape(
                                .contextMenuPreview,
                                RoundedRectangle(cornerRadius: LumoryCornerRadius.card, style: .continuous)
                            )
                            .padding(.bottom, 10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableScaleButtonStyle())
                    .lumoryGlassListRow(top: 6)
                    // 删除直接执行 — 4 秒撤销 toast 替代 confirmation alert。
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
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
                    EmptyStateView(
                        systemImage: "calendar",
                        title: NSLocalizedString("该时段没有日记", comment: "No entries for bucket"),
                        size: .compact
                    )
                }
            }
            .lumoryReadableContent(maxWidth: LumoryAdaptivePresentation.listContentMaxWidth)
            // 嵌套 sheet,root / parent overlay 看不见,在这层兜一份给删除 toast。
            .lumoryToastOverlay()
            .navigationTitle(dateLabel)
            .navigationBarTitleDisplayMode(.inline)
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
                        Task { await loadAvailableDays() }
                    }
                )
            }
            .toolbar {
                // 左右切换"有日记的天" — availableDays > 1 才显;到边界时 disabled,SwiftUI 自带灰显。
                // 1 天时两个 chevron 都 disabled 但仍 visible 看起来像坏了 → 隐藏。
                // 系统通过 chevron.left/right 已经传达"切换前后",accessibilityLabel 给 VO 朗读。
                if availableDays.count > 1 {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            stepDay(by: -1)
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(!canStepBack)
                        .accessibilityLabel(NSLocalizedString("上一天", comment: "Previous day with entries"))
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            stepDay(by: 1)
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(!canStepForward)
                        .accessibilityLabel(NSLocalizedString("下一天", comment: "Next day with entries"))
                    }
                }
                // iPad / regular size class 走 fullScreenCover 没下拉手势,留小关闭按钮兜底。
                // 跟 NarrativeDetailSheet 同 pattern,只在 regular 显;iPhone (compact) 仍靠下拉关闭。
                if hSizeClass == .regular {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel(NSLocalizedString("关闭", comment: "Close"))
                    }
                }
            }
            .task {
                await loadAvailableDays()
                await fetch()
            }
            .onChange(of: currentDate) { _, _ in
                Task { await fetch() }
            }
            // 横向 swipe 切换天:左划 → 后一天,右划 → 前一天(跟 iOS 标准时间线一致)。
            // **阈值 140pt**(原 60pt)— trailing swipe-to-delete reveal 大约 80pt,List
            // swipeActions 不允许 full swipe 删除,避免"删一条 + 切一天"双触发。
            // 横向距离仍需大于纵向 1.5 倍,避免抢 List 的纵向滚动手势。
            // .simultaneousGesture 而非 .gesture 让 List scroll 仍可工作;DragGesture 自身
            // 只在 onEnded 时判断,不影响 hit testing。
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        let h = value.translation.width
                        let v = value.translation.height
                        guard abs(h) > 140, abs(h) > abs(v) * 1.5 else { return }
                        if h < 0 {
                            stepDay(by: 1)
                        } else {
                            stepDay(by: -1)
                        }
                    }
            )
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

    // MARK: - Day navigation

    private var canStepBack: Bool {
        guard let idx = availableDays.firstIndex(of: currentDate) else { return false }
        return idx > 0
    }

    private var canStepForward: Bool {
        guard let idx = availableDays.firstIndex(of: currentDate) else { return false }
        return idx < availableDays.count - 1
    }

    private func stepDay(by delta: Int) {
        guard let idx = availableDays.firstIndex(of: currentDate) else { return }
        let target = idx + delta
        guard target >= 0, target < availableDays.count else { return }
        HapticManager.shared.impact(.light)
        currentDate = availableDays[target]
    }

    /// 跟 HomeView / DiaryDetailView / ThemeFilteredEntriesView 同 pattern — 4 秒撤销窗口。
    /// attachment 文件清理由 EntryDeletionUndoService 在窗口结束时跑,撤销期内还在原位。
    private func deleteEntry(_ entry: DiaryEntry) {
        let snapshot = EntryDeletionSnapshot(entry: entry)
        let entryObjectID = entry.objectID

        viewContext.delete(entry)
        do {
            try viewContext.save()
            HapticManager.shared.destructive()
            EntryWipeOrchestrator.performSingleDeleteCleanup()
            withAnimation { entries.removeAll { $0.objectID == entryObjectID } }
            // selectedEntry 可能指向被删 entry — DiaryDetailView 内部 swipe 删除完 pop 回来后
            // `.navigationDestination(item:)` 重 evaluate,引用 tombstoned MO 会 CoreData abort。
            // HomeView 1056 行有同 pattern。
            if selectedEntry?.objectID == entryObjectID { selectedEntry = nil }
            onEntryDeleted?()
            // sheet 内删完最后一条 → availableDays 仍含该日 → step 回去看到"该时段没有日记" stale。
            // 异步重新拉一次最新 day 列表。撤销 path 也跟着重 load(可能那天又有 entry 了)。
            Task { await loadAvailableDays() }

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
                        //
                        // **P2 fix (2026-05-14 superreview round 3)**:删某天唯一 entry 后
                        // `loadAvailableDays()` 会把 `currentDate` 跳到最近仍有日记的一天。撤销时
                        // 若 restoredEntry 不属于当前显示那天,无条件 append 会让标题是 B 日、列表
                        // 混入 A 日的 entry。同天才 splice;跨天则把 currentDate 切回 restoredEntry
                        // 那天重新 fetch()。
                        if Calendar.current.isDate(
                            restoredEntry.date ?? .distantPast,
                            inSameDayAs: currentDate
                        ) {
                            withAnimation {
                                entries.append(restoredEntry)
                                entries.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
                            }
                        } else if let restoredDate = restoredEntry.date {
                            currentDate = Calendar.current.startOfDay(for: restoredDate)
                            Task { await fetch() }
                        }
                        onEntryDeletedRef?()
                        Task { await loadAvailableDays() }
                    }
                }
            )
        } catch {
            viewContext.rollback()
            Log.error("[PointDetailSheet] 删除日记失败: \(error)", category: .ui)
            deleteFailureMessage = NSLocalizedString("删除失败,可能是磁盘空间不足或同步冲突。请稍后重试。", comment: "Generic delete failure fallback")
        }
    }

    private var dateLabel: String {
        currentDate.formatted(date: .abbreviated, time: .omitted)
    }

    /// 一次性 fetch 所有 entry 的 date,startOfDay 去重 + sorted asc。给前后导航边界判定用。
    /// 用 NSDictionaryResultType 只拉 date 列,~数百条主线程也快。
    /// **过滤 date <= now** — 防 CK 同步进来的未来 entry / 设备时钟漂移让 step 越过今天。
    /// 跟 `WidgetSnapshotService` 的 future-entry guard 同 idiom。
    @MainActor
    private func loadAvailableDays() async {
        availableDaysGen &+= 1
        let myGen = availableDaysGen
        let days: [Date] = await PersistenceController.shared.container
            .performBackgroundTask { context in
                let request = NSFetchRequest<NSDictionary>(entityName: "DiaryEntry")
                request.resultType = .dictionaryResultType
                request.propertiesToFetch = ["date"]
                request.returnsDistinctResults = true
                request.predicate = NSPredicate(format: "date <= %@", Date() as NSDate)
                do {
                    let rows = try context.fetch(request)
                    let calendar = Calendar.current
                    var set: Set<Date> = []
                    for dict in rows {
                        if let date = dict["date"] as? Date {
                            set.insert(calendar.startOfDay(for: date))
                        }
                    }
                    return set.sorted()
                } catch {
                    // 静默吞会让两个 chevron 永久 disabled,用户看不到任何线索。
                    Log.error("[PointDetailSheet] loadAvailableDays fetch 失败: \(error)", category: .persistence)
                    return []
                }
        }
        guard myGen == availableDaysGen else { return }
        availableDays = days
        let calendar = Calendar.current
        if !days.isEmpty, !days.contains(where: { calendar.isDate($0, inSameDayAs: currentDate) }) {
            let previousDate = currentDate
            currentDate = days.min {
                abs($0.timeIntervalSince(previousDate)) < abs($1.timeIntervalSince(previousDate))
            } ?? days[days.count - 1]
        }
    }

    @MainActor
    private func fetch() async {
        // 世代号防 stale-write — 50ms 内连点 chevron 两次,fetch-A(D1)和 fetch-B(D2)同时
        // in-flight,bg fetch 完成顺序不确定。老 fetch 后返就会把"D1 内容"塞进现在显示 D2 的标题下。
        fetchGen &+= 1
        let myGen = fetchGen
        let calendar = Calendar.current
        let bucketStart = calendar.startOfDay(for: currentDate)
        guard let bucketEnd = calendar.date(byAdding: .day, value: 1, to: bucketStart) else { return }
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
        guard myGen == fetchGen else { return }
        entries = objectIDs.compactMap { try? viewContext.existingObject(with: $0) as? DiaryEntry }
    }
}
