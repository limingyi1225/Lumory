import SwiftUI
import CoreData

// MARK: - AskPastView
//
// Phase 2 主入口：聊天式回顾。
// - 顶部预设问题胶囊（由用户数据动态生成）
// - 消息列表：user 气泡右对齐；ai 气泡左对齐 + 流式 markdown + 折叠引用卡
// - 底部输入框
//
// 整条检索+生成链路由 `InsightsEngine.ask(_:)` 负责；本视图只关心 UI。

struct AskPastView: View {

    enum Role { case user, ai }

    struct Message: Identifiable, Equatable {
        var id: UUID = UUID()
        let role: Role
        var text: String
        var citedEntryIds: [UUID]
        var isStreaming: Bool
    }

    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    @State private var messages: [Message] = []
    @State private var inputText: String = ""
    @State private var activeTask: Task<Void, Never>?
    @FocusState private var inputFocused: Bool

    // 引用卡展开状态（按 message id 记录）
    @State private var expandedCitations: Set<UUID> = []

    // 动态预设问题
    @State private var presets: [String] = []
    /// 初始 false —— `.task` 跑 loadPresetsIfNeeded 时:Path A(cache 命中)立刻拿到 presets
    /// 不显 spinner;Path B(无 cache)在阻塞前会显式 set true。初始 true 会在 .task 触发前
    /// 闪一帧 spinner,即使 cache 命中也一闪而过。
    @State private var isLoadingPresets: Bool = false
    /// 后台静默刷新 task 的句柄 —— onDisappear 时取消,避免 view 关掉后还在跑/写 singleton。
    @State private var backgroundRefreshTask: Task<Void, Never>?

    private let engine = InsightsEngine.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if messages.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            welcomeHeader
                            presetGrid
                        }
                        .padding(20)
                    }
                    .scrollDismissesKeyboard(.interactively)
                } else {
                    conversationList
                }
                inputBar
            }
            .navigationTitle(NSLocalizedString("回顾", comment: "Ask Your Past title"))
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("关闭", comment: "Close")) {
                        activeTask?.cancel()
                        dismiss()
                    }
                }
                if !messages.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            reset()
                        } label: {
                            Image(systemName: "trash.slash")
                        }
                    }
                }
            }
            .task {
                await loadPresetsIfNeeded()
            }
            .onDisappear {
                activeTask?.cancel()
                backgroundRefreshTask?.cancel()
            }
        }
    }

    // MARK: Welcome

    private var welcomeHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                Text(NSLocalizedString("问问过去的你", comment: "Ask your past heading"))
                    .font(.title3.weight(.semibold))
            }
            Text(NSLocalizedString("AI 会从你的日记里检索相关片段，回答你的问题，并附上可跳转的参考。", comment: "Ask your past subtitle"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var presetGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(NSLocalizedString("试试这些问题", comment: "Try these questions"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                if isLoadingPresets {
                    ProgressView().scaleEffect(0.6)
                }
                Spacer()
                if !isLoadingPresets && !presets.isEmpty {
                    Button {
                        Task { await regeneratePresets() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(NSLocalizedString("换一组", comment: "Refresh presets"))
                }
            }
            if presets.isEmpty && !isLoadingPresets {
                Text(NSLocalizedString("写几篇日记之后，这里会出现针对你的问题建议。", comment: "Empty presets hint"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                // 多个相邻 glass card 用同一个 container 合并采样,折射边缘更自然。
                GlassEffectContainer(spacing: 10) {
                    VStack(spacing: 10) {
                        ForEach(presets, id: \.self) { preset in
                            Button {
                                submit(preset)
                            } label: {
                                HStack {
                                    Text(preset)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 8)
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .liquidGlassCard(cornerRadius: 14, interactive: true)
                            }
                            .buttonStyle(PressableScaleButtonStyle())
                        }
                    }
                }
            }
        }
    }

    // MARK: Conversation

    private var conversationList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(messages) { message in
                        bubble(for: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.last?.id) { _, id in
                guard let id else { return }
                withAnimation(AnimationConfig.smoothTransition) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
            .onChange(of: messages.last?.text) { _, _ in
                guard let id = messages.last?.id else { return }
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func bubble(for message: Message) -> some View {
        switch message.role {
        case .user:
            userBubble(message)
        case .ai:
            aiBubble(message)
        }
    }

    private func userBubble(_ message: Message) -> some View {
        HStack {
            Spacer(minLength: 40)
            Text(message.text)
                .font(.body)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18).fill(.tint)
                )
        }
    }

    private func aiBubble(_ message: Message) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14))
                    .foregroundStyle(.tint)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 6) {
                    if message.text.isEmpty && message.isStreaming {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.7)
                            Text(NSLocalizedString("正在读你的日记…", comment: "Reading diary"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        MarkdownText(markdown: message.text)
                            .textSelection(.enabled)
                    }
                    if message.isStreaming && !message.text.isEmpty {
                        Circle()
                            .fill(Color.primary.opacity(0.5))
                            .frame(width: 6, height: 6)
                    }
                }
            }
            if !message.citedEntryIds.isEmpty {
                citationsFold(for: message)
                    .padding(.leading, 22)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 40)
    }

    // MARK: Citations — stacked fold

    @ViewBuilder
    private func citationsFold(for message: Message) -> some View {
        let ids = message.citedEntryIds
        let isExpanded = expandedCitations.contains(message.id)

        VStack(alignment: .leading, spacing: 0) {
            // 折叠头：永远显示 —— 数量 + 展开/收起箭头
            Button {
                #if canImport(UIKit)
                HapticManager.shared.click()
                #endif
                withAnimation(.interpolatingSpring(stiffness: 320, damping: 28)) {
                    if isExpanded {
                        expandedCitations.remove(message.id)
                    } else {
                        expandedCitations.insert(message.id)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.caption)
                    Text(String(format: NSLocalizedString("%d 篇相关日记", comment: "N related entries"), ids.count))
                        .font(.caption.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                isExpanded
                ? NSLocalizedString("收起参考", comment: "Collapse citations a11y")
                : NSLocalizedString("展开参考", comment: "Expand citations a11y")
            )

            // 展开态才渲染卡片；折叠态只留 header 按钮，不再用叠卡预览。
            // 原来的 `stackedPeek`（顶卡全展示 + 两张后卡 peek）在真机上视觉错位明显
            // （cornerRadius 重叠 / 阴影穿透 / 行距被 compact 卡片撑开），去掉更干净。
            if isExpanded {
                VStack(spacing: 8) {
                    ForEach(ids, id: \.self) { entryId in
                        CitationEntryCard(entryId: entryId)
                            .environment(\.managedObjectContext, viewContext)
                    }
                }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity
                ))
            }
        }
    }

    // MARK: Input bar

    private var inputBar: some View {
        // iOS 26 浮动玻璃 dock:输入框走 glass 胶囊,发送按钮走 glassProminent。
        // 多个相邻 glass 元素归到同一个 GlassEffectContainer,折射合批,边缘观感统一。
        GlassEffectContainer(spacing: 10) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    NSLocalizedString("问问过去的自己…", comment: "Ask placeholder"),
                    text: $inputText,
                    axis: .vertical
                )
                .lineLimit(1...4)
                .focused($inputFocused)
                .textFieldStyle(.plain)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .liquidGlassCapsule()

                Button {
                    if isStreaming {
                        activeTask?.cancel()
                    } else {
                        submit(inputText)
                    }
                } label: {
                    Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.glassProminent)
                .disabled(!canSubmit && !isStreaming)
                .accessibilityLabel(
                    isStreaming
                    ? NSLocalizedString("停止", comment: "Stop streaming")
                    : NSLocalizedString("发送", comment: "Send")
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private var canSubmit: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isStreaming
    }

    private var isStreaming: Bool {
        messages.last?.isStreaming ?? false
    }

    // MARK: Actions

    private func submit(_ raw: String) {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // `isStreaming` 靠 `messages.last?.isStreaming`，在 `messages.append` 之前为 false，
        // 连点 / preset 连击可能两个 submit 都越过 guard。`activeTask` guard 更硬：同一时刻最多一个。
        guard !question.isEmpty, !isStreaming, activeTask == nil else { return }
        inputText = ""
        inputFocused = false
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif

        messages.append(Message(role: .user, text: question, citedEntryIds: [], isStreaming: false))
        let aiMessageID = UUID()
        messages.append(Message(id: aiMessageID, role: .ai, text: "", citedEntryIds: [], isStreaming: true))

        activeTask = Task {
            for await chunk in engine.ask(question) {
                if Task.isCancelled { break }
                await MainActor.run {
                    update(messageID: aiMessageID) { msg in
                        switch chunk.kind {
                        case .citation:
                            msg.citedEntryIds = chunk.citedEntryIds
                        case .text:
                            msg.text += chunk.text
                        }
                    }
                }
            }
            await MainActor.run {
                update(messageID: aiMessageID) { msg in
                    msg.isStreaming = false
                }
                // 清掉 activeTask，下一次 submit 才能通过 guard
                activeTask = nil
            }
        }
    }

    private func update(messageID: UUID, mutate: (inout Message) -> Void) {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }) else { return }
        var msg = messages[idx]
        mutate(&msg)
        messages[idx] = msg
    }

    private func reset() {
        activeTask?.cancel()
        messages = []
        inputText = ""
        expandedCitations = []
    }

    // MARK: Presets (AI-authored via PromptSuggestionEngine)

    /// 进入视图时调。
    /// 关键约束:**只要 cache 命中就立刻展示并 return,绝不在用户面前重生成。**
    /// 刷新只通过用户主动点 refresh 按钮触发,或后台静默 task(下次进入才生效)。
    private func loadPresetsIfNeeded() async {
        guard presets.isEmpty else { return }

        // Path A:有缓存 → 直接展示,不显示 spinner,不重生成。
        // 后台静默 refresh 存到 backgroundRefreshTask 句柄,onDisappear 时 cancel,
        // 避免 view 关掉后还在跑(虽然写到 singleton 不算泄漏,但会引起其他订阅者
        // 不必要的 SwiftUI 重渲染)。
        if let cached = PromptSuggestionEngine.shared.current,
           !cached.askPastPresets.isEmpty {
            presets = cached.askPastPresets
            isLoadingPresets = false
            backgroundRefreshTask?.cancel()
            backgroundRefreshTask = Task.detached(priority: .utility) {
                await PromptSuggestionEngine.shared.refreshIfNeeded()
            }
            return
        }

        // Path B:没缓存(首次进入 / 旧版本 cache 失效) → 阻塞等待
        isLoadingPresets = true
        await PromptSuggestionEngine.shared.refreshIfNeeded()
        await applyFreshestSuggestions()
        isLoadingPresets = false
    }

    /// 用户点 refresh 按钮时调。
    private func regeneratePresets() async {
        isLoadingPresets = true
        await PromptSuggestionEngine.shared.forceRefresh()
        await applyFreshestSuggestions()
        isLoadingPresets = false
    }

    /// 统一收束：AI 有就用 AI，否则落到 PersonalizedPresetGenerator 模板版。
    @MainActor
    private func applyFreshestSuggestions() async {
        if let bundle = PromptSuggestionEngine.shared.current, !bundle.askPastPresets.isEmpty {
            presets = bundle.askPastPresets
            return
        }
        presets = await PersonalizedPresetGenerator.generate()
    }
}

// MARK: - Personalized preset generator

/// 从用户真实数据里长出一组预设问题。
/// 策略：主题频次 + 情绪极端 + 近期变化，几项合成 4 条。
/// 数据不足时返回空 —— 由 UI 决定兜底提示。
enum PersonalizedPresetGenerator {

    /// 不触发 AI，全本地聚合。
    static func generate() async -> [String] {
        let engine = InsightsEngine.shared
        let now = Date()
        let calendar = Calendar.current

        // 主题用 90 天视角；情绪点用 30 天视角
        let themeRange = DateInterval(
            start: calendar.date(byAdding: .day, value: -90, to: now) ?? now,
            end: now
        )
        let moodRange = DateInterval(
            start: calendar.date(byAdding: .day, value: -30, to: now) ?? now,
            end: now
        )

        async let themes = engine.themes(in: themeRange, limit: 8)
        async let points = engine.moodSeries(in: moodRange, bucket: .day)
        async let stats = engine.writingStats()
        let (topThemes, moodPoints, writingStats) = await (themes, points, stats)

        var out: [String] = []

        // 1. 最常出现的主题
        if let top = topThemes.first {
            out.append(String(
                format: NSLocalizedString("关于 %@，我最近在想什么？", comment: "Preset top theme"),
                top.name
            ))
        }

        // 2. 情绪最好的主题（阈值 0.6 避免假积极）
        let sortedByMoodDesc = topThemes.sorted { $0.avgMood > $1.avgMood }
        if let best = sortedByMoodDesc.first, best.avgMood >= 0.6, best.id != topThemes.first?.id {
            out.append(String(
                format: NSLocalizedString("哪些日子因为 %@ 特别开心？", comment: "Preset best theme"),
                best.name
            ))
        }

        // 3. 情绪最低的那一天
        if let lowDay = moodPoints.min(by: { $0.mood < $1.mood }), lowDay.mood < 0.4 {
            out.append(String(
                format: NSLocalizedString("%@ 那天我为什么情绪低？", comment: "Preset low day"),
                Self.dateFormatter.string(from: lowDay.date)
            ))
        }

        // 4. 两个主题之间的联系
        if topThemes.count >= 2 {
            out.append(String(
                format: NSLocalizedString("%@ 和 %@ 之间有什么联系？", comment: "Preset two themes"),
                topThemes[0].name, topThemes[1].name
            ))
        }

        // 5. 连续书写 → 反思最近变化
        if writingStats.currentStreak >= 5 {
            out.append(NSLocalizedString("最近这段时间我变化了什么？", comment: "Preset recent change"))
        }

        // 不足 3 条时补几条通用但仍"问我自己"的问题
        let fallbacks = [
            NSLocalizedString("上周最值得记住的一件事是什么？", comment: "Fallback preset 1"),
            NSLocalizedString("最近反复出现的情绪是什么？", comment: "Fallback preset 2"),
            NSLocalizedString("现在的我最担心什么？", comment: "Fallback preset 3")
        ]
        for fallback in fallbacks where out.count < 4 {
            if !out.contains(fallback) {
                out.append(fallback)
            }
        }

        return Array(out.prefix(4))
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()
}
