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

// 新的音频播放控制器
class AudioPlaybackController: NSObject, AVAudioPlayerDelegate, ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var progress: Double = 0.0 // 0.0 to 1.0
    @Published var duration: TimeInterval = 0.0
    @Published var currentTime: TimeInterval = 0.0
    @Published private(set) var currentPlayingFileName: String? // 用于确保只操作当前音频. private(set) 外部只读

    private var audioPlayer: AVAudioPlayer?
#if canImport(UIKit)
    private var displayLink: CADisplayLink?
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
            print("[AudioPlaybackController] Could not play audio: \\(error)")
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
                print("[AudioPlaybackController] Could not deactivate audio session: \\(error)")
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
                print("[AudioPlaybackController] Could not deactivate audio session on cleanup: \\(error)")
            }
             audioPlayer = nil
        }
        onFinishPlaying?()
    }

    @objc private func updateProgress() {
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
        if displayLink == nil {
            displayLink = CADisplayLink(target: self, selector: #selector(updateProgress))
            // 限制刷新率到 30fps，平衡 UI 流畅度和 CPU 占用
            if #available(iOS 15.0, macOS 12.0, *) {
                displayLink?.preferredFrameRateRange = CAFrameRateRange.uiUpdates
            } else {
                displayLink?.preferredFramesPerSecond = 15  // 优化：从30fps降至15fps
            }
            displayLink?.add(to: .main, forMode: .common)
        }
        displayLink?.isPaused = false
#else
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0/15.0, repeats: true) { _ in  // 优化：从30fps降至15fps
            self.updateProgress()
        }
#endif
    }

    private func stopDisplayLink() {
#if canImport(UIKit)
        displayLink?.isPaused = true
#else
        progressTimer?.invalidate()
        progressTimer = nil
#endif
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        print("[AudioPlaybackController] Audio finished playing. Success: \\(flag)")
        // Set progress to 1.0 when playback completes
        progress = 1.0
        currentTime = duration
        stopPlaybackCleanup()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        if let error = error {
            print("[AudioPlaybackController] Audio player decode error: \\(error.localizedDescription)")
            onPlayError?(error)
        }
        stopPlaybackCleanup()
    }
    
    deinit {
#if canImport(UIKit)
        displayLink?.invalidate()
        displayLink = nil
#else
        progressTimer?.invalidate()
        progressTimer = nil
#endif
        audioPlayer?.stop()
        print("[AudioPlaybackController] deinit")
    }
}

// 支持多条录音，最多3条
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
    
    // AI 服务（从 DiaryStore 中提取）
    private let aiService = AppleRecognitionService(openAIApiKey: AppSecrets.openAIKey)
    
    // 导入服务（与 SettingsView 共享）
    @EnvironmentObject var importService: CoreDataImportService
    
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
    @State private var isCalendarActive: Bool = false
    @State private var shouldStartEditing: Bool = false
    @State private var entryToDelete: DiaryEntry? = nil
    @State private var showDeleteConfirmation: Bool = false
    
    // Mac toolbar action listeners
    @State private var macToolbarListeners: [Any] = []
    
    // Database recreation observer
    @State private var databaseRecreationObserver: NSObjectProtocol?

    var body: some View {
        #if targetEnvironment(macCatalyst)
        // Use Mac-specific navigation
        MacNavigationView()
            .environment(\.managedObjectContext, viewContext)
            .environmentObject(importService)
        #else
        // Original iOS interface
        iOSHomeView
        #endif
    }
    
    // 将 iOS 界面提取为单独的计算属性
    @ViewBuilder
    private var iOSHomeView: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // 计算设置面板相关变量 - Mac优化
                let panelWidth = UIDevice.isMac ? MacOptimizedSpacing.sidebarWidth : geometry.size.width
                let panelOffsetX = isSettingsOpen ? dragOffsetX : -panelWidth + dragOffsetX
                let normalizedOpen = min(max((panelOffsetX + panelWidth) / panelWidth, 0), 1)
                let maskAlpha = UIDevice.isMac ? 0 : normalizedOpen * 0.3

                // 主界面 - Mac自适应布局
                mainContentView
                    .disabled(isSettingsOpen && !UIDevice.isMac)
                    .overlay(alignment: .leading) {
                        leadingSwipeGesture(panelWidth: panelWidth)
                    }
                    .overlay(alignment: .trailing) {
                        trailingSwipeGesture(panelWidth: panelWidth)
                    }

                // 遮罩层 - iOS only
                maskLayer(maskAlpha: maskAlpha, panelWidth: panelWidth)

                // 设置面板 - Mac优化为侧边栏
                settingsPanel(panelWidth: panelWidth, panelOffsetX: panelOffsetX)
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
        .onChange(of: isCalendarActive) { _, newValue in
            if newValue == false && !UIDevice.isMac {
                #if canImport(UIKit)
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                #endif
            }
        }
        .onAppear {
            setupMacToolbarListeners()
            setupDatabaseRecreationObserver()
        }
        .onDisappear {
            removeMacToolbarListeners()
            removeDatabaseRecreationObserver()
        }
        .macKeyboardShortcuts()
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
        MacAdaptiveLayout {
            NavigationStack {
                VStack(spacing: 0) {
                    // 导航栏 - Mac版本隐藏或简化
                    customNavigationBar

                    // 导入进度条
                    importProgressView

                    // 主列表内容
                    mainListContent
                }
                .navigationDestination(item: $selectedEntry) { entry in
                    DiaryDetailView(entry: entry, startInEditMode: shouldStartEditing)
                        .onDisappear {
                            shouldStartEditing = false
                        }
                }
                .navigationDestination(isPresented: $isCalendarActive) {
                    CalendarDiaryView()
                }
#if canImport(UIKit)
                .navigationBarHidden(true)
#endif
            }
        }
    }
    
    @ViewBuilder
    private var customNavigationBar: some View {
        if !UIDevice.isMac {
            HStack {
                Button {
                    #if canImport(UIKit)
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
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
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    #endif
                    isCalendarActive = true
                } label: {
                    Image(systemName: "calendar")
                        .font(.system(size: 20, weight: .regular))
                        .frame(width: 24, height: 24, alignment: .trailing)
                }
                .buttonStyle(PressableScaleButtonStyle())
                .foregroundColor(Color.primary.opacity(0.75))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
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
    }
    
    @ViewBuilder
    private var moodSliderSection: some View {
        VStack(alignment: .center, spacing: 4) {
            SimplifiedMoodPicker(
                moodValue: $moodValue,
                isEnabled: !isSending && !isTranscribing
            )
            .frame(maxWidth: UIDevice.isMac ? 600 : .infinity)
        }
        .padding(.horizontal, UIDevice.isMac ? MacOptimizedSpacing.cardPadding : 14)
        .padding(.top, UIDevice.isMac ? 20 : 12)
        .padding(.bottom, UIDevice.isMac ? -40 : -50)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
    
    @ViewBuilder
    private var inputSection: some View {
        VStack(alignment: .leading, spacing: UIDevice.isMac ? 16 : 12) {
            // 文本输入区域
            textInputArea

            // 录音文件显示区域
            recordingsSection
            
            // 图片显示区域
            if !selectedImages.isEmpty {
                photosSection
            }

            // 底部按钮区域
            actionButtonsSection
        }
        .padding(UIDevice.isMac ? MacOptimizedSpacing.cardPadding : 16)
        .background(
            RoundedRectangle(cornerRadius: UIDevice.isMac ? 16 : 12, style: .continuous)
                #if canImport(UIKit)
                .fill(Color(UIColor.secondarySystemBackground))
                #else
                .fill(Color(NSColor.controlBackgroundColor))
                #endif
                .shadow(color: Color.primary.opacity(UIDevice.isMac ? 0.1 : 0.2), radius: UIDevice.isMac ? 8 : 4, x: 0, y: UIDevice.isMac ? 4 : 2)
        )
        .listRowInsets(EdgeInsets(
            top: 0, 
            leading: UIDevice.isMac ? MacOptimizedSpacing.cardPadding : 16, 
            bottom: UIDevice.isMac ? 16 : 12, 
            trailing: UIDevice.isMac ? MacOptimizedSpacing.cardPadding : 16
        ))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .macHoverEffect()
    }
    
    @ViewBuilder
    private var textInputArea: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $inputText)
                .frame(minHeight: 140, maxHeight: 400)
                .frame(height: textEditorHeight)
                .frame(maxWidth: UIDevice.isMac ? 700 : .infinity)
                // 设置移动端上下内边距4，左右8，Mac保持8
                .padding(.horizontal, 8)
                .padding(.vertical, UIDevice.isMac ? 8 : 4)
                .background(Color.clear)
                .scrollContentBackground(.hidden)
                .font(.system(size: UIDevice.isMac ? 16 : 17)) // 移动端文字大小为17pt
                .onChange(of: inputText) { _, newValue in
                    calculateTextHeight(for: newValue)
                }
            if inputText.isEmpty {
                Text(NSLocalizedString("今天是怎样的一天呢？", comment: "Daily prompt"))
                    .font(.system(size: UIDevice.isMac ? 16 : 17)) // 同步占位文本大小
                    .foregroundColor(.secondary.opacity(0.6))
                    // 设置移动端上下内边距10，左右10，Mac保持8
                    .padding(.horizontal, 10)
                    .padding(.vertical, UIDevice.isMac ? 8 : 12)
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
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let audioURL = documentsURL.appendingPathComponent(target)
        do {
            try FileManager.default.removeItem(at: audioURL)
        } catch {
            print("[HomeView deleteCurrentAudio] 删除音频文件出错: \(error.localizedDescription)")
        }
        // 删除录音时使用动画
        withAnimation(AnimationConfig.stiffSpring) {
            audioRecordings.removeAll { $0.fileName == target }
        }
        deleteTarget = nil
    }
    
    @ViewBuilder
    private var actionButtonsSection: some View {
        HStack(spacing: UIDevice.isMac ? 16 : 12) {
            // 录音按钮（占主要位置）
            AppleStyleRecordButton(
                recorder: recorder,
                onStop: { await handleStopRecording() }
            )
            .disabled(audioRecordings.count >= 3)
            .frame(maxWidth: .infinity, minHeight: UIDevice.isMac ? 52 : 48)
            
            // 添加照片按钮
            PhotosPicker(
                selection: $selectedPhotos,
                maxSelectionCount: 9,
                matching: .images
            ) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 48, height: 48)
                    
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            .disabled(selectedImages.count >= 9)
            
            // 发送按钮
            AppleStyleSendButton(
                buttonState: $sendButtonState,
                revealedMood: $revealedMood,
                isEnabled: (!inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !audioRecordings.isEmpty || !selectedImages.isEmpty) && !isTranscribing
            ) {
                handleSendAction()
            }
        }
        .onChange(of: selectedPhotos) { _, newValue in
            Task {
                await loadPhotosWithCompression(newValue)
            }
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
                            print("[HomeView] Image compressed: \(originalSize/1024)KB → \(compressedSize/1024)KB")
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
            print("[HomeView] Total compressed images: \(selectedImages.count)")
        }
    }

    private func calculateTextHeight(for text: String) {
        let lineCount = text.components(separatedBy: "\n").count
        let estimatedHeight = max(140, min(400, CGFloat(lineCount) * 22 + 40))

        withAnimation(AnimationConfig.smoothTransition) {
            textEditorHeight = estimatedHeight
        }
    }

    private func handleSendAction() {
#if canImport(UIKit)
        HapticManager.shared.click()
#endif
        Task {
            // 1. 发送开始 → sending状态
            await MainActor.run {
                print("[HomeView SendButton] Starting send action")
                withAnimation(AnimationConfig.standardResponse) {
                    sendButtonState = .sending
                    isSending = true
                }
            }

            // 2. 执行AI情绪分析（只调用一次）
            let textToAnalyze = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            var finalMoodValue = self.moodValue

            if !textToAnalyze.isEmpty {
                print("[HomeView SendButton] Analyzing mood for text")
                let mood = await aiService.analyzeMood(text: textToAnalyze)
                finalMoodValue = mood
                await MainActor.run {
                    self.moodValue = mood
                }
            }

            // 3. 显示情绪反馈 → moodRevealing状态
            await MainActor.run {
                withAnimation(AnimationConfig.smoothTransition) {
                    revealedMood = finalMoodValue
                    sendButtonState = .moodRevealing
                }
                #if canImport(UIKit)
                HapticManager.shared.notification(.success)
                #endif
                print("[HomeView SendButton] Mood revealed: \(finalMoodValue)")
            }

            // 4. 等待脉冲动画完成（1.2秒）
            try? await Task.sleep(nanoseconds: 1_200_000_000)

            // 5. 清除输入并保存日记
            let textToSend = inputText
            let audioToSend = currentAudioFileName
            let moodToSend = finalMoodValue
            let imagesToSend = selectedImages

            await MainActor.run {
                withAnimation(AnimationConfig.fastResponse) {
                    inputText = ""
                    currentAudioFileName = nil
                    audioRecordings.removeAll()
                    selectedImages.removeAll()
                    selectedPhotos.removeAll()
                }
                hideKeyboard()
            }

            // 6. 保存日记
            await addEntry(text: textToSend, audioFileName: audioToSend, moodValue: moodToSend, images: imagesToSend)

            // 7. 完成动画 → completed → idle
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
                }
            }

            print("[HomeView SendButton] Send action completed")
        }
    }
    
    @ViewBuilder
    private func leadingSwipeGesture(panelWidth: CGFloat) -> some View {
        if !UIDevice.isMac && selectedEntry == nil && !isCalendarActive && !isSettingsOpen {
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
        if !UIDevice.isMac && selectedEntry == nil && !isCalendarActive && !isSettingsOpen {
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
                                    isCalendarActive = true
                                }
                            }
                        }
                )
        }
    }
    
    @ViewBuilder
    private func maskLayer(maskAlpha: Double, panelWidth: CGFloat) -> some View {
        if !UIDevice.isMac {
            Color.black
                .opacity(maskAlpha)
                .animation(AnimationConfig.smoothTransition, value: maskAlpha)
                .ignoresSafeArea()
                .allowsHitTesting(maskAlpha > 0.01)
                .onTapGesture {
                    #if canImport(UIKit)
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    #endif
                    withAnimation(AnimationConfig.smoothTransition) {
                        isSettingsOpen = false
                        dragOffsetX = 0
                    }
                }
                .gesture(
                    DragGesture().onEnded { value in
                        let dx = value.translation.width
                        let dy = value.translation.height
                        if dx < -panelWidth * 0.1 && abs(dx) > abs(dy) {
                            #if canImport(UIKit)
                            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                            #endif
                            withAnimation(AnimationConfig.smoothTransition) {
                                isSettingsOpen = false
                                dragOffsetX = 0
                            }
                        }
                    }
                )
        }
    }
    
    @ViewBuilder
    private func settingsPanel(panelWidth: CGFloat, panelOffsetX: CGFloat) -> some View {
        if UIDevice.isMac {
            MacSidebar(isVisible: $isSettingsOpen) {
                SettingsView(isSettingsOpen: $isSettingsOpen)
                    .environmentObject(importService)
                    .environment(\.managedObjectContext, viewContext)
            }
        } else {
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
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let dx = value.translation.width
                            let dy = value.translation.height
                            if isSettingsOpen && abs(dx) > abs(dy) {
                                dragOffsetX = min(max(dx, -panelWidth), 0)
                            }
                        }
                        .onEnded { value in
                            let dx = value.translation.width
                            let dy = value.translation.height
                            if isSettingsOpen && abs(dx) > abs(dy) {
                                if dragOffsetX < -panelWidth * 0.2 {
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
    
    // MARK: - Helper Functions
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: appLanguage)
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
    
    // MARK: - Core Data 操作
    
    private func addEntry(text: String, audioFileName: String?, moodValue: Double? = nil, images: [Data] = []) async {
        // 并行调用摘要与情绪（如果未提供）以提升性能
        let finalMoodValue: Double
        let summary: String?
        
        if let moodValue {
            summary = await aiService.summarize(text: text)
            finalMoodValue = moodValue
        } else {
            let (summaryResult, moodResult) = await aiService.analyzeAndSummarize(text: text)
            summary = summaryResult
            finalMoodValue = moodResult
        }
        
        // 在主线程创建 Core Data 实体
        await MainActor.run {
            let newEntry = DiaryEntry(context: viewContext)
            newEntry.id = UUID()
            newEntry.date = Date()
            newEntry.text = text
            newEntry.moodValue = finalMoodValue
            newEntry.summary = summary
            // Copy audio file to iCloud if needed
            if let audioFileName = audioFileName {
                let localURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent(audioFileName)
                
                if FileManager.default.fileExists(atPath: localURL.path),
                   let audioData = try? Data(contentsOf: localURL) {
                    
                    // Save to iCloud location
                    if let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.Mingyi.Lumory") {
                        let audioDir = iCloudURL.appendingPathComponent("Documents/LumoryAudio")
                        if !FileManager.default.fileExists(atPath: audioDir.path) {
                            try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true, attributes: nil)
                        }
                        
                        let iCloudAudioURL = audioDir.appendingPathComponent(audioFileName)
                        try? audioData.write(to: iCloudAudioURL)
                        print("[HomeView] Saved audio to iCloud: \(audioFileName)")
                        
                        // Delete from local after successful copy
                        try? FileManager.default.removeItem(at: localURL)
                    }
                }
                
                newEntry.audioFileName = audioFileName
            }
            
            // 保存图片
            print("[HomeView addEntry] Saving \(images.count) images")
            var imageFileNames: [String] = []
            for (index, imageData) in images.enumerated() {
                let fileName = "img_\(newEntry.id?.uuidString ?? UUID().uuidString)_\(index).jpg"
                do {
                    let savedFileName = try DiaryEntry.saveImageToDocuments(imageData, fileName: fileName)
                    imageFileNames.append(savedFileName)
                    print("[HomeView addEntry] Saved image \(index + 1)/\(images.count): \(savedFileName)")
                } catch {
                    print("[HomeView] 保存图片失败: \(error)")
                }
            }
            if !imageFileNames.isEmpty {
                newEntry.imageFileNames = imageFileNames.joined(separator: ",")
                print("[HomeView addEntry] Set imageFileNames: \(newEntry.imageFileNames ?? "")")
                
                // Also save images data for sync
                newEntry.saveImagesForSync(images)
            }
            
            do {
                try viewContext.save()
            } catch {
                print("[HomeView] 保存日记失败: \(error)")
            }
        }
    }

    // 原 allDiariesSection 重命名并重构，将日期整合到卡片背景中
    @ViewBuilder
    private var diaryContentSections: some View {
        if entries.isEmpty {
            emptyStateSection
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
        let sortedEntries = entries.sorted(by: { ($0.date ?? Date.distantPast) > ($1.date ?? Date.distantPast) })
        let grouped = Dictionary(grouping: sortedEntries) { cal.startOfDay(for: $0.date ?? Date()) }
        let sortedDates = grouped.keys.sorted(by: >)
        ForEach(sortedDates, id: \.self) { date in
            Section {
                ForEach(grouped[date]!, id: \.id) { entry in
                    diaryEntryRow(entry: entry)
                }
            } header: {
                Text(formatDate(date))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 16)
                    .padding(.top, 8)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
    }
    
    @ViewBuilder
    private func diaryEntryRow(entry: DiaryEntry) -> some View {
        Button {
            selectedEntry = entry
        } label: {
            DiaryRow(entry: entry, hasContainerBackground: true)
                .padding(UIDevice.isMac ? MacOptimizedSpacing.cardPadding : 16)
                .background(entryRowBackground)
                .macHoverEffect()
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
                selectedEntry = entry
            }
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
    }
    
    private var entryRowBackground: some View {
        RoundedRectangle(cornerRadius: UIDevice.isMac ? 16 : 12, style: .continuous)
            #if canImport(UIKit)
            .fill(Color(UIColor.secondarySystemBackground))
            #else
            .fill(Color(NSColor.controlBackgroundColor))
            #endif
            .shadow(
                color: Color.primary.opacity(UIDevice.isMac ? 0.1 : 0.2),
                radius: UIDevice.isMac ? 8 : 4,
                x: 0,
                y: UIDevice.isMac ? 4 : 2
            )
    }

    func handleStopRecording() async {
        print("[HomeView handleStopRecording START] Current SFCFN: \(currentAudioFileName ?? "nil")")
        guard let fileName = recorder.stopRecording() else {
            print("[HomeView handleStopRecording: stopRecording returned nil] SFCFN: \(currentAudioFileName ?? "nil")")
            return
        }
        print("[HomeView handleStopRecording: recording stopped, fileName: \(fileName)] SFCFN: \(currentAudioFileName ?? "nil")")
        
        // 标记正在转录
        await MainActor.run {
            isTranscribing = true
            print("[HomeView handleStopRecording: isTranscribing set to true] SFCFN: \(currentAudioFileName ?? "nil")")
        }
        
        print("[HomeView handleStopRecording] Setting currentAudioFileName. Old SFCFN: \(currentAudioFileName ?? "nil"), New FileName: \(fileName)")
        currentAudioFileName = fileName // SET FILENAME in handleStopRecording
        // 添加录音文件到列表，最多3条，最新置顶，使用动画
        withAnimation(AnimationConfig.stiffSpring) {
            let rec = Recording(id: fileName, fileName: fileName, duration: recorder.duration)
            audioRecordings.insert(rec, at: 0)
            if audioRecordings.count > 3 {
                audioRecordings.removeLast()
            }
        }
        print("[HomeView handleStopRecording] Did set currentAudioFileName. New SFCFN: \(currentAudioFileName ?? "nil")")
        
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        print("[HomeView handleStopRecording: got documentsURL] SFCFN: \(currentAudioFileName ?? "nil")")
        let audioURL = documentsURL.appendingPathComponent(fileName)
        print("[HomeView handleStopRecording: got audioURL: \(audioURL)] SFCFN: \(currentAudioFileName ?? "nil")")
        
        // 开始异步转录任务
        transcriptionTask = Task {
            print("[HomeView handleStopRecording Task START] SFCFN: \(currentAudioFileName ?? "nil")")
            print("[HomeView] Using language for transcription: \(appLanguage)")
            let transcribedTextOpt = await aiService.transcribeAudio(fileURL: audioURL, localeIdentifier: appLanguage)
            // 转录完成，更新状态
            await MainActor.run {
                isTranscribing = false
                print("[HomeView transcriptionTask] isTranscribing set to false")
            }
            if let transcribedText = transcribedTextOpt {
                // 确保当前文件未变更
                guard currentAudioFileName == fileName else {
                    print("[HomeView transcriptionTask] 任务文件已改变，放弃更新")
                    return
                }
                print("[HomeView handleStopRecording Task - transcription successful, text: \(transcribedText)] SFCFN: \(currentAudioFileName ?? "nil")")
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
                print("[HomeView transcriptionTask] Transcription completed, mood analysis will happen on send.")
            } else {
                print("[HomeView transcriptionTask] 转录失败或返回nil")
            }
            print("[HomeView handleStopRecording Task END] SFCFN: \(currentAudioFileName ?? "nil")")
        }
        print("[HomeView handleStopRecording END FUNCTION] SFCFN: \(currentAudioFileName ?? "nil")")
    }

    private func playAudio(fileName: String) {
        print("[HomeView playAudio START] Requested to play: \(fileName). Current SFCFN: \(currentAudioFileName ?? "nil")")

        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let audioURL = documentsURL.appendingPathComponent(fileName)

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            print("[HomeView playAudio] File NOT FOUND: \(fileName). Current SFCFN: \(currentAudioFileName ?? "nil")")
            if currentAudioFileName == fileName { // 如果UI上显示的是这个不存在的文件
                 print("[HomeView playAudio] Clearing SFCFN because file missing. Old SFCFN: \(currentAudioFileName ?? "nil")")
                 withAnimation(AnimationConfig.standardResponse) {
                    currentAudioFileName = nil // SET NIL
                    print("[HomeView playAudio] Did set SFCFN to nil due to missing file. New SFCFN: \(self.currentAudioFileName ?? "nil")")
                 }
                 if audioPlaybackController.currentPlayingFileName == fileName {
                    audioPlaybackController.stopPlayback()
                 }
            }
            return
        }
        
        print("[HomeView playAudio] File exists for: \(fileName). Current SFCFN: \(currentAudioFileName ?? "nil")")

        if audioPlaybackController.isPlaying && audioPlaybackController.currentPlayingFileName != fileName {
            print("[HomeView playAudio] Controller was playing another file (\(audioPlaybackController.currentPlayingFileName ?? "nil")). Stopping it. Current SFCFN: \(currentAudioFileName ?? "nil")")
            audioPlaybackController.stopPlayback(clearCurrentFile: true) 
            print("[HomeView playAudio] Controller stopped. Current SFCFN: \(currentAudioFileName ?? "nil")")
        }
        
        print("[HomeView playAudio] Calling controller.play for: \(fileName). Current SFCFN: \(currentAudioFileName ?? "nil")")
        audioPlaybackController.play(url: audioURL, fileName: fileName)
        print("[HomeView playAudio] Called controller.play. Controller isPlaying: \(audioPlaybackController.isPlaying), Controller file: \(audioPlaybackController.currentPlayingFileName ?? "nil"). Current SFCFN: \(currentAudioFileName ?? "nil")")

        if self.currentAudioFileName != fileName {
            print("[HomeView playAudio] SFCFN (\(self.currentAudioFileName ?? "nil")) != fileName (\(fileName)). Restoring SFCFN.")
            withAnimation(AnimationConfig.standardResponse) { 
                 self.currentAudioFileName = fileName // SET FILENAME
                 print("[HomeView playAudio] Did set SFCFN to \(fileName). New SFCFN: \(self.currentAudioFileName ?? "nil")")
            }
        }

        audioPlaybackController.onFinishPlaying = { [weak audioPlaybackController, capturedFileName = fileName] in
            Task { @MainActor in
                print("[HomeView playAudio CB_Finish] Playback finished for \(capturedFileName). Controller playing: \(audioPlaybackController?.isPlaying ?? false). SFCFN: \(self.currentAudioFileName ?? "nil")")
                if self.currentAudioFileName == nil && capturedFileName == audioPlaybackController?.currentPlayingFileName { 
                     print("[HomeView playAudio CB_Finish] SFCFN is nil, restoring to \(capturedFileName).")
                     withAnimation(AnimationConfig.standardResponse) {
                        self.currentAudioFileName = capturedFileName 
                        print("[HomeView playAudio CB_Finish] Did set SFCFN to \(capturedFileName). New SFCFN: \(self.currentAudioFileName ?? "nil")")
                     }
                }
                if audioPlaybackController?.isPlaying == false {
                    if audioPlaybackController?.currentPlayingFileName == capturedFileName {
                        print("[HomeView playAudio CB_Finish] Controller not playing & file matches, stopping controller.")
                        audioPlaybackController?.stopPlayback(clearCurrentFile: true)
                    }
                }
            }
        }
        audioPlaybackController.onPlayError = { [weak audioPlaybackController, capturedFileName = fileName] error in
            Task { @MainActor in
                print("[HomeView playAudio CB_Error] Playback error for \(capturedFileName). Error: \(error.localizedDescription). SFCFN: \(self.currentAudioFileName ?? "nil")")
                if self.currentAudioFileName == nil && capturedFileName == audioPlaybackController?.currentPlayingFileName { 
                     print("[HomeView playAudio CB_Error] SFCFN is nil, restoring to \(capturedFileName) after error.")
                     withAnimation(AnimationConfig.standardResponse) {
                        self.currentAudioFileName = capturedFileName 
                        print("[HomeView playAudio CB_Error] Did set SFCFN to \(capturedFileName). New SFCFN: \(self.currentAudioFileName ?? "nil")")
                     }
                }
                if audioPlaybackController?.currentPlayingFileName == capturedFileName {
                    print("[HomeView playAudio CB_Error] Error matches controller file, stopping controller.")
                    audioPlaybackController?.stopPlayback(clearCurrentFile: true)
                }
            }
        }
        print("[HomeView playAudio END] For: \(fileName). SFCFN: \(currentAudioFileName ?? "nil")")
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
            // Delete associated images
            entry.deleteAllImages()
            
            viewContext.delete(entry)
            
            do {
                try viewContext.save()
                #if canImport(UIKit)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                #endif
            } catch {
                // Log the error appropriately
                print("[HomeView] 删除日记失败: \(error.localizedDescription)")
                // Potentially show an error to the user
            }
        }
        
        // Ensure entryToDelete is cleared AFTER the operation.
        // If this closure is part of an alert, ensure it's cleared
        // whether the operation succeeded or failed, to reset state.
        entryToDelete = nil
    }
    
    // MARK: - Mac Toolbar Support
    
    #if targetEnvironment(macCatalyst)
    private func setupMacToolbarListeners() {
        let newEntryListener = NotificationCenter.default.addObserver(
            forName: .navigateToHome,
            object: nil,
            queue: .main
        ) { _ in
            // Focus on text input for new entry
            // This would be equivalent to tapping in the text area
        }
        
        let calendarListener = NotificationCenter.default.addObserver(
            forName: .navigateToCalendar,
            object: nil,
            queue: .main
        ) { _ in
            isCalendarActive = true
        }
        
        let settingsListener = NotificationCenter.default.addObserver(
            forName: .showSettings,
            object: nil,
            queue: .main
        ) { _ in
            withAnimation(AnimationConfig.smoothTransition) {
                isSettingsOpen.toggle()
            }
        }
        
        macToolbarListeners = [newEntryListener, calendarListener, settingsListener]
    }
    
    private func removeMacToolbarListeners() {
        macToolbarListeners.forEach { observer in
            NotificationCenter.default.removeObserver(observer)
        }
        macToolbarListeners.removeAll()
    }
    #else
    private func setupMacToolbarListeners() {}
    private func removeMacToolbarListeners() {}
    #endif
    
    // MARK: - Database Recreation Observer
    
    private func setupDatabaseRecreationObserver() {
        databaseRecreationObserver = NotificationCenter.default.addObserver(
            forName: .databaseRecreated,
            object: nil,
            queue: .main
        ) { _ in
            print("[HomeView] Database recreated notification received")
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
        
        print("[HomeView] Database recreation handled - state cleared and context refreshed")
    }
}

struct DiaryRow: View {
    @ObservedObject var entry: DiaryEntry
    var hasContainerBackground: Bool = false // New parameter

    var body: some View {
        // Add safety check for deleted entry
        if entry.isDeleted || entry.managedObjectContext == nil {
            // Render an empty view or a placeholder if the entry is deleted
            // This prevents accessing properties of a deleted object.
            EmptyView()
        } else {
            // Original content
            HStack {
                Circle()
                    .fill(entry.moodColor)
                    .frame(width: 12, height: 12)
                VStack(alignment: .leading) {
                    Text(displayText)
                        .lineLimit(1)
                    Text(entry.date ?? Date(), style: .time)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(hasContainerBackground ? 0 : 12) // Conditional padding
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(hasContainerBackground ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.regularMaterial))
            )
        }
    }

    private var displayText: String {
        // Guard against accessing properties of a deleted or invalid entry
        guard !entry.isDeleted, entry.managedObjectContext != nil else {
            return NSLocalizedString("日记已删除", comment: "Entry deleted") // Or an empty string: ""
        }
        let raw = entry.summary ?? String((entry.text ?? "").prefix(30)) + "..."
        // 过滤掉句号、星号和引号
        let filtered = raw
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "\"", with: "")
        return filtered
    }
}

// MARK: - Apple Style Button Components

/// Apple风格录音按钮 - 现代设计
struct AppleStyleRecordButton: View {
    @ObservedObject var recorder: AudioRecorder
    var onStop: () async -> Void

    @State private var isPressing: Bool = false
    @State private var pulseOpacity: Double = 0.0
    @Environment(\.colorScheme) private var colorScheme
    
    // 使用静态函数确保默认值类型正确
    private static var defaultAppLanguage: String {
        let currentLocale = Locale.current.identifier
        return currentLocale.hasPrefix("zh") ? "zh-Hans" : "en"
    }
    
    @AppStorage("appLanguage") private var appLanguage: String = AppleStyleRecordButton.defaultAppLanguage

    var body: some View {
        HStack(spacing: 10) {
            // 录音图标
            Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(iconColor)
            
            // 文字
            Text(recorder.isRecording ?
                NSLocalizedString("Tap to Stop", comment: "Tap to stop recording") :
                NSLocalizedString("Hold to Speak", comment: "Hold to speak")
            )
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(textColor)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .background(
            ZStack {
                // 主背景
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(backgroundColor)
                
                // 脉冲效果（录音时）
                if recorder.isRecording {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.red.opacity(0.4), lineWidth: 2)
                        .opacity(pulseOpacity)
                }
                
                // 按压时的覆盖层
                if isPressing && !recorder.isRecording {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.1))
                }
            }
        )
        .scaleEffect(isPressing ? 0.96 : 1.0)
        .animation(AnimationConfig.bouncySpring, value: recorder.isRecording || isPressing)
        .onChange(of: recorder.isRecording) { _, isRecording in
            if isRecording {
                startPulseAnimation()
            } else {
                pulseOpacity = 0.0
            }
        }
        .onLongPressGesture(minimumDuration: 0, pressing: { pressing in
            if pressing {
#if canImport(UIKit)
                HapticManager.shared.click()
#endif
            }
        }, perform: {})
        .contentShape(Rectangle())
        .simultaneousGesture(
            // 点击手势 - 用于停止录音
            TapGesture()
                .onEnded {
                    if recorder.isRecording {
#if canImport(UIKit)
                        HapticManager.shared.click()
#endif
                        Task { await onStop() }
                    }
                }
        )
        .simultaneousGesture(
            // 长按手势 - 用于开始和停止录音
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !recorder.isRecording && !isPressing {
                        isPressing = true
#if canImport(UIKit)
                        HapticManager.shared.click()
#endif
                        recorder.startRecording()
                    }
                }
                .onEnded { _ in
                    isPressing = false
                    if recorder.isRecording {
#if canImport(UIKit)
                        HapticManager.shared.click()
#endif
                        Task { await onStop() }
                    }
                }
        )
    }

    private func startPulseAnimation() {
        guard recorder.isRecording else { return }

        withAnimation(Animation.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
            pulseOpacity = 1.0
        }
    }

    // MARK: - 计算属性
    
    private var backgroundColor: Color {
        if recorder.isRecording {
            return Color.red
        } else {
#if canImport(UIKit)
            return Color(.systemGray5)  // 更明显的灰色，与发送按钮风格统一
#else
            return Color(NSColor.controlBackgroundColor)
#endif
        }
    }
    
    private var iconColor: Color {
        if recorder.isRecording {
            return .white
        } else {
#if canImport(UIKit)
            return Color(.systemGray2)  // 更深的灰色图标，增强对比度
#else
            return Color(NSColor.secondaryLabelColor)
#endif
        }
    }
    
    private var textColor: Color {
        if recorder.isRecording {
            return .white
        } else {
            return .primary
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

/// Apple风格发送按钮
struct AppleStyleSendButton: View {
    @Binding var buttonState: SendButtonState
    @Binding var revealedMood: Double?
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // 背景
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(buttonBackgroundColor)
                    .frame(width: 48, height: 48)

                // 内容
                if buttonState == .sending {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white)
                }
            }
        }
        .buttonStyle(PressableScaleButtonStyle())
        .disabled(!isEnabled || buttonState != .idle)
        .scaleEffect(buttonState == .moodRevealing ? 1.1 : 1.0)
        .animation(
            buttonState == .moodRevealing
            ? Animation.easeInOut(duration: 0.6).repeatCount(2, autoreverses: true)
            : AnimationConfig.smoothTransition,
            value: buttonState
        )
    }

    private var buttonBackgroundColor: Color {
        switch buttonState {
        case .idle, .completed:
            if !isEnabled {
                #if canImport(UIKit)
                return Color(.systemGray4)
                #else
                return Color(NSColor.disabledControlTextColor)
                #endif
            } else {
                return Color(red: 114/255, green: 192/255, blue: 254/255)
            }

        case .sending:
            #if canImport(UIKit)
            return Color(.systemGray3)
            #else
            return Color(NSColor.tertiaryLabelColor)
            #endif

        case .moodRevealing:
            return Color.moodSpectrum(value: revealedMood ?? 0.5)
        }
    }
}

// 录音按钮组件：长按开始，松开结束；点击开始/结束。
struct RecordButton: View {
    @ObservedObject var recorder: AudioRecorder
    var onStop: () async -> Void
    var colorScheme: ColorScheme

    @State private var isPressing: Bool = false

    var body: some View {
        let baseColor = recorder.isRecording ? Color.red : Color.accentColor

        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(baseColor)
            .frame(height: 48)
            .overlay(
                HStack(spacing: 6) {
                    Image(systemName: recorder.isRecording ? "stop.fill" : "mic")
                    Text(recorder.isRecording ? NSLocalizedString("松开结束", comment: "Release to stop") : NSLocalizedString("按住说话", comment: "Hold to speak"))
                }
                .font(.headline)
                .foregroundColor(.white)
            )
        .scaleEffect(isPressing || recorder.isRecording ? 0.96 : 1.0)
        .animation(AnimationConfig.fastResponse, value: isPressing || recorder.isRecording)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !recorder.isRecording && !isPressing {
                        isPressing = true
#if canImport(UIKit)
                        HapticManager.shared.click()
#endif
                        recorder.startRecording()
                    }
                }
                .onEnded { _ in
                    isPressing = false
                    if recorder.isRecording {
#if canImport(UIKit)
                        HapticManager.shared.click()
#endif
                        Task { await onStop() }
                    }
                }
        )
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
        .padding(.horizontal, UIDevice.isMac ? 12 : 8)
        .padding(.vertical, UIDevice.isMac ? 8 : 6)
        .background(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: UIDevice.isMac ? 10 : 8, style: .continuous)
#if canImport(UIKit)
                    .fill(Color(.systemGray6))
#else
                    .fill(Color(NSColor.controlBackgroundColor))
#endif
                if controller.currentPlayingFileName == recording.fileName && recording.duration > 0 {
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: UIDevice.isMac ? 10 : 8, style: .continuous)
                            .fill(Color.blue.opacity(0.3))
                            .frame(width: geo.size.width * controller.progress)
                    }
                }
            }
        )
        .macHoverEffect()
        // 移除自定义 transition，依赖 withAnimation 平滑移动
    }
}


// 日记预览视图
struct DiaryPreviewView: View {
    @ObservedObject var entry: DiaryEntry
    let appLanguage: String
    let onTap: () -> Void
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: appLanguage)
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: appLanguage)
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    var body: some View {
        // 确保 entry 仍然有效
        if entry.managedObjectContext != nil && !entry.isFault {
            VStack(alignment: .leading, spacing: 12) {
                // 日期和心情
                HStack {
                    Circle()
                        .fill(entry.moodColor)
                        .frame(width: 12, height: 12)
                    Text(formatDate(entry.wrappedDate))
                        .font(.headline)
                    Spacer()
                    Text(formatTime(entry.wrappedDate))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                // 摘要
                if let summary = entry.wrappedSummary, !summary.isEmpty {
                    Text(NSLocalizedString("摘要", comment: "Summary"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(summary)
                        .font(.body)
                        .lineLimit(2)
                }
                
                // 正文预览
                Text(NSLocalizedString("内容", comment: "Content"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(entry.wrappedText)
                    .font(.body)
                    .lineLimit(5)
                
                Spacer()
            }
            .padding()
            .frame(width: 300, height: 400)
#if canImport(UIKit)
            .background(Color(.systemBackground))
#else
            .background(Color(NSColor.windowBackgroundColor))
#endif
            .contentShape(Rectangle())
            .onTapGesture {
                onTap()
            }
        } else {
            // 如果 entry 已被删除或无效，显示一个占位符或空视图
            Color.clear.frame(width: 300, height: 400)
        }
    }
}

#Preview {
    HomeView()
}