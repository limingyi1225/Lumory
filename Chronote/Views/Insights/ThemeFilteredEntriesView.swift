import SwiftUI
import CoreData

// MARK: - Theme filtered entries sheet
//
// 点击 ThemeCard 后弹出：筛选出该主题的所有日记条目，视觉贴近 Home timeline。

struct ThemeFilteredEntriesView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @AppStorage("appLanguage", store: AppGroup.userDefaults) private var appLanguage: String = {
        Locale.current.identifier.hasPrefix("zh") ? "zh-Hans" : "en"
    }()
    let theme: InsightsEngine.Theme
    /// 父视图传入的全部 themes(用来给 merge sheet 列候选,排除自己)
    let allThemes: [InsightsEngine.Theme]
    /// 父视图回调,处理合并成功后的 toast / reload。
    let onMerged: ((_ message: String) -> Void)?
    /// 父视图回调,处理删除主题后的 toast / 关 sheet。
    let onDeleted: ((_ name: String, _ undoPayload: ThemeManagementService.ThemeDeletionUndoPayload?) -> Void)?
    /// 父视图回调,处理 sheet 内单删 entry 后的聚合刷新。
    let onEntryDeleted: (() -> Void)?

    @State private var entries: [DiaryEntry] = []
    /// merge sheet 的 trigger。`.sheet(item:)` 比 `.sheet(isPresented:)` 抗父级 reload —
    /// alias map 变更通知能让父级 InsightsView 重 evaluate `themeFilter`,sheet item identity
    /// 驱动比 Bool 稳。CLAUDE.md `.sheet` 反复踩坑章节。
    @State private var mergeSubject: InsightsEngine.Theme?
    @State private var showDeleteAlert = false
    @State private var deleteFailureMessage: String?
    @State private var fetchGen: Int = 0
    /// Button row tap 后塞这个,.navigationDestination(item:) 接住推到 DiaryDetailView。
    /// wave17 改 Button + item-driven destination 是为了去掉 NavigationLink 自带 chevron(用户反馈"杂乱")。
    @State private var selectedEntry: DiaryEntry?
    // entryToDelete 已移除 — 删除走 4 秒撤销 toast,直接调 deleteEntry,不再 stage。

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    EmptyStateView(
                        systemImage: "tag",
                        title: NSLocalizedString("没有匹配的日记", comment: "No matched entries"),
                        message: NSLocalizedString("这个主题暂时没有可显示的日记。", comment: "No matched entries detail"),
                        size: .compact
                    )
                } else {
                    // .plain + 透明 row + 清空 List 背景 → HomeTimelineCard 的 accent-card
                    // 才能干净地浮在系统的玻璃 sheet 背景上,不被 insetGrouped 的灰底压住。
                    List {
                        themePulseHeader
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 10, trailing: 16))

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
                // iPad / regular size class 走 fullScreenCover 没下拉手势,留小关闭按钮兜底。
                // 跟 AskPastView / PointDetailSheet 同 pattern,只在 regular 显;iPhone (compact) 靠下拉关闭。
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
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        #if canImport(UIKit)
                        HapticManager.shared.impact(.light)
                        #endif
                        mergeSubject = theme
                    } label: {
                        Image(systemName: "arrow.triangle.merge")
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(NSLocalizedString("合并到其他主题…", comment: "Merge into another theme"))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        #if canImport(UIKit)
                        HapticManager.shared.impact(.light)
                        #endif
                        showDeleteAlert = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(NSLocalizedString("删除主题", comment: "Delete theme"))
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
                Text(NSLocalizedString("将从所有日记里抹掉这个主题(包括它的所有别名)。原日记内容不变。删除后可短暂撤销。", comment: "Delete theme message"))
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
                onDeleted?(theme.name, outcome.undoPayload)
            }
        } else {
            deleteFailureMessage = String(
                format: NSLocalizedString("删除「%@」失败,可能是磁盘空间不足或同步冲突。请稍后重试。", comment: "Delete theme failed"),
                theme.name
            )
        }
    }

    @ViewBuilder
    private var themePulseHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle()
                    .fill(Color.moodSpectrum(value: theme.avgMood))
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(NSLocalizedString("Theme Pulse", comment: "Theme pulse header"))
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                    Text(theme.name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                pulseMetric(
                    value: String(format: NSLocalizedString("%d 次", comment: "Theme count"), theme.count),
                    label: NSLocalizedString("出现", comment: "Theme pulse count label")
                )
                pulseMetric(
                    value: String(format: NSLocalizedString("%d 天", comment: "Theme unique days"), theme.uniqueDays),
                    label: NSLocalizedString("分布", comment: "Theme pulse days label")
                )
                pulseMetric(
                    value: "\(Int(theme.avgMood * 100))",
                    label: NSLocalizedString("平均心情", comment: "Theme pulse mood label")
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                moodRangeBar
                Text(recentPulseSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !relatedThemeNames.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(NSLocalizedString("常一起出现", comment: "Related themes label"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 8) {
                        ForEach(relatedThemeNames, id: \.self) { name in
                            Text(name)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .liquidGlassCapsule(tint: Color.moodSpectrum(value: theme.avgMood))
                        }
                    }
                }
            }
        }
        .padding(16)
        .liquidGlassCard(
            cornerRadius: LumoryCornerRadius.card,
            tint: Color.moodSpectrum(value: theme.avgMood),
            tintStrength: 0.10,
            interactive: false
        )
    }

    private func pulseMetric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .liquidGlassCard(cornerRadius: LumoryCornerRadius.nestedRow, interactive: false)
    }

    private var moodRangeBar: some View {
        GeometryReader { geo in
            let widthFraction = min(1, max(0.08, theme.moodHigh - theme.moodLow))
            let offsetFraction = min(max(0, theme.moodLow), max(0, 1 - widthFraction))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.14))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.moodSpectrum(value: theme.moodLow),
                                Color.moodSpectrum(value: theme.avgMood),
                                Color.moodSpectrum(value: theme.moodHigh)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(12, geo.size.width * CGFloat(widthFraction)))
                    .offset(x: geo.size.width * CGFloat(offsetFraction))
            }
        }
        .frame(height: 8)
    }

    private var recentPulseSummary: String {
        let calendar = Calendar.current
        let now = Date()
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        let recentCount = entries.filter { ($0.date ?? .distantPast) >= thirtyDaysAgo }.count
        if recentCount > 0 {
            return String(format: NSLocalizedString("最近 30 天出现 %d 次", comment: "Theme recent pulse summary"), recentCount)
        }
        guard let latest = entries.compactMap(\.date).max() else {
            return NSLocalizedString("还没有足够的时间线数据", comment: "Theme no timeline summary")
        }
        return String(
            format: NSLocalizedString("最近一次出现在 %@", comment: "Theme latest occurrence summary"),
            LumoryDateFormatters.mediumDate.string(from: latest)
        )
    }

    private var relatedThemeNames: [String] {
        var counts: [String: Int] = [:]
        let current = ThemeAliasResolver.shared.canonicalize(theme.name).lowercased()
        for entry in entries {
            var seenInEntry = Set<String>()
            for raw in entry.themeArray {
                let canonical = ThemeAliasResolver.shared.canonicalize(raw)
                let key = canonical.lowercased()
                guard key != current,
                      !InsightsEngine.isBannedTheme(canonical),
                      seenInEntry.insert(key).inserted else { continue }
                counts[canonical, default: 0] += 1
            }
        }
        return counts
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }
            .prefix(3)
            .map(\.key)
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
            HapticManager.shared.destructive()
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
        fetchGen &+= 1
        let myGen = fetchGen
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
        guard myGen == fetchGen else { return }
        entries = objectIDs.compactMap { try? viewContext.existingObject(with: $0) as? DiaryEntry }
    }
}
