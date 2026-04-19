import SwiftUI
import AVFoundation
import Combine
import CoreData
import PhotosUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Send Button State Machine
enum SendButtonState {
    case idle           // 蓝色（默认状态）
    case sending        // 灰色loading（AI分析中）
    case moodRevealing  // 情绪颜色+脉冲动画（1.2秒）
    case completed      // 淡出回到蓝色
}

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

// 自定义两条横线图标
struct TwoLineIcon: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 1)
                .frame(width: 18, height: 2)
            RoundedRectangle(cornerRadius: 1)
                .frame(width: 12, height: 2)
        }
        .frame(width: 24, height: 24, alignment: .leading)
        .foregroundColor(Color.primary.opacity(0.75))
    }
}

// Custom ButtonStyle for Settings Icon visual feedback
struct SettingsIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(AnimationConfig.fastResponse, value: configuration.isPressed)
    }
}

struct HomeView: View {
    // Core Data 相关
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)],
        animation: .default
    ) private var entries: FetchedResults<DiaryEntry>
    
    // AI 服务（后端代理会处理认证）——走共享实例，避免 HomeView 每次 init 都新建一个。
    private let aiService: AIServiceProtocol = OpenAIService.shared
    // 语音转录（独立的服务，不和 AI 混在一起）
    private let transcriber: TranscriberProtocol = AppleSpeechRecognizer()
    
    // 导入服务（与 SettingsView 共享）
    @EnvironmentObject var importService: CoreDataImportService
    @EnvironmentObject var syncMonitor: CloudKitSyncMonitor
    
    @StateObject private var recorder = AudioRecorder()
    @StateObject private var audioPlaybackController = AudioPlaybackController() // 新的控制器

    @State private var inputText: String = ""
    @State private var isTranscribing = false
    @State private var currentAudioFileName: String? = nil
    @State private var showingDeleteAlert: Bool = false
    @State private var moodValue: Double = 0.5
    @State private var transcriptionTask: Task<Void, Never>? = nil
    @State private var isSending: Bool = false
    @State private var sendButtonState: SendButtonState = .idle
    @State private var revealedMood: Double? = nil
    @State private var textEditorHeight: CGFloat = 140
    @State private var showMoodReveal: Bool = false
    @State private var spectrumDisplayState: SpectrumDisplayState = .idle
    @State private var showingSettingsSheet: Bool = false
    @State private var selectedEntry: DiaryEntry? = nil
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var selectedImages: [Data] = []
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
    
    @State private var audioRecordings: [Recording] = []
    @State private var deleteTarget: String? = nil
    @State private var isSettingsOpen: Bool = false
    @State private var dragOffsetX: CGFloat = 0
    @State private var isInsightsPresented: Bool = false
    @State private var contextPrompts: [ContextPrompt] = []
    /// 稳定的占位语——只在明确时刻更新（进入页面 / 发送完成 / AI 池刷新完成），
    /// 避免 body 重评时反复换给人"抽风"的感觉。
    @State private var stablePlaceholder: String = ""
    @State private var shouldStartEditing: Bool = false
    @State private var entryToDelete: DiaryEntry? = nil
    @State private var showDeleteConfirmation: Bool = false
    /// 冷启动首帧 @FetchRequest 尚未完成时为 false——避免 emptyState 闪一帧。
    @State private var hasLoadedOnce: Bool = false

    // Inline search state — 替代原来的全屏 SearchView sheet
    @State private var isSearchActive: Bool = false
    @State private var searchQuery: String = ""
    @State private var searchResults: [DiaryEntry] = []
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool


    // Database recreation observer
    @State private var databaseRecreationObserver: NSObjectProtocol?

    var body: some View {
        iOSHomeView
    }
    
    // 将 iOS 界面提取为单独的计算属性
    @ViewBuilder
    private var iOSHomeView: some View {
        GeometryReader { geometry in
            let panelWidth = geometry.size.width
            let panelOffsetX = isSettingsOpen ? dragOffsetX : -panelWidth + dragOffsetX
            
            ZStack(alignment: .leading) {
                // 1. 主界面
                mainContentWithGestures(panelWidth: panelWidth)

                // 2. 遮罩层
                settingsMaskLayer(panelWidth: panelWidth, panelOffsetX: panelOffsetX)

                // 3. 设置面板
                settingsPanel(panelWidth: panelWidth, panelOffsetX: panelOffsetX)

                // 4. 情绪动画覆盖
                moodAnimationOverlay
            }
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
        .onChange(of: isSettingsOpen) { _, _ in
            dragOffsetX = 0
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
    private func mainContentWithGestures(panelWidth: CGFloat) -> some View {
        mainContentView
            .disabled(isSettingsOpen)
            .overlay(alignment: .leading) {
                leadingSwipeGesture(panelWidth: panelWidth)
            }
            .overlay(alignment: .trailing) {
                trailingSwipeGesture(panelWidth: panelWidth)
            }
    }
    
    @ViewBuilder
    private func settingsMaskLayer(panelWidth: CGFloat, panelOffsetX: CGFloat) -> some View {
            let normalizedOpen = min(max((panelOffsetX + panelWidth) / panelWidth, 0), 1)
            let maskAlpha = normalizedOpen * 0.3
            
            Color.black.opacity(maskAlpha)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(AnimationConfig.smoothTransition) {
                        isSettingsOpen = false
                        dragOffsetX = 0
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 5)
                        .onChanged { value in
                            if isSettingsOpen {
                                let dx = value.translation.width
                                if dx < 0 {
                                    dragOffsetX = max(dx, -panelWidth)
                                }
                            }
                        }
                        .onEnded { value in
                            if isSettingsOpen {
                                let dx = value.translation.width
                                if dx < -panelWidth * 0.15 {
                                    #if canImport(UIKit)
                                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                                    #endif
                                    withAnimation(AnimationConfig.smoothTransition) {
                                        isSettingsOpen = false
                                        dragOffsetX = 0
                                    }
                                } else {
                                    withAnimation(AnimationConfig.standardResponse) {
                                        dragOffsetX = 0
                                    }
                                }
                            }
                        }
                )
                .allowsHitTesting(isSettingsOpen)
    }
    
    @ViewBuilder
    private var moodAnimationOverlay: some View {
        // 动画现在直接在MoodSpectrumBar上显示，不需要额外覆盖层
        EmptyView()
    }
    
    @ViewBuilder
    private var mainContentView: some View {
            NavigationStack {
                VStack(spacing: 0) {
                    // 顶栏：搜索激活时换成搜索输入条
                    if isSearchActive {
                        inlineSearchBar
                            .transition(.move(edge: .top).combined(with: .opacity))
                    } else {
                        customNavigationBar
                            .transition(.opacity)
                    }

                    // 导入进度条
                    importProgressView

                    // 主列表：搜索中显示结果，否则显示常规时间线
                    if isSearchActive {
                        searchResultsList
                    } else {
                        mainListContent
                    }
                }
                .animation(.interpolatingSpring(stiffness: 320, damping: 28), value: isSearchActive)
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
#if canImport(UIKit)
                .navigationBarHidden(true)
#endif
            }
    }
    
    @ViewBuilder
    private var customNavigationBar: some View {
            HStack {
                Button {
                    #if canImport(UIKit)
                    HapticManager.shared.click()
                    #endif
                    withAnimation(AnimationConfig.smoothTransition) {
                        isSettingsOpen = true
                        dragOffsetX = 0
                    }
                } label: {
                    TwoLineIcon()
                        .padding(8) // 扩大触摸区域
                }
                .contentShape(Rectangle())
                .buttonStyle(SettingsIconButtonStyle())
                .foregroundColor(Color.primary.opacity(0.75))

                Spacer()

                Button {
                    #if canImport(UIKit)
                    HapticManager.shared.click()
                    #endif
                    withAnimation(.interpolatingSpring(stiffness: 320, damping: 28)) {
                        isSearchActive = true
                    }
                    // 下一帧再 focus，避免动画和键盘抢节奏
                    DispatchQueue.main.async { searchFocused = true }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20, weight: .regular))
                        .frame(width: 24, height: 24, alignment: .center)
                }
                .buttonStyle(PressableScaleButtonStyle())
                .foregroundColor(Color.primary.opacity(0.75))
                .accessibilityLabel(NSLocalizedString("搜索日记", comment: "Search diary"))

                Button {
                    #if canImport(UIKit)
                    HapticManager.shared.click()
                    #endif
                    isInsightsPresented = true
                } label: {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 20, weight: .regular))
                        .frame(width: 28, height: 24, alignment: .center)
                }
                .buttonStyle(PressableScaleButtonStyle())
                .foregroundColor(Color.primary.opacity(0.75))
                .accessibilityLabel(NSLocalizedString("洞察", comment: "Insights"))

            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
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
        List {
            // 心情光谱滑块 - Mac优化布局
            moodSliderSection

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
                moodValue: revealedMood ?? moodValue,
                displayState: spectrumDisplayState
            )
            .frame(maxWidth: .infinity)
            .frame(height: 32)
        }
        .frame(height: 80)
        .padding(.horizontal, 16)
        .zIndex(spectrumDisplayState == .revealed ? 100 : 0)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    }
    
    @ViewBuilder
    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            textInputArea
            recordingsSection
            if !selectedImages.isEmpty { photosSection }
            Divider().overlay(Color.primary.opacity(0.08))
            iconToolbarRow
        }
        .padding(.init(top: 14, leading: 14, bottom: 10, trailing: 10))
        .liquidGlassCard(cornerRadius: 22)
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 4)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 12, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var textInputArea: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $inputText)
                .frame(minHeight: 140, maxHeight: 400)
                .frame(height: textEditorHeight)
                .frame(maxWidth: .infinity)
                .background(Color.clear)
                .scrollContentBackground(.hidden)
                .font(.system(size: 17))
                .onChange(of: inputText) { _, newValue in
                    calculateTextHeight(for: newValue)
                    let hasContent = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if hasContent && spectrumDisplayState == .idle {
                        withAnimation(.easeInOut(duration: 1.0)) {
                            spectrumDisplayState = .analyzing
                        }
                    } else if !hasContent && spectrumDisplayState == .analyzing {
                        withAnimation(.easeInOut(duration: 0.8)) {
                            spectrumDisplayState = .idle
                        }
                    }
                }
            if inputText.isEmpty {
                Text(inputPlaceholder)
                    .font(.system(size: 17))
                    .foregroundColor(.secondary.opacity(0.55))
                    .padding(.leading, 5)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
    }
    
    
    @ViewBuilder
    private var recordingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(audioRecordings) { rec in
                RecordingRow(
                    recording: rec,
                    controller: audioPlaybackController,
                    isTranscribing: isTranscribing,
                    onPlay: { playAudio(fileName: rec.fileName) },
                    onDelete: {
                        deleteTarget = rec.fileName
                        showingDeleteAlert = true
                    }
                )
            }
        }
        .frame(height: audioRecordings.isEmpty ? 0 : nil)
        .alert(NSLocalizedString("删除录音？", comment: "Delete recording confirmation"), isPresented: $showingDeleteAlert) {
            Button(NSLocalizedString("删除", comment: "Delete button"), role: .destructive) {
                if let target = deleteTarget {
                    deleteRecording(target)
                }
            }
            Button(NSLocalizedString("取消", comment: "Cancel button"), role: .cancel) {
                deleteTarget = nil
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
            audioRecordings.removeAll { $0.fileName == target }
        }
        // 清掉对已删除文件的悬空引用，否则再发送会把不存在的文件名落库
        if currentAudioFileName == target {
            currentAudioFileName = nil
        }
        deleteTarget = nil
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
        var compressedImages: [Data] = []

        await withTaskGroup(of: Data?.self) { group in
            for item in items {
                group.addTask {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        let originalSize = data.count
                        if let compressed = await data.compressImage(maxSizeKB: 500, maxDimension: 1024) {
                            let compressedSize = compressed.count
                            Log.info("[HomeView] Image compressed: \(originalSize/1024)KB → \(compressedSize/1024)KB", category: .ui)
                            return compressed
                        }
                    }
                    return nil
                }
            }

            for await compressedData in group {
                if let data = compressedData {
                    compressedImages.append(data)
                }
            }
        }

        await MainActor.run {
            selectedImages = compressedImages
            Log.info("[HomeView] Total compressed images: \(selectedImages.count)", category: .ui)
        }
    }

    private func calculateTextHeight(for text: String) {
        let lineCount = text.components(separatedBy: "\n").count
        let estimatedHeight = max(140, min(400, CGFloat(lineCount) * 22 + 40))

        withAnimation(AnimationConfig.smoothTransition) {
            textEditorHeight = estimatedHeight
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
        guard !isSending else {
            Log.info("[HomeView SendButton] 已有发送在跑，忽略重复 tap", category: .ui)
            return
        }
        // **必须**同步置位。以前 `isSending = true` 写在下面 `Task { MainActor.run { ... } }`
        // 里，两次极速 tap 之间的 SwiftUI dispatch 窗口（第一次 Task 尚未跑进 MainActor.run）
        // 内，第二次 tap 照样能过上面的 guard —— 两条日记双发落库。
        // handleSendAction 由 Button action 触发，天然在主线程，`@State` 同步写合法。
        isSending = true
#if canImport(UIKit)
        HapticManager.shared.click()
#endif
        Task {
            // 1. 发送开始：snapshot 输入 + 立即清空 UI，避免 2 秒动画窗口内继续打字造成
            //    情绪分析文本与落库文本错位，或新输入被后续清空吞掉。
            let snapshot = await MainActor.run { () -> SendSnapshot in
                let captured = SendSnapshot(
                    text: inputText,
                    audio: currentAudioFileName,
                    images: selectedImages,
                    mood: moodValue
                )

                Log.info("[HomeView SendButton] Starting send action", category: .ui)
                withAnimation(AnimationConfig.standardResponse) {
                    sendButtonState = .sending
                    // isSending 已在 Task 外同步置 true，这里不重复写。
                    spectrumDisplayState = .analyzing  // 光谱进入分析状态（呼吸效果）
                }
                withAnimation(AnimationConfig.fastResponse) {
                    inputText = ""
                    currentAudioFileName = nil
                    audioRecordings.removeAll()
                    selectedImages.removeAll()
                    selectedPhotos.removeAll()
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
                    self.moodValue = mood
                }
            }

            // 3. 显示情绪反馈 → spectrum揭示结果（光点聚焦动画）
            await MainActor.run {
                withAnimation(AnimationConfig.smoothTransition) {
                    revealedMood = finalMoodValue
                    sendButtonState = .moodRevealing
                    spectrumDisplayState = .revealed  // 光谱显示结果
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
                    sendButtonState = .completed
                    isSending = false
                }
            }

            try? await Task.sleep(nanoseconds: 300_000_000)

            await MainActor.run {
                withAnimation(AnimationConfig.smoothTransition) {
                    sendButtonState = .idle
                    revealedMood = nil
                    spectrumDisplayState = .idle  // 光谱重置
                }
            }

            Log.info("[HomeView SendButton] Send action completed", category: .ui)
        }
    }
    
    @ViewBuilder
    private func leadingSwipeGesture(panelWidth: CGFloat) -> some View {
        if selectedEntry == nil && !isSettingsOpen {
            Color.clear
                .frame(width: 20)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { value in
                            let dx = value.translation.width
                            let dy = value.translation.height
                            // 水平滑动大于垂直，且起始点在左边缘
                            if abs(dx) > abs(dy) && dx > 0 {
                                dragOffsetX = min(dx, panelWidth)
                            }
                        }
                        .onEnded { value in
                            let dx = value.translation.width
                            if dx > panelWidth * 0.2 {
                                #if canImport(UIKit)
                                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                                #endif
                                withAnimation(AnimationConfig.smoothTransition) {
                                    isSettingsOpen = true
                                    dragOffsetX = 0
                                }
                            } else {
                                withAnimation(AnimationConfig.standardResponse) {
                                    dragOffsetX = 0
                                }
                            }
                        }
                )
        }
    }
    
    @ViewBuilder
    private func trailingSwipeGesture(panelWidth: CGFloat) -> some View {
        if selectedEntry == nil && !isSettingsOpen {
            Color.clear
                .frame(width: 20)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .onEnded { value in
                            let dx = value.translation.width
                            let dy = value.translation.height
                            if abs(dx) > abs(dy) && dx < 0 {
                                if dx < -panelWidth * 0.1 {
                                    #if canImport(UIKit)
                                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                                    #endif
                                    isInsightsPresented = true
                                }
                            }
                        }
                )
        }
    }
    

    
    @ViewBuilder
    private func settingsPanel(panelWidth: CGFloat, panelOffsetX: CGFloat) -> some View {
            SettingsView(isSettingsOpen: $isSettingsOpen)
                .environmentObject(importService)
                .environment(\.managedObjectContext, viewContext)
                .frame(width: panelWidth)
                #if canImport(UIKit)
                .background(Color(UIColor.systemBackground))
                #else
                .background(Color(NSColor.windowBackgroundColor))
                #endif
                .offset(x: panelOffsetX)
                .animationIfChanged(AnimationConfig.smoothTransition, value: panelOffsetX)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 5)
                        .onChanged { value in
                            let dx = value.translation.width
                            let dy = value.translation.height
                            if isSettingsOpen && abs(dx) > abs(dy) {
                                dragOffsetX = min(max(dx, -panelWidth), 0)
                            }
                        }
                        .onEnded { _ in
                            if isSettingsOpen {
                                if dragOffsetX < -panelWidth * 0.15 {
                                    #if canImport(UIKit)
                                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                                    #endif
                                    withAnimation(AnimationConfig.smoothTransition) {
                                        isSettingsOpen = false
                                        dragOffsetX = 0
                                    }
                                } else {
                                    withAnimation(AnimationConfig.standardResponse) {
                                        dragOffsetX = 0
                                    }
                                }
                            }
                        }
                )
    }

    @ViewBuilder
    private var photosSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "photo.stack")
                    .foregroundColor(.blue)
                Text(selectedImages.count == 1 ? NSLocalizedString("1张照片", comment: "") : String(format: NSLocalizedString("%d张照片", comment: ""), selectedImages.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(selectedImages.indices, id: \.self) { index in
                        Group {
                            #if os(iOS)
                            if let uiImage = UIImage(data: selectedImages[index]) {
                                ZStack(alignment: .topTrailing) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 80, height: 80)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    
                                    Button(action: {
                                        withAnimation(AnimationConfig.stiffSpring) {
                                            selectedImages.remove(at: index)
                                            if index < selectedPhotos.count {
                                                selectedPhotos.remove(at: index)
                                            }
                                        }
                                    }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 20))
                                            .foregroundColor(.white)
                                            .background(
                                                Circle()
                                                    .fill(Color.black.opacity(0.6))
                                            )
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .padding(4)
                                }
                            }
                            #else
                            if let nsImage = NSImage(data: selectedImages[index]) {
                                ZStack(alignment: .topTrailing) {
                                    Image(nsImage: nsImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 80, height: 80)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    
                                    Button(action: {
                                        withAnimation(AnimationConfig.stiffSpring) {
                                            selectedImages.remove(at: index)
                                            if index < selectedPhotos.count {
                                                selectedPhotos.remove(at: index)
                                            }
                                        }
                                    }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 20))
                                            .foregroundColor(.white)
                                            .background(
                                                Circle()
                                                    .fill(Color.black.opacity(0.6))
                                            )
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .padding(4)
                                }
                            }
                            #endif
                        }
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
        timelineSectionHeader
        // **NOTE — 为什么不用 `ForEach(entries, id: \.objectID)`**：
        // 这里的 ForEach 在外层 `List` 里。换成 objectID identity 后，SwiftUI 的 List
        // 能识别"单行 delete"，会播**原生 row-removal 动画**（被删行 fade + 下方 slide up）；
        // 叠加 `deleteEntry` 里的 `withAnimation { }` 外包装以及 `@FetchRequest(animation: .default)`
        // 的内建动画，三层动画时序错开，视觉上出现"行错位"。小规模用户 500 条的 index-shuffle
        // 重建 overhead 可接受，先让视觉稳定，性能后续换分页 / `fetchLimit` 方案解决。
        let lastIndex = entries.count - 1
        ForEach(entries.indices, id: \.self) { idx in
            let entry = entries[idx]
            timelineRow(entry: entry, isFirst: idx == 0, isLast: idx == lastIndex)
                .id(entry.objectID)
        }
    }

    /// 输入框和第一条日记之间的分节线：纯一条淡色细线居中。
    @ViewBuilder
    private var timelineSectionHeader: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.18))
            .frame(height: 0.5)
            .padding(.top, 6)
            .padding(.bottom, 8)
            .padding(.horizontal, 60)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .accessibilityHidden(true)
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
        .liquidGlassCard(cornerRadius: cornerRadius)
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
        Log.info("[HomeView handleStopRecording START] Current SFCFN: \(currentAudioFileName ?? "nil")", category: .ui)
        guard let fileName = recorder.stopRecording() else {
            Log.info("[HomeView handleStopRecording: stopRecording returned nil] SFCFN: \(currentAudioFileName ?? "nil")", category: .ui)
            return
        }
        Log.info("[HomeView handleStopRecording: recording stopped, fileName: \(fileName)] SFCFN: \(currentAudioFileName ?? "nil")", category: .ui)
        
        // 标记正在转录
        await MainActor.run {
            isTranscribing = true
            Log.info("[HomeView handleStopRecording: isTranscribing set to true] SFCFN: \(currentAudioFileName ?? "nil")", category: .ui)
        }
        
        Log.info("[HomeView handleStopRecording] Setting currentAudioFileName. Old SFCFN: \(currentAudioFileName ?? "nil"), New FileName: \(fileName)", category: .ui)

        // UI 理论上已通过 disabled 拦住重复录音，但兜底一下：如果仍存在旧 take，
        // 删掉它们的磁盘文件，避免孤儿音频（数据模型是单值 audioFileName，不会被引用到）。
        var filesToCleanup = Set(audioRecordings.map(\.fileName))
        if let current = currentAudioFileName { filesToCleanup.insert(current) }
        filesToCleanup.remove(fileName)
        for stale in filesToCleanup {
            deleteAudioFileFromDocuments(stale)
        }

        currentAudioFileName = fileName // SET FILENAME in handleStopRecording
        // UI 只保留当前这一段（数据模型也是单值）；新录直接替换。
        withAnimation(AnimationConfig.stiffSpring) {
            let rec = Recording(id: fileName, fileName: fileName, duration: recorder.duration)
            audioRecordings.removeAll()
            audioRecordings.append(rec)
        }
        Log.info("[HomeView handleStopRecording] Did set currentAudioFileName. New SFCFN: \(currentAudioFileName ?? "nil")", category: .ui)
        
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        Log.info("[HomeView handleStopRecording: got documentsURL] SFCFN: \(currentAudioFileName ?? "nil")", category: .ui)
        let audioURL = documentsURL.appendingPathComponent(fileName)
        Log.info("[HomeView handleStopRecording: got audioURL: \(audioURL)] SFCFN: \(currentAudioFileName ?? "nil")", category: .ui)
        
        // 开始异步转录任务
        transcriptionTask = Task {
            Log.info("[HomeView handleStopRecording Task START] SFCFN: \(currentAudioFileName ?? "nil")", category: .ui)
            Log.info("[HomeView] Using language for transcription: \(appLanguage)", category: .ui)
            let transcribedTextOpt = await transcriber.transcribeAudio(fileURL: audioURL, localeIdentifier: appLanguage)
            // 转录完成，更新状态
            await MainActor.run {
                isTranscribing = false
                Log.info("[HomeView transcriptionTask] isTranscribing set to false", category: .ui)
            }
            if let transcribedText = transcribedTextOpt {
                // 确保当前文件未变更
                guard currentAudioFileName == fileName else {
                    Log.info("[HomeView transcriptionTask] 任务文件已改变，放弃更新", category: .ui)
                    return
                }
                Log.info("[HomeView handleStopRecording Task - transcription successful, text: \(transcribedText)] SFCFN: \(currentAudioFileName ?? "nil")", category: .ui)
                // 更新文本并分析情绪
                await MainActor.run {
                    let punctuation = transcribedText.range(of: "[\\u4E00-\\u9FFF]", options: .regularExpression) != nil ? "。" : "."
                    if inputText.isEmpty {
                        inputText = transcribedText + punctuation
                    } else {
                        inputText += transcribedText + punctuation
                    }
                }
                // 转录后不再自动分析情绪，等待发送时统一分析
                Log.info("[HomeView transcriptionTask] Transcription completed, mood analysis will happen on send.", category: .ui)
            } else {
                Log.error("[HomeView transcriptionTask] 转录失败或返回nil", category: .ui)
            }
            Log.info("[HomeView handleStopRecording Task END] SFCFN: \(currentAudioFileName ?? "nil")", category: .ui)
        }
        Log.info("[HomeView handleStopRecording END FUNCTION] SFCFN: \(currentAudioFileName ?? "nil")", category: .ui)
    }

    private func playAudio(fileName: String) {
        Log.info("[HomeView playAudio START] Requested to play: \(fileName). Current SFCFN: \(currentAudioFileName ?? "nil")", category: .ui)

        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let audioURL = documentsURL.appendingPathComponent(fileName)

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            Log.info("[HomeView playAudio] File NOT FOUND: \(fileName). Current SFCFN: \(currentAudioFileName ?? "nil")", category: .ui)
            if currentAudioFileName == fileName { // 如果UI上显示的是这个不存在的文件
                 Log.info("[HomeView playAudio] Clearing SFCFN because file missing. Old SFCFN: \(currentAudioFileName ?? "nil")", category: .ui)
                 withAnimation(AnimationConfig.standardResponse) {
                    currentAudioFileName = nil // SET NIL
                    Log.info("[HomeView playAudio] Did set SFCFN to nil due to missing file. New SFCFN: \(self.currentAudioFileName ?? "nil")", category: .ui)
                 }
                 if audioPlaybackController.currentPlayingFileName == fileName {
                    audioPlaybackController.stopPlayback()
                 }
            }
            return
        }
        
        Log.info("[HomeView playAudio] File exists for: \(fileName). Current SFCFN: \(currentAudioFileName ?? "nil")", category: .ui)

        if audioPlaybackController.isPlaying && audioPlaybackController.currentPlayingFileName != fileName {
            Log.info("[HomeView playAudio] Controller was playing another file (\(audioPlaybackController.currentPlayingFileName ?? "nil")). Stopping it. Current SFCFN: \(currentAudioFileName ?? "nil")", category: .ui)
            audioPlaybackController.stopPlayback(clearCurrentFile: true) 
            Log.info("[HomeView playAudio] Controller stopped. Current SFCFN: \(currentAudioFileName ?? "nil")", category: .ui)
        }
        
        Log.info("[HomeView playAudio] Calling controller.play for: \(fileName). Current SFCFN: \(currentAudioFileName ?? "nil")", category: .ui)
        audioPlaybackController.play(url: audioURL, fileName: fileName)
        Log.info("[HomeView playAudio] Called controller.play. Controller isPlaying: \(audioPlaybackController.isPlaying), Controller file: \(audioPlaybackController.currentPlayingFileName ?? "nil"). Current SFCFN: \(currentAudioFileName ?? "nil")", category: .ui)

        if self.currentAudioFileName != fileName {
            Log.info("[HomeView playAudio] SFCFN (\(self.currentAudioFileName ?? "nil")) != fileName (\(fileName)). Restoring SFCFN.", category: .ui)
            withAnimation(AnimationConfig.standardResponse) { 
                 self.currentAudioFileName = fileName // SET FILENAME
                 Log.info("[HomeView playAudio] Did set SFCFN to \(fileName). New SFCFN: \(self.currentAudioFileName ?? "nil")", category: .ui)
            }
        }

        // **引用循环防护**：闭包存在 audioPlaybackController 身上、访问 self.currentAudioFileName，
        // self 是 HomeView struct 但里面的 @StateObject 存储是引用语义——
        // closure → self → @StateObject audioPlaybackController → closure 形成完整循环，
        // `@StateObject` 的 deinit 被顶死永不触发，运行时泄漏 `audioPlaybackController` + 它拿的
        // AVAudioPlayer / CADisplayLink / AudioSession 资源。
        // 做法：抓 Binding 而不是 self，抓 [weak audioPlaybackController]；不在闭包里提到 self。
        let fileNameBinding = $currentAudioFileName
        audioPlaybackController.onFinishPlaying = { [weak audioPlaybackController, capturedFileName = fileName] in
            Task { @MainActor in
                guard let controller = audioPlaybackController else { return }
                Log.info("[HomeView playAudio CB_Finish] Playback finished for \(capturedFileName)", category: .ui)
                if fileNameBinding.wrappedValue == nil && capturedFileName == controller.currentPlayingFileName {
                    withAnimation(AnimationConfig.standardResponse) {
                        fileNameBinding.wrappedValue = capturedFileName
                    }
                }
                if !controller.isPlaying, controller.currentPlayingFileName == capturedFileName {
                    controller.stopPlayback(clearCurrentFile: true)
                }
            }
        }
        audioPlaybackController.onPlayError = { [weak audioPlaybackController, capturedFileName = fileName] error in
            Task { @MainActor in
                guard let controller = audioPlaybackController else { return }
                Log.error("[HomeView playAudio CB_Error] Playback error for \(capturedFileName): \(error.localizedDescription)", category: .ui)
                if fileNameBinding.wrappedValue == nil && capturedFileName == controller.currentPlayingFileName {
                    withAnimation(AnimationConfig.standardResponse) {
                        fileNameBinding.wrappedValue = capturedFileName
                    }
                }
                if controller.currentPlayingFileName == capturedFileName {
                    controller.stopPlayback(clearCurrentFile: true)
                }
            }
        }
        Log.info("[HomeView playAudio END] For: \(fileName). SFCFN: \(currentAudioFileName ?? "nil")", category: .ui)
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
        inputText = ""
        currentAudioFileName = nil
        audioRecordings.removeAll()
        selectedImages.removeAll()
        selectedPhotos.removeAll()
        moodValue = 0.5

        // Cancel any ongoing tasks
        transcriptionTask?.cancel()
        
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
        stablePlaceholder.isEmpty
            ? NSLocalizedString("今天是怎样的一天呢？", comment: "Daily prompt fallback")
            : stablePlaceholder
    }

    /// 在三级 fallback 里挑一条写入 `stablePlaceholder`：
    ///   1. AI 池 `PromptSuggestionEngine.randomHomePlaceholder`
    ///   2. 本地 `contextPrompts` 第一条
    ///   3. 不动（保持 "今天是怎样的一天呢？" 兜底）
    func rollPlaceholderIfNeeded(force: Bool = false) {
        if !force && !stablePlaceholder.isEmpty { return }
        if let aiLine = PromptSuggestionEngine.shared.randomHomePlaceholder() {
            stablePlaceholder = aiLine
            return
        }
        if let first = contextPrompts.first {
            stablePlaceholder = first.text
            return
        }
        // 保持旧值；下次 AI 池 / 本地模板就绪会再试
    }

    /// 启动 / 进入首页时调。**本地 fallback 先顶上，AI 在后台刷新**：
    /// 冷启动 + 无 cache + 网慢时，`refreshIfNeeded` 可能要几秒，不能让占位语被它拖着等——
    /// 先把本地 `ContextPromptGenerator` 的结果 apply + roll 一次，AI 完成后再 roll 第二次，
    /// 有新池就无缝升级，没新池也不影响用户看到合理的本地占位。
    private func loadContextPrompts() async {
        let aiRefreshTask = Task.detached(priority: .utility) {
            await PromptSuggestionEngine.shared.refreshIfNeeded()
        }

        let prompts = await ContextPromptGenerator.shared.generate()
        await MainActor.run {
            withAnimation(AnimationConfig.smoothTransition) {
                self.contextPrompts = prompts
            }
            rollPlaceholderIfNeeded()
        }

        await aiRefreshTask.value
        await MainActor.run {
            // AI 池准备好了，强制 roll 一次，让首页用户第一屏能看到 AI 写的占位语。
            rollPlaceholderIfNeeded(force: true)
        }
    }
}

// MARK: - Input Toolbar

extension HomeView {
    @ViewBuilder
    var iconToolbarRow: some View {
        HStack(spacing: 4) {
            CompactMicButton(
                recorder: recorder,
                onStop: { await handleStopRecording() },
                disabled: audioRecordings.count >= 1
            )

            PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 9, matching: .images) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.primary.opacity(0.75))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(PressableScaleButtonStyle())
            .disabled(selectedImages.count >= 9)

            Spacer(minLength: 0)

            if recorder.isRecording {
                Text(formattedDuration(currentTime: recorder.duration, totalDuration: 0))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundColor(.red)
                    .transition(.opacity)
            }

            CompactSendButton(
                buttonState: $sendButtonState,
                revealedMood: $revealedMood,
                isEnabled: hasSendableContent,
                action: handleSendAction
            )
        }
        .onChange(of: selectedPhotos) { _, newValue in
            Task { await loadPhotosWithCompression(newValue) }
        }
    }

    var hasSendableContent: Bool {
        // `!isSending` 是重发双点防护：`handleSendAction` 把 isSending flip 到 true 的是
        // 在第一个 `await MainActor.run` 里（本身是 sync block），所以 flip 发生在 Task 创建后
        // 至少一个调度点之后——这个窗口里用户再点一下发送按钮，`hasSendableContent`
        // 仍为 true，就会进来第二次 `handleSendAction`，snapshot 的都是旧内容，并行写两条重复日记。
        // 把 `isSending` 纳入 `hasSendableContent` 做 UI 级互斥，handleSendAction 开头再加一层
        // guard 兜底，双重保险。
        (!inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !audioRecordings.isEmpty
            || !selectedImages.isEmpty) && !isTranscribing && !isSending
    }
}

// MARK: - Inline search

extension HomeView {
    @ViewBuilder
    var inlineSearchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    NSLocalizedString("搜索日记", comment: "Search field prompt"),
                    text: $searchQuery
                )
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .submitLabel(.search)
                .onChange(of: searchQuery) { _, newValue in
                    scheduleInlineSearch(for: newValue)
                }
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                        searchResults = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(NSLocalizedString("清空搜索", comment: "Clear search"))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .liquidGlassCapsule()

            Button(NSLocalizedString("取消", comment: "Cancel")) {
                #if canImport(UIKit)
                HapticManager.shared.click()
                #endif
                searchFocused = false
                searchTask?.cancel()
                withAnimation(.interpolatingSpring(stiffness: 320, damping: 28)) {
                    isSearchActive = false
                    searchQuery = ""
                    searchResults = []
                }
            }
            .font(.body)
            .foregroundStyle(Color.primary.opacity(0.85))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

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

// MARK: - Compact icon buttons (for toolbar & floating input styles)

struct CompactMicButton: View {
    @ObservedObject var recorder: AudioRecorder
    var onStop: () async -> Void
    var disabled: Bool = false
    var size: CGFloat = 44

    @State private var pulseOpacity: Double = 0

    var body: some View {
        Button {
            #if canImport(UIKit)
            HapticManager.shared.click()
            #endif
            if recorder.isRecording {
                Task { await onStop() }
            } else {
                recorder.startRecording()
            }
        } label: {
            ZStack {
                if recorder.isRecording {
                    Circle()
                        .fill(Color.red)
                    Circle()
                        .stroke(Color.red.opacity(0.4), lineWidth: 2)
                        .opacity(pulseOpacity)
                }
                Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(recorder.isRecording ? .white : Color.primary.opacity(0.8))
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(PressableScaleButtonStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1.0)
        .animation(AnimationConfig.bouncySpring, value: recorder.isRecording)
        .onChange(of: recorder.isRecording) { _, isRecording in
            if isRecording {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulseOpacity = 1.0
                }
            } else {
                pulseOpacity = 0.0
            }
        }
    }
}

struct CompactSendButton: View {
    @Binding var buttonState: SendButtonState
    @Binding var revealedMood: Double?
    let isEnabled: Bool
    let action: () -> Void
    var size: CGFloat = 44

    @State private var bounce: Int = 0

    var body: some View {
        Button {
            bounce &+= 1
            action()
        } label: {
            ZStack {
                iconView
            }
            .frame(width: size, height: size)
            .foregroundStyle(iconColor)
            .contentShape(Circle())
        }
        .buttonStyle(PressableScaleButtonStyle())
        .disabled(!isEnabled || buttonState != .idle)
        .scaleEffect(buttonState == .moodRevealing ? 1.1 : 1.0)
        .animation(AnimationConfig.smoothTransition, value: buttonState)
        .accessibilityLabel(NSLocalizedString("发送", comment: "Send"))
    }

    /// 和 mic/photo 统一：只是一个 symbol；颜色用"可用 → accent 蓝 / 禁用 → 次要灰"语义来暗示状态。
    /// 不加额外玻璃底、光晕或阴影；按钮在 iconToolbarRow 里已经坐在 liquidGlassCard 上，够了。
    @ViewBuilder
    private var iconView: some View {
        switch buttonState {
        case .sending:
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .secondary))
                .scaleEffect(0.75)
        default:
            Image(systemName: "paperplane.fill")
                .font(.system(size: size * 0.42, weight: .semibold))
                .symbolEffect(.bounce, value: bounce)
        }
    }

    /// 仅用颜色区分状态，不再堆叠玻璃+光晕
    private var iconColor: Color {
        switch buttonState {
        case .idle, .completed:
            return isEnabled
                ? Color(red: 48/255, green: 164/255, blue: 255/255)
                : Color.primary.opacity(0.3)
        case .sending:
            return .secondary
        case .moodRevealing:
            return Color.moodSpectrum(value: revealedMood ?? 0.5)
        }
    }
}

// 插入录音行子视图以简化列表项
struct RecordingRow: View {
    let recording: Recording
    @ObservedObject var controller: AudioPlaybackController
    let isTranscribing: Bool
    let onPlay: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .foregroundColor(.blue)
            Text(formattedDuration(
                currentTime: controller.currentPlayingFileName == recording.fileName ? controller.currentTime : 0,
                totalDuration: recording.duration
            ))
                .font(.caption)
                .monospacedDigit()
            Spacer()
            Button(action: onPlay) {
                Image(systemName: controller.isPlaying && controller.currentPlayingFileName == recording.fileName ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(PlainButtonStyle())
            .fixedSize()
            .disabled(isTranscribing)
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.red)
            }
            .buttonStyle(PlainButtonStyle())
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
#if canImport(UIKit)
                    .fill(Color(.systemGray6))
#else
                    .fill(Color(NSColor.controlBackgroundColor))
#endif
                if controller.currentPlayingFileName == recording.fileName && recording.duration > 0 {
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.blue.opacity(0.3))
                            .frame(width: geo.size.width * controller.progress)
                    }
                }
            }
        )
        // 移除自定义 transition，依赖 withAnimation 平滑移动
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
            .liquidGlassCard(cornerRadius: cornerRadius)
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