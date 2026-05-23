import SwiftUI
import CoreData

// MARK: - SuggestionTargetPickerSheet
//
// Banner / Management 上的"保存为其他主题" sheet —— 列出全部历史主题让用户挑一个作为合并目标。
// 视觉:**普通 liquid glass**(无 accent tint)—— 之前用 accent 蓝色 tint 整个 sheet 都泛蓝,
// 视觉过载。改成中性 glass(默认 .regular,iOS 26 自带的灰白色折射)更干净。
//
// 共享给:
//   - ThemeAliasBanner.customEditorSheet
//   - ThemeAliasManagementView.customEditor

struct SuggestionTargetPickerSheet: View {
    let suggestion: PendingSuggestion
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var allThemes: [ThemeOption] = []
    @State private var isLoading = true
    @State private var searchText: String = ""
    @State private var confirmingName: String?

    /// 一条候选主题 = canonical 名 + 总出现次数(同 canonical 的所有 alias 频次合计)。
    struct ThemeOption: Identifiable, Equatable {
        let name: String
        let count: Int
        var id: String { name.lowercased() }
    }

    private var filteredOptions: [ThemeOption] {
        // 只排除 newTag —— 不能保存为自己。
        // canonicalGuess 不再排除:语义改为"只把 newTag 保存为别的",保留 canonicalGuess 作为合法候选
        // (用户在搜索框找到 canonicalGuess 也能合并,跟主按钮等价)。
        let exclude = Set([suggestion.newTag.lowercased()])
        let trimmed = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return allThemes.filter { opt in
            guard !exclude.contains(opt.name.lowercased()) else { return false }
            guard !trimmed.isEmpty else { return true }
            return opt.name.lowercased().contains(trimmed)
        }
    }

    /// 搜索框输入了一个 list 里没有的名字 → 显示一条"用『xxx』作为新主题名"作为 fallback。
    /// 排除三种情况:
    ///   1. 输入的字符串是 allThemes(canonical 集合)里的某个 → 该 canonical 已在主列表
    ///   2. 输入的字符串是某个现有 group 的 alias —— 用户输入"abby"(已是 Abby 的 alias)
    ///      会让 confirm 内部 resolve 到 Abby,不会创建独立 group(数据正确),
    ///      但 confirmingOverlay 显示"已保存为 abby"会撒谎(用户以为新 canonical)。
    ///      这里直接屏蔽 customCandidate,把这条输入吞掉,鼓励用户改输 canonical 或直接选列表里的。
    ///   3. 输入的字符串命中 `InsightsEngine.isBannedTheme`(情绪/心情这类元词)。
    ///      让用户创建后整个 Insights 又会过滤掉它 → 鬼组,体感是"我创建了主题但它消失了"。
    private var customCandidate: String? {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        let existsInList = allThemes.contains { $0.name.lowercased() == lower }
        if existsInList { return nil }
        // 已是某 group 的 alias → 不允许当"新主题名"
        if !aliasParent(of: trimmed).isEmpty { return nil }
        // banned theme → 创建后 Insights 立刻把它过滤掉,等于鬼组,直接不让创建。
        if InsightsEngine.isBannedTheme(trimmed) { return nil }
        return trimmed
    }

    /// 当输入的字符串已是某 group 的 alias 时,返回该 group 的 canonical 名(原文)。
    /// 否则返回空串。给"已是别名"提示用。
    private func aliasParent(of raw: String) -> String {
        let snapshot = ThemeAliasResolver.shared.snapshotIndex()
        let key = raw.lowercased()
        guard let canonical = snapshot[key] else { return "" }
        // 命中:canonical 自己也会指向自己;这种情况已被 existsInList 挡掉,这里只剩"真 alias"。
        if canonical.lowercased() == key { return "" }
        return canonical
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    sourceHeader
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                    if isLoading {
                        ProgressView()
                            .padding(.top, 40)
                    } else {
                        GlassEffectContainer(spacing: 10) {
                            VStack(spacing: 10) {
                                if let custom = customCandidate {
                                    customOptionCard(name: custom)
                                }
                                // 输入是已有 alias → 提示"它已经是某 canonical 的别名",鼓励用户改输 canonical
                                let trimmed = searchText.trimmingCharacters(in: .whitespaces)
                                if customCandidate == nil, !trimmed.isEmpty {
                                    let parent = aliasParent(of: trimmed)
                                    if !parent.isEmpty {
                                        aliasHintCard(input: trimmed, canonical: parent)
                                    }
                                }
                                if filteredOptions.isEmpty && customCandidate == nil {
                                    emptyState.padding(.top, 30)
                                } else {
                                    ForEach(filteredOptions) { option in
                                        candidateCard(option: option)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                    }
                }
            }
            .searchable(
                text: $searchText,
                prompt: NSLocalizedString("搜索 / 输入新主题名", comment: "Picker search prompt")
            )
            .navigationTitle(NSLocalizedString("合并到", comment: "Picker title"))
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "Cancel")) { dismiss() }
                }
            }
            .overlay {
                if let target = confirmingName {
                    confirmingOverlay(target: target)
                        .transition(.opacity)
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.85), value: confirmingName)
            .task { await loadThemes() }
        }
    }

    // MARK: Subviews

    private var sourceHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(NSLocalizedString("把这个标签合并到", comment: "Picker source header"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(suggestion.newTag)
                    .font(.body.weight(.semibold))
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 中性 liquid glass —— 不传 tint,使用 iOS 26 默认 regular 玻璃材质
            .liquidGlassCard(cornerRadius: LumoryCornerRadius.nestedRow, interactive: false)
        }
    }

    @ViewBuilder
    private func candidateCard(option: ThemeOption) -> some View {
        Button {
            select(option.name)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Text(String(format: NSLocalizedString("%d 次", comment: "Theme count"), option.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 中性 liquid glass + interactive(让按下有反馈)
            .liquidGlassCard(cornerRadius: LumoryCornerRadius.nestedRow, interactive: true)
        }
        .buttonStyle(PressableScaleButtonStyle())
        .disabled(confirmingName != nil)
    }

    /// 用户输入的新名字(列表里没有)对应的选项 —— 让自定义新主题仍可达成。
    /// 这里**唯一**保留 accent tint(因为是"加号 / 创建" 语义,需要视觉上区别于普通候选)。
    @ViewBuilder
    private func customOptionCard(name: String) -> some View {
        Button {
            select(name)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: NSLocalizedString("合并到新主题「%@」", comment: "Custom new name option"), name))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Text(NSLocalizedString("还没在你的日记里出现过", comment: "Hint that name is brand-new"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlassCard(cornerRadius: LumoryCornerRadius.nestedRow, interactive: true)
        }
        .buttonStyle(PressableScaleButtonStyle())
        .disabled(confirmingName != nil)
    }

    /// 输入是某个 group 的 alias 时的提示卡片。点了直接选 canonical,行为等价。
    @ViewBuilder
    private func aliasHintCard(input: String, canonical: String) -> some View {
        Button {
            select(canonical)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "info.circle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: NSLocalizedString("『%@』已经是『%@』的别名", comment: "Alias already exists hint"), input, canonical))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(String(format: NSLocalizedString("点这里直接合并到「%@」", comment: "Tap to use canonical hint"), canonical))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlassCard(cornerRadius: LumoryCornerRadius.nestedRow, interactive: true)
        }
        .buttonStyle(PressableScaleButtonStyle())
        .disabled(confirmingName != nil)
    }

    private var emptyState: some View {
        EmptyStateView(
            systemImage: "magnifyingglass",
            title: NSLocalizedString("没有匹配的主题", comment: "No matching themes"),
            size: .compact,
            showsIconBackground: false
        )
    }

    @ViewBuilder
    private func confirmingOverlay(target: String) -> some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.bounce, value: confirmingName != nil)
                Text(String(format: NSLocalizedString("已合并到「%@」", comment: "Merge success"), target))
                    .font(.headline)
                    .foregroundStyle(Color.primary)
            }
            .padding(28)
            .liquidGlassCard(cornerRadius: LumoryCornerRadius.chip)
        }
    }

    // MARK: Actions

    private func select(_ name: String) {
        guard confirmingName == nil else { return }
        onConfirm(name)
        Task { @MainActor in
            confirmingName = name
            try? await Task.sleep(for: .milliseconds(320))
            dismiss()
        }
    }

    /// 后台扫所有 entry.themes,按出现次数 desc 排序。
    /// 折叠 alias:同 canonical 的标签合并计数,只保留 canonical 名(列表更干净)。
    private func loadThemes() async {
        let resolverSnapshot = ThemeAliasResolver.shared.snapshotIndex()
        let result: [(name: String, count: Int)] = await PersistenceController.shared.container.performBackgroundTask { context in
            let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
            request.predicate = NSPredicate(format: "themes != nil AND themes != %@", "")
            request.fetchBatchSize = 200
            guard let entries = try? context.fetch(request) else { return [] }
            var rawCounts: [String: Int] = [:]
            for entry in entries {
                for tag in entry.themeArray where !tag.isEmpty && !InsightsEngine.isBannedTheme(tag) {
                    rawCounts[tag, default: 0] += 1
                }
            }
            var folded: [String: (display: String, count: Int)] = [:]
            for (tag, count) in rawCounts {
                let lower = tag.lowercased()
                let canon = resolverSnapshot[lower] ?? tag
                let key = canon.lowercased()
                if var entry = folded[key] {
                    entry.count += count
                    folded[key] = entry
                } else {
                    folded[key] = (canon, count)
                }
            }
            return folded.values
                .map { (name: $0.display, count: $0.count) }
                .sorted { $0.count > $1.count }
        }
        await MainActor.run {
            self.allThemes = result.map { ThemeOption(name: $0.name, count: $0.count) }
            self.isLoading = false
        }
    }
}
