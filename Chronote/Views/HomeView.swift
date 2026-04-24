import SwiftUI
import AVFoundation
import Combine
import CoreData
import PhotosUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Send Button State Machine
// `enum SendButtonState` 已 moved 到 Views/HomeView/HomeInputViewModel.swift,
// 与发送按钮动画的 `@State` 一起收束。HomeView 内继续按原名引用,类型语义不变。

// 全局辅助函数：格式化时长
func formattedDuration(currentTime: TimeInterval, totalDuration: TimeInterval) -> String {
    let currentIntSec = Int(max(0, currentTime))
    let current_m = currentIntSec / 60
    let current_s = currentIntSec % 60

    if totalDuration > 0 {
        let totalIntSec = Int(max(0, totalDuration))
        let total_m = totalIntSec / 60
        let total_s = totalIntSec % 60
        return String(format: "%02d:%02d / %02d:%02d", current_m, current_s, total_m, total_s)
    } else {
        return String(format: "%02d:%02d", current_m, current_s)
    }
}

// MARK: - Corner Rounding Helper
#if canImport(UIKit)
import UIKit

struct RoundedCorner: Shape {
    var radius: CGFloat
    var corners: UIRectCorner
    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect,
                                byRoundingCorners: corners,
                                cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}
#else
// macOS version using NSBezierPath
struct RoundedCorner: Shape {
    var radius: CGFloat
    var corners: RectCorner
    
    struct RectCorner: OptionSet {
        let rawValue: Int
        static let topLeft = RectCorner(rawValue: 1 << 0)
        static let topRight = RectCorner(rawValue: 1 << 1)
        static let bottomLeft = RectCorner(rawValue: 1 << 2)
        static let bottomRight = RectCorner(rawValue: 1 << 3)
        static let allCorners: RectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
    }
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        
        let width = rect.size.width
        let height = rect.size.height
        
        // Start from top-left
        if corners.contains(.topLeft) {
            path.move(to: CGPoint(x: radius, y: 0))
        } else {
            path.move(to: CGPoint(x: 0, y: 0))
        }
        
        // Top edge and top-right corner
        if corners.contains(.topRight) {
            path.addLine(to: CGPoint(x: width - radius, y: 0))
            path.addArc(center: CGPoint(x: width - radius, y: radius),
                       radius: radius,
                       startAngle: .degrees(-90),
                       endAngle: .degrees(0),
                       clockwise: false)
        } else {
            path.addLine(to: CGPoint(x: width, y: 0))
        }
        
        // Right edge and bottom-right corner
        if corners.contains(.bottomRight) {
            path.addLine(to: CGPoint(x: width, y: height - radius))
            path.addArc(center: CGPoint(x: width - radius, y: height - radius),
                       radius: radius,
                       startAngle: .degrees(0),
                       endAngle: .degrees(90),
                       clockwise: false)
        } else {
            path.addLine(to: CGPoint(x: width, y: height))
        }
        
        // Bottom edge and bottom-left corner
        if corners.contains(.bottomLeft) {
            path.addLine(to: CGPoint(x: radius, y: height))
            path.addArc(center: CGPoint(x: radius, y: height - radius),
                       radius: radius,
                       startAngle: .degrees(90),
                       endAngle: .degrees(180),
                       clockwise: false)
        } else {
            path.addLine(to: CGPoint(x: 0, y: height))
        }
        
        // Left edge and top-left corner
        if corners.contains(.topLeft) {
            path.addLine(to: CGPoint(x: 0, y: radius))
            path.addArc(center: CGPoint(x: radius, y: radius),
                       radius: radius,
                       startAngle: .degrees(180),
                       endAngle: .degrees(270),
                       clockwise: false)
        } else {
            path.addLine(to: CGPoint(x: 0, y: 0))
        }
        
        path.closeSubpath()
        return path
    }
}

extension View {
    func cornerRadius(_ radius: CGFloat, corners: RoundedCorner.RectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

// Compatibility typealias
typealias UIRectCorner = RoundedCorner.RectCorner
#endif

#if canImport(UIKit)
/// CADisplayLink 要求 `target` 保持 Obj-C runtime 可访问，它会**强引用** target。
/// 让它直接指向 AudioPlaybackController 会造成 `displayLink ⇄ controller` 循环强引用
/// （controller 存 displayLink，displayLink 存 controller），导致 deinit 不触发、音频会话泄漏。
/// 这里放一个弱回指的代理，由代理中转调用，controller 可以被正常释放。
private final class DisplayLinkProxy: NSObject {
    weak var target: AudioPlaybackController?
    init(target: AudioPlaybackController) { self.target = target }
    // CADisplayLink 添加到 `.main` runloop，fire 天然在主线程上——用 `assumeIsolated` 把编译器
    // 的 `@MainActor` 隔离检查满足掉，无需付一次 Task 切换 / hop 开销。
    @objc func tick() {
        MainActor.assumeIsolated {
            target?.updateProgress()
        }
    }
}
#endif

// 新的音频播放控制器
//
// **@MainActor 强制**：这个 class 有一堆 @Published 属性，Swift 6 strict 下从非主线程改
// 会 hard-crash ("Publishing changes from background threads is not allowed")。
// `AVAudioPlayerDelegate` 的回调（didFinishPlaying / decodeErrorDidOccur）**Apple 不保证**
// 主线程触发——某些 iOS 版本/codec 会从底层 audio 队列线程直接调进来。
// 做法：整个类 @MainActor，delegate 方法用 `nonisolated` 接受底层回调后立刻 hop 回 main。
@MainActor
final class AudioPlaybackController: NSObject, AVAudioPlayerDelegate, ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var progress: Double = 0.0 // 0.0 to 1.0
    @Published var duration: TimeInterval = 0.0
    @Published var currentTime: TimeInterval = 0.0
    @Published private(set) var currentPlayingFileName: String? // 用于确保只操作当前音频. private(set) 外部只读

    private var audioPlayer: AVAudioPlayer?
#if canImport(UIKit)
    private var displayLink: CADisplayLink?
    private var displayLinkProxy: DisplayLinkProxy?
#else
    private var progressTimer: Timer?
#endif

    var onFinishPlaying: (() -> Void)?
    var onPlayError: ((Error) -> Void)?

    func play(url: URL, fileName: String) {
        if audioPlayer != nil && audioPlayer!.isPlaying && currentPlayingFileName == fileName {
            audioPlayer?.pause()
            isPlaying = false
            stopDisplayLink()
            return
        }
        if audioPlayer != nil && !audioPlayer!.isPlaying && currentPlayingFileName == fileName {
            audioPlayer?.play()
            isPlaying = true
            startDisplayLink()
            return
        }

        stopPlayback(clearCurrentFile: false) // 停止之前的播放，但不清除 currentPlayingFileName

        currentPlayingFileName = fileName // 在这里设置当前播放文件名
        do {
#if canImport(UIKit)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
#endif

            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            duration = audioPlayer?.duration ?? 0.0
            currentTime = 0.0
            progress = 0.0
            audioPlayer?.play()
            isPlaying = true
            startDisplayLink()
        } catch {
            Log.error("[AudioPlaybackController] Could not play audio: \\(error)", category: .ui)
            onPlayError?(error)
            stopPlaybackCleanup() // 出错时彻底清理
        }
    }

    func pause() {
        guard audioPlayer != nil && audioPlayer!.isPlaying else { return }
        audioPlayer?.pause()
        isPlaying = false
        stopDisplayLink()
    }
    
    func stopPlayback(clearCurrentFile: Bool = true) {
        audioPlayer?.stop()
        isPlaying = false
        if clearCurrentFile {
             currentPlayingFileName = nil
        }
        stopDisplayLink()
        if audioPlayer != nil {
            do {
#if canImport(UIKit)
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
            } catch {
                Log.error("[AudioPlaybackController] Could not deactivate audio session: \\(error)", category: .ui)
            }
            audioPlayer = nil
        }
    }

    private func stopPlaybackCleanup() {
        isPlaying = false
        stopDisplayLink()
        if audioPlayer != nil {
            do {
#if canImport(UIKit)
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
            } catch {
                Log.error("[AudioPlaybackController] Could not deactivate audio session on cleanup: \\(error)", category: .ui)
            }
             audioPlayer = nil
        }
        onFinishPlaying?()
    }

    @objc fileprivate func updateProgress() {
        guard let player = audioPlayer else {
            if isPlaying { isPlaying = false; stopDisplayLink() }
            return
        }
        // 确保只有在播放时才更新进度和时间
        if player.isPlaying {
            currentTime = player.currentTime
            if duration > 0 {
                progress = player.currentTime / duration
            } else {
                progress = 0
            }
        } else {
            // 如果播放器没有在播放 (例如暂停了)，停止 displayLink
            if isPlaying { // 如果状态错误地认为还在播放
                isPlaying = false
            }
            stopDisplayLink()
        }
    }

    private func startDisplayLink() {
#if canImport(UIKit)
        // 每次 start 都是全新 CADisplayLink——stopDisplayLink 现在真的 invalidate 了，
        // 不再复用之前的 paused 实例。这样 runloop 里不会累积"暂停的僵尸 display link"。
        let proxy = DisplayLinkProxy(target: self)
        displayLinkProxy = proxy
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
        // 限制刷新率到 30fps，平衡 UI 流畅度和 CPU 占用
        link.preferredFrameRateRange = CAFrameRateRange.uiUpdates
        link.add(to: .main, forMode: .common)
        displayLink = link
#else
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0/15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateProgress() }
        }
#endif
    }

    private func stopDisplayLink() {
#if canImport(UIKit)
        // 之前只 `isPaused = true`——CADisplayLink 还留在 runloop 上，proxy 也还在 retain 它。
        // 一旦 controller 因为 deinit 没被触发（retain cycle 或 closure 捕 self），link 就永不消失。
        // 彻底 invalidate + 丢引用，下次 start 时重建。
        displayLink?.invalidate()
        displayLink = nil
        displayLinkProxy = nil
#else
        progressTimer?.invalidate()
        progressTimer = nil
#endif
    }

    // AVAudioPlayerDelegate 的回调 Apple 不保证主线程触发——nonisolated 接底层，然后
    // 显式 hop 回 @MainActor 做状态更新。Swift 6 下从后台改 @Published 会 hard-crash。
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            Log.info("[AudioPlaybackController] Audio finished playing. Success: \(flag)", category: .ui)
            self.progress = 1.0
            self.currentTime = self.duration
            self.stopPlaybackCleanup()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            if let error = error {
                Log.error("[AudioPlaybackController] Audio player decode error: \(error.localizedDescription)", category: .ui)
                self.onPlayError?(error)
            }
            self.stopPlaybackCleanup()
        }
    }

    deinit {
        // 说明：class 打了 @MainActor，但 deinit 运行线程 Swift 不保证——
        // 这里的所有操作都用"非 actor-isolated API 即可（Timer.invalidate / AVAudioPlayer.stop 都是线程安全）。
        // 不能访问 `displayLinkProxy` / `audioPlayer` 等隔离属性——所以拿一份局部引用快照。
#if canImport(UIKit)
        let linkToKill = displayLink
        let proxyToKill = displayLinkProxy
        linkToKill?.invalidate()
        _ = proxyToKill  // 持到 deinit 末尾，避免提前释放 mid-invalidate
#else
        progressTimer?.invalidate()
#endif
        audioPlayer?.stop()
        Log.info("[AudioPlaybackController] deinit", category: .ui)
    }
}

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
        sortDescriptors: [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)]
    ) private var entries: FetchedResults<DiaryEntry>
    
    // AI 服务从 SwiftUI Environment 注入，默认指向 `OpenAIService.shared`。
    // 生产零行为变化；测试 / Preview 里可以 `.environment(\.aiService, MockAIService())` 替换。
    @Environment(\.aiService) private var aiService
    // 语音转录（独立的服务，不和 AI 混在一起）
    private let transcriber: TranscriberProtocol = AppleSpeechRecognizer()
    
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
    @State private var photoVM = HomePhotoViewModel()

    @StateObject private var recorder = AudioRecorder()
    @StateObject private var audioPlaybackController = AudioPlaybackController() // 新的控制器

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

    @AppStorage("appLanguage") private var appLanguage: String = HomeView.defaultAppLanguage

    // MARK: - View-level 路由 / 搜索 / 生命周期 state
    // 这些**留在 HomeView**:和 NavigationStack / sheet / .searchable 生命周期耦合,
    // 抽进 VM 反而要反向同步。
    @State private var selectedEntry: DiaryEntry? = nil
    /// 现在直接驱动 `.sheet` —— 不再走自绘抽屉。
    @State private var isSettingsOpen: Bool = false
    @State private var isInsightsPresented: Bool = false
    @State private var shouldStartEditing: Bool = false
    @State private var entryToDelete: DiaryEntry? = nil
    @State private var showDeleteConfirmation: Bool = false
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



    // Database recreation observer
    @State private var databaseRecreationObserver: NSObjectProtocol?

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
                setupDatabaseRecreationObserver()
                // AI 池可能已就绪（另一视图暖过）——进入首页立即尝试拿一条稳定值
                rollPlaceholderIfNeeded()
            }
            .onDisappear {
                removeDatabaseRecreationObserver()
            }
            .alert(NSLocalizedString("删除日记", comment: "Delete entry"), isPresented: $showDeleteConfirmation) {
                Button(NSLocalizedString("删除", comment: "Delete"), role: .destructive) {
                    if let entry = entryToDelete {
                        deleteEntry(entry)
                    }
                }
                Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {
                    entryToDelete = nil
                }
            } message: {
                Text(NSLocalizedString("确定要删除这篇日记吗？此操作无法撤销。", comment: "Delete confirmation"))
            }
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
                            Image(systemName: "line.3.horizontal")
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
                .sheet(isPresented: $isInsightsPresented) {
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
            .scrollDismissesKeyboard(.interactively)
            .refreshable {
                await triggerManualSync()
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

    /// Pull-to-refresh：触发 CloudKit 同步 + 换一条占位语（从当前池里挑一个不同项）。
    /// AI 池的 `refreshIfNeeded` 走**独立 detached Task**，不塞进 refreshable 窗口——
    /// 否则如果指纹变了要调一次 gpt-5.4（~2-3s），用户会感觉"下拉卡好几秒"。
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
                if !photoVM.selectedImages.isEmpty { photosSection }
                // 卡内分隔线:把"内容区"和"动作区(工具栏)"隔开。
                Capsule()
                    .fill(Color.primary.opacity(0.06))
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
        .onChange(of: inputVM.inputText) { _, newValue in
            let hasContent = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
    }
    
    
    @ViewBuilder
    private var recordingsSection: some View {
        // alert(isPresented:) 要 Binding<Bool>,走 `@Bindable` shadow。
        @Bindable var recordingVM = recordingVM
        VStack(alignment: .leading, spacing: 8) {
            ForEach(recordingVM.audioRecordings) { rec in
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
    
    private func deleteRecording(_ target: String) {
        if audioPlaybackController.currentPlayingFileName == target {
            audioPlaybackController.stopPlayback(clearCurrentFile: true)
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
        // 关键改动 1:每个 item 走 Task.detached 跳到后台 actor —— 之前 addTask 继承父
        // MainActor,compressImage 里的 UIImage 解码 + JPEG 重编码全卡在主线程上,选 9 张图
        // 直接掉帧到底。detached 之后 UI 不再被压死,选完照片到出现缩略图之间也没有阻塞。
        //
        // 关键改动 2:**保序 + 配对收集**。每个 (PhotosPickerItem, Data?) 一起收回来,
        // 失败的丢弃但**两边一起丢弃**。之前只 compactMap selectedImages,
        // selectedPhotos 没动 → 长度不一致 → 删除时 firstIndex(of:) 找 selectedImages 的 idx
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
            .compactMap { (i, data) -> (PhotosPickerItem, Data)? in
                guard let data else { return nil }
                return (items[i], data)
            }

        let prunedItems = successful.map(\.0)
        let images = successful.map(\.1)

        await MainActor.run {
            photoVM.selectedImages = images
            // F2:把 selectedPhotos 也剪枝到只剩压缩成功的 items,保证两边长度严格对齐。
            // 等值检查避免触发自身的 .onChange 死循环 —— PhotosPickerItem 是 Equatable。
            if photoVM.selectedPhotos != prunedItems {
                photoVM.selectedPhotos = prunedItems
            }
            Log.info("[HomeView] Total compressed images: \(photoVM.selectedImages.count)", category: .ui)
        }
    }

    private struct SendSnapshot {
        let text: String
        let audio: String?
        let images: [Data]
        let mood: Double
    }

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
#if canImport(UIKit)
        HapticManager.shared.click()
#endif
        Task {
            // 1. 发送开始：snapshot 输入 + 立即清空 UI，避免 2 秒动画窗口内继续打字造成
            //    情绪分析文本与落库文本错位，或新输入被后续清空吞掉。
            let snapshot = await MainActor.run { () -> SendSnapshot in
                let captured = SendSnapshot(
                    text: inputVM.inputText,
                    audio: recordingVM.currentAudioFileName,
                    images: photoVM.selectedImages,
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
                    photoVM.selectedImages.removeAll()
                    photoVM.selectedPhotos.removeAll()
                }
                hideKeyboard()
                // 发送完成：换一条占位语给用户新的灵感
                rollPlaceholderIfNeeded(force: true)

                return captured
            }

            let textToSend = snapshot.text
            let audioToSend = snapshot.audio
            let imagesToSend = snapshot.images
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
            await saveTask.value

            // 7. 完成动画 → 重置状态
            await MainActor.run {
                withAnimation(AnimationConfig.smoothTransition) {
                    inputVM.sendButtonState = .completed
                    inputVM.isSending = false
                }
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
                Text(photoVM.selectedImages.count == 1 ? NSLocalizedString("1张照片", comment: "") : String(format: NSLocalizedString("%d张照片", comment: ""), photoVM.selectedImages.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // 用 Data 内容作 id —— InputPhotoThumbnail 内部 @State 缓存解码后的
                    // UIImage,如果用 index 作 id,删掉中间一张图后剩下的图接管它的 index
                    // 但 @State 还在 → 一闪"错图配错按钮"。Data 作 id 让 SwiftUI 按内容
                    // 追踪 cell 身份,删除/重排都不会让仍存在的 cell 重新解码。
                    ForEach(photoVM.selectedImages, id: \.self) { data in
                        InputPhotoThumbnail(
                            data: data,
                            onRemove: {
                                withAnimation(AnimationConfig.stiffSpring) {
                                    // 按内容查当前 index —— closure 捕获的 index 在
                                    // selectedImages 被其他事件改过后会过期。
                                    if let idx = photoVM.selectedImages.firstIndex(of: data) {
                                        photoVM.selectedImages.remove(at: idx)
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
    
    private func addEntry(text: String, audioFileName: String?, moodValue: Double? = nil, images: [Data] = []) async {
        // 立即保存日记（不等待标题生成），标题异步生成
        let finalMoodValue = moodValue ?? 0.5
        let entryID = UUID()
        var savedEntryID: UUID?

        // 把磁盘 I/O、CloudKit blob 编码全部挪到非主线程，主线程只做 Core Data 字段赋值 + save。
        // 之前这些都挤在 `await MainActor.run { ... }` 里，附件多一点 UI 就会卡。
        async let preparedAudio: String? = Self.persistAudioOffMain(audioFileName: audioFileName)
        async let preparedImages: [String] = Self.persistImagesOffMain(images: images, entryID: entryID)
        async let preparedSyncBlob: Data? = Self.encodeImagesForSyncOffMain(images: images)

        let (audioName, imageFileNames, syncBlob) = await (preparedAudio, preparedImages, preparedSyncBlob)

        await MainActor.run {
            let newEntry = DiaryEntry(context: viewContext)
            newEntry.id = entryID
            savedEntryID = entryID
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
                Log.info("[HomeView] 日记已保存，标题稍后生成", category: .ui)
            } catch {
                Log.error("[HomeView] 保存日记失败: \(error)", category: .ui)
            }
        }

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

                await MainActor.run {
                    let fetchRequest: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "id == %@", entryID as NSUUID)
                    guard let entry = try? viewContext.fetch(fetchRequest).first else { return }
                    // 跟 DiaryDetailView.refreshAIIndex 同一套 stale-write guard：
                    // 当前 entry.text 已经被更新就跳过这次写入。
                    guard entry.wrappedText == textSnapshot else {
                        Log.info("[HomeView] 文本已被更新，丢弃 stale AI 结果（v1 不覆盖 v2）", category: .ai)
                        return
                    }
                    entry.summary = summary
                    entry.setThemes(themes)
                    if let vector = embedding {
                        entry.setEmbedding(vector)
                    }
                    try? viewContext.save()
                    Log.info("[HomeView] 摘要+主题+索引已更新: themes=\(themes.count), hasEmbedding=\(embedding != nil)", category: .ai)
                }
            }
        }
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
                if !FileManager.default.fileExists(atPath: audioDir.path) {
                    try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true, attributes: nil)
                }
                let iCloudAudioURL = audioDir.appendingPathComponent(audioFileName)
                try? audioData.write(to: iCloudAudioURL)
                try? FileManager.default.removeItem(at: localURL)
                Log.info("[HomeView] Saved audio to iCloud: \(audioFileName)", category: .ui)
            }

            return audioFileName
        }.value
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

    /// 后台线程把图片压缩后 NSKeyedArchiver 编码成 Data，落库时直接赋给 `imagesData`。
    /// 替代原来 `saveImagesForSync`（同步版）在 MainActor 里跑的重活。
    private static func encodeImagesForSyncOffMain(images: [Data]) async -> Data? {
        guard !images.isEmpty else { return nil }
        // **顺序保持**：TaskGroup 的 `for await` 按**完成顺序**yield 结果，不是提交顺序。
        // compressImageData 根据像素量挑 JPEG quality，大图慢、小图快——直接 append 会让 blob
        // 顺序被打乱。用户选 [A, B, C]，blob 里可能是 [B, C, A]；CloudKit 同步到另一台设备 /
        // 重装后，`loadAllImageDataAsync` 优先读 blob，用户看到的图片顺序跟选择时不一样、
        // 且跟 `imageFileNames` 的文件序不一致（永久错位）。
        // 加索引后按 index 落位，保证输出与输入顺序一致。
        let compressed = await withTaskGroup(of: (Int, Data).self, returning: [Data].self) { group in
            for (idx, imageData) in images.enumerated() {
                group.addTask { (idx, DiaryEntry.compressImageData(imageData)) }
            }
            var buffer = [Data?](repeating: nil, count: images.count)
            for await (idx, data) in group {
                buffer[idx] = data
            }
            return buffer.compactMap { $0 }
        }
        do {
            let encoded = try NSKeyedArchiver.archivedData(withRootObject: compressed, requiringSecureCoding: false)
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
            Text(NSLocalizedString("暂无日记，快去记录吧～", comment: "No entries message"))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding()
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
        let lastIndex = entries.count - 1
        ForEach(Array(entries.enumerated()), id: \.element.objectID) { idx, entry in
            timelineRow(entry: entry, isFirst: idx == 0, isLast: idx == lastIndex)
        }
    }

    @ViewBuilder
    private func timelineRow(entry: DiaryEntry, isFirst: Bool, isLast: Bool) -> some View {
        Button {
            // 原先只设 selectedEntry，若上次长按"编辑"后 onDisappear 还没跑完就再次点击，
            // `shouldStartEditing` 残留 true，这次普通点击也会进编辑模式。显式清掉。
            shouldStartEditing = false
            selectedEntry = entry
        } label: {
            timelineCard(for: entry)
                .padding(.bottom, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .contextMenu {
            Button {
                shouldStartEditing = true
                selectedEntry = entry
            } label: {
                Label(NSLocalizedString("编辑", comment: "Edit"), systemImage: "pencil")
            }
            Button(role: .destructive) {
                entryToDelete = entry
                showDeleteConfirmation = true
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
            Button(role: .destructive) {
                entryToDelete = entry
                showDeleteConfirmation = true
            } label: {
                Label(NSLocalizedString("删除", comment: "Delete"), systemImage: "trash")
            }
            Button {
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
    // = 2N 次 alloc + ICU 查表。hoist 到 static，按 locale 缓存。
    private static var cachedWeekdayFormatter: DateFormatter?
    private static var cachedMonthDayFormatter: DateFormatter?
    private static var cachedLocale: String = ""
    private static let timeOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func relativeDateLabel(_ date: Date?) -> String {
        guard let date else { return "" }
        if cal.isDateInToday(date) { return NSLocalizedString("今天", comment: "Today") }
        if cal.isDateInYesterday(date) { return NSLocalizedString("昨天", comment: "Yesterday") }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 0
        // 按 appLanguage 缓存两个 formatter；语言变了重建
        if Self.cachedLocale != appLanguage {
            Self.cachedLocale = appLanguage
            let weekday = DateFormatter()
            weekday.locale = Locale(identifier: appLanguage)
            weekday.dateFormat = "EEEE"
            Self.cachedWeekdayFormatter = weekday
            let monthDay = DateFormatter()
            monthDay.locale = Locale(identifier: appLanguage)
            monthDay.setLocalizedDateFormatFromTemplate("MMMd")
            Self.cachedMonthDayFormatter = monthDay
        }
        let formatter = days < 7 ? Self.cachedWeekdayFormatter : Self.cachedMonthDayFormatter
        return formatter?.string(from: date) ?? ""
    }

    private func timeLabel(_ date: Date?) -> String {
        guard let date else { return "" }
        return Self.timeOnlyFormatter.string(from: date)
    }

    private func cleanedSummary(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "\"", with: "")
    }
    
    func handleStopRecording() async {
        Log.info("[HomeView handleStopRecording START] Current SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
        guard let fileName = recorder.stopRecording() else {
            Log.info("[HomeView handleStopRecording: stopRecording returned nil] SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
            return
        }
        Log.info("[HomeView handleStopRecording: recording stopped, fileName: \(fileName)] SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)

        // 标记正在转录
        await MainActor.run {
            recordingVM.isTranscribing = true
            Log.info("[HomeView handleStopRecording: isTranscribing set to true] SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
        }

        Log.info("[HomeView handleStopRecording] Setting currentAudioFileName. Old SFCFN: \(recordingVM.currentAudioFileName ?? "nil"), New FileName: \(fileName)", category: .ui)

        // UI 理论上已通过 disabled 拦住重复录音，但兜底一下：如果仍存在旧 take，
        // 删掉它们的磁盘文件，避免孤儿音频（数据模型是单值 audioFileName，不会被引用到）。
        var filesToCleanup = Set(recordingVM.audioRecordings.map(\.fileName))
        if let current = recordingVM.currentAudioFileName { filesToCleanup.insert(current) }
        filesToCleanup.remove(fileName)
        for stale in filesToCleanup {
            deleteAudioFileFromDocuments(stale)
        }

        recordingVM.currentAudioFileName = fileName // SET FILENAME in handleStopRecording
        // UI 只保留当前这一段（数据模型也是单值）；新录直接替换。
        withAnimation(AnimationConfig.stiffSpring) {
            let rec = Recording(id: fileName, fileName: fileName, duration: recorder.duration)
            recordingVM.audioRecordings.removeAll()
            recordingVM.audioRecordings.append(rec)
        }
        Log.info("[HomeView handleStopRecording] Did set currentAudioFileName. New SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)

        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        Log.info("[HomeView handleStopRecording: got documentsURL] SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
        let audioURL = documentsURL.appendingPathComponent(fileName)
        Log.info("[HomeView handleStopRecording: got audioURL: \(audioURL)] SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)

        // 开始异步转录任务
        recordingVM.transcriptionTask = Task {
            Log.info("[HomeView handleStopRecording Task START] SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
            Log.info("[HomeView] Using language for transcription: \(appLanguage)", category: .ui)
            let transcribedTextOpt = await transcriber.transcribeAudio(fileURL: audioURL, localeIdentifier: appLanguage)
            // 转录完成，更新状态
            await MainActor.run {
                recordingVM.isTranscribing = false
                Log.info("[HomeView transcriptionTask] isTranscribing set to false", category: .ui)
            }
            if let transcribedText = transcribedTextOpt {
                // 确保当前文件未变更
                guard recordingVM.currentAudioFileName == fileName else {
                    Log.info("[HomeView transcriptionTask] 任务文件已改变，放弃更新", category: .ui)
                    return
                }
                Log.info("[HomeView handleStopRecording Task - transcription successful, text: \(transcribedText)] SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
                // 更新文本并分析情绪
                await MainActor.run {
                    let punctuation = transcribedText.range(of: "[\\u4E00-\\u9FFF]", options: .regularExpression) != nil ? "。" : "."
                    if inputVM.inputText.isEmpty {
                        inputVM.inputText = transcribedText + punctuation
                    } else {
                        inputVM.inputText += transcribedText + punctuation
                    }
                }
                // 转录后不再自动分析情绪，等待发送时统一分析
                Log.info("[HomeView transcriptionTask] Transcription completed, mood analysis will happen on send.", category: .ui)
            } else {
                Log.error("[HomeView transcriptionTask] 转录失败或返回nil", category: .ui)
            }
            Log.info("[HomeView handleStopRecording Task END] SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
        }
        Log.info("[HomeView handleStopRecording END FUNCTION] SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
    }

    private func playAudio(fileName: String) {
        Log.info("[HomeView playAudio START] Requested to play: \(fileName). Current SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)

        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let audioURL = documentsURL.appendingPathComponent(fileName)

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            Log.info("[HomeView playAudio] File NOT FOUND: \(fileName). Current SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
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

        Log.info("[HomeView playAudio] File exists for: \(fileName). Current SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)

        if audioPlaybackController.isPlaying && audioPlaybackController.currentPlayingFileName != fileName {
            Log.info("[HomeView playAudio] Controller was playing another file (\(audioPlaybackController.currentPlayingFileName ?? "nil")). Stopping it. Current SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
            audioPlaybackController.stopPlayback(clearCurrentFile: true)
            Log.info("[HomeView playAudio] Controller stopped. Current SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
        }

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

        // **引用循环防护**：闭包存在 audioPlaybackController 身上、访问 recordingVM.currentAudioFileName，
        // recordingVM 是 `@Observable` 引用类型，若闭包强捕获 recordingVM:
        // closure → recordingVM → (nothing back) —— VM 不持 controller,不成环。
        // 但 HomeView 的 @StateObject 存储仍是引用语义,self-capture 仍有风险。
        // 做法：抓 [weak audioPlaybackController, weak recordingVM]；不在闭包里提到 self。
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
        Log.info("[HomeView playAudio END] For: \(fileName). SFCFN: \(recordingVM.currentAudioFileName ?? "nil")", category: .ui)
    }

    private func hideKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    private func deleteEntry(_ entry: DiaryEntry) {
        // Check if the entry to be deleted is the currently selected one for navigation
        if selectedEntry == entry {
            selectedEntry = nil // Prevent navigation to a deleted item
        }

        // 先停止可能的音频播放，如果该条目正在播放
        if self.audioPlaybackController.currentPlayingFileName == entry.audioFileName {
            self.audioPlaybackController.stopPlayback(clearCurrentFile: true)
        }
        
        // Perform deletion within a withAnimation block for smoother UI updates
        withAnimation {
            // 先清磁盘附件（图片 + 音频），再 delete managed object——
            // managed object 被 delete 之后访问 audioFileName / imageFileNames 会出脏数据。
            entry.deleteAllImages()
            entry.deleteAudioFile()

            viewContext.delete(entry)
            
            do {
                try viewContext.save()
                #if canImport(UIKit)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                #endif
            } catch {
                // Log the error appropriately
                Log.error("[HomeView] 删除日记失败: \(error.localizedDescription)", category: .ui)
                // Potentially show an error to the user
            }
        }
        
        // Ensure entryToDelete is cleared AFTER the operation.
        // If this closure is part of an alert, ensure it's cleared
        // whether the operation succeeded or failed, to reset state.
        entryToDelete = nil
    }
    
    // MARK: - Database Recreation Observer
    
    private func setupDatabaseRecreationObserver() {
        databaseRecreationObserver = NotificationCenter.default.addObserver(
            forName: .databaseRecreated,
            object: nil,
            queue: .main
        ) { _ in
            Log.info("[HomeView] Database recreated notification received", category: .ui)
            handleDatabaseRecreation()
        }
    }
    
    private func removeDatabaseRecreationObserver() {
        if let observer = databaseRecreationObserver {
            NotificationCenter.default.removeObserver(observer)
            databaseRecreationObserver = nil
        }
    }
    
    private func handleDatabaseRecreation() {
        // Clear any local state that might reference deleted objects
        selectedEntry = nil
        entryToDelete = nil
        
        // Stop any ongoing audio playback
        audioPlaybackController.stopPlayback(clearCurrentFile: true)
        
        // Clear input state
        inputVM.inputText = ""
        recordingVM.currentAudioFileName = nil
        recordingVM.audioRecordings.removeAll()
        photoVM.selectedImages.removeAll()
        photoVM.selectedPhotos.removeAll()
        inputVM.moodValue = 0.5

        // Cancel any ongoing tasks
        recordingVM.transcriptionTask?.cancel()
        
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
        .disabled(photoVM.selectedImages.count >= 9)
        .accessibilityLabel(NSLocalizedString("添加照片", comment: "Add photos"))
        .accessibilityIdentifier("home.keyboard.photo")
        .photosPicker(
            isPresented: $photoVM.photosPickerPresented,
            selection: $photoVM.selectedPhotos,
            maxSelectionCount: 9,
            matching: .images
        )
        .onChange(of: photoVM.selectedPhotos) { _, newValue in
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
                recorder.startRecording()
                #if canImport(UIKit)
                // 录音开始的第二记重一些的反馈,告诉用户"已经在录了" ——
                // 不只是按下按钮,而是确认进入了录音状态。
                HapticManager.shared.notification(.success)
                #endif
            }
        } label: {
            Image(systemName: recorder.isRecording ? "stop.circle.fill" : "mic")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(recorder.isRecording ? .red : Color.primary.opacity(0.85))
                .symbolEffect(.bounce, value: recorder.isRecording)
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(recordingVM.audioRecordings.count >= 1 && !recorder.isRecording)
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
            Text(formattedDuration(currentTime: recorder.duration, totalDuration: 0))
                .font(.footnote.weight(.medium).monospacedDigit())
                .foregroundColor(.red)
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
            || !photoVM.selectedImages.isEmpty) && !recordingVM.isTranscribing && !inputVM.isSending
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

    func keywordHits(for text: String) async -> [DiaryEntry] {
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
        return await MainActor.run {
            // 用 existingObject 而不是 object(with:)：后者返回未验证 fault，
            // 若该条目在 fetch→access 之间被 CloudKit tombstone / 用户侧滑删除，
            // 属性首访会抛 NSObjectInaccessibleException（Obj-C 异常，Swift try/catch 接不住）。
            // existingObject 抛 Swift-catchable 错误，try? 安静降级即可。
            objectIDs.compactMap { try? viewContext.existingObject(with: $0) as? DiaryEntry }
        }
    }
}

/// 在按下时微缩按钮的通用样式
struct PressableScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(AnimationConfig.gentleSpring,
                       value: configuration.isPressed)
    }
}

// 插入录音行子视图以简化列表项
struct RecordingRow: View {
    let recording: Recording
    @ObservedObject var controller: AudioPlaybackController
    let isTranscribing: Bool
    let onPlay: () -> Void
    let onDelete: () -> Void

    private var isCurrent: Bool {
        controller.currentPlayingFileName == recording.fileName
    }
    private var isPlayingThis: Bool {
        isCurrent && controller.isPlaying
    }

    var body: some View {
        HStack(spacing: 10) {
            // 左侧 mini 播放/暂停按钮 —— 单层 glass,小尺寸,贴合输入卡的玻璃语言
            Button(action: onPlay) {
                Image(systemName: isPlayingThis ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.glass)
            .disabled(isTranscribing)
            .accessibilityLabel(isPlayingThis
                ? NSLocalizedString("暂停", comment: "Pause")
                : NSLocalizedString("播放", comment: "Play"))

            Image(systemName: "waveform")
                .font(.footnote)
                .foregroundStyle(Color.accentColor.opacity(0.85))

            Text(formattedDuration(
                currentTime: isCurrent ? controller.currentTime : 0,
                totalDuration: recording.duration
            ))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary.opacity(0.85))

            Spacer(minLength: 4)

            // 右侧 ghost 删除钮 —— 不抢眼,但 hit area 够大
            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("删除录音", comment: "Delete recording"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            // 玻璃胶囊背景 + 播放进度作为 accent 色 capsule overlay,
            // 比之前的实色灰底 + 蓝条柔和很多。
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.clear)
                    .liquidGlassCapsule()
                if isCurrent && recording.duration > 0 {
                    GeometryReader { geo in
                        Capsule()
                            .fill(Color.accentColor.opacity(0.18))
                            .frame(width: geo.size.width * controller.progress)
                    }
                    .clipShape(Capsule())
                    .allowsHitTesting(false)
                }
            }
        }
    }
}


// MARK: - Input photo thumbnail (lazy decode + cache)
//
// 抽出独立子视图避免父视图(HomeView)body 重 eval 时反复 `UIImage(data:)` 解码 9 张图。
// 之前每输入一个字符就触发 9 次解码,选完照片后输入卡卡得没法用。
//
// 内部用 .task(id: data) 把 UIImage 解码挪到 Task.detached 后台,完成后存到 @State。
// data 变了(新一组照片)才重新解码。

struct InputPhotoThumbnail: View {
    let data: Data
    let onRemove: () -> Void

    #if canImport(UIKit)
    @State private var decoded: UIImage?
    #else
    @State private var decoded: NSImage?
    #endif

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let decoded {
                    #if canImport(UIKit)
                    Image(uiImage: decoded)
                        .resizable()
                        .scaledToFill()
                    #else
                    Image(nsImage: decoded)
                        .resizable()
                        .scaledToFill()
                    #endif
                } else {
                    Color.secondary.opacity(0.10)
                        .overlay(
                            ProgressView()
                                .controlSize(.small)
                        )
                }
            }
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.white)
                    .background(Circle().fill(Color.black.opacity(0.6)))
            }
            .buttonStyle(PlainButtonStyle())
            .padding(4)
        }
        .task(id: data) {
            // detached → 解码不占主线程,选 9 张图后输入框立刻能用,缩略图陆续浮上来。
            let bytes = data
            let image = await Task.detached(priority: .userInitiated) {
                #if canImport(UIKit)
                return UIImage(data: bytes)
                #else
                return NSImage(data: bytes)
                #endif
            }.value
            await MainActor.run { self.decoded = image }
        }
    }
}

// 日记预览视图
struct DiaryPreviewView: View {
    @ObservedObject var entry: DiaryEntry
    let appLanguage: String
    let onTap: () -> Void

    private let cal = Calendar.current

    var body: some View {
        // 确保 entry 仍然有效
        if entry.managedObjectContext != nil && !entry.isFault {
            let cornerRadius: CGFloat = 20

            VStack(alignment: .leading, spacing: 10) {
                // 日期 / 时间 —— 复用时间线卡片上的 uppercase + tracking 风格
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(relativeDateLabel(entry.wrappedDate))
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.primary)
                        .textCase(.uppercase)
                        .tracking(0.4)
                    Text(timeLabel(entry.wrappedDate))
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.7))
                    Spacer(minLength: 0)
                }

                if let summary = entry.wrappedSummary, !summary.isEmpty {
                    Text(cleanedSummary(summary))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }

                if !entry.wrappedText.isEmpty {
                    Text(entry.wrappedText)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .lineLimit(8)
                        .lineSpacing(3)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                if hasAttachments {
                    HStack(spacing: 8) {
                        if entry.wrappedAudioFileName != nil {
                            attachmentBadge(
                                icon: "mic.fill",
                                label: NSLocalizedString("语音", comment: "Voice attachment badge")
                            )
                        }
                        if imageCount > 0 {
                            attachmentBadge(icon: "photo.fill", label: "\(imageCount)")
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.init(top: 16, leading: 20, bottom: 14, trailing: 16))
            .frame(width: 300, height: 400, alignment: .topLeading)
            .liquidGlassCard(cornerRadius: cornerRadius, interactive: true)
            .moodAccentBar(entry.moodColor, cornerRadius: cornerRadius)
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
        } else {
            // 如果 entry 已被删除或无效，显示一个占位符或空视图
            Color.clear.frame(width: 300, height: 400)
        }
    }

    private var hasAttachments: Bool {
        entry.wrappedAudioFileName != nil || imageCount > 0
    }

    private var imageCount: Int {
        entry.imageFileNameArray.count
    }

    @ViewBuilder
    private func attachmentBadge(icon: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(label)
                .font(.caption2.weight(.medium))
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }

    private func relativeDateLabel(_ date: Date) -> String {
        if cal.isDateInToday(date) { return NSLocalizedString("今天", comment: "Today") }
        if cal.isDateInYesterday(date) { return NSLocalizedString("昨天", comment: "Yesterday") }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 0
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: appLanguage)
        if days < 7 {
            formatter.dateFormat = "EEEE"
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
        }
        return formatter.string(from: date)
    }

    private func timeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func cleanedSummary(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "\"", with: "")
    }
}

#Preview {
    HomeView()
}
