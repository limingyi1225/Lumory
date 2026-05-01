import SwiftUI
import CoreData

// MARK: - ThemeAliasManagementView
//
// Settings → 主题别名 的承载页。三个区:
//   1) 顶部:扫描已有主题(一次性 LLM scan,把潜在 alias 加入 pending 队列)
//   2) 待审 (pending):每条建议一张玻璃卡 + 合并/不合并/自定义
//   3) 已合并 (groups):列出现有 canonical → aliases,可以 swipe 删除整组 / 长按拆某个 alias

struct ThemeAliasManagementView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @ObservedObject private var resolver = ThemeAliasResolver.shared
    @ObservedObject private var judgeService = ThemeAliasJudgeService.shared

    @State private var customEditorTarget: PendingSuggestion?
    /// 弹"是否真的从所有日记删除这个主题"alert 的目标。
    @State private var groupPendingDeletion: String?
    @State private var showResetNegativeAlert = false
    @State private var deleteFailureMessage: String?

    /// 引文 entry 的预取缓存。@State 在 view-local 生命周期内保留,避开了
    /// "每次 render 都同步 fetchSamples → 主线程 jank"(codex P2 fix)。
    /// 用 lightweight DTO 而非 NSManagedObject(后者非 Sendable + 跨 task boundary 风险)。
    @State private var citationCache: [UUID: CitationSnapshot] = [:]

    struct CitationSnapshot: Equatable {
        let id: UUID
        let date: Date
        let snippet: String
    }

    var body: some View {
        Form {
            scanSection
            emptyStateSection
            pendingSection
            groupsSection
            negativeResetSection
        }
        #if os(macOS)
        .listStyle(.plain)
        #else
        .listStyle(.insetGrouped)
        #endif
        .scrollContentBackground(.hidden)
        .background(backgroundGradient.ignoresSafeArea())
        .navigationTitle(NSLocalizedString("合并主题", comment: "Merge themes title"))
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(item: $customEditorTarget) { suggestion in
            SuggestionTargetPickerSheet(suggestion: suggestion) { chosen in
                confirm(suggestion, canonical: chosen)
            }
        }
        .alert(
            groupPendingDeletion.map {
                String(format: NSLocalizedString("删除主题「%@」?", comment: "Delete group alert title"), $0)
            } ?? "",
            isPresented: Binding(
                get: { groupPendingDeletion != nil },
                set: { if !$0 { groupPendingDeletion = nil } }
            )
        ) {
            Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {
                groupPendingDeletion = nil
            }
            Button(NSLocalizedString("删除", comment: "Delete"), role: .destructive) {
                guard let canonical = groupPendingDeletion else { return }
                groupPendingDeletion = nil
                Task {
                    let outcome = await ThemeManagementService.shared.deleteTheme(canonical: canonical)
                    if !outcome.succeeded {
                        deleteFailureMessage = String(
                            format: NSLocalizedString("删除「%@」失败,可能是磁盘空间不足或同步冲突。请稍后重试。", comment: "Delete theme failed"),
                            canonical
                        )
                    }
                }
            }
        } message: {
            Text(NSLocalizedString("将从所有日记里抹掉这个主题(包括它的所有别名)。原日记内容不变。此操作不可撤销。", comment: "Delete theme message"))
        }
        .alert(
            NSLocalizedString("删除失败", comment: "Delete failed alert"),
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
        .alert(
            NSLocalizedString("清空所有否决记录?", comment: "Reset rejections alert"),
            isPresented: $showResetNegativeAlert
        ) {
            Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) { }
            Button(NSLocalizedString("清空", comment: "Reset"), role: .destructive) {
                resolver.resetNegativePairs()
            }
        } message: {
            Text(NSLocalizedString("下次扫描时,之前点过『不是』的对子会重新被 AI 考虑。", comment: "Reset rejections message"))
        }
        .task {
            // 首次进入此页:如果 alias map 还是空 + pending 也空 + judge 不在跑,
            // 自动后台扫一次。**持久化标记在 resolver.didAutoScanOnce**(codex P2 fix),
            // view 重建后不会重复触发。
            await maybeAutoScan()
        }
        .task(id: citationCacheKey) {
            // 预取所有 pending 引文 entry,缓存到 @State —— 之前 citationsView body 里同步 fetch,
            // 多 pending 时主线程 jank(codex P2 fix)。task(id:) 在 pending 发生增删时重跑。
            await prefetchCitations()
        }
    }

    @ViewBuilder
    private var emptyStateSection: some View {
        if resolver.groups.isEmpty,
           resolver.pending.isEmpty,
           !judgeService.scanProgress.isRunning {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(NSLocalizedString("还没有合并过的主题", comment: "Theme alias empty title"))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Color.primary)
                        Text(NSLocalizedString("AI 扫描会找出意思相近的主题,比如昵称、同义词或中英文写法。确认后,洞察和回顾会把它们当作同一个主题。", comment: "Theme alias empty body"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    /// task(id:) 的 fingerprint —— pending 增删 / 切到不同条目都触发 prefetch。
    private var citationCacheKey: String {
        resolver.pending.map { $0.id.uuidString }.sorted().joined()
    }

    // MARK: - Scan section

    @ViewBuilder
    private var scanSection: some View {
        Section(
            header: header(NSLocalizedString("AI 扫描", comment: "Scan section header"))
        ) {
            Button {
                #if canImport(UIKit)
                HapticManager.shared.click()
                #endif
                judgeService.scanAllHistory()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: scanIconName)
                        .foregroundStyle(Color.accentColor)
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(scanButtonTitle)
                            .foregroundStyle(Color.primary)
                        if let phaseText = scanPhaseText {
                            Text(phaseText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if judgeService.scanProgress.isRunning {
                        ProgressView()
                    }
                }
            }
            .disabled(judgeService.scanProgress.isRunning)
        }
    }

    /// 按钮文案随状态切换 —— 没扫过就"扫描",扫过一次后改成"重新扫描"让用户明白可重复触发。
    private var scanButtonTitle: String {
        let hasState = !resolver.groups.isEmpty || !resolver.pending.isEmpty
            || judgeService.scanProgress.phase == .done
        if judgeService.scanProgress.isRunning {
            return NSLocalizedString("扫描中…", comment: "Scanning")
        }
        return hasState
            ? NSLocalizedString("重新扫描", comment: "Re-scan themes")
            : NSLocalizedString("扫描已有主题", comment: "Scan existing themes")
    }

    private var scanIconName: String {
        if judgeService.scanProgress.isRunning { return "sparkles" }
        let hasState = !resolver.groups.isEmpty || !resolver.pending.isEmpty
            || judgeService.scanProgress.phase == .done
        return hasState ? "arrow.clockwise.circle" : "wand.and.stars"
    }

    private var scanPhaseText: String? {
        switch judgeService.scanProgress.phase {
        case .idle:
            return nil
        case .fetchingInventory:
            return NSLocalizedString("正在统计标签…", comment: "Scan phase fetch")
        case .judging:
            return NSLocalizedString("AI 正在分析…", comment: "Scan phase judge")
        case .applying:
            return NSLocalizedString("正在整理建议…", comment: "Scan phase apply")
        case .done:
            let n = judgeService.scanProgress.suggestionsAdded
            return n == 0
                ? NSLocalizedString("没有找到可能合并的主题。", comment: "Scan empty")
                : String(format: NSLocalizedString("扫到 %d 条建议", comment: "Scan added"), n)
        case .failed(let reason):
            return reason
        }
    }

    // MARK: - Pending section

    @ViewBuilder
    private var pendingSection: some View {
        if !resolver.pending.isEmpty {
            Section {
                ForEach(resolver.pending) { suggestion in
                    pendingCard(for: suggestion)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
            } header: {
                HStack {
                    Text(String(format: NSLocalizedString("待审 (%d)", comment: "Pending header"), resolver.pending.count))
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if resolver.pending.count >= 3 {
                        // 待审超 3 条时给一个"全部清空"按钮 —— 不写 negativePairs,
                        // 用户下次 scan 还能重新看到。Menu 风格让它不那么显眼。
                        Menu {
                            Button(role: .destructive) {
                                resolver.clearAllPending()
                            } label: {
                                Label(
                                    NSLocalizedString("全部清空", comment: "Clear all pending"),
                                    systemImage: "trash.slash"
                                )
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel(NSLocalizedString("更多操作", comment: "More actions"))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func pendingCard(for suggestion: PendingSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题 + 置信度
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: NSLocalizedString("「%@」=%@?", comment: "Pending card headline"),
                            suggestion.newTag, suggestion.canonicalGuess))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.primary)
                Spacer()
                // confidence pill —— high 用中性灰(banner 已弹过,卡片只是 reference);
                // medium 用 orange 提示"AI 不太确定,慎重判断"。降低色彩噪声。
                Text(confidenceLabel(suggestion.confidence))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.secondary.opacity(0.12))
                    )
                    .foregroundStyle(suggestion.confidence == .medium ? Color.orange : Color.secondary)
            }

            // 引文样例
            if !suggestion.sampleEntryIds.isEmpty {
                citationsView(ids: suggestion.sampleEntryIds, canonical: suggestion.canonicalGuess)
            }

            // 操作按钮 —— 跟 banner 统一:主操作撑满第一行,次要 + 忽略 同第二行。
            VStack(alignment: .leading, spacing: 8) {
                chip(
                    title: String(format: NSLocalizedString("合并到 %@", comment: "Merge into canonical"), suggestion.canonicalGuess),
                    style: .primary,
                    fullWidth: true
                ) { confirm(suggestion, canonical: suggestion.canonicalGuess) }

                HStack(spacing: 8) {
                    chip(
                        title: String(
                            format: NSLocalizedString("把「%@」合并到其他主题", comment: "Pick another canonical for newTag"),
                            suggestion.newTag
                        ),
                        style: .secondary,
                        fullWidth: true
                    ) {
                        customEditorTarget = suggestion
                    }
                    chip(
                        title: NSLocalizedString("忽略", comment: "Reject (ignore) merge"),
                        style: .ghost
                    ) { reject(suggestion) }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 中性 liquid glass —— 跟 picker / SuggestionTargetPickerSheet 设计一致,
        // 不再用 confidence color 给整张卡 tint(之前蓝色/橙色 tint 让 Settings 整页过载)。
        .liquidGlassCard(cornerRadius: 16, interactive: false)
    }

    @ViewBuilder
    private func citationsView(ids: [UUID], canonical: String) -> some View {
        // 走 @State 缓存 —— 之前同步 fetchSamples 在每次 body 渲染时打 Core Data,
        // 多 pending 卡片 → 主线程 jank。codex P2 fix。
        let snapshots = ids.compactMap { citationCache[$0] }
        if !snapshots.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(snapshots, id: \.id) { snap in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(snippetText(for: snap))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func snippetText(for snap: CitationSnapshot) -> String {
        let format = NSLocalizedString("M月d日", comment: "Date short")
        let dateStr = Self.snippetDateFormatter(format: format).string(from: snap.date)
        return "\(dateStr) — \(snap.snippet)"
    }

    private static let snippetDateFormatterLock = NSLock()
    private static var snippetDateFormatterCache: [String: DateFormatter] = [:]

    private static func snippetDateFormatter(format: String) -> DateFormatter {
        snippetDateFormatterLock.lock()
        defer { snippetDateFormatterLock.unlock() }
        if let cached = snippetDateFormatterCache[format] { return cached }
        let formatter = DateFormatter()
        formatter.dateFormat = format
        snippetDateFormatterCache[format] = formatter
        return formatter
    }

    // MARK: - Groups section

    @ViewBuilder
    private var groupsSection: some View {
        if !resolver.groups.isEmpty {
            Section(header: header(String(format: NSLocalizedString("已合并 (%d)", comment: "Merged groups header"), resolver.groups.count))) {
                ForEach(sortedGroupKeys, id: \.self) { canonical in
                    groupRow(canonical: canonical, aliases: resolver.groups[canonical] ?? [])
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        // leading/trailing 16,跟 pendingCard 和 HomeView 时间线 row 一致 ——
                        // 之前用 0 让 liquidGlassCard 顶满整个 Form inset row container 边缘,
                        // 跟系统 Form 的 rounded chrome 视觉叠出"突兀阴影"。给卡留 16pt 呼吸空间
                        // 后只显示自己的玻璃边,系统 chrome 在外面看不见。
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                groupPendingDeletion = canonical
                            } label: {
                                Label(NSLocalizedString("删除", comment: "Delete theme"), systemImage: "trash")
                            }
                            Button {
                                resolver.deleteGroup(canonical: canonical)
                            } label: {
                                Label(NSLocalizedString("拆开", comment: "Unmerge group"), systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                            }
                            .tint(.orange)
                        }
                }
            }
        }
    }

    // MARK: - Negative pairs reset section

    @ViewBuilder
    private var negativeResetSection: some View {
        if !resolver.negativePairs.isEmpty {
            Section(
                header: header(NSLocalizedString("否决记录", comment: "Rejected pairs section")),
                footer: Text(NSLocalizedString("点过『不是』的对子被永久跳过。如果想让 AI 重新考虑这些对子(下次扫描时再次提议),清空这里。", comment: "Reset negative footer"))
            ) {
                Button(role: .destructive) {
                    showResetNegativeAlert = true
                } label: {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                            .foregroundStyle(.orange)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(NSLocalizedString("清空否决记录", comment: "Reset rejections"))
                                .foregroundStyle(Color.primary)
                            Text(String(format: NSLocalizedString("共 %d 条", comment: "Negative pair count"), resolver.negativePairs.count))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private var sortedGroupKeys: [String] {
        resolver.groups.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    @ViewBuilder
    private func groupRow(canonical: String, aliases: [String]) -> some View {
        let cornerRadius: CGFloat = 16
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(canonical)
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(String(format: NSLocalizedString("%d 个别名", comment: "Alias count"), aliases.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            FlowLayout(spacing: 6) {
                ForEach(aliases, id: \.self) { alias in
                    // contextMenu 比 Menu 更符合 iOS 26 标准:长按/触摸-保持 出菜单,
                    // 单击不触发任何操作(纯展示)。Menu 在 iOS 26 上单击即弹出菜单,
                    // 用户摸到 chip 时容易误触。
                    Text(alias)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        // 中性 glass capsule(去蓝)
                        .liquidGlassCapsule(interactive: true)
                        .foregroundStyle(Color.primary)
                        .contextMenu {
                            Button(role: .destructive) {
                                resolver.unmerge(canonical: canonical, removeAlias: alias)
                            } label: {
                                Label(NSLocalizedString("从这组拆出", comment: "Unmerge alias"), systemImage: "scissors")
                            }
                        }
                }
            }
        }
        .padding(.init(top: 12, leading: 18, bottom: 12, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard(cornerRadius: cornerRadius, interactive: false)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Helpers

    private func confirm(_ suggestion: PendingSuggestion, canonical: String) {
        #if canImport(UIKit)
        HapticManager.shared.notification(.success)
        #endif
        resolver.confirm(suggestion, canonical: canonical)
    }

    private func reject(_ suggestion: PendingSuggestion) {
        #if canImport(UIKit)
        HapticManager.shared.click()
        #endif
        resolver.reject(suggestion)
    }

    private func confidenceLabel(_ c: PendingSuggestion.Confidence) -> String {
        switch c {
        case .high: return NSLocalizedString("高置信", comment: "High confidence")
        case .medium: return NSLocalizedString("中置信", comment: "Medium confidence")
        }
    }

    private func confidenceColor(_ c: PendingSuggestion.Confidence) -> Color {
        switch c {
        case .high: return Color.accentColor
        case .medium: return .orange
        }
    }

    /// 一次性预取所有 pending 引文 entry,落到 @State citationCache。
    /// 走 background context + DTO 跨边界(NSManagedObject 不 Sendable)。
    private func prefetchCitations() async {
        let allIDs = Set(resolver.pending.flatMap { $0.sampleEntryIds })
        // 无条件清一次 stale —— 旧实现把这步藏在 `missing.isEmpty` guard 内,
        // 当 missing 非空(常见)时 stale 不清,长期使用会让 cache 跟着已 confirm/reject 的 pending
        // 累积旧 entry。把清洗提到 guard 之前保证每次都跑。
        let stale = Set(citationCache.keys).subtracting(allIDs)
        if !stale.isEmpty {
            for k in stale { citationCache.removeValue(forKey: k) }
        }
        let missing = allIDs.subtracting(citationCache.keys)
        guard !missing.isEmpty else { return }
        let snapshots = await PersistenceController.shared.container.performBackgroundTask { context in
            let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", Array(missing) as NSArray)
            request.sortDescriptors = [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)]
            guard let entries = try? context.fetch(request) else { return [CitationSnapshot]() }
            return entries.compactMap { entry -> CitationSnapshot? in
                guard let id = entry.id else { return nil }
                let body = (entry.summary?.isEmpty == false ? entry.summary! : (entry.text ?? ""))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                let snippet = String(body.prefix(50)) + (body.count > 50 ? "…" : "")
                return CitationSnapshot(id: id, date: entry.date ?? Date(), snippet: snippet)
            }
        }
        for snap in snapshots {
            citationCache[snap.id] = snap
        }
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.08), Color.clear],
            startPoint: .top,
            endPoint: .center
        )
    }

    @MainActor
    private func maybeAutoScan() async {
        // 持久化标记在 resolver(codex P2 fix):
        // 之前的 view-local @State hasAutoScannedOnce 会在用户每次 push 进来都重置 → 反复触发 AI 扫描。
        // 现在状态在 resolver,跨 view 重建仍生效。
        guard !resolver.didAutoScanOnce else { return }
        guard resolver.groups.isEmpty,
              resolver.pending.isEmpty,
              !judgeService.scanProgress.isRunning else {
            // 不会自动扫了,但也算"已经走过自动判断流程",写入持久化标记避免下次再 evaluate。
            resolver.markAutoScanned()
            return
        }

        // 只在用户已经积累 ≥ 20 条 distinct theme 才自动跑(空库存跑也没意义)。
        let distinctCount = await Task.detached(priority: .utility) { () -> Int in
            let bg = PersistenceController.shared.container.newBackgroundContext()
            return await bg.perform {
                let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
                request.predicate = NSPredicate(format: "themes != nil AND themes != %@", "")
                request.fetchBatchSize = 200
                guard let entries = try? bg.fetch(request) else { return 0 }
                var seen = Set<String>()
                for e in entries {
                    for t in e.themeArray { seen.insert(t.lowercased()) }
                    if seen.count >= 20 { break }
                }
                return seen.count
            }
        }.value
        guard distinctCount >= 20 else {
            // 库存不够,也标记"评估过了"——避免每次进来都重复 fetch + 计数,
            // 用户主题量 < 20 时不会自动扫,他想扫直接点按钮。
            resolver.markAutoScanned()
            return
        }
        Log.info("[ThemeAliasManagement] auto-scan triggered, distinctTags=\(distinctCount)", category: .ai)
        resolver.markAutoScanned()
        judgeService.scanAllHistory()
    }

    // MARK: - Chip

    fileprivate enum ChipKind { case primary, secondary, ghost }

    @ViewBuilder
    fileprivate func chip(
        title: String,
        icon: String? = nil,
        style: ChipKind,
        fullWidth: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption.weight(.semibold))
                }
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // frame(maxWidth) 必须在 background modifier 之前,否则 capsule 仍 size-to-fit
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 30)
            .modifier(MgmtChipModifier(kind: style))
        }
        .buttonStyle(.plain)
    }
}

private struct MgmtChipModifier: ViewModifier {
    let kind: ThemeAliasManagementView.ChipKind
    func body(content: Content) -> some View {
        switch kind {
        case .primary:
            content
                .foregroundStyle(Color.white)
                .background(Capsule().fill(Color.accentColor))
        case .secondary:
            content
                .foregroundStyle(Color.primary)
                // 中性 glass capsule —— 不传 tint,避免 banner / picker / 待审三处都泛蓝
                .liquidGlassCapsule(interactive: true)
        case .ghost:
            content
                .foregroundStyle(Color.secondary)
                .background(Capsule().fill(Color.secondary.opacity(0.10)))
        }
    }
}

// 复用 DiaryDetailView 里已有的 FlowLayout(默认 spacing=8,struct level internal)。
// 不再自定义,避免符号冲突。
