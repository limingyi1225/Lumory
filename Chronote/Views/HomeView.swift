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
    // **Property visibility 约定**:本 struct 大部分 stored prop 是 `internal`(无 modifier),
    // 让 `HomeView/HomeView+*.swift` 几个 extension 文件能跨文件访问 state。Swift `private`
    // 在 extension 是 file-scoped,跨文件访问不到 —— 因此我们把 view state 提升到 internal。
    // 仅 `topAnchorID`、几个 view-builder 私有计算属性、`defaultAppLanguage` 静态等只在主文件
    // 内使用的留 `private`。

    // Core Data 相关
    @Environment(\.managedObjectContext) var viewContext
    // 注意：这里**故意不用** `animation: .default`。
    // 历史上同时开 FetchRequest animation、List 原生 row-removal、`withAnimation { delete }`
    // 三层动画时序会错开导致行错位。把 FetchRequest 的 animation 撤掉后，动画由 List + `withAnimation`
    // 两层控制就够，且 `ForEach(entries, id: \.objectID)` 也能恢复正常 identity。
    // (2026-05-15 megareview OPT-HIGH-1)`fetchBatchSize: 50` — 不再首次访问就全表实例化。
    // FetchedResults 仍按需 fault 进每个 entry,但 batch 50 让长 timeline 在 scroll 时按页拉,
    // 避免冷启动 + 大量(年级别)日记一次性把整张表 hydrate。`fetchRequest:` initializer 是
    // 唯一允许传 batchSize 的入口(SwiftUI 的 sortDescriptors: + animation: convenience 都吞掉 batch)。
    @FetchRequest(fetchRequest: {
        let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false),
            NSSortDescriptor(keyPath: \DiaryEntry.id, ascending: false)
        ]
        request.fetchBatchSize = 50
        return request
    }()) var entries: FetchedResults<DiaryEntry>

    // AI 服务从 SwiftUI Environment 注入，默认指向 `OpenAIService.shared`。
    // 生产零行为变化；测试 / Preview 里可以 `.environment(\.aiService, MockAIService())` 替换。
    @Environment(\.aiService) var aiService
    // 语音转录（独立的服务，不和 AI 混在一起）。走 Lumory 后端代理 OpenAI gpt-4o-mini-transcribe。
    let transcriber: TranscriberProtocol = OpenAITranscriber()
    
    // 导入服务（与 SettingsView 共享）
    @EnvironmentObject var importService: CoreDataImportService
    @EnvironmentObject var syncMonitor: CloudKitSyncMonitor
    
    // MARK: - 拆分出的 3 个 @Observable ViewModel
    // 原来 20+ 个 `@State` 按职责聚合到三个 VM(见 `Views/HomeView/`),每个 VM 字段变动只
    // 会失效该 VM 的 tracking,不再让无关字段(比如单字输入 vs 录音计时)互相触发整个 body
    // 重算。ObservableObject 类型(`AudioRecorder` / `AudioPlaybackController`)**没有**
    // 搬进 VM —— 原因见 `HomeRecordingViewModel.swift` 文件头说明。
    @State var inputVM = HomeInputViewModel()
    @State var recordingVM = HomeRecordingViewModel()
    /// Theme alias 软提示。observed 让 pending 列表变化时 banner 自动显隐。
    @ObservedObject var aliasResolver = ThemeAliasResolver.shared
    @ObservedObject var reminderRouter = ReminderNotificationRouter.shared
    @ObservedObject var appLockService = AppLockService.shared
    @State var photoVM = HomePhotoViewModel()

    @StateObject var recorder = AudioRecorder()
    @StateObject var audioPlaybackController = AudioPlaybackController() // 新的控制器
    @FocusState var isInputFocused: Bool
    @State var transcriptionGeneration = 0

    /// 草稿持久化 debounce —— 用户连打字时不每键写 AppGroup UserDefaults(plist encode + KVO +
    /// 跨进程 sync 累计开销),改成 500ms 静默后才写;scenePhase=.background 强 flush 一次防丢。
    @State var draftSaveTask: Task<Void, Never>?
    @Environment(\.scenePhase) var scenePhase

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

    @AppStorage("appLanguage", store: AppGroup.userDefaults) var appLanguage: String = HomeView.defaultAppLanguage
    @AppStorage("home.showOnThisDay", store: AppGroup.userDefaults) var showOnThisDay: Bool = true

    // MARK: - View-level 路由 / 搜索 / 生命周期 state
    // 这些**留在 HomeView**:和 NavigationStack / sheet / .searchable 生命周期耦合,
    // 抽进 VM 反而要反向同步。
    @State var selectedEntry: DiaryEntry?
    /// 现在直接驱动 `.sheet` —— 不再走自绘抽屉。
    @State var isSettingsOpen: Bool = false
    @State var isInsightsPresented: Bool = false
    @State var shouldStartEditing: Bool = false
    // entryToDelete / showDeleteConfirmation 已移除 — 删除走 4 秒撤销 toast,不再有 alert。
    // 旧 contextMenu / swipeAction 直接调 deleteEntry(entry)。
    /// 冷启动首帧 @FetchRequest 尚未完成时为 false——避免 emptyState 闪一帧。
    @State var hasLoadedOnce: Bool = false

    /// "On This Day" cache — 改成 `@State` 而非 computed property,避免 SwiftUI body 每次
    /// re-eval(composer typing / mood slider 拖动 / recording state 变化等高频触发)都遍历
    /// 整个 `entries` FetchedResults。`refreshOnThisDayHighlights()` 只在 entries.count 变
    /// (新增/删除日记)或 scenePhase=.active(跨午夜兜底)时调,长 timeline 用户不再被
    /// O(N) 主线程扫描卡顿。
    @State var cachedOnThisDayHighlights: [OnThisDayHighlight] = []

    // Search state — 由系统 .searchable 托管输入;下面是结果 + 节流 task。
    // wave14 — 改成"无感"双引擎融合:keyword 立刻出 + 600ms 后 semantic 后台补,
    // 删除 SearchMode picker。embed 失败时给一次轻提示,避免用户以为搜索条件太窄。
    @State var searchQuery: String = ""
    /// keyword 命中(主结果)。
    @State var searchResults: [DiaryEntry] = []
    @State var keywordSearchTask: Task<Void, Never>?

    /// semantic 补充结果(渲染时实时过滤掉 keyword 已命中,见 searchResultsBody)。
    @State var semanticAuxResults: [DiaryEntry] = []
    @State var semanticSearchTask: Task<Void, Never>?
    /// 世代号 — 防 stale write,onChange 起新 task 前 `&+= 1`。
    @State var semanticSearchGen: Int = 0
    /// 涵盖 600ms debounce + embed in-flight。从 onChange 创建 semantic task 起即 true,
    /// 完成或失败后置 false。但 UI 渲染"正在扩展搜索…"时还要看 `keywordSearchSettled`,
    /// 否则用户键入瞬间(keyword 180ms debounce 还没过)就会闪 loading,体验差。
    @State var semanticSearchPending: Bool = false
    @State var semanticSearchFailureNotifiedFor: String?
    /// keyword 路径是否已"落定" — debounce 过 + bg fetch 完。键入瞬间 false,180ms+ 后 true。
    /// UI 用这个 gate"正在扩展搜索…"提示,不在 keyword 还没出结果时就先闪 semantic loading。
    @State var keywordSearchSettled: Bool = false

    /// 滚动深度 —— 用户向下滚超过阈值才显示"回顶部"FAB,避免常态遮挡内容。
    @State var showScrollToTop: Bool = false
    /// List 顶部锚点 id,FAB 用 ScrollViewProxy.scrollTo 跳回这里。
    private let topAnchorID = "__lumory_top__"
    @State var composerFocusRequestID: UUID?
    /// Optional composer date override. nil means "today / now"; set from the keyboard toolbar only.
    @State var draftEntryDate: Date?

    // MARK: - Composer 回调粘合
    //
    // `HomeComposerCard` 是纯展示 + callback 边界,parent 这里把"按下文本变化 / mic 点击"
    // 翻译成项目内的 task / debounce / haptic / 录音生命周期。
    // `handleInputTextChanged` 已抽到 HomeView/HomeView+Helpers.swift,
    // `handleMicTap` 已抽到 HomeView/HomeView+Recording.swift。

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
                if inputVM.inputText.isEmpty, let draft = Self.persistedDraftText() {
                    draftEntryDate = Self.persistedDraftDate()
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
            .onChange(of: appLockService.isLocked) { _, isLocked in
                if !isLocked {
                    handleReminderComposeFocusIfNeeded()
                }
            }
            // **音频中断录音 → UI 接管**:电话 / Siri 打断录音时,AudioRecorder 自己 stopRecording 落盘 +
            // 透出 filename。HomeView 在这里接住,把段落塞进 audioRecordings 起转写,然后清 filename
            // (单次消费)。否则用户的录音段落留在磁盘但 UI 看不到,等于丢失。
            .onChange(of: recorder.interruptedRecordingFileName) { _, fileName in
                if let fileName {
                    _ = processStoppedRecording(fileName: fileName, duration: recorder.duration)
                    recorder.interruptedRecordingFileName = nil
                }
            }
            .onChange(of: recorder.maxDurationRecording) { _, completed in
                guard let completed else { return }
                let accepted = processStoppedRecording(fileName: completed.fileName, duration: completed.duration)
                recorder.maxDurationRecording = nil
                if accepted {
                    LumoryToastCenter.shared.show(
                        NSLocalizedString("录音已到 10 分钟上限,已自动停止。", comment: "Recording auto-stopped after max duration"),
                        severity: .info
                    )
                } else if !inputVM.isSending {
                    LumoryToastCenter.shared.show(
                        NSLocalizedString("录音已停止,但当前状态下未保存。", comment: "Recording auto-stopped but was not saved"),
                        severity: .warning
                    )
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .databaseRecreated)) { _ in
                Log.info("[HomeView] Database recreated notification received", category: .ui)
                handleDatabaseRecreation()
            }
            .onReceive(NotificationCenter.default.publisher(for: .lumoryReturnHomeRequested)) { _ in
                isSettingsOpen = false
                isInsightsPresented = false
                selectedEntry = nil
                shouldStartEditing = false
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
                    // wave14 "无感"融合:keyword 立刻出(180ms debounce)+ semantic 600ms 后
                    // 后台补。embed 失败静默,无 picker,无 hint banner。
                    handleSearchQueryChange(newValue)
                }
                .navigationDestination(item: $selectedEntry) { entry in
                    let entryObjectID = entry.objectID
                    DiaryDetailView(
                        entry: entry,
                        startInEditMode: shouldStartEditing,
                        onDeleted: {
                            if selectedEntry?.objectID == entryObjectID {
                                selectedEntry = nil
                            }
                            removeDeletedEntryFromSearchResults(entryObjectID)
                        }
                    )
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
                    await MainActor.run {
                        hasLoadedOnce = true
                        // FetchRequest 第一轮完成,这里 compute 一次 On This Day 填 cache。
                        refreshOnThisDayHighlights()
                    }
                    await loadContextPrompts()
                }
                .onChange(of: entries.count) { _, _ in
                    // 新增/删除日记 → recompute(targets 仍是同两个日子,但底层 entries 集合变了)。
                    refreshOnThisDayHighlights()
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: .NSManagedObjectContextObjectsDidChange,
                    object: viewContext
                )) { notification in
                    guard Self.notificationTouchesDiaryEntries(notification) else { return }
                    refreshOnThisDayHighlights()
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

    /// "On This Day" 计算 — **在 body 外调,结果写 `cachedOnThisDayHighlights` @State**。
    /// SwiftUI body 内只读 cache,不再扫 `entries` FetchedResults(长 timeline 用户避免
    /// 主线程 O(N) fault)。trigger 点见 `.task` / `.onChange(of: entries.count)` /
    /// `.onChange(of: scenePhase)` active(跨午夜)。
    private func refreshOnThisDayHighlights() {
        let calendar = Calendar.current
        let now = Date()
        let targets: [(Date?, String)] = [
            (
                calendar.date(byAdding: .year, value: -1, to: now),
                NSLocalizedString("去年的今天", comment: "On This Day card title for last year")
            ),
            (
                calendar.date(byAdding: .month, value: -3, to: now),
                NSLocalizedString("3 个月前的这一天", comment: "On This Day card title for three months ago")
            )
        ]

        var usedEntryIDs = Set<NSManagedObjectID>()
        var highlights: [OnThisDayHighlight] = []
        highlights.reserveCapacity(targets.count)

        for (targetDate, title) in targets {
            guard let targetDate,
                  let dayInterval = calendar.dateInterval(of: .day, for: targetDate),
                  let entry = fetchOnThisDayEntry(in: dayInterval),
                  !usedEntryIDs.contains(entry.objectID) else { continue }
            usedEntryIDs.insert(entry.objectID)
            highlights.append(OnThisDayHighlight(id: entry.objectID, title: title, entry: entry))
        }

        cachedOnThisDayHighlights = highlights
    }

    private func fetchOnThisDayEntry(in dayInterval: DateInterval) -> DiaryEntry? {
        let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
        request.predicate = NSPredicate(
            format: "date >= %@ AND date < %@",
            dayInterval.start as NSDate,
            dayInterval.end as NSDate
        )
        request.sortDescriptors = [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)]
        request.fetchLimit = 1
        request.fetchBatchSize = 1
        request.returnsObjectsAsFaults = true
        return try? viewContext.fetch(request).first
    }

    private static func notificationTouchesDiaryEntries(_ notification: Notification) -> Bool {
        let keys = [
            NSInsertedObjectsKey,
            NSUpdatedObjectsKey,
            NSDeletedObjectsKey,
            NSRefreshedObjectsKey,
            NSInvalidatedObjectsKey
        ]
        return keys.contains { key in
            guard let objects = notification.userInfo?[key] as? Set<NSManagedObject> else {
                return false
            }
            return objects.contains { $0 is DiaryEntry }
        }
    }
    
    @ViewBuilder
    private var mainListContent: some View {
        ScrollViewReader { proxy in
            List {
                // 心情光谱滑块 - Mac优化布局
                moodSliderSection
                    .id(topAnchorID)

                // (2026-05-19 P1-03 audit)Composer 紧贴 mood slider 下方,主写作动作 = 首屏
                // 第一个 affordance。OnThisDay 是被动回忆触发器,挪到 composer 之后、日记
                // 时间线之前作"历史区域第一项",写日记主路径不被打断。
                HomeComposerCard(
                    inputVM: inputVM,
                    recordingVM: recordingVM,
                    photoVM: photoVM,
                    recorder: recorder,
                    audioPlaybackController: audioPlaybackController,
                    isInputFocused: $isInputFocused,
                    draftEntryDate: $draftEntryDate,
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

                let highlights = cachedOnThisDayHighlights
                if showOnThisDay, !highlights.isEmpty {
                    OnThisDaySection(
                        highlights: highlights,
                        appLanguage: appLanguage,
                        onTap: { entry in
                            shouldStartEditing = false
                            selectedEntry = entry
                        }
                    )
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 14, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }

                // 日记条目内容 Sections
                diaryContentSections
            }
            .optimizedList()
            // iOS 26 顶部边缘软渐隐 — 内容滚到顶下时贴玻璃感更自然,不再硬切到 navigation chrome。
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: scenePhase) { _, newPhase in
                // 进 background 时 cancel debounce + 同步 flush 草稿。
                // 否则用户输入完立刻锁屏 / 切走,iOS 5s background grace 内 task 可能没跑完,丢草稿。
                // 原来挂在 textInputArea 内部的 onChange,composer 拆出去后挪到 list 根上,作用范围一致。
                if newPhase == .background {
                    finalizeActiveRecordingForBackground()
                    draftSaveTask?.cancel()
                    Self.persistDraft(inputVM.inputText, date: draftEntryDate)
                }
                // 跨午夜兜底:用户长时间挂着 app(锁屏 / 切走 → 再回来),"今天"已经变了,
                // On This Day 的两个 target date 也跟着移一天。.active 时无脑 recompute 一次,
                // 成本低(只 2 个 target + entries.first(where:),数千 entry 内不到 ms 级)。
                if newPhase == .active {
                    refreshOnThisDayHighlights()
                }
            }
            .onChange(of: draftEntryDate) { _, newValue in
                Self.persistDraftDate(newValue, draftText: inputVM.inputText)
            }
            .onChange(of: composerFocusRequestID) { _, requestID in
                guard requestID != nil else { return }
                withAnimation(.smooth(duration: 0.35)) {
                    proxy.scrollTo(topAnchorID, anchor: .top)
                }
                isInputFocused = true
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

    // `handleReminderComposeFocusIfNeeded` / `triggerManualSync` 已抽到 HomeView/HomeView+Helpers.swift

    @ViewBuilder
    private var moodSliderSection: some View {
        // mood reveal 窗口期(`.moodRevealing`)光谱条可拖。watchdog 在 HomeView+Send
        // 里跑:从未碰 → 2.5s 落库;松手 → 立即落库(~100ms poll)。没有显式"完成"按钮 ——
        // 用户松手就是 commit 信号。(A-07 superreview:此处旧注释写的 4s/1.5s 是过时的常量值。)
        let isMoodEditable = inputVM.sendButtonState == .moodRevealing
        VStack(alignment: .center, spacing: 4) {
            MoodSpectrumBar(
                moodValue: inputVM.revealedMood ?? inputVM.moodValue,
                displayState: inputVM.spectrumDisplayState,
                onMoodChanged: isMoodEditable ? { value in
                    inputVM.revealedMood = value
                    inputVM.moodValue = value
                    // 任何 onChanged 都 bump tick + 清掉旧的 releasedAt(用户重新按住了)。
                    inputVM.moodEditTouchTick &+= 1
                    inputVM.moodEditReleasedAt = nil
                } : nil,
                onInteractionEnded: isMoodEditable ? {
                    inputVM.moodEditReleasedAt = Date()
                } : nil
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
    
    // `persistDraft` 已抽到 HomeView/HomeView+Helpers.swift
    // `deleteRecording` / `deleteAudioFileFromDocuments` 已抽到 HomeView/HomeView+Recording.swift
    // `loadPhotosWithCompression` 已抽到 HomeView/HomeView+Helpers.swift
    // `SendSnapshot` + `handleSendAction` 已抽到 HomeView/HomeView+Send.swift

    // MARK: - Core Data 操作
    //
    // 写日记落库 + 附件 I/O + AI writeback 整段搬到 `EntryCreationService`(`Services/`),
    // `handleSendAction` 直接 `await EntryCreationService.create(...).didSave` 控 UI 状态机。
    // 单测覆盖 service 入口(`ChronoteTests/EntryCreationServiceTests.swift`)。

    // `resolvedAudioURL` 已抽到 HomeView/HomeView+Audio.swift

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
                // (2026-05-15 superreview-3 P1)直接传 FetchedResults,避免每次 body re-eval
                // 全表 materialize 抵消 fetchBatchSize=50。
                entries: entries,
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

    // `handleStopRecording` / `processStoppedRecording` / `startTranscription` /
    // `separatorBeforeAppendingTranscription` / `retryTranscription` 已抽到
    // HomeView/HomeView+Recording.swift

    // `playAudio` / `hideKeyboard` 已抽到 HomeView/HomeView+Audio.swift

    // `deleteEntry` / `handleDatabaseRecreation` 已抽到 HomeView/HomeView+Entry.swift

    // MARK: - Context prompt helpers 已抽到 HomeView/HomeView+Helpers.swift
    // (inputPlaceholder / rollPlaceholderIfNeeded / loadContextPrompts)
}

// MARK: - Inline search 已抽到 HomeView/HomeView+Search.swift
//
// 包含 handleSearchQueryChange / removeDeletedEntryFromSearchResults / searchResultsList /
// searchResultsBody / searchResultRow / keywordHits。state 声明仍在主 struct(SwiftUI
// 限制 stored prop 必须在主 struct),`.searchable` modifier 也留在 mainContentView。

#Preview {
    HomeView()
}
