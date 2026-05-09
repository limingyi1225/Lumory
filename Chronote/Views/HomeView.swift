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

    // `cal` / `colorScheme` 跟随 timelineCard / textInputArea 一起搬出去
    // (`HomeTimelineCard` / `HomeComposerCard` 各自持本地 `@Environment(\.colorScheme)`)。

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

    // Search state — 由系统 .searchable 托管输入;下面三个仅是结果与节流任务。
    @State private var searchQuery: String = ""
    @State private var searchResults: [DiaryEntry] = []
    @State private var searchTask: Task<Void, Never>?

    // F1 语义搜索:模式切换 + loading state + 索引覆盖率提示。
    // **`.searchable(placement: .toolbar)` 已占满 toolbar**(codex review 提醒),segmented picker
    // 不能塞 toolbar,放在搜索结果列表顶部 header。字面是默认(行为不变),用户主动切语义模式
    // 时才走 embed → cosine 排名。语义模式下 typing 不触发(embed 一次 800ms-2s 太贵),只在
    // 用户按 return 键(`.onSubmit`)时跑。
    enum SearchMode: String, CaseIterable, Identifiable {
        case keyword
        case semantic
        var id: String { rawValue }
        var label: String {
            switch self {
            case .keyword: return NSLocalizedString("字面", comment: "Search mode: keyword")
            case .semantic: return NSLocalizedString("语义", comment: "Search mode: semantic")
            }
        }
    }
    @State private var searchMode: SearchMode = .keyword
    @State private var isSemanticSearchInFlight: Bool = false
    /// 语义搜索索引覆盖率 0.0-1.0;< 0.95 时 UI 提示"索引不完整"。nil = 还没跑过。
    @State private var semanticIndexCoverage: Double?
    /// 总日记数(用来算"X 条没在结果里")。
    @State private var semanticTotalCount: Int = 0
    /// `for await` 完整跑完时的世代号 — 防 stale write 覆盖更新结果。每次 submit 前 `&+= 1`。
    @State private var semanticSearchGen: Int = 0
    /// 语义搜索 embed 失败 → UI 显示"网络错误,试试字面搜索"。
    @State private var semanticSearchFailed: Bool = false

    /// 滚动深度 —— 用户向下滚超过阈值才显示"回顶部"FAB,避免常态遮挡内容。
    @State private var showScrollToTop: Bool = false
    /// List 顶部锚点 id,FAB 用 ScrollViewProxy.scrollTo 跳回这里。
    private let topAnchorID = "__lumory_top__"
    @State private var composerFocusRequestID: UUID?

    // MARK: - Composer 回调粘合
    //
    // `HomeComposerCard` 是纯展示 + callback 边界,parent 这里把"按下文本变化 / mic 点击"
    // 翻译成项目内的 task / debounce / haptic / 录音生命周期。
    // 抽成方法是为了 `mainListContent` 的 init 不被 closure 字面量塞爆。

    /// composer 文本变化:500ms debounce 写 AppGroup defaults;空白立即同步清(防 send 后 OOM 还原)。
    private func handleInputTextChanged(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            draftSaveTask?.cancel()
            draftSaveTask = nil
            AppGroup.userDefaults.removeObject(forKey: "lumory.home.draft.text")
        } else {
            draftSaveTask?.cancel()
            draftSaveTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                Self.persistDraft(newValue)
            }
        }
    }

    /// Mic 按钮 tap:isRecording → 走 stop 路径(转写跟进);否则启录,真起录才发 success haptic。
    /// 权限未定时 startRecording 触发授权 alert 后 return false,这种"假启动"不该 haptic 暗示已开始。
    private func handleMicTap() {
        if recorder.isRecording {
            Task { await handleStopRecording() }
        } else {
            let didStart = recorder.startRecording()
            if didStart {
                #if canImport(UIKit)
                HapticManager.shared.notification(.success)
                #endif
            }
        }
    }

    var body: some View {
        iOSHomeView
    }
    
    // 主体:一个 NavigationStack + 系统 .sheet 承载设置。
    // 旧的自绘抽屉(ZStack + drag offset + mask 层)整个去掉,改成 iOS 26 标准 sheet,
    // 自动拿到玻璃过渡 / 多 detent / 系统手势下滑关闭。toolbar 上的设置钮触发。
    @ViewBuilder
    private var iOSHomeView: some View {
        mainContentView
            // F8 — iPad 上 Settings 走 fullScreenCover 而非 formSheet 浮卡(跟 Insights / AskPast 一致)
            .lumoryAdaptiveModal(isPresented: $isSettingsOpen) {
                SettingsView(isSettingsOpen: $isSettingsOpen)
                    .environmentObject(importService)
                    .environment(\.managedObjectContext, viewContext)
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
                    // 字面模式:边打边搜(180ms debounce 同原逻辑)。
                    // 语义模式:**不**自动搜 — embed 一次 800ms-2s,跟着 typing 跑既贵又烦,
                    // 用户按 return 键(.onSubmit)才触发。query 清空时本地清结果。
                    if searchMode == .keyword {
                        scheduleInlineSearch(for: newValue)
                    } else {
                        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty {
                            searchTask?.cancel()
                            searchResults = []
                            semanticSearchFailed = false
                            isSemanticSearchInFlight = false
                        }
                    }
                }
                .onSubmit(of: .search) {
                    // 语义模式 return 键提交 → 走 embed + cosine。字面模式系统已经处理。
                    if searchMode == .semantic {
                        triggerSemanticSearch(for: searchQuery)
                    }
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

                // 输入框和录音功能容器。视觉/交互拆到 `HomeComposerCard`(`Components/`),
                // parent 这里负责 wire callbacks(send / 录音生命周期 / 草稿 debounce / 图片压缩任务)
                // 把 composer 拉回到 List row 上下文 — listRow* 修饰器留外侧,内部不感知 list 结构。
                HomeComposerCard(
                    inputVM: inputVM,
                    recordingVM: recordingVM,
                    photoVM: photoVM,
                    recorder: recorder,
                    audioPlaybackController: audioPlaybackController,
                    isInputFocused: $isInputFocused,
                    inputPlaceholder: inputPlaceholder,
                    onInputTextChanged: handleInputTextChanged,
                    onSend: handleSendAction,
                    onPlayRecording: { fileName in playAudio(fileName: fileName) },
                    onRetryTranscription: retryTranscription,
                    onMicTap: handleMicTap,
                    onPhotoSelectionChanged: { newValue in
                        // F1 fix:取消上一轮压缩任务。否则用户快速换选时,旧任务可能后完成
                        // 覆盖掉新结果(stale write)。
                        photoVM.photoLoadTask?.cancel()
                        photoVM.photoLoadTask = Task { await loadPhotosWithCompression(newValue) }
                    },
                    onDeleteRecordingConfirmed: { target in deleteRecording(target) }
                )
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 28, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

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
            .onChange(of: scenePhase) { _, newPhase in
                // 进 background 时 cancel debounce + 同步 flush 草稿。
                // 否则用户输入完立刻锁屏 / 切走,iOS 5s background grace 内 task 可能没跑完,丢草稿。
                // 原来挂在 textInputArea 内部的 onChange,composer 拆出去后挪到 list 根上,作用范围一致。
                if newPhase == .background {
                    draftSaveTask?.cancel()
                    Self.persistDraft(inputVM.inputText)
                }
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
            // F7 — iPad 时间线宽度限定。12.9" iPad 全宽会让每条 row 拉得很长(右侧大片空白),
            // 900pt listContentMaxWidth 是 list 类内容的舒适宽度。iPhone < 900pt 不裁剪。
            .lumoryReadableContent(maxWidth: LumoryAdaptivePresentation.listContentMaxWidth)
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
    
    /// 草稿写盘的单点入口。空白 → remove key,非空 → set。
    /// `HomeComposerCard.onInputTextChanged` 经 parent 内 debounce 调本函数;
    /// scenePhase=background 强 flush 也走这里。
    private static func persistDraft(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            AppGroup.userDefaults.removeObject(forKey: "lumory.home.draft.text")
        } else {
            AppGroup.userDefaults.set(value, forKey: "lumory.home.draft.text")
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

            // 4. 把落库和 2 秒光谱动画并行跑 —— 保存不再被动画白白拖 2 秒,
            //    动画也不会被慢网络/磁盘 I/O 拖过 2 秒。
            // **service 边界**:`EntryCreationService.create` 一手包办附件 I/O + Core Data save +
            // Reminder reschedule + StreakMilestone + fire-and-forget AI writeback(stale-guard 在
            // service 内部)。HomeView 只 await Result.didSave 控 UI 状态机。
            let saveTask = Task {
                return await EntryCreationService.create(
                    .init(
                        text: textToSend,
                        audioFileName: audioToSend,
                        images: imagesToSend,
                        moodValue: finalMoodValue
                    ),
                    in: PersistenceController.shared,
                    viewContext: viewContext,
                    ai: aiService
                ).didSave
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
    
    // MARK: - Core Data 操作
    //
    // 写日记落库 + 附件 I/O + AI writeback 整段搬到 `EntryCreationService`(`Services/`),
    // `handleSendAction` 直接 `await EntryCreationService.create(...).didSave` 控 UI 状态机。
    // 单测覆盖 service 入口(`ChronoteTests/EntryCreationServiceTests.swift`)。

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

    // 时间线列表:竖直连接线 + 彩色节点 + 卡片。不再按日分组 —— 每行自带相对日期标签。
    // 真实渲染由 `HomeTimelineList` / `HomeTimelineEmptyState` / `HomeTimelineRow` /
    // `HomeTimelineCard` 拆分承担(`Views/HomeView/Components/`)。这里只做 entries.isEmpty 的
    // 分支调度 + parent state 回调 wiring。
    @ViewBuilder
    private var diaryContentSections: some View {
        if entries.isEmpty {
            // 冷启动首帧 `@FetchRequest` 还没把 SQLite 读完就返空,emptyState 会闪一下。
            // 等 `hasLoadedOnce` 置位后(.task 里设)再允许显示空态。
            if hasLoadedOnce {
                HomeTimelineEmptyState()
            }
        } else {
            HomeTimelineList(
                entries: Array(entries),
                appLanguage: appLanguage,
                onTap: { entry in
                    // 上次长按"编辑"后 onDisappear 还没跑完就再次点击,`shouldStartEditing` 残留 true,
                    // 这次普通点击也会进编辑模式。显式清掉。
                    shouldStartEditing = false
                    selectedEntry = entry
                },
                onEdit: { entry in
                    shouldStartEditing = true
                    selectedEntry = entry
                },
                onDelete: { entry in
                    deleteEntry(entry)
                }
            )
        }
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

// MARK: - Inline search

extension HomeView {
    /// 字面 / 语义切换的 segmented picker + 语义模式特有的 hint 横条。
    /// 放在搜索结果列表顶部 — `.searchable(placement: .toolbar)` 已占满 toolbar,picker 不能塞那里。
    @ViewBuilder
    private var searchModeHeader: some View {
        VStack(spacing: 8) {
            Picker("", selection: $searchMode) {
                ForEach(SearchMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: searchMode) { _, newMode in
                // 切模式时清结果(防止字面结果残留在语义模式视图,反之亦然)。
                searchResults = []
                semanticSearchFailed = false
                // 语义模式提示用户按 return 触发 — 这里不主动跑(embed 太贵)。
                // 字面模式下,如果 query 非空,立刻走原有 inline keyword search。
                if newMode == .keyword {
                    let trimmed = searchQuery.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { scheduleInlineSearch(for: searchQuery) }
                }
            }
            .padding(.horizontal, 16)

            // 语义模式专属提示
            if searchMode == .semantic {
                if isSemanticSearchInFlight {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text(NSLocalizedString("正在按相关度搜索…", comment: "Semantic search in progress"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                } else if semanticSearchFailed {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Text(NSLocalizedString("语义搜索网络错误,试试字面模式", comment: "Semantic search network error"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                } else if let coverage = semanticIndexCoverage, coverage < 0.95, semanticTotalCount > 0 {
                    let unindexed = semanticTotalCount - Int(Double(semanticTotalCount) * coverage)
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.blue)
                            .font(.caption)
                        Text(String(
                            format: NSLocalizedString("有 %d 条日记还没生成语义索引,可能漏在结果外", comment: "Semantic index incomplete hint"),
                            unindexed
                        ))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    var searchResultsList: some View {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespaces)
        VStack(spacing: 0) {
            searchModeHeader
            searchResultsBody(trimmed: trimmed)
        }
    }

    @ViewBuilder
    private func searchResultsBody(trimmed: String) -> some View {
        if trimmed.isEmpty {
            Spacer(minLength: 0)
            Text(searchMode == .keyword
                 ? NSLocalizedString("按标题、正文或主题匹配", comment: "Keyword search hint")
                 : NSLocalizedString("输入关键词后按回车进行语义搜索", comment: "Semantic search hint"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Spacer(minLength: 0)
        } else if searchMode == .semantic && isSemanticSearchInFlight && searchResults.isEmpty {
            // loading 第一次(已经有 header 上的 spinner,这里给 list 区域空白避免突然弹空状态)。
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
                        HomeTimelineCard(entry: entry, appLanguage: appLanguage)
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

    /// F1 语义搜索触发。`InsightsEngine.searchSemantic` 是 Sendable 接口,返 `[NSManagedObjectID]` +
    /// 索引覆盖率。**世代号 guard** 防 stale write:用户连按两次 return,旧 task 跑完时世代号已变,
    /// 不写 result。
    func triggerSemanticSearch(for query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            searchResults = []
            isSemanticSearchInFlight = false
            return
        }
        searchTask?.cancel()
        semanticSearchGen &+= 1
        let myGen = semanticSearchGen
        isSemanticSearchInFlight = true
        semanticSearchFailed = false

        searchTask = Task { @MainActor in
            let result = await InsightsEngine.shared.searchSemantic(query: trimmed, topK: 20)
            // stale write guard
            guard self.semanticSearchGen == myGen, !Task.isCancelled else { return }

            self.semanticIndexCoverage = result.indexCoverage
            self.semanticTotalCount = result.totalCount
            self.isSemanticSearchInFlight = false

            // embed 失败 → 提示用户换字面模式。不静默漏掉。
            guard result.queryEmbedded else {
                self.semanticSearchFailed = true
                self.searchResults = []
                return
            }
            // 物化 objectIDs → DiaryEntry。和 keywordHits 同 idiom(existingObject 容错 tombstone)。
            self.searchResults = result.ids.compactMap {
                try? viewContext.existingObject(with: $0) as? DiaryEntry
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
