import SwiftUI
import CoreData
import PhotosUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Send Button State Machine
// `enum SendButtonState` 已 moved 到 Views/HomeView/HomeInputViewModel.swift,
// 与发送按钮动画的 `@State` 一起收束。HomeView 内继续按原名引用,类型语义不变。

// 当前数据模型只持久化一段录音（DiaryEntry.audioFileName 是单值），
// UI 最多保留 1 条 take；重录前用户需要先删除已有 take。
struct Recording: Identifiable {
    let id: String
    let fileName: String
    let duration: TimeInterval
}

struct HomeView: View {
    // Core Data 相关
    @Environment(\.managedObjectContext) private var viewContext
    // 注意：这里**故意不用** `animation: .default`。
    // 历史上同时开 FetchRequest animation、List 原生 row-removal、`withAnimation { delete }`
    // 三层动画时序会错开导致行错位。把 FetchRequest 的 animation 撤掉后，动画由 List + `withAnimation`
    // 两层控制就够，且 `ForEach(entries, id: \.objectID)` 也能恢复正常 identity。
    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false),
            NSSortDescriptor(keyPath: \DiaryEntry.id, ascending: false)
        ]
    ) private var entries: FetchedResults<DiaryEntry>
    
    // AI 服务从 SwiftUI Environment 注入，默认指向 `OpenAIService.shared`。
    // 生产零行为变化；测试 / Preview 里可以 `.environment(\.aiService, MockAIService())` 替换。
    @Environment(\.aiService) private var aiService
    // 语音转录（独立的服务，不和 AI 混在一起）。走 Lumory 后端代理 OpenAI gpt-4o-mini-transcribe。
    private let transcriber: TranscriberProtocol = OpenAITranscriber()
    
    // 导入服务（与 SettingsView 共享）
    @EnvironmentObject var importService: CoreDataImportService
    @EnvironmentObject var syncMonitor: CloudKitSyncMonitor
    
    // MARK: - 拆分出的 3 个 @Observable ViewModel
    // 原来 20+ 个 `@State` 按职责聚合到三个 VM(见 `Views/HomeView/`),每个 VM 字段变动只
    // 会失效该 VM 的 tracking,不再让无关字段(比如单字输入 vs 录音计时)互相触发整个 body
    // 重算。ObservableObject 类型(`AudioRecorder` / `AudioPlaybackController`)**没有**
    // 搬进 VM —— 原因见 `HomeRecordingViewModel.swift` 文件头说明。
    @State private var inputVM = HomeInputViewModel()
    @State private var recordingVM = HomeRecordingViewModel()
    /// Theme alias 软提示。observed 让 pending 列表变化时 banner 自动显隐。
    @ObservedObject private var aliasResolver = ThemeAliasResolver.shared
    @ObservedObject private var reminderRouter = ReminderNotificationRouter.shared
    @State private var photoVM = HomePhotoViewModel()

    @StateObject private var recorder = AudioRecorder()
    @StateObject private var audioPlaybackController = AudioPlaybackController() // 新的控制器
    @FocusState private var isInputFocused: Bool
    @State private var transcriptionGeneration = 0

    /// 草稿持久化 debounce —— 用户连打字时不每键写 AppGroup UserDefaults(plist encode + KVO +
    /// 跨进程 sync 累计开销),改成 500ms 静默后才写;scenePhase=.background 强 flush 一次防丢。
    @State private var draftSaveTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    private let cal = Calendar.current
    @Environment(\.colorScheme) private var colorScheme

    // 简化的语言检测
    private static var defaultAppLanguage: String {
        let currentLocale = Locale.current.identifier
        if currentLocale.hasPrefix("zh") {
            return "zh-Hans"
        } else {
            return "en"
        }
    }

    @AppStorage("appLanguage", store: AppGroup.userDefaults) private var appLanguage: String = HomeView.defaultAppLanguage

    // MARK: - View-level 路由 / 搜索 / 生命周期 state
    // 这些**留在 HomeView**:和 NavigationStack / sheet / .searchable 生命周期耦合,
    // 抽进 VM 反而要反向同步。
    @State private var selectedEntry: DiaryEntry?
    /// 现在直接驱动 `.sheet` —— 不再走自绘抽屉。
    @State private var isSettingsOpen: Bool = false
    @State private var isInsightsPresented: Bool = false
    @State private var shouldStartEditing: Bool = false
    // entryToDelete / showDeleteConfirmation 已移除 — 删除走 4 秒撤销 toast,不再有 alert。
    // 旧 contextMenu / swipeAction 直接调 deleteEntry(entry)。
    /// 冷启动首帧 @FetchRequest 尚未完成时为 false——避免 emptyState 闪一帧。
    @State private var hasLoadedOnce: Bool = false

    // Search state — 由系统 .searchable 托管输入；下面三个仅是结果与节流任务。
    @State private var searchQuery: String = ""
    @State private var searchResults: [DiaryEntry] = []
    @State private var searchTask: Task<Void, Never>?

    /// 滚动深度 —— 用户向下滚超过阈值才显示"回顶部"FAB,避免常态遮挡内容。
    @State private var showScrollToTop: Bool = false
    /// List 顶部锚点 id,FAB 用 ScrollViewProxy.scrollTo 跳回这里。
    private let topAnchorID = "__lumory_top__"
    @State private var composerFocusRequestID: UUID?

    var body: some View {
        iOSHomeView
    }
    
    // 主体:一个 NavigationStack + 系统 .sheet 承载设置。
    // 旧的自绘抽屉(ZStack + drag offset + mask 层)整个去掉,改成 iOS 26 标准 sheet,
    // 自动拿到玻璃过渡 / 多 detent / 系统手势下滑关闭。toolbar 上的设置钮触发。
    @ViewBuilder
    private var iOSHomeView: some View {
        mainContentView
            .sheet(isPresented: $isSettingsOpen) {
                SettingsView(isSettingsOpen: $isSettingsOpen)
                    .environmentObject(importService)
                    .environment(\.managedObjectContext, viewContext)
                    .lumorySheetDecoration()
            }
            .onChange(of: importService.isImporting) { _, isImporting in
                if isImporting {
                    isSettingsOpen = false
                } else {
                    #if canImport(UIKit)
                    HapticManager.shared.click()
                    #endif
                }
            }
            .onAppear {
                // AI 池可能已就绪（另一视图暖过）——进入首页立即尝试拿一条稳定值
                rollPlaceholderIfNeeded()
                handleReminderComposeFocusIfNeeded()
                // P1-Home-13 草稿 hydrate — 用户切微信回来 OK,但 App 被 OOM 杀掉就丢。
                // hydrate 时只在输入框为空才填(防止 onChange 触发后被反填)。
                if inputVM.inputText.isEmpty,
                   let draft = AppGroup.userDefaults.string(forKey: "lumory.home.draft.text"),
                   !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    inputVM.inputText = draft
                }
            }
            .task {
                // 防御:cold-launch 路径上 ReminderNotificationRouter 在 background queue
                // 收到 didReceive,然后 hop `Task { @MainActor }` 才 publish requestID。
                // 当前 .onAppear 通常先跑(此时 requestID 还 nil)→ 路由器 hop 完成 →
                // .onChange fire,正常工作。但如果 future 把 router publish 改成同步主线程,
                // requestID 已是非 nil 在 @ObservedObject 订阅前 set,.onChange 不会 fire,
                // 通知冷启动 focus 整个失效。.task 在 view 完整 wired 后跑 read-and-clear,
                // 让两条路径都至少能各跑一次,UUID 单次消费保证不重复 focus。
                handleReminderComposeFocusIfNeeded()
            }
            .onChange(of: reminderRouter.composeFocusRequestID) { _, requestID in
                if requestID != nil {
                    handleReminderComposeFocusIfNeeded()
                }
            }
            // **音频中断录音 → UI 接管**:电话 / Siri 打断录音时,AudioRecorder 自己 stopRecording 落盘 +
            // 透出 filename。HomeView 在这里接住,把段落塞进 audioRecordings 起转写,然后清 filename
            // (单次消费)。否则用户的录音段落留在磁盘但 UI 看不到,等于丢失。
            .onChange(of: recorder.interruptedRecordingFileName) { _, fileName in
                if let fileName {
                    processStoppedRecording(fileName: fileName, duration: recorder.duration)
                    recorder.interruptedRecordingFileName = nil
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .databaseRecreated)) { _ in
                Log.info("[HomeView] Database recreated notification received", category: .ui)
                handleDatabaseRecreation()
            }
            // 删除 confirmation 已移除 — 4 秒撤销 toast 替代。swipe / contextMenu 直接 deleteEntry。
    }
    
    @ViewBuilder
    private var mainContentView: some View {
            NavigationStack {
                VStack(spacing: 0) {
                    // 导入进度条
                    importProgressView

                    // 主列表：搜索中显示结果，否则显示常规时间线
                    // `.searchable` 把搜索字段托管到 NavigationStack 顶部；query 非空时切到结果列表。
                    if searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                        mainListContent
                    } else {
                        searchResultsList
                    }
                }
                .navigationTitle("")
                #if canImport(UIKit)
                .toolbarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            #if canImport(UIKit)
                            HapticManager.shared.click()
                            #endif
                            isSettingsOpen = true
                        } label: {
                            // 系统 SF Symbol "line.3.horizontal" —— iOS 26 toolbar 自动适配
                            // 玻璃 / 描边 / 触控反馈,无需自绘 RoundedRectangle 双线。
                            // 当 ThemeAliasResolver 有 high+medium pending 建议(且不在冷却期)时,
                            // 在按钮右上角叠一个红点,引导用户进 Settings 处理。
                            Image(systemName: "line.3.horizontal")
                                .overlay(alignment: .topTrailing) {
                                    if aliasResolver.redDotVisible {
                                        Circle()
                                            .fill(Color.red)
                                            .frame(width: 7, height: 7)
                                            .offset(x: 4, y: -3)
                                            .accessibilityLabel(NSLocalizedString("有待审建议", comment: "A11y red dot"))
                                    }
                                }
                        }
                        .accessibilityLabel(NSLocalizedString("设置", comment: "Settings"))
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            #if canImport(UIKit)
                            HapticManager.shared.click()
                            #endif
                            isInsightsPresented = true
                        } label: {
                            Image(systemName: "chart.xyaxis.line")
                        }
                        .accessibilityLabel(NSLocalizedString("洞察", comment: "Insights"))
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    // Theme alias 软提示。busy(录音 / 转写 / 发送 / 输入 spectrum 非 idle)时绝对不弹,
                    // 避免打断写作流。banner 内部还会自我节流(冷却期 / sessionDismissCount)。
                    ThemeAliasBanner(
                        resolver: aliasResolver,
                        isBusy: recorder.isRecording
                            || recordingVM.isTranscribing
                            || inputVM.isSending
                            || inputVM.spectrumDisplayState != .idle
                    )
                }
                .searchable(
                    text: $searchQuery,
                    placement: .toolbar,
                    prompt: NSLocalizedString("搜索日记", comment: "Search field prompt")
                )
                .onChange(of: searchQuery) { _, newValue in
                    scheduleInlineSearch(for: newValue)
                }
                .navigationDestination(item: $selectedEntry) { entry in
                    DiaryDetailView(entry: entry, startInEditMode: shouldStartEditing)
                        .onDisappear {
                            shouldStartEditing = false
                        }
                }
                .lumoryAdaptiveModal(isPresented: $isInsightsPresented) {
                    InsightsView()
                        .environment(\.managedObjectContext, viewContext)
                }
                .task {
                    // FetchRequest 此时已经第一轮完成，把 hasLoadedOnce 置位
                    // 让 empty state 从此时起才允许显示（避免冷启动闪一帧）。
                    await MainActor.run { hasLoadedOnce = true }
                    await loadContextPrompts()
                }
            }
    }
    
    @ViewBuilder
    private var importProgressView: some View {
        if importService.isImporting {
            HStack(spacing: 8) {
                BreathingDots()
                Text(NSLocalizedString("导入中", comment: "Importing"))
                    .font(.subheadline)
                    .foregroundColor(.accentColor)
            }
            .padding(.horizontal, 16)
        }
    }
    
    @ViewBuilder
    private var mainListContent: some View {
        ScrollViewReader { proxy in
            List {
                // 心情光谱滑块 - Mac优化布局
                moodSliderSection
                    .id(topAnchorID)

                // 输入框和录音功能容器 - Mac优化
                inputSection

                // 日记条目内容 Sections
                diaryContentSections
            }
            .optimizedList()
            // iOS 26 顶部边缘软渐隐 — 内容滚到顶下时贴玻璃感更自然,不再硬切到 navigation chrome。
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollDismissesKeyboard(.interactively)
            .refreshable {
                await triggerManualSync()
            }
            .onChange(of: composerFocusRequestID) { _, requestID in
                guard requestID != nil else { return }
                withAnimation(.smooth(duration: 0.35)) {
                    proxy.scrollTo(topAnchorID, anchor: .top)
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(260))
                    isInputFocused = true
                }
            }
            // 跟踪滚动 offset:超过 480pt 才弹 FAB,小幅滚动不打扰。
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y
            } action: { _, newY in
                let shouldShow = newY > 480
                if shouldShow != showScrollToTop {
                    withAnimation(.smooth(duration: 0.25)) {
                        showScrollToTop = shouldShow
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if showScrollToTop {
                    Button {
                        #if canImport(UIKit)
                        HapticManager.shared.click()
                        #endif
                        withAnimation(.smooth(duration: 0.45)) {
                            proxy.scrollTo(topAnchorID, anchor: .top)
                        }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.glass)
                    .padding(.bottom, 18)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .accessibilityLabel(NSLocalizedString("回到顶部", comment: "Scroll to top"))
                }
            }
        }
    }

    private func handleReminderComposeFocusIfNeeded() {
        guard let requestID = reminderRouter.consumeComposeFocusRequest() else { return }
        isSettingsOpen = false
        isInsightsPresented = false
        selectedEntry = nil
        searchQuery = ""
        composerFocusRequestID = nil
        Task { @MainActor in
            await Task.yield()
            composerFocusRequestID = requestID
        }
    }

    /// Pull-to-refresh：触发 CloudKit 同步 + 换一条占位语（从当前池里挑一个不同项）。
    /// AI 池的 `refreshIfNeeded` 走**独立 detached Task**，不塞进 refreshable 窗口——
    /// 否则如果指纹变了要调一次 gpt-5.5（~2-3s），用户会感觉"下拉卡好几秒"。
    /// AI 刷完之后下一次下拉/聚焦才用得上，体感上毫无损失。
    private func triggerManualSync() async {
        syncMonitor.forceSync()
        rollPlaceholderIfNeeded(force: true)
        Task.detached(priority: .utility) {
            await PromptSuggestionEngine.shared.refreshIfNeeded()
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
    }
    
    @ViewBuilder
    private var moodSliderSection: some View {
        VStack(alignment: .center, spacing: 4) {
            MoodSpectrumBar(
                moodValue: inputVM.revealedMood ?? inputVM.moodValue,
                displayState: inputVM.spectrumDisplayState
            )
            .frame(maxWidth: .infinity)
            .frame(height: 32)
        }
        .frame(height: 80)
        .padding(.horizontal, 16)
        .zIndex(inputVM.spectrumDisplayState == .revealed ? 100 : 0)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    }
    
    @ViewBuilder
    private var inputSection: some View {
        // GlassEffectContainer 包 outer card glass + inner send button(.glassProminent),
        // SwiftUI 合并渲染,给 .glassProminent 必要的 surface 上下文。
        // 不保证视觉上有明显玻璃感 —— .glassProminent 在没有可折射 backdrop 时可能就是
        // tinted 色块,原生就这样,算了。
        GlassEffectContainer(spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                textInputArea
                recordingsSection
                if !photoVM.selectedImageItems.isEmpty { photosSection }
                if photoVM.compressionFailureCount > 0 { compressionFailureBanner }
                // 卡内分隔线:把"内容区"和"动作区(工具栏)"隔开。
                // P1-Dark-3 用 .separator system color — 暗色下系统自动算到约 0.20 alpha,
                // 之前 primary.opacity(0.06) 在 OLED 暗色基本不可见,分隔线消失。
                Capsule()
                    .fill(Color(.separator))
                    .frame(height: 1)
                    .padding(.horizontal, 4)
                // 工具栏:photo / mic / 计时 / 发送。
                HStack(spacing: 18) {
                    keyboardActionsBar
                }
                .padding(.top, 2)
            }
            .padding(16)
            .liquidGlassCard(cornerRadius: 22)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 28, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var textInputArea: some View {
        // 原生 SwiftUI TextField(axis:.vertical),不再走 UIKit 桥也不挂 .toolbar(.keyboard) ——
        // 工具栏挪进了输入卡内部(横线下方),始终可见,不再依赖 keyboard accessory 协商。
        // Prompt 颜色按色彩模式分:亮色 secondary 0.50(浅),暗色实 .secondary。
        let promptColor: Color = colorScheme == .dark
            ? Color.secondary
            : Color.secondary.opacity(0.50)

        // `@Observable` VM 拿 Binding 需要 `@Bindable` shadow —— iOS 17+ 标准写法。
        @Bindable var inputVM = inputVM

        TextField(
            "",
            text: $inputVM.inputText,
            prompt: Text(inputPlaceholder)
                .font(.system(size: 16))
                .foregroundColor(promptColor),
            axis: .vertical
        )
        .lineLimit(6...20)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(Color.clear)
        .font(.system(size: 17))
        .focused($isInputFocused)
        // P1-Home-12 键盘 toolbar 加"完成"按钮 — 中文拼音输入法 candidate bar 占额外 36pt,
        // 用户要看下方滚动区必须先关键盘。"keyboard.chevron.compact.down" 是系统标准 dismiss 图标。
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button {
                    isInputFocused = false
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                }
                .accessibilityLabel(NSLocalizedString("收起键盘", comment: "Dismiss keyboard"))
            }
        }
        .onChange(of: inputVM.inputText) { _, newValue in
            // P1-Home-13 草稿持久化 — 用户切微信回来 OK,但 App 被 OOM 杀掉就丢了。
            // 写到 AppGroup defaults 防进程被杀,但**500ms debounce**:用户每键写一次会让
            // plist encode + KVO + AppGroup 跨进程 sync 累计可观,scrollback 时尤其明显;
            // 改成静默 500ms 后再写,scenePhase=.background 时强 flush(见下面的 onChange)。
            draftSaveTask?.cancel()
            draftSaveTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                Self.persistDraft(newValue)
            }

            // spectrum state 切换是即时 UI 反馈,不能 debounce
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasContent = !trimmed.isEmpty
            if hasContent && inputVM.spectrumDisplayState == .idle {
                withAnimation(.easeInOut(duration: 1.0)) {
                    inputVM.spectrumDisplayState = .analyzing
                }
            } else if !hasContent && inputVM.spectrumDisplayState == .analyzing {
                withAnimation(.easeInOut(duration: 0.8)) {
                    inputVM.spectrumDisplayState = .idle
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // 进 background 时 cancel debounce + 同步 flush 草稿。
            // 否则用户输入完立刻锁屏 / 切走,iOS 5s background grace 内 task 可能没跑完,丢草稿。
            if newPhase == .background {
                draftSaveTask?.cancel()
                Self.persistDraft(inputVM.inputText)
            }
        }
    }

    /// 草稿写盘的单点入口。空白 → remove key,非空 → set。
    private static func persistDraft(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            AppGroup.userDefaults.removeObject(forKey: "lumory.home.draft.text")
        } else {
            AppGroup.userDefaults.set(value, forKey: "lumory.home.draft.text")
        }
    }
    
    @ViewBuilder
    private var recordingsSection: some View {
        // alert(isPresented:) 要 Binding<Bool>,走 `@Bindable` shadow。
        @Bindable var recordingVM = recordingVM
        VStack(alignment: .leading, spacing: 8) {
            if let rec = recordingVM.audioRecordings.first {
                RecordingRow(
                    recording: rec,
                    controller: audioPlaybackController,
                    isTranscribing: recordingVM.isTranscribing,
                    onPlay: { playAudio(fileName: rec.fileName) },
                    onDelete: {
                        recordingVM.deleteTarget = rec.fileName
                        recordingVM.showingDeleteAlert = true
                    }
                )
                if let failure = recordingVM.transcriptionError {
                    transcriptionErrorBanner(failure: failure)
                }
                if let playbackError = recordingVM.audioPlaybackError {
                    audioPlaybackErrorBanner(message: playbackError)
                }
            }
        }
        .frame(height: recordingVM.audioRecordings.isEmpty ? 0 : nil)
        .alert(NSLocalizedString("删除录音？", comment: "Delete recording confirmation"), isPresented: $recordingVM.showingDeleteAlert) {
            Button(NSLocalizedString("删除", comment: "Delete button"), role: .destructive) {
                if let target = recordingVM.deleteTarget {
                    deleteRecording(target)
                }
            }
            Button(NSLocalizedString("取消", comment: "Cancel button"), role: .cancel) {
                recordingVM.deleteTarget = nil
            }
        }
    }

    /// 音频播放失败 inline banner。playAudio 的 onPlayError 把文案塞 VM,这里渲染。点 X 清。
    @ViewBuilder
    private func audioPlaybackErrorBanner(message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.footnote)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button {
                recordingVM.audioPlaybackError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(NSLocalizedString("关闭", comment: "Dismiss"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    /// 图片压缩 / 加载失败 inline banner。9 张选 7 成功 → "2 张图片处理失败" 提醒,跟 transcription
    /// banner 同 visual idiom。用户点 "知道了" 清。photoVM.compressionFailureCount = 0 不显示。
    @ViewBuilder
    private var compressionFailureBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.footnote)
            Text(String(
                format: NSLocalizedString("有 %d 张图片处理失败", comment: "Photo compression failure banner"),
                photoVM.compressionFailureCount
            ))
            .font(.footnote)
            .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button {
                photoVM.compressionFailureCount = 0
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(NSLocalizedString("关闭", comment: "Dismiss"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func transcriptionErrorBanner(failure: TranscriptionFailure) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.footnote)
            VStack(alignment: .leading, spacing: 4) {
                Text(transcriptionErrorMessage(for: failure))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if failure.isRetryable {
                    Button {
                        retryTranscription()
                    } label: {
                        Text(NSLocalizedString("transcription.retry", comment: "Retry transcription button"))
                            .font(.footnote.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func transcriptionErrorMessage(for failure: TranscriptionFailure) -> String {
        switch failure {
        case .networkFailed:
            return NSLocalizedString("transcription.error.network", comment: "Network failure during transcription")
        case .audioTooLarge:
            return NSLocalizedString("transcription.error.audioTooLarge", comment: "Audio file too large")
        case .audioReadFailed:
            return NSLocalizedString("transcription.error.audioRead", comment: "Could not read audio file")
        case .serverError(let code):
            return String(
                format: NSLocalizedString("transcription.error.server", comment: "Transcription server error"),
                code
            )
        case .sharedSecretMissing:
            return NSLocalizedString("transcription.error.config", comment: "App config error")
        }
    }
    
    private func deleteRecording(_ target: String) {
        if audioPlaybackController.currentPlayingFileName == target {
            audioPlaybackController.stopPlayback(clearCurrentFile: true)
        }
        // **隐私关键**:删除录音必须同时取消正在跑的转写上传 —— 否则用户删了录音,
        // 25 MB 的 multipart 还在飞往 OpenAI。Task.cancel 会让 URLSession 中止上传,
        // OpenAITranscriber 里 catch URLError(.cancelled) 走通用网络错误分支(无害,
        // 因为 audioRecordings 已清空,banner 不会渲染)。
        if recordingVM.currentAudioFileName == target {
            transcriptionGeneration &+= 1
            recordingVM.transcriptionTask?.cancel()
            recordingVM.transcriptionTask = nil
            recordingVM.isTranscribing = false
        }
        deleteAudioFileFromDocuments(target)
        // 删除录音时使用动画
        withAnimation(AnimationConfig.stiffSpring) {
            recordingVM.audioRecordings.removeAll { $0.fileName == target }
        }
        // 清掉对已删除文件的悬空引用，否则再发送会把不存在的文件名落库
        if recordingVM.currentAudioFileName == target {
            recordingVM.currentAudioFileName = nil
        }
        // 录音被删了,挂着的转写 / 播放错误 banner 也没意义了。
        recordingVM.transcriptionError = nil
        recordingVM.audioPlaybackError = nil
        recordingVM.deleteTarget = nil
    }

    private func deleteAudioFileFromDocuments(_ fileName: String) {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let audioURL = documentsURL.appendingPathComponent(fileName)
        do {
            try FileManager.default.removeItem(at: audioURL)
        } catch CocoaError.fileNoSuchFile {
            // already gone, nothing to do
        } catch {
            Log.error("[HomeView] 删除音频文件出错 (\(fileName)): \(error.localizedDescription)", category: .ui)
        }
    }
    
    private func loadPhotosWithCompression(_ items: [PhotosPickerItem]) async {
        // 新一轮 pick 开始就清掉旧的失败 banner,不让用户再选时还看到"上次失败 3 张"。
        // 真正的 failed count 在末尾根据本轮结果重新写入。
        photoVM.compressionFailureCount = 0
        // 关键改动 1:每个 item 走 Task.detached 跳到后台 actor —— 之前 addTask 继承父
        // MainActor,compressImage 里的 UIImage 解码 + JPEG 重编码全卡在主线程上,选 9 张图
        // 直接掉帧到底。detached 之后 UI 不再被压死,选完照片到出现缩略图之间也没有阻塞。
        //
        // 关键改动 2:**保序 + 配对收集**。每个 (PhotosPickerItem, Data?) 一起收回来,
        // 失败的丢弃但**两边一起丢弃**。之前只 compactMap selectedImages,
        // selectedPhotos 没动 → 长度不一致 → 删除时按 selectedImageItems 的 idx
        // 然后用同 idx 删 selectedPhotos 删错。F2 fix:同步重建 selectedPhotos。
        var indexed: [(Int, Data?)] = []

        await withTaskGroup(of: (Int, Data?).self) { group in
            for (idx, item) in items.enumerated() {
                group.addTask {
                    guard let data = try? await item.loadTransferable(type: Data.self) else {
                        return (idx, nil)
                    }
                    let compressed = await Task.detached(priority: .userInitiated) {
                        await data.compressImage(maxSizeKB: 500, maxDimension: 1024)
                    }.value
                    return (idx, compressed)
                }
            }
            for await result in group {
                if Task.isCancelled { return }   // F1:任务被取消立即收手
                indexed.append(result)
            }
        }

        // F1:任务被取消则不更新 state,让新任务去主导。
        if Task.isCancelled { return }

        // 按 idx 排序,只保留压缩成功的 (item, data) 对。
        let successful: [(PhotosPickerItem, Data)] = indexed
            .sorted { $0.0 < $1.0 }
            .compactMap { i, data -> (PhotosPickerItem, Data)? in
                guard let data else { return nil }
                return (items[i], data)
            }

        let prunedItems = successful.map(\.0)
        let imageItems = successful.map { HomePhotoViewModel.SelectedImage(data: $0.1) }
        // **失败提示** —— 9 张选 7 张成功 → 之前 silently drop 2 张,用户以为都加了。把失败数推进 VM
        // 让 banner 显示;0 时不显示。
        let failedCount = items.count - successful.count
        photoVM.compressionFailureCount = failedCount

        await MainActor.run {
            photoVM.selectedImageItems = imageItems
            // F2:把 selectedPhotos 也剪枝到只剩压缩成功的 items,保证两边长度严格对齐。
            // 等值检查避免触发自身的 .onChange 死循环 —— PhotosPickerItem 是 Equatable。
            if photoVM.selectedPhotos != prunedItems {
                photoVM.suppressNextPhotoSelectionReload = true
                photoVM.selectedPhotos = prunedItems
            }
            Log.info("[HomeView] Total compressed images: \(photoVM.selectedImageItems.count)", category: .ui)
        }
    }

    private struct SendSnapshot {
        let text: String
        let audio: String?
        // 失败回滚时,Recording 要带回真实时长,不然 audio row 会显示 0:00
        // 即便文件还在。原始 Recording.duration 来自 recorder.duration,这里同步快照下来。
        let audioDuration: TimeInterval
        let images: [Data]
        let photos: [PhotosPickerItem]
        let mood: Double
    }

    @MainActor
    private func handleSendAction() {
        // 重发双点防护：`hasSendableContent` 已包含 `!isSending`，但用户触到第二次 tap 的极端
        // race（SwiftUI tap dispatch + `isSending` 还没 flip）在 struct-copy 语义下仍可能穿透。
        // 这里再加一层 synchronous guard 作为底线：同一个 HomeView 实例里永远最多一个发送在跑。
        guard !inputVM.isSending else {
            Log.info("[HomeView SendButton] 已有发送在跑，忽略重复 tap", category: .ui)
            return
        }
        // **必须**同步置位。以前 `isSending = true` 写在下面 `Task { MainActor.run { ... } }`
        // 里，两次极速 tap 之间的 SwiftUI dispatch 窗口（第一次 Task 尚未跑进 MainActor.run）
        // 内，第二次 tap 照样能过上面的 guard —— 两条日记双发落库。
        // handleSendAction 由 Button action 触发，天然在主线程，VM 字段同步写合法。
        inputVM.isSending = true
        // 之前发送有三次 haptic:button click + mood reveal + save success → 用户感觉太抖。
        // 只保留**保存完成**那一次(行末 .completed 状态时发,跟"已记录"toast 一起),
        // 把 click 删掉(.glassProminent 视觉高亮已经够) + mood reveal 也删(在 MoodSpectrumBar)。
        Task {
            // 1. 发送开始：snapshot 输入 + 立即清空 UI，避免 2 秒动画窗口内继续打字造成
            //    情绪分析文本与落库文本错位，或新输入被后续清空吞掉。
            let snapshot = await MainActor.run { () -> SendSnapshot in
                let captured = SendSnapshot(
                    text: inputVM.inputText,
                    audio: recordingVM.currentAudioFileName,
                    audioDuration: recordingVM.audioRecordings.first?.duration ?? 0,
                    images: photoVM.selectedImages,
                    photos: photoVM.selectedPhotos,
                    mood: inputVM.moodValue
                )

                Log.info("[HomeView SendButton] Starting send action", category: .ui)
                withAnimation(AnimationConfig.standardResponse) {
                    inputVM.sendButtonState = .sending
                    // isSending 已在 Task 外同步置 true，这里不重复写。
                    inputVM.spectrumDisplayState = .analyzing  // 光谱进入分析状态（呼吸效果）
                }
                withAnimation(AnimationConfig.fastResponse) {
                    inputVM.inputText = ""
                    recordingVM.currentAudioFileName = nil
                    recordingVM.audioRecordings.removeAll()
                    photoVM.selectedImageItems.removeAll()
                    photoVM.selectedPhotos.removeAll()
                }
                hideKeyboard()
                // 发送完成：换一条占位语给用户新的灵感
                rollPlaceholderIfNeeded(force: true)

                return captured
            }

            let textToSend = snapshot.text
            let audioToSend = snapshot.audio
            let audioDurationToRestore = snapshot.audioDuration
            let imagesToSend = snapshot.images
            let photosToSend = snapshot.photos
            var finalMoodValue = snapshot.mood

            // 2. 执行AI情绪分析（基于 snapshot 的文本，只调用一次）
            let textToAnalyze = textToSend.trimmingCharacters(in: .whitespacesAndNewlines)

            if !textToAnalyze.isEmpty {
                Log.info("[HomeView SendButton] Analyzing mood for text", category: .ui)
                let mood = await aiService.analyzeMood(text: textToAnalyze)
                finalMoodValue = mood
                await MainActor.run {
                    inputVM.moodValue = mood
                }
            }

            // 3. 显示情绪反馈 → spectrum揭示结果（光点聚焦动画）
            await MainActor.run {
                withAnimation(AnimationConfig.smoothTransition) {
                    inputVM.revealedMood = finalMoodValue
                    inputVM.sendButtonState = .moodRevealing
                    inputVM.spectrumDisplayState = .revealed  // 光谱显示结果
                }
                Log.info("[HomeView SendButton] Mood revealed: \(finalMoodValue)", category: .ui)
            }

            // 4. 把落库和 2 秒光谱动画并行跑 —— 保存不再被动画白白拖 2 秒，
            //    动画也不会被慢网络/磁盘 I/O 拖过 2 秒。
            let saveTask = Task {
                await addEntry(text: textToSend, audioFileName: audioToSend, moodValue: finalMoodValue, images: imagesToSend)
            }

            try? await Task.sleep(nanoseconds: 2_000_000_000)

            // 起手语刷新是给"下一条"用的，完全不必卡住当前发送的收尾动画。
            Task { await loadContextPrompts() }

            // 等落库真正完成再亮"完成"状态，避免按钮骗人。
            let didSave = await saveTask.value
            guard didSave else {
                await MainActor.run {
                    withAnimation(AnimationConfig.smoothTransition) {
                        inputVM.inputText = textToSend
                        inputVM.sendButtonState = .idle
                        inputVM.isSending = false
                        inputVM.revealedMood = nil
                        inputVM.spectrumDisplayState = .idle
                        recordingVM.currentAudioFileName = audioToSend
                        recordingVM.audioRecordings = audioToSend.map {
                            [Recording(id: $0, fileName: $0, duration: audioDurationToRestore)]
                        } ?? []
                        photoVM.selectedImageItems = imagesToSend.map { HomePhotoViewModel.SelectedImage(data: $0) }
                        photoVM.selectedPhotos = photosToSend
                    }
                }
                return
            }

            // 7. 完成动画 → 重置状态
            await MainActor.run {
                withAnimation(AnimationConfig.smoothTransition) {
                    inputVM.sendButtonState = .completed
                    inputVM.isSending = false
                }
                // P0-2 send 完成成功反馈 — 之前完全没 haptic,跟"删 / 存"高频动作统一。
                #if canImport(UIKit)
                HapticManager.shared.notification(.success)
                #endif
                LumoryToastCenter.shared.show(
                    NSLocalizedString("已记录", comment: "Toast after diary entry saved"),
                    severity: .success
                )
            }

            try? await Task.sleep(nanoseconds: 300_000_000)

            await MainActor.run {
                withAnimation(AnimationConfig.smoothTransition) {
                    inputVM.sendButtonState = .idle
                    inputVM.revealedMood = nil
                    inputVM.spectrumDisplayState = .idle  // 光谱重置
                }
            }

            Log.info("[HomeView SendButton] Send action completed", category: .ui)
        }
    }
    
    @ViewBuilder
    private var photosSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "photo.stack")
                    .foregroundColor(.blue)
                Text(photoCountLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // 用压缩完成时分配的 UUID 作 id。不要用 Data 自身作 id:
                    // SwiftUI 每次 diff 都会 hash 图片 payload,选 9 张图后输入会被拖慢。
                    ForEach(photoVM.selectedImageItems) { item in
                        InputPhotoThumbnail(
                            data: item.data,
                            dataID: item.id,
                            onRemove: {
                                withAnimation(AnimationConfig.stiffSpring) {
                                    // 按稳定 id 查当前 index —— closure 捕获的 index 在
                                    // selectedImageItems 被其他事件改过后会过期。
                                    if let idx = photoVM.selectedImageItems.firstIndex(where: { $0.id == item.id }) {
                                        photoVM.selectedImageItems.remove(at: idx)
                                        if idx < photoVM.selectedPhotos.count {
                                            photoVM.selectedPhotos.remove(at: idx)
                                        }
                                    }
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal, 4)
            }
            .frame(height: 88)
        }
    }
    
    // MARK: - Core Data 操作
    
    private func addEntry(text: String, audioFileName: String?, moodValue: Double? = nil, images: [Data] = []) async -> Bool {
        // 立即保存日记（不等待标题生成），标题异步生成
        let finalMoodValue = moodValue ?? 0.5
        let entryID = UUID()
        var savedEntryID: UUID?
        var didSave = false

        // 把磁盘 I/O、CloudKit blob 编码全部挪到非主线程，主线程只做 Core Data 字段赋值 + save。
        // 之前这些都挤在 `await MainActor.run { ... }` 里，附件多一点 UI 就会卡。
        async let preparedAudio: String? = Self.persistAudioOffMain(audioFileName: audioFileName)
        async let preparedImages: [String] = Self.persistImagesOffMain(images: images, entryID: entryID)
        async let preparedSyncBlob: Data? = Self.encodeImagesForSyncOffMain(images: images)

        let (audioName, imageFileNames, syncBlob) = await (preparedAudio, preparedImages, preparedSyncBlob)

        await MainActor.run {
            let newEntry = DiaryEntry(context: viewContext)
            newEntry.id = entryID
            newEntry.date = Date()
            newEntry.text = text
            newEntry.moodValue = finalMoodValue
            newEntry.summary = nil  // 标题稍后异步生成
            newEntry.recomputeWordCount()  // Phase 3: 本地计算，供统计使用

            if let audioName = audioName {
                newEntry.audioFileName = audioName
            }

            if !imageFileNames.isEmpty {
                newEntry.imageFileNames = imageFileNames.joined(separator: ",")
                Log.info("[HomeView addEntry] Set imageFileNames: \(newEntry.imageFileNames ?? "")", category: .ui)
            }
            if let syncBlob = syncBlob {
                newEntry.imagesData = syncBlob
            }

            do {
                try viewContext.save()
                savedEntryID = entryID
                didSave = true
                Log.info("[HomeView] 日记已保存，标题稍后生成", category: .ui)
            } catch {
                Log.error("[HomeView] 保存日记失败: \(error)", category: .ui)
                // 已落盘的 image 文件孤儿清理 —— entry save 失败时这些文件已经被 persistImagesOffMain
                // 写到 Documents/LumoryImages,无人引用就是 storage leak,长期累积。best-effort 删,失败静默。
                // (audio 暂不清:persistAudioOffMain 已把本地副本搬到 iCloud,iCloud 路径由 entry.audioURL 三层
                // fallback 解析,这个 catch 分支拿不到 entry 实例 / 也不该重新做一遍 lookup,留给后续策略处理。)
                for fileName in imageFileNames {
                    try? DiaryEntry.deleteImageFromDocuments(fileName)
                }
            }
        }

        guard didSave else { return false }

        // 智能 reminder reschedule:任何成功 save(含纯录音 / 纯图片 entry)都可能 fulfill
        // 当前固定周期(cycle-based),在 !text.isEmpty 之外触发。requestReschedule 是
        // task cancel + replace,多入口并发安全。
        ReminderService.shared.requestReschedule()

        // Streak milestone 庆祝。fire-and-forget — 内部跑后台 fetch 算 streak,命中 7/14/30/60/100/(+100)
        // 且之前没庆祝过 → set pendingMilestone,ChronoteApp ZStack 顶层 overlay 自动渲染。
        // 用最新 entry 的 mood 作 overlay 配色。
        StreakMilestoneService.shared.evaluateAfterSave(
            persistence: PersistenceController.shared,
            latestEntryMood: moodValue ?? 0.5
        )

        // 异步生成摘要、主题、embedding（Phase 3 × Phase 2 融合）
        // **Stale-write guard**：用户可能在 AI 请求返回前就打开这条日记编辑了，
        // 那时 `entry.text` 已经是 v2，但我们手上的结果是基于 v1 算出来的——
        // 直接写回就把 v2 的 summary/themes/embedding 污染成 v1 的。
        // 比较 `entry.wrappedText == text`（我们入参的快照），不匹配就丢弃结果，
        // 等 DiaryDetailView.refreshAIIndex 按 v2 重算。
        if let entryID = savedEntryID, !text.isEmpty {
            let textSnapshot = text
            Task {
                async let summaryTask = aiService.summarize(text: textSnapshot)
                async let themesTask = aiService.extractThemes(text: textSnapshot)
                async let embeddingTask = aiService.embed(text: textSnapshot)
                let (summary, themes, embedding) = await (summaryTask, themesTask, embeddingTask)

                // 把"writeback 是否真的提交了"flag 跨出 MainActor.run —— 关键!
                // 否则即使 stale guard 丢弃了写入,我们仍会把 themes 喂给 alias judge,
                // 给一个**根本没保存这些 themes 的 entry** 入队 alias 建议(用户后续看到的
                // "「X」是不是 Y?" 是基于 ghost 数据生成的,极易 confusing)。
                let didCommitThemes: Bool = await MainActor.run {
                    let fetchRequest: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "id == %@", entryID as NSUUID)
                    guard let entry = try? viewContext.fetch(fetchRequest).first else { return false }
                    // 跟 DiaryDetailView.refreshAIIndex 同一套 stale-write guard：
                    // 当前 entry.text 已经被更新就跳过这次写入。
                    guard entry.wrappedText == textSnapshot else {
                        Log.info("[HomeView] 文本已被更新，丢弃 stale AI 结果（v1 不覆盖 v2）", category: .ai)
                        return false
                    }
                    entry.summary = summary
                    entry.setThemes(themes)
                    if let vector = embedding {
                        entry.setEmbedding(vector)
                    }
                    do {
                        try viewContext.save()
                        Log.info("[HomeView] 摘要+主题+索引已更新: themes=\(themes.count), hasEmbedding=\(embedding != nil)", category: .ai)
                        return true
                    } catch {
                        Log.error("[HomeView] AI 写回保存失败: \(error)", category: .ai)
                        return false
                    }
                }

                // Theme alias judge —— 仅在 themes 真的写到 entry 上时才跑。否则 alias 建议是
                // 基于 ghost 数据(参考 codex review)。
                if didCommitThemes, !themes.isEmpty {
                    await ThemeAliasJudgeService.shared.judgeAfterWrite(
                        entryID: entryID,
                        newTags: themes
                    )
                }
            }
        }
        return true
    }

    // MARK: - addEntry helpers (off-main I/O)

    /// 在后台线程把本地录音拷贝到 iCloud 容器，并删掉本地副本。返回最终落库用的文件名。
    /// 非 @MainActor：磁盘读写、FileManager、Data(contentsOf:) 都没必要卡主线程。
    private static func persistAudioOffMain(audioFileName: String?) async -> String? {
        guard let audioFileName = audioFileName else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> String? in
            let localURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(audioFileName)

            if FileManager.default.fileExists(atPath: localURL.path),
               let audioData = try? Data(contentsOf: localURL),
               let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.Mingyi.Lumory") {
                let audioDir = iCloudURL.appendingPathComponent("Documents/LumoryAudio")
                let iCloudAudioURL = audioDir.appendingPathComponent(audioFileName)
                do {
                    if !FileManager.default.fileExists(atPath: audioDir.path) {
                        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true, attributes: nil)
                    }
                    try audioData.write(to: iCloudAudioURL, options: .atomic)
                    try? FileManager.default.removeItem(at: localURL)
                    Log.info("[HomeView] Saved audio to iCloud: \(audioFileName)", category: .ui)
                } catch {
                    Log.error("[HomeView] Audio iCloud write failed, keeping local copy \(audioFileName): \(error)", category: .ui)
                }
            }

            return audioFileName
        }.value
    }

    private static func resolvedAudioURL(fileName: String) -> URL? {
        let fm = FileManager.default
        if let iCloudURL = fm.url(forUbiquityContainerIdentifier: "iCloud.com.Mingyi.Lumory") {
            let audioURL = iCloudURL
                .appendingPathComponent("Documents/LumoryAudio")
                .appendingPathComponent(fileName)
            if fm.fileExists(atPath: audioURL.path) { return audioURL }
        }

        let documentsURL = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localAudioURL = documentsURL
            .appendingPathComponent("LumoryAudio")
            .appendingPathComponent(fileName)
        if fm.fileExists(atPath: localAudioURL.path) { return localAudioURL }

        let legacyURL = documentsURL.appendingPathComponent(fileName)
        if fm.fileExists(atPath: legacyURL.path) { return legacyURL }

        return nil
    }

    /// 后台线程把图片逐一落到 documents 目录并返回文件名列表。
    private static func persistImagesOffMain(images: [Data], entryID: UUID) async -> [String] {
        guard !images.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) { () -> [String] in
            var names: [String] = []
            names.reserveCapacity(images.count)
            for (index, imageData) in images.enumerated() {
                let fileName = "img_\(entryID.uuidString)_\(index).jpg"
                do {
                    let saved = try DiaryEntry.saveImageToDocuments(imageData, fileName: fileName)
                    names.append(saved)
                    Log.info("[HomeView addEntry] Saved image \(index + 1)/\(images.count): \(saved)", category: .ui)
                } catch {
                    Log.error("[HomeView] 保存图片失败: \(error)", category: .ui)
                }
            }
            return names
        }.value
    }

    /// 后台线程把已压缩的图片 NSKeyedArchiver 编码成 Data，落库时直接赋给 `imagesData`。
    /// 替代原来 `saveImagesForSync`（同步版）在 MainActor 里跑的重活。
    private static func encodeImagesForSyncOffMain(images: [Data]) async -> Data? {
        guard !images.isEmpty else { return nil }
        do {
            let encoded = try NSKeyedArchiver.archivedData(withRootObject: images, requiringSecureCoding: true)
            Log.info("[HomeView] Encoded \(images.count) images for sync, total size: \(encoded.count) bytes", category: .ui)
            return encoded
        } catch {
            Log.error("[HomeView] 图片编码失败: \(error)", category: .ui)
            return nil
        }
    }

    // 时间线列表：竖直连接线 + 彩色节点 + 卡片。不再按日分组 —— 每行自带相对日期标签。
    @ViewBuilder
    private var diaryContentSections: some View {
        if entries.isEmpty {
            // 冷启动首帧 `@FetchRequest` 还没把 SQLite 读完就返空，emptyState 会闪一下。
            // 等 `hasLoadedOnce` 置位后（.onAppear 里设）再允许显示空态。
            if hasLoadedOnce {
                emptyStateSection
            }
        } else {
            entriesListSection
        }
    }

    @ViewBuilder
    private var emptyStateSection: some View {
        Section {
            // 用项目共享的 EmptyStateView 替代单行 placeholder —— 第一次打开 App 看到的就是这块,
            // 给图标 + 标题 + 提示三层信息,引导用户走录音 / 文字两条入口。
            EmptyStateView(
                systemImage: "book.closed",
                title: NSLocalizedString("暂无日记，快去记录吧～", comment: "Empty timeline title"),
                // P1-Home-7 修正"长按麦克风"→"或点下麦克风" — 当前实际交互是 tap toggle 不是
                // hold-to-talk(P1-Home-2 落地后再改回长按文案)。让首次用户跟着提示能真触发录音。
                message: NSLocalizedString("点下方输入框写一句,或点下麦克风录一段语音。",
                                            comment: "Empty timeline subtitle")
            )
            .frame(minHeight: 320)
        }
        .listRowSeparator(.hidden)
        .listSectionSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var entriesListSection: some View {
        // 用 objectID 作稳定 identity，List 能识别单行 delete 播原生 row-removal 动画；
        // 同时 `@FetchRequest` 已关 animation，`deleteEntry` 里的 `withAnimation` 独立生效，
        // 不再和 FetchRequest 内建动画打架。500 条日记 shuffle 时子视图 @State（如图片 thumbnail 解码）
        // 也不会因索引重排而整列重建。
        let firstID = entries.first?.objectID
        let lastID = entries.last?.objectID
        ForEach(entries, id: \.objectID) { entry in
            timelineRow(
                entry: entry,
                isFirst: entry.objectID == firstID,
                isLast: entry.objectID == lastID
            )
        }
    }

    @ViewBuilder
    private func timelineRow(entry: DiaryEntry, isFirst: Bool, isLast: Bool) -> some View {
        Button {
            // P1-T5 主入口 haptic — 日记卡 tap 是高频主入口,之前完全没反馈 vs 二级主题卡 tap
            // 反而有,主次颠倒。规则见 CLAUDE.md:自定义 Button-shape 进 detail 卡 = .light impact。
            #if canImport(UIKit)
            HapticManager.shared.impact(.light)
            #endif
            // 原先只设 selectedEntry，若上次长按"编辑"后 onDisappear 还没跑完就再次点击，
            // `shouldStartEditing` 残留 true，这次普通点击也会进编辑模式。显式清掉。
            shouldStartEditing = false
            selectedEntry = entry
        } label: {
            timelineCard(for: entry)
                .contentShape(
                    .contextMenuPreview,
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .padding(.bottom, 10)
                .contentShape(Rectangle())
        }
        // P1-T6 PressableScaleButtonStyle — 主时间线日记卡之前 plain,无任何按下反馈。
        // 规则见 CLAUDE.md:自定义 Button-shape 卡片(日记 / 主题 / Settings 自定义 row)统一套这个。
        .buttonStyle(PressableScaleButtonStyle())
        .contextMenu {
            Button {
                shouldStartEditing = true
                selectedEntry = entry
            } label: {
                Label(NSLocalizedString("编辑", comment: "Edit"), systemImage: "pencil")
            }
            // 删除直接执行 — 4 秒撤销 toast 替代了 confirmation alert。
            Button(role: .destructive) {
                deleteEntry(entry)
            } label: {
                Label(NSLocalizedString("删除", comment: "Delete"), systemImage: "trash")
            }
        } preview: {
            DiaryPreviewView(entry: entry, appLanguage: appLanguage) {
                shouldStartEditing = false
                selectedEntry = entry
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            // 删除直接执行 — 4 秒撤销 toast 替代了 confirmation alert。
            Button(role: .destructive) {
                deleteEntry(entry)
            } label: {
                Label(NSLocalizedString("删除", comment: "Delete"), systemImage: "trash")
            }
            Button {
                HapticManager.shared.click()
                shouldStartEditing = true
                selectedEntry = entry
            } label: {
                Label(NSLocalizedString("编辑", comment: "Edit"), systemImage: "pencil")
            }
            .tint(.blue)
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }

    @ViewBuilder
    private func timelineCard(for entry: DiaryEntry) -> some View {
        let cornerRadius: CGFloat = 16
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(relativeDateLabel(entry.date))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.primary)
                    .textCase(.uppercase)
                    .tracking(0.4)
                Text(timeLabel(entry.date))
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.7))
                Spacer(minLength: 0)
            }
            if let summary = entry.summary, !summary.isEmpty {
                Text(cleanedSummary(summary))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(2)
            }
            if let text = entry.text, !text.isEmpty {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .lineSpacing(2)
            }
        }
        .padding(.init(top: 12, leading: 18, bottom: 12, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard(cornerRadius: cornerRadius, interactive: true)
        .moodAccentBar(entry.moodColor, cornerRadius: cornerRadius)
        .accessibilityElement(children: .combine)
    }

    // 每行都 new 一个 DateFormatter 是主线程热路径浪费——List 每次 diff 刷新，N 行 × 2 个格式
    // = 2N 次 alloc + ICU 查表。 weekday / monthDay 按 `appLanguage` 锁定语言,走
    // `LumoryDateFormatters` 的共享 cache;HH:mm 是 locale-independent 数字格式,本地保留。
    private static let timeOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var photoCountLabel: String {
        if photoVM.selectedImageItems.count == 1 {
            return NSLocalizedString("1张照片", comment: "")
        }
        return String(format: NSLocalizedString("%d张照片", comment: ""), photoVM.selectedImageItems.count)
    }

    private func relativeDateLabel(_ date: Date?) -> String {
        guard let date else { return "" }
        if cal.isDateInToday(date) { return NSLocalizedString("今天", comment: "Today") }
        if cal.isDateInYesterday(date) { return NSLocalizedString("昨天", comment: "Yesterday") }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 0
        return Self.relativeDateString(for: date, days: days, language: appLanguage)
    }

    private static func relativeDateString(for date: Date, days: Int, language: String) -> String {
        let formatter = days < 7
            ? LumoryDateFormatters.weekdayFull(language: language)
            : LumoryDateFormatters.monthDay(language: language)
        return formatter.string(from: date)
    }

    private func timeLabel(_ date: Date?) -> String {
        guard let date else { return "" }
        return Self.timeOnlyFormatter.string(from: date)
    }

    private func cleanedSummary(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "*\"“”'‘’ \n\t"))
            .trimmingCharacters(in: CharacterSet(charactersIn: ".。"))
    }
    
    @MainActor
    func handleStopRecording() async {
        Log.info("[HomeView handleStopRecording START] Current SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
        guard let fileName = recorder.stopRecording() else {
            Log.info("[HomeView handleStopRecording: stopRecording returned nil] SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
            return
        }
        processStoppedRecording(fileName: fileName, duration: recorder.duration)
    }

    /// 走过了 `recorder.stopRecording()` 之后,把 (fileName, duration) 接进 UI 状态、清孤儿、起转写。
    /// 用户主动按停 (handleStopRecording) 和被音频中断 (recorder.interruptedRecordingFileName .onChange)
    /// 都走这里,**保证中断录到的段落不会被默默吞掉**。
    @MainActor
    private func processStoppedRecording(fileName: String, duration: TimeInterval) {
        Log.info("[HomeView processStoppedRecording: fileName=\(fileName), duration=\(duration)] SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)

        // 标记正在转录
        recordingVM.isTranscribing = true

        // UI 理论上已通过 disabled 拦住重复录音，但兜底一下：如果仍存在旧 take，
        // 删掉它们的磁盘文件，避免孤儿音频（数据模型是单值 audioFileName，不会被引用到）。
        var filesToCleanup = Set(recordingVM.audioRecordings.map(\.fileName))
        if let current = recordingVM.currentAudioFileName { filesToCleanup.insert(current) }
        filesToCleanup.remove(fileName)
        for stale in filesToCleanup {
            deleteAudioFileFromDocuments(stale)
        }

        recordingVM.currentAudioFileName = fileName
        withAnimation(AnimationConfig.stiffSpring) {
            let rec = Recording(id: fileName, fileName: fileName, duration: duration)
            recordingVM.audioRecordings.removeAll()
            recordingVM.audioRecordings.append(rec)
        }

        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let audioURL = documentsURL.appendingPathComponent(fileName)

        // 进入转写任务前清掉上次的错误,新一轮开始。
        recordingVM.transcriptionError = nil
        startTranscription(audioURL: audioURL, fileName: fileName)
        Log.info("[HomeView processStoppedRecording END] SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
    }

    /// 启动转写任务,失败时把错误塞进 `recordingVM.transcriptionError` 让 UI 显示 inline banner +
    /// 重试按钮。提取成方法是为了 retry 入口能复用同一段逻辑。
    private func startTranscription(audioURL: URL, fileName: String) {
        recordingVM.transcriptionTask?.cancel()
        transcriptionGeneration &+= 1
        let generation = transcriptionGeneration
        recordingVM.transcriptionTask = Task { @MainActor in
            Log.info("[HomeView startTranscription START] SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
            Log.info("[HomeView] appLanguage=\(appLanguage) (OpenAITranscriber 自动检测语言,该参数当前忽略)", category: .ui)
            let transcribedTextOpt = await transcriber.transcribeAudio(fileURL: audioURL, localeIdentifier: appLanguage)
            guard generation == transcriptionGeneration, !Task.isCancelled else {
                Log.info("[HomeView transcriptionTask] stale/cancelled generation,放弃更新", category: .ui)
                return
            }
            // 文件被替换 / 删除时不更新 UI(保持原行为)。
            guard recordingVM.currentAudioFileName == fileName else {
                Log.info("[HomeView transcriptionTask] 任务文件已改变,放弃更新", category: .ui)
                recordingVM.isTranscribing = false
                return
            }
            recordingVM.isTranscribing = false
            if let transcribedText = transcribedTextOpt {
                Log.info("[HomeView transcriptionTask] 成功,长度=\(transcribedText.count)", category: .ui)
                // gpt-4o-mini-transcribe 会自带句末标点;只在缺失时补一个,避免双句号("test.." / "你好。。")。
                // 末尾如果是闭合引号 / 括号 / 中文版书名号(常见模式 "test." / 他说"你好。"),
                // 视作已终结 —— 句末标点惯例放在闭合符号内,外面再补 `.` 反而怪。
                let endingPunctuation: Set<Character> = [
                    ".", "。", "?", "？", "!", "！", "…",
                    "\"", "'", "”", "’", "」", "』", "》",
                    ")", "）", "】", "]", "}"
                ]
                let alreadyTerminated = transcribedText.last.map { endingPunctuation.contains($0) } ?? true
                let suffix: String = {
                    guard !alreadyTerminated else { return "" }
                    let isChinese = transcribedText.range(of: "[\\u4E00-\\u9FFF]", options: .regularExpression) != nil
                    return isChinese ? "。" : "."
                }()
                let toAppend = transcribedText + suffix
                if inputVM.inputText.isEmpty {
                    inputVM.inputText = toAppend
                } else {
                    inputVM.inputText += Self.separatorBeforeAppendingTranscription(
                        existingText: inputVM.inputText,
                        appendedText: toAppend
                    )
                    inputVM.inputText += toAppend
                }
                recordingVM.transcriptionError = nil
                // 转录后不再自动分析情绪,等待发送时统一分析
            } else {
                let failure = transcriber.lastFailure ?? .networkFailed
                Log.error("[HomeView transcriptionTask] 转写失败: \(failure)", category: .ui)
                recordingVM.transcriptionError = failure
            }
        }
    }

    private static func separatorBeforeAppendingTranscription(existingText: String, appendedText: String) -> String {
        guard let last = existingText.last else { return "" }
        if last.isWhitespace || last.isNewline { return "" }

        let sentenceBoundary: Set<Character> = [
            ".", "。", "?", "？", "!", "！", "…",
            "\"", "'", "”", "’", "」", "』", "》",
            ")", "）", "】", "]", "}"
        ]
        if sentenceBoundary.contains(last) { return "\n" }

        let combined = existingText + appendedText
        let containsChinese = combined.range(of: "[\\u4E00-\\u9FFF]", options: .regularExpression) != nil
        return containsChinese ? "\n" : " "
    }

    /// inline error banner 上的"重试转写"按钮回调。
    /// 文件被删过(用户先点了删录音再点重试)就不重试,设为 .audioReadFailed。
    private func retryTranscription() {
        guard let fileName = recordingVM.currentAudioFileName else { return }
        guard let audioURL = Self.resolvedAudioURL(fileName: fileName) else {
            recordingVM.transcriptionError = .audioReadFailed
            return
        }
        recordingVM.transcriptionError = nil
        recordingVM.isTranscribing = true
        startTranscription(audioURL: audioURL, fileName: fileName)
    }

    private func playAudio(fileName: String) {
        Log.info("[HomeView playAudio START] Requested to play: \(fileName). Current SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)

        guard let audioURL = Self.resolvedAudioURL(fileName: fileName) else {
            Log.info("[HomeView playAudio] File NOT FOUND: \(fileName). Current SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
            // **失败提示**:文件丢失走早返路径 — onPlayError 不会 fire,banner 不会显示。这里手动 set。
            recordingVM.audioPlaybackError = NSLocalizedString("无法播放该录音,文件可能已损坏或丢失。",
                                                                comment: "Audio playback failure banner")
            if recordingVM.currentAudioFileName == fileName { // 如果UI上显示的是这个不存在的文件
                 Log.info("[HomeView playAudio] Clearing SFCFN because file missing. Old SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
                 withAnimation(AnimationConfig.standardResponse) {
                    recordingVM.currentAudioFileName = nil // SET NIL
                    Log.info("[HomeView playAudio] Did set SFCFN to nil due to missing file. New SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
                 }
                 if audioPlaybackController.currentPlayingFileName == fileName {
                    audioPlaybackController.stopPlayback()
                 }
            }
            return
        }
        // 新一次 play 成功就清掉旧错误 banner;onPlayError / missing-file path 会再 set。
        recordingVM.audioPlaybackError = nil

        Log.info("[HomeView playAudio] File exists for: \(fileName). Current SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)

        if audioPlaybackController.isPlaying && audioPlaybackController.currentPlayingFileName != fileName {
            Log.info("[HomeView playAudio] Controller was playing another file (\(audioPlaybackController.currentPlayingFileName ?? "nil")). Stopping it. Current SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
            audioPlaybackController.stopPlayback(clearCurrentFile: true)
            Log.info("[HomeView playAudio] Controller stopped. Current SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
        }

        // **关键顺序**:callback 必须在 `play()` **之前**注册。AVAudioPlayer init 偶尔会同步抛
        // (corrupt file / unsupported codec),controller.play 内 catch 后**同步** call onPlayError。
        // 之前的顺序是 play → 设回调,这种同步错误就丢了 banner 不会显示。
        //
        // **引用循环防护**:闭包存在 audioPlaybackController 身上、访问 recordingVM.currentAudioFileName,
        // recordingVM 是 `@Observable` 引用类型,若闭包强捕获 recordingVM:
        // closure → recordingVM → (nothing back) —— VM 不持 controller,不成环。
        // 但 HomeView 的 @StateObject 存储仍是引用语义,self-capture 仍有风险。
        // 做法:抓 [weak audioPlaybackController, weak recordingVM];不在闭包里提到 self。
        audioPlaybackController.onFinishPlaying = { [weak audioPlaybackController, weak recordingVM, capturedFileName = fileName] in
            Task { @MainActor in
                guard let controller = audioPlaybackController else { return }
                Log.info("[HomeView playAudio CB_Finish] Playback finished for \(capturedFileName)", category: .ui)
                if recordingVM?.currentAudioFileName == nil && capturedFileName == controller.currentPlayingFileName {
                    withAnimation(AnimationConfig.standardResponse) {
                        recordingVM?.currentAudioFileName = capturedFileName
                    }
                }
                if !controller.isPlaying, controller.currentPlayingFileName == capturedFileName {
                    controller.stopPlayback(clearCurrentFile: true)
                }
            }
        }
        audioPlaybackController.onPlayError = { [weak audioPlaybackController, weak recordingVM, capturedFileName = fileName] error in
            Task { @MainActor in
                guard let controller = audioPlaybackController else { return }
                Log.error("[HomeView playAudio CB_Error] Playback error for \(capturedFileName): \(error.localizedDescription)", category: .ui)
                // **失败提示**:之前只 log,用户感知不到。塞进 VM 让 banner 显示。
                recordingVM?.audioPlaybackError = NSLocalizedString("无法播放该录音,文件可能已损坏或丢失。",
                                                                    comment: "Audio playback failure banner")
                if recordingVM?.currentAudioFileName == nil && capturedFileName == controller.currentPlayingFileName {
                    withAnimation(AnimationConfig.standardResponse) {
                        recordingVM?.currentAudioFileName = capturedFileName
                    }
                }
                if controller.currentPlayingFileName == capturedFileName {
                    controller.stopPlayback(clearCurrentFile: true)
                }
            }
        }

        // **真正调 play 在回调装好之后**,见上方注释。同步抛错时 onPlayError 已经能接到。
        Log.info("[HomeView playAudio] Calling controller.play for: \(fileName). Current SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
        audioPlaybackController.play(url: audioURL, fileName: fileName)
        Log.info("[HomeView playAudio] Called controller.play. Controller isPlaying: \(audioPlaybackController.isPlaying), Controller file: \(audioPlaybackController.currentPlayingFileName ?? "nil"). Current SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)

        if recordingVM.currentAudioFileName != fileName {
            Log.info("[HomeView playAudio] SFCFN (\(recordingVM.currentAudioFileName ?? "nil")) != fileName (\(fileName)). Restoring SFCFN.", category: .ui)
            withAnimation(AnimationConfig.standardResponse) {
                 recordingVM.currentAudioFileName = fileName // SET FILENAME
                 Log.info("[HomeView playAudio] Did set SFCFN to \(fileName). New SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
            }
        }
        Log.info("[HomeView playAudio END] For: \(fileName). SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
    }

    private func hideKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    private func deleteEntry(_ entry: DiaryEntry) {
        // Check if the entry to be deleted is the currently selected one for navigation
        if selectedEntry?.objectID == entry.objectID {
            selectedEntry = nil // Prevent navigation to a deleted item
        }

        // 先停止可能的音频播放，如果该条目正在播放
        if self.audioPlaybackController.currentPlayingFileName == entry.audioFileName {
            self.audioPlaybackController.stopPlayback(clearCurrentFile: true)
        }

        // P1-Home-6 抓快照 — 必须在 viewContext.delete 之前(@NSManaged 访问 deleted entry 会 crash)。
        // attachment 文件**不**在这里删,延迟到 commitPendingNow 跑(让撤销窗口里 restore 时文件还在)。
        let snapshot = EntryDeletionSnapshot(entry: entry)

        // Perform deletion within a withAnimation block for smoother UI updates.
        // **register / show 故意挪出 withAnimation**(reviewer P1):toast `show()` mutate `@Observable`
        // 字段时如果在 withAnimation 里,会跟 LumoryToastOverlay 自带的 `AnimationConfig.toast` 叠成
        // 两层动画,节奏跑偏。其他 3 个删除 callsite(DiaryDetail / ThemeFiltered / PointDetail)都
        // 在 withAnimation 之外做,这里改成同一 idiom 保持一致。
        var didSucceed = false
        withAnimation {
            viewContext.delete(entry)

            do {
                try viewContext.save()
                didSucceed = true
            } catch {
                // Log the error appropriately
                Log.error("[HomeView] 删除日记失败: \(error.localizedDescription)", category: .ui)
                viewContext.rollback()
            }
        }

        guard didSucceed else { return }
        HapticManager.shared.impact(.medium)
        // 单删派生缓存清理统一走 EntryWipeOrchestrator(Reminder + Prompt + Insights + alias 孤儿清理)。
        // 注意:这层是聚合刷新,不删 attachment 文件 — attachment 由 EntryDeletionUndoService 4s 后清。
        EntryWipeOrchestrator.performSingleDeleteCleanup()

        // P1-Home-6 注册到 undo service + 弹带"撤销"按钮的 toast。4 秒内点撤销 → entry 复活。
        let viewContextRef = viewContext
        EntryDeletionUndoService.shared.register(snapshot: snapshot)
        LumoryToastCenter.shared.show(
            NSLocalizedString("已删除", comment: "Toast after entry deletion"),
            severity: .success,
            duration: EntryDeletionUndoService.undoWindow,
            action: LumoryToastCenter.Action(
                label: NSLocalizedString("撤销", comment: "Undo delete action")
            ) {
                if EntryDeletionUndoService.shared.undo(into: viewContextRef) != nil {
                    #if canImport(UIKit)
                    HapticManager.shared.notification(.success)
                    #endif
                }
            }
        )
    }

    private func handleDatabaseRecreation() {
        // Clear any local state that might reference deleted objects
        selectedEntry = nil

        // Stop any ongoing audio playback
        audioPlaybackController.stopPlayback(clearCurrentFile: true)
        
        // Clear input state
        inputVM.inputText = ""
        recordingVM.currentAudioFileName = nil
        recordingVM.audioRecordings.removeAll()
        photoVM.selectedImageItems.removeAll()
        photoVM.selectedPhotos.removeAll()
        inputVM.moodValue = 0.5

        // Cancel any ongoing tasks
        transcriptionGeneration &+= 1
        recordingVM.transcriptionTask?.cancel()
        recordingVM.transcriptionTask = nil
        recordingVM.isTranscribing = false
        
        // Force Core Data to refresh
        viewContext.refreshAllObjects()
        
        // Haptic feedback to indicate refresh
        #if canImport(UIKit)
        HapticManager.shared.click()
        #endif
        
        Log.info("[HomeView] Database recreation handled - state cleared and context refreshed", category: .ui)
    }

    // MARK: - Context prompt helpers

    /// 输入框占位文字。**stable**：一旦选定就不变，避免 SwiftUI body 重评时反复换。
    /// 重新选只发生在几个明确时刻：进入首页、发送后清空、AI 池更新完成、本地模板加载完成。
    private var inputPlaceholder: String {
        inputVM.stablePlaceholder.isEmpty
            ? NSLocalizedString("今天是怎样的一天呢？", comment: "Daily prompt fallback")
            : inputVM.stablePlaceholder
    }

    /// 在三级 fallback 里挑一条写入 `stablePlaceholder`：
    ///   1. AI 池 `PromptSuggestionEngine.randomHomePlaceholder`
    ///   2. 本地 `contextPrompts` 第一条
    ///   3. 不动（保持 "今天是怎样的一天呢？" 兜底）
    func rollPlaceholderIfNeeded(force: Bool = false) {
        if !force && !inputVM.stablePlaceholder.isEmpty { return }
        if let aiLine = PromptSuggestionEngine.shared.randomHomePlaceholder() {
            inputVM.stablePlaceholder = aiLine
            return
        }
        if let first = inputVM.contextPrompts.first {
            inputVM.stablePlaceholder = first.text
            return
        }
        // 保持旧值；下次 AI 池 / 本地模板就绪会再试
    }

    /// 启动 / 进入首页时调。**本地 fallback 顶上,AI 在后台静默刷新**:
    /// 冷启动 + 无 cache + 网慢时,`refreshIfNeeded` 可能要几秒。先把本地
    /// `ContextPromptGenerator` 的结果 apply + roll 一次,AI 写完之后**只更新 cache,
    /// 不在用户面前 re-roll** —— 用户下次下拉刷新 / 发送日记后才看到新的 AI 提示词。
    /// 之前的"AI 完成后强制 re-roll"会在用户盯着首页时占位语突然换字,体验不好。
    private func loadContextPrompts() async {
        // AI 在后台静默刷新,完成后落到 PromptSuggestionEngine.shared.current,
        // 等下次 rollPlaceholderIfNeeded(force: true) 被用户主动触发时才用上。
        Task.detached(priority: .utility) {
            await PromptSuggestionEngine.shared.refreshIfNeeded()
        }

        let prompts = await ContextPromptGenerator.shared.generate()
        await MainActor.run {
            withAnimation(AnimationConfig.smoothTransition) {
                inputVM.contextPrompts = prompts
            }
            rollPlaceholderIfNeeded()
        }
    }
}

// MARK: - Keyboard Accessory Toolbar

extension HomeView {
    @ViewBuilder
    var keyboardActionsBar: some View {
        // `.photosPicker(isPresented:)` / `.photosPicker(selection:)` 要 Binding,走 `@Bindable` shadow。
        @Bindable var photoVM = photoVM

        // 关键 fix 1(tap 串):PhotosPicker 当 button 用时 hit area 在 HStack 里和邻居
        // 按钮串,点照片偶尔触发录音。改成普通 Button + `.photosPicker(isPresented:)` ——
        // 走 SwiftUI 标准的 sheet 模态,完全独立按钮,绝不和 mic 串。
        // 关键 fix 2(玻璃):每个 tappable 显式 `.frame(44, 36) + .contentShape(Rectangle())`,
        // tap 区独立。

        Button {
            #if canImport(UIKit)
            HapticManager.shared.click()
            #endif
            photoVM.photosPickerPresented = true
        } label: {
            Image(systemName: "photo")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.85))
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(photoVM.selectedImageItems.count >= 9)
        .accessibilityLabel(NSLocalizedString("添加照片", comment: "Add photos"))
        .accessibilityIdentifier("home.keyboard.photo")
        .photosPicker(
            isPresented: $photoVM.photosPickerPresented,
            selection: $photoVM.selectedPhotos,
            maxSelectionCount: 9,
            matching: .images
        )
        .onChange(of: photoVM.selectedPhotos) { _, newValue in
            if photoVM.suppressNextPhotoSelectionReload {
                photoVM.suppressNextPhotoSelectionReload = false
                return
            }
            // F1 fix:取消上一轮压缩任务。否则用户快速换选时,旧任务可能后完成
            // 覆盖掉新结果(stale write)。
            photoVM.photoLoadTask?.cancel()
            photoVM.photoLoadTask = Task { await loadPhotosWithCompression(newValue) }
        }

        Button {
            #if canImport(UIKit)
            HapticManager.shared.click()
            #endif
            if recorder.isRecording {
                Task { await handleStopRecording() }
            } else {
                // **只有真开始录才发 success haptic**:首次点录音 + 权限未定时 startRecording 只触发
                // 授权 alert 立刻返 false,实际不录;此时发 success haptic 暗示"已开始"是误导。
                // 用户授权完后还得再点一次才会真录起来 — 那次返 true 才发 haptic。
                let didStart = recorder.startRecording()
                if didStart {
                    #if canImport(UIKit)
                    HapticManager.shared.notification(.success)
                    #endif
                }
            }
        } label: {
            // .buttonStyle(.plain) 不应用系统默认的 disabled dim,所以同色 mic 在 disabled 时
            // 视觉上跟 enabled 完全一样,用户每次都得点一下才知道(reviewer Wave-C BUG-P2)。
            // 显式 opacity 让"已有录音"态可见。
            let isMicDisabled = recordingVM.audioRecordings.count >= 1 && !recorder.isRecording
            Image(systemName: recorder.isRecording ? "stop.circle.fill" : "mic")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(recorder.isRecording ? .red : Color.primary.opacity(0.85))
                .opacity(isMicDisabled ? 0.4 : 1.0)
                .symbolEffect(.bounce, value: recorder.isRecording)
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(recordingVM.audioRecordings.count >= 1 && !recorder.isRecording)
        // P1-Home-14 disabled tap 教育 — 录音卡只能存一条,用户不知道为什么 mic 灰着。
        // overlay tap 在 disabled 时仍接收事件,弹 toast 解释。
        .overlay {
            if recordingVM.audioRecordings.count >= 1 && !recorder.isRecording {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        LumoryToastCenter.shared.show(
                            NSLocalizedString("已有录音,删除当前录音才能重录", comment: "Recording slot occupied"),
                            severity: .info
                        )
                    }
            }
        }
        .accessibilityLabel(recorder.isRecording
            ? NSLocalizedString("停止录音", comment: "Stop recording")
            : NSLocalizedString("开始录音", comment: "Start recording"))
        .accessibilityIdentifier("home.keyboard.mic")

        recordingTimerInline

        Spacer()

        // 原生 `.buttonStyle(.glassProminent)` + accent tint。
        // Apple 文档说这是"the most prominent action"用的 Liquid Glass style。
        // 在 GlassEffectContainer 里 + 外层 liquidGlassCard 提供 surface 上下文。
        // 渲染成什么样交给 SwiftUI,不手绘装饰。
        Button {
            // 用户反馈:点的瞬间没触觉 = 不知道按到了 — 之前为了消三连 haptic 把入口的 click() 删了,
            // 现在补回 .light impact(只这一处,不再加 reveal milestone 那条)。完成时仍走 success。
            #if canImport(UIKit)
            HapticManager.shared.impact(.light)
            #endif
            handleSendAction()
        } label: {
            if inputVM.sendButtonState == .sending {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
            }
        }
        .buttonStyle(.glassProminent)
        .tint(Color.accentColor)
        .disabled(!hasSendableContent || inputVM.sendButtonState != .idle)
        .accessibilityLabel(NSLocalizedString("发送", comment: "Send"))
        .accessibilityIdentifier("home.keyboard.send")
    }

    @ViewBuilder
    private var recordingTimerInline: some View {
        if recorder.isRecording {
            // P1-Home-1 实时电平条 — 高频刷新隔离在小控件内部,避免整页跟着 20Hz 重绘。
            RecordingLiveStatusView(recorder: recorder)
            .transition(.opacity)
        }
    }

    var hasSendableContent: Bool {
        // `!isSending` 是重发双点防护：`handleSendAction` 把 isSending flip 到 true 的是
        // 在第一个 `await MainActor.run` 里（本身是 sync block），所以 flip 发生在 Task 创建后
        // 至少一个调度点之后——这个窗口里用户再点一下发送按钮，`hasSendableContent`
        // 仍为 true，就会进来第二次 `handleSendAction`，snapshot 的都是旧内容，并行写两条重复日记。
        // 把 `isSending` 纳入 `hasSendableContent` 做 UI 级互斥，handleSendAction 开头再加一层
        // guard 兜底，双重保险。
        (!inputVM.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !recordingVM.audioRecordings.isEmpty
            || !photoVM.selectedImageItems.isEmpty) && !recordingVM.isTranscribing && !inputVM.isSending
    }
}

// MARK: - Inline search

extension HomeView {
    @ViewBuilder
    var searchResultsList: some View {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Spacer(minLength: 0)
            Text(NSLocalizedString("按标题、正文或主题匹配", comment: "Search hint"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Spacer(minLength: 0)
        } else if searchResults.isEmpty {
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary.opacity(0.5))
                Text(NSLocalizedString("没有匹配的日记", comment: "No results"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Spacer(minLength: 0)
        } else {
            List {
                ForEach(searchResults, id: \.objectID) { entry in
                    Button {
                        shouldStartEditing = false
                        selectedEntry = entry
                    } label: {
                        timelineCard(for: entry)
                            .padding(.bottom, 10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                }
            }
            .optimizedList()
            .scrollDismissesKeyboard(.interactively)
        }
    }

    func scheduleInlineSearch(for query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            let hits = await keywordHits(for: trimmed)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.searchResults = hits
            }
        }
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

#Preview {
    HomeView()
}
