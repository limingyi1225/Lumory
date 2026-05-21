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
    /// 调用方可通过此参数让 view 一上来就 fire 一道问题。InsightsView 行动区 preset chip
    /// 入口走这条 — 用户从 Insights 点一个建议问题,sheet 出场即"用户气泡 + AI 流式回答",
    /// 跳过 empty / preset grid 闪烁。nil(默认) = 跟原来一样进 empty welcome + presetGrid;
    /// non-nil = `.task` 里自动 fire 一次 submit。`hasSubmittedInitial` 守住只 fire 一次,
    /// 用户在内部按"清空"reset 回 empty 后不重新自动 submit。
    var initialQuestion: String? = nil

    enum Role { case user, ai }
    struct Message: Identifiable, Equatable {
        var id: UUID = UUID()
        let role: Role
        var text: String
        var citedEntryIds: [UUID]
        var isStreaming: Bool
        /// AI 流被中断但已产出部分内容 —— UI 在气泡下渲染提示条,并不把截断文案
        /// 当正文 append。默认 false,保持旧行为不受影响。
        var isIncomplete: Bool = false
        /// AI 流彻底失败(零内容产出) —— UI 在气泡里直接显示这条 errorText
        /// (localizedDescription),用户能看到"是网络问题还是认证问题"而不是空白 + 通用提示。
        /// 和 `isIncomplete` 互斥:isIncomplete 是"断在中间",errorText 是"根本没开始"。
        var errorText: String?
    }

    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSizeClass

    @State private var messages: [Message] = []
    @State private var inputText: String = ""
    @State private var activeTask: Task<Void, Never>?
    @State private var activeTaskID: UUID?
    /// wave14 — 历史回顾入口从 InsightsView toolbar Menu 移到 AskPastView 自己的 toolbar。
    @State private var showHistory: Bool = false
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
    @State private var lastAutoScrollAt: Date = .distantPast
    /// initialQuestion 模式的"只 fire 一次"守卫。reset() 后保持 true,清空对话不重 fire。
    @State private var hasSubmittedInitial: Bool = false

    private let engine = InsightsEngine.shared
    private static let streamFlushInterval: TimeInterval = 0.08

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if messages.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            welcomeHeader
                            presetGrid
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                        .padding(.top, -12)
                        .lumoryReadableContent(maxWidth: LumoryAdaptivePresentation.chatContentMaxWidth)
                    }
                    .scrollDismissesKeyboard(.interactively)
                } else {
                    conversationList
                }
                inputBar
            }
            .accessibilityIdentifier("askPastRoot")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            #endif
            .toolbar {
                // iPad / regular size class 走 fullScreenCover 没有下拉手势,留小关闭按钮兜底。
                if hSizeClass == .regular {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel(NSLocalizedString("关闭", comment: "Close"))
                    }
                }
                if !messages.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            HapticManager.shared.impact(.medium)
                            reset()
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(NSLocalizedString("清空", comment: "Reset chat"))
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        #if canImport(UIKit)
                        HapticManager.shared.impact(.light)
                        #endif
                        showHistory = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(NSLocalizedString("提问历史", comment: "Ask Past history"))
                    .accessibilityIdentifier("askPastHistoryButton")
                }
            }
            .lumoryAdaptiveModal(isPresented: $showHistory) {
                // §2.3 (2026-05-19) — askPast 历史只显提问记录;narrative 回顾历史从
                // NarrativeDetailSheet 自己的 toolbar 入口,两条不再混在同一列表。
                ConversationHistoryView(filterKind: .askPast)
                    .environment(\.managedObjectContext, viewContext)
            }
            .task {
                // InsightsView 行动区 preset chip 入口:先 fire 再 hydrate presets。
                // submit 同步 append messages → 下一帧渲染 conversationList,presetGrid
                // 已不在 messages.isEmpty 分支,不会闪一帧 preset。
                if let initial = initialQuestion?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !initial.isEmpty,
                   !hasSubmittedInitial {
                    hasSubmittedInitial = true
                    submit(initial)
                }
                await loadPresetsIfNeeded()
            }
            .onDisappear {
                activeTask?.cancel()
                activeTask = nil
                activeTaskID = nil
                backgroundRefreshTask?.cancel()
                backgroundRefreshTask = nil
            }
        }
    }

    // MARK: Welcome

    private var welcomeHeader: some View {
        // wave14 — 删 "AI 会从你的日记里检索相关片段..." 副标题(去 AI 化、保持无感)。
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            Text(NSLocalizedString("问问过去的你", comment: "Ask your past heading"))
                .font(.title3.weight(.semibold))
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
                                .contentShape(RoundedRectangle(cornerRadius: LumoryCornerRadius.nestedRow, style: .continuous))
                                .liquidGlassCard(cornerRadius: LumoryCornerRadius.nestedRow, interactive: true)
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
                .lumoryReadableContent(maxWidth: LumoryAdaptivePresentation.chatContentMaxWidth)
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
                let now = Date()
                guard now.timeIntervalSince(lastAutoScrollAt) > 0.15 else { return }
                lastAutoScrollAt = now
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func bubble(for message: Message) -> some View {
        AskPastMessageRow(
            message: message,
            isCitationExpanded: expandedCitations.contains(message.id),
            onToggleCitations: { toggleCitations(for: message.id) }
        )
        .equatable()
    }

    // MARK: Citations — stacked fold

    private func toggleCitations(for messageID: UUID) {
        #if canImport(UIKit)
        HapticManager.shared.click()
        #endif
        withAnimation(.interpolatingSpring(stiffness: 320, damping: 28)) {
            if expandedCitations.contains(messageID) {
                expandedCitations.remove(messageID)
            } else {
                expandedCitations.insert(messageID)
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
                // 软键盘 Return 在 axis=.vertical 上仍是换行(SwiftUI 这是 by-design,onSubmit 不 fire)。
                // .submitLabel(.send) 只换键盘上 Return 按钮的字面 — 视觉提示用户"这条按下能发"。
                // 真正的"按 Return 发送"需要监听 inputText 变化里的 \n,这条会让粘贴多行也误触发,
                // 不上;hardware keyboard / iPad 用户走下面 send button 上的 Cmd+Return 快捷键。
                .submitLabel(.send)

                Button {
                    if isStreaming {
                        cancelActiveAnswer()
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
                // **Cmd+Return 双语义**:idle 时发送当前 inputText;streaming 时按一下 = 停止流(因为
                // 这同一个按钮在 streaming 时切到 stop.fill 图标 + cancel 路径)。这是有意的 — 硬件键盘
                // 用户 streaming 中能用 Cmd+Return 中断,跟 Send 是同位 hot key。
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel(
                    isStreaming
                    ? NSLocalizedString("停止", comment: "Stop streaming")
                    : NSLocalizedString("发送", comment: "Send")
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .lumoryReadableContent(maxWidth: LumoryAdaptivePresentation.chatContentMaxWidth)
        .padding(.bottom, 8)
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
        HapticManager.shared.impact(.light)

        messages.append(Message(role: .user, text: question, citedEntryIds: [], isStreaming: false))
        let aiMessageID = UUID()
        messages.append(Message(id: aiMessageID, role: .ai, text: "", citedEntryIds: [], isStreaming: true))

        let taskID = UUID()
        activeTaskID = taskID
        activeTask = Task {
            var pendingText = ""
            var lastFlushAt = Date()

            func flushPendingText() async {
                guard !pendingText.isEmpty else { return }
                let text = pendingText
                pendingText = ""
                lastFlushAt = Date()
                await MainActor.run {
                    update(messageID: aiMessageID) { msg in
                        msg.text += text
                    }
                }
            }

            streamLoop: for await chunk in engine.ask(question) {
                if Task.isCancelled { break }
                switch chunk.kind {
                case .text:
                    pendingText += chunk.text
                    if Date().timeIntervalSince(lastFlushAt) >= Self.streamFlushInterval {
                        await flushPendingText()
                    }
                case .citation, .truncated, .failed:
                    await flushPendingText()
                    await MainActor.run {
                        update(messageID: aiMessageID) { msg in
                            switch chunk.kind {
                            case .citation:
                                msg.citedEntryIds = chunk.citedEntryIds
                            case .truncated:
                                // 流中断(已有部分正文) —— 不把 `⚠️…` 当正文 append,set flag,
                                // UI 渲染独立提示条 + "重新生成"按钮。
                                msg.isIncomplete = true
                            case .failed:
                                // 流完全失败 —— 把 localized error 塞进 errorText,
                                // 气泡里直接显示 "Error: <原因>",用户能区分离线/认证/5xx。
                                msg.errorText = chunk.text
                            case .text:
                                break
                            }
                        }
                    }
                    if case .failed = chunk.kind {
                        break streamLoop
                    }
                }
            }
            await flushPendingText()
            let wasCancelled = Task.isCancelled
            await MainActor.run {
                update(messageID: aiMessageID) { msg in
                    if wasCancelled, !msg.text.isEmpty, msg.errorText == nil {
                        msg.isIncomplete = true
                    }
                    msg.isStreaming = false
                }
                // 清掉 activeTask,下一次 submit 才能通过 guard;stale 旧 task 不得清掉新 task。
                let isSuperseded = activeTaskID != nil && activeTaskID != taskID
                if activeTaskID == taskID {
                    activeTask = nil
                    activeTaskID = nil
                }
                // **wave12-3 自动保存历史**(codex review:`InsightsEngine.ask` 已内部消费 .done,
                // 这里 `for await` loop 自然结束就视为流程完成)。每次 Q+A pair 一条记录。
                // 跳过保存的情况:用户取消(wasCancelled 且无内容)/ AI 一字未产出且无错误。
                // 保存的情况:有正文(包括 isIncomplete 半截) / 有 errorText(让用户能回看
                // "网络炸了那次"问的什么)。世代号 guard 防 stale write 不需要 — task 已结束。
                //
                // **P2 clarity fix (2026-05-13 superreview)**:之前 `if activeTaskID != nil { return }`
                // 在同 task 完成路径上 activeTaskID 已清 → 永远 false,只在"newer task 抢了
                // activeTaskID 但本 task 还没 reach 这行"的极窄 race window 才生效。改用显式
                // isSuperseded 表达意图,后人改时不会误以为是死代码。
                if isSuperseded { return }
                // **用户主动 cancel 不入库**:`persistConversationIfNeeded` 仅挡彻底空 cancel
                // (`text == "" && errorText == ""`),挡不住"已流半句被用户点 stop"的场景 —
                // 那种半截答案会进 History 让用户看到"咦我刚才取消的内容怎么还在",信任崩。
                // 注意 errorText 仍走 persist 路径(让用户能回看"网络炸了那次问的什么")。
                if wasCancelled { return }
                self.persistConversationIfNeeded(question: question, aiMessageID: aiMessageID)
            }
        }
    }

    /// 把刚结束的 Q+A pair 存进 CoreData(`AIConversation` entity,kind=askPast)。
    /// fire-and-forget,失败仅 Log 不打扰用户。
    private func persistConversationIfNeeded(question: String, aiMessageID: UUID) {
        guard let aiMsg = messages.first(where: { $0.id == aiMessageID }) else { return }
        // 啥都没有 → 不保存(取消空 / 用户秒删 / 等)。errorText 仍保存(让用户回看)。
        if aiMsg.text.isEmpty && (aiMsg.errorText ?? "").isEmpty {
            return
        }

        let userMsg = AIConversation.AskPastPayload.Message(
            role: .user,
            text: question,
            citedEntryIds: [],
            isIncomplete: false,
            errorText: nil
        )
        let aiPayloadMsg = AIConversation.AskPastPayload.Message(
            role: .ai,
            text: aiMsg.text,
            citedEntryIds: aiMsg.citedEntryIds,
            isIncomplete: aiMsg.isIncomplete,
            errorText: aiMsg.errorText
        )
        let payload = AIConversation.AskPastPayload(messages: [userMsg, aiPayloadMsg])

        do {
            _ = try AIConversation.insertAskPast(
                in: viewContext,
                title: question,
                payload: payload,
                citedEntryIds: aiMsg.citedEntryIds
            )
            try viewContext.save()
        } catch {
            Log.error("[AskPastView] 持久化 AskPast 历史失败: \(error)", category: .persistence)
        }
    }

    private func update(messageID: UUID, mutate: (inout Message) -> Void) {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }) else { return }
        var msg = messages[idx]
        mutate(&msg)
        messages[idx] = msg
    }

    private func cancelActiveAnswer() {
        activeTask?.cancel()
        activeTask = nil
        activeTaskID = nil

        // 只在"第一 chunk 还没到 + 没失败"才清,有内容的回答留着让用户看到自己取消了多少。
        guard let last = messages.last,
              last.role == .ai,
              last.isStreaming,
              last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (last.errorText ?? "").isEmpty else { return }
        messages.removeLast()

        // (codex 终审 2026-05-19) 在 first-chunk 之前秒停时,刚 append 的 user message 也要一起拿掉。
        // submit 顺序是"user.append → ai.placeholder.append",所以现在的 last 应该是配对的 user。
        // 不一起删,用户看到的是"自己问了一个问题但 AI 没回答" 的悬挂 turn,而且 user.text 不会
        // 进 ConversationHistory(persistConversationIfNeeded 跳过空回答),用户重开 sheet 也看不见 —
        // 等同于 ghost question。整对一起删等同于"这次提问从未发生",符合用户意图。
        if let pairedUser = messages.last, pairedUser.role == .user {
            messages.removeLast()
        }
    }

    private func reset() {
        activeTask?.cancel()
        activeTask = nil
        activeTaskID = nil
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
            backgroundRefreshTask = Task(priority: .utility) {
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
                LumoryDateFormatters.monthDay.string(from: lowDay.date)
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

}

private struct AskPastMessageRow: View, Equatable {
    let message: AskPastView.Message
    let isCitationExpanded: Bool
    let onToggleCitations: () -> Void
    @Environment(\.managedObjectContext) private var viewContext

    static func == (lhs: AskPastMessageRow, rhs: AskPastMessageRow) -> Bool {
        lhs.message == rhs.message && lhs.isCitationExpanded == rhs.isCitationExpanded
    }

    var body: some View {
        switch message.role {
        case .user:
            userBubble
        case .ai:
            aiBubble
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 40)
            Text(message.text)
                .font(.body)
                // P1-Ins-13 玻璃化 — 之前是 .tint 实色蓝填充,跟整 App 中性玻璃语言脱节。
                // 改 liquidGlassCard + accent tint 0.18,文字回 primary,跟 ThemeAliasBanner /
                // pendingCard 同语言。
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .liquidGlassCard(
                    cornerRadius: 18,
                    tint: Color.accentColor,
                    tintStrength: 0.18
                )
        }
    }

    private var aiBubble: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14))
                    .foregroundStyle(.tint)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 6) {
                    aiText
                    if message.isStreaming && !message.text.isEmpty {
                        // P1-Ins-12 打字中 indicator — 之前是静态圆点,现在用 SF Symbols ellipsis
                        // + symbolEffect(.pulse) 做苹果原生"打字中"动画。
                        // outer if 已 gate 住 isStreaming=true,内层 isActive 永远 true → 移除冗余参数。
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(0.5))
                            .symbolEffect(.pulse)
                    }
                    if message.isIncomplete {
                        incompleteBanner
                    }
                    if let error = message.errorText, !error.isEmpty {
                        errorRow(message: error)
                    }
                }
            }
            if !message.citedEntryIds.isEmpty {
                citationsFold
                    .padding(.leading, 22)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 40)
    }

    @ViewBuilder
    private var aiText: some View {
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
    }

    /// 完全失败时在气泡内渲染错误原文，不把具体网络/认证错误吞成通用文案。
    private func errorRow(message error: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.caption)
            Text(error)
                .font(.caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: LumoryCornerRadius.inline, style: .continuous)
                .fill(Color.red.opacity(0.08))
        )
    }

    /// 对话气泡里的"内容不完整"提示条，避免把系统状态当作 AI 正文 append。
    /// §4.3 (2026-05-19) — 走共享 `InlineWarningBanner`(tintOpacity 0.12 跟 HomeComposer 三胞胎
    /// 的 0.08 略不同,用 init 参数传)。
    private var incompleteBanner: some View {
        InlineWarningBanner(
            message: NSLocalizedString("stream.incomplete.banner", comment: "Stream truncated hint"),
            tintOpacity: 0.12
        )
    }

    private var citationsFold: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggleCitations) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.caption)
                    Text(
                        String(
                            format: NSLocalizedString("%d 篇相关日记", comment: "N related entries"),
                            message.citedEntryIds.count
                        )
                    )
                    .font(.caption.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isCitationExpanded ? 180 : 0))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                isCitationExpanded
                ? NSLocalizedString("收起参考", comment: "Collapse citations a11y")
                : NSLocalizedString("展开参考", comment: "Expand citations a11y")
            )

            if isCitationExpanded {
                CitationEntryList(ids: message.citedEntryIds)
                    .environment(\.managedObjectContext, viewContext)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
            }
        }
    }
}
