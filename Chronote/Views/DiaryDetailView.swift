import SwiftUI
import AVFoundation // Re-add AVFoundation for AVURLAsset
import CoreData
#if canImport(UIKit)
import UIKit
#endif
// AVFoundation will be implicitly imported via AudioPlaybackController if needed,
// but it's good practice to keep it if direct AVAudioSession manipulation happens.
// For now, let's assume AudioPlaybackController handles session.
// import AVFoundation 

struct DiaryDetailView: View {
    @ObservedObject var entry: DiaryEntry
    var startInEditMode: Bool = false
    var showUnifiedToolbar: Bool = false
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.aiService) private var aiService
    @State private var showDeleteAlert = false
    @StateObject private var audioPlaybackController = AudioPlaybackController() // 新的控制器
    @State private var displayableAudioDuration: TimeInterval = 0.0 // State for fetched duration
    
    // 编辑模式相关状态
    @State private var isEditing = false
    @State private var editedSummary: String = ""
    @State private var editedText: String = ""
    @State private var editedMoodValue: Double = 0.5
    @State private var editedDate: Date = Date()
    @State private var hasUnsavedChanges = false
    /// 保存失败时向用户展示的错误消息；非 nil 时弹 alert。
    @State private var saveError: String?
    @State private var showDiscardChangesAlert = false
    /// 编辑态下日期 picker 的 popover 显隐 —— 让查看 / 编辑两种模式渲染同一个 Text,
    /// 只是编辑模式下点击 Text 弹 popover,避免 .compact DatePicker 切换时日期格式跳变。
    @State private var showDatePopover: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    
    // Animation states
    @State private var animateIn = false
    @State private var showContent = false
    @State private var shareButtonPressed = false
    @State private var showImageViewer = false
    @State private var selectedImageIndex = 0
    /// Image viewer 的图片数据：在点击缩略图时异步加载，加载完成后再呈现 viewer，
    /// 避免在 cover/sheet body 里做同步 I/O 阻塞主线程。
    @State private var viewerImages: [Data] = []

    private func presentImageViewer(at index: Int) {
        Task { @MainActor in
            let loaded = await entry.loadAllImageDataAsync()
            guard !loaded.isEmpty else { return }
            viewerImages = loaded
            // **index 安全钳位**：`index` 是缩略图 grid（基于 `imageFileNameArray`）的索引，
            // `loaded` 是异步加载的 blob / fallback 结果，两者 count 不保证相等：
            //   - blob 缺失 / CloudKit 未同步完 → fallback 过滤掉 nil → 比 grid 短
            //   - blob 存在但 encode 时索引已做顺序保持（bug_006 修复后）→ 等长
            // 钳位避免 grid 上点最后一张但 loaded 不够长时，TabView 抓不到 tag 显示空白 + "5 / 3" 这种乱数。
            selectedImageIndex = min(max(index, 0), loaded.count - 1)
            showImageViewer = true
        }
    }
    
    // Platform-specific color
    private var systemGray6Color: Color {
        #if canImport(UIKit)
        return Color(UIColor.systemGray6)
        #else
        return Color(NSColor.controlBackgroundColor)
        #endif
    }
    
    @AppStorage("appLanguage") private var appLanguage: String = {
        let currentLocale = Locale.current.identifier
        if currentLocale.hasPrefix("zh") {
            return "zh-Hans"
        } else {
            return "en"
        }
    }()
    
    // 缓存按 (kind, language) —— 每次 body eval new 一次 `DateFormatter` ICU 加载不便宜，
    // 播放进度 30fps 驱动 body 时主线程会被 formatter alloc 拉满。
    private enum DiaryDateFormatterKind { case longDate, shortTime }
    private static let detailFormatterLock = NSLock()
    private static var detailFormatterCache: [String: DateFormatter] = [:]
    private static func detailFormatter(kind: DiaryDateFormatterKind, language: String) -> DateFormatter {
        let key = "\(kind)-\(language)"
        detailFormatterLock.lock()
        defer { detailFormatterLock.unlock() }
        if let cached = detailFormatterCache[key] { return cached }
        let f = DateFormatter()
        f.locale = Locale(identifier: language)
        switch kind {
        case .longDate:
            f.dateStyle = .long
            f.timeStyle = .none
        case .shortTime:
            f.dateStyle = .none
            f.timeStyle = .short
        }
        detailFormatterCache[key] = f
        return f
    }

    private func formatDate(_ date: Date) -> String {
        Self.detailFormatter(kind: .longDate, language: appLanguage).string(from: date)
    }

    private func formatTime(_ date: Date) -> String {
        Self.detailFormatter(kind: .shortTime, language: appLanguage).string(from: date)
    }

    var body: some View {
        Group {
            // Check if entry is still valid
            if entry.managedObjectContext == nil {
                // Entry has been deleted, just show a placeholder
                Text(NSLocalizedString("正在返回...", comment: "Returning message"))
                    .onAppear {
                        dismiss()
                    }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        heroHeader
                        if isEditing {
                            moodEditorBlock
                        }
                        summaryBlock
                        themesSection
                        entryBodyBlock
                        if !entry.imageFileNameArray.isEmpty {
                            photosBlock
                        }
                        if let audioFileName = entry.audioFileName, let audioURL = entry.audioURL() {
                            audioBlock(audioFileName: audioFileName, audioURL: audioURL)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
                }
                .scrollDismissesKeyboard(.interactively)
                .background(detailBackground.ignoresSafeArea())
                .navigationTitle(NSLocalizedString("日记详情", comment: "Diary details title"))
            .toolbar {
#if canImport(UIKit)
                // 左侧按钮：取消（编辑模式下）
                ToolbarItem(placement: .navigationBarLeading) {
                    if isEditing {
                        Button(NSLocalizedString("取消", comment: "Cancel button")) {
                            if hasUnsavedChanges {
                                showDiscardChangesAlert = true
                            } else {
                                cancelEditing()
                            }
                        }
                    }
                }
                // 右侧按钮组：编辑/保存 + 删除
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        if isEditing {
                            Button(NSLocalizedString("保存", comment: "Save button")) {
                                saveChanges()
                            }
                            .fontWeight(.semibold)
                        } else {
                            Button(NSLocalizedString("编辑", comment: "Edit button")) {
                                startEditing()
                            }
                        }
                        Button(role: .destructive) {
                            showDeleteAlert = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .foregroundColor(.red)
                    }
                }
#endif
            }
            .alert(NSLocalizedString("确认删除此日记？", comment: "Delete diary confirmation"), isPresented: $showDeleteAlert) {
                Button(NSLocalizedString("删除", comment: "Delete button"), role: .destructive) {
                    // Stop audio and perform deletion
                    audioPlaybackController.stopPlayback(clearCurrentFile: true)

                    // 在 Core Data delete 之前先清磁盘文件——delete 之后 entry 的属性访问不可靠。
                    entry.deleteAllImages()
                    entry.deleteAudioFile()

                    // Delete the entry
                    viewContext.delete(entry)
                    
                    // Save and dismiss immediately
                    do {
                        try viewContext.save()
                        #if canImport(UIKit)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        #endif
                    } catch {
                        Log.error("[DiaryDetailView] 删除日记失败: \(error)", category: .ui)
                    }
                    
                    // Dismiss immediately after deletion
                    dismiss()
                }
                Button(NSLocalizedString("取消", comment: "Cancel button"), role: .cancel) { }
            } message: {
                Text(NSLocalizedString("此操作无法撤销，是否确定？", comment: "Cannot undo confirmation"))
            }
            .alert(NSLocalizedString("放弃更改？", comment: "Discard changes confirmation"), isPresented: $showDiscardChangesAlert) {
                Button(NSLocalizedString("放弃", comment: "Discard button"), role: .destructive) {
                    cancelEditing()
                }
                Button(NSLocalizedString("继续编辑", comment: "Continue editing button"), role: .cancel) { }
            } message: {
                Text(NSLocalizedString("您有未保存的更改，确定要放弃吗？", comment: "Unsaved changes warning"))
            }
            .alert(
                NSLocalizedString("保存失败", comment: "Save failed alert title"),
                isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
            ) {
                Button(NSLocalizedString("好", comment: "OK"), role: .cancel) { saveError = nil }
            } message: {
                if let msg = saveError {
                    Text(msg)
                }
            }
            .onDisappear {
                // 当视图消失时停止播放，避免音频在后台继续
                audioPlaybackController.stopPlayback(clearCurrentFile: true)
            }
            .navigationBarBackButtonHidden(isEditing)
            .interactiveDismissDisabled(isEditing && hasUnsavedChanges)
            #if os(iOS)
            .fullScreenCover(isPresented: $showImageViewer) {
                if !viewerImages.isEmpty {
                    ImageViewerView(
                        images: viewerImages,
                        selectedIndex: $selectedImageIndex,
                        isPresented: $showImageViewer
                    )
                }
            }
            #else
            .sheet(isPresented: $showImageViewer) {
                if !viewerImages.isEmpty {
                    ImageViewerView(
                        images: viewerImages,
                        selectedIndex: $selectedImageIndex,
                        isPresented: $showImageViewer
                    )
                }
            }
            #endif
            .onAppear {
                // 如果需要直接进入编辑模式
                if startInEditMode && !isEditing {
                    startEditing()
                }
                
                // Animate in
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                    animateIn = true
                }
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.2)) {
                    showContent = true
                }
            }
            }
        }
    }

    
    // MARK: - View Components (Available for all platforms)
    
    @ViewBuilder
    private var headerSection: some View {
        VStack(spacing: 24) {
            // Date and mood header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(formatDate(entry.wrappedDate))
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text(formatTime(entry.wrappedDate))
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Mood visualization
                VStack(alignment: .trailing, spacing: 12) {
                    Circle()
                        .fill(
                            RadialGradient(
                                gradient: Gradient(colors: [
                                    isEditing ? Color.moodSpectrum(value: editedMoodValue) : entry.moodColor,
                                    (isEditing ? Color.moodSpectrum(value: editedMoodValue) : entry.moodColor).opacity(0.3)
                                ]),
                                center: .center,
                                startRadius: 5,
                                endRadius: 30
                            )
                        )
                        .frame(width: 60, height: 60)
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.8), lineWidth: 3)
                        )
                        .shadow(color: (isEditing ? Color.moodSpectrum(value: editedMoodValue) : entry.moodColor).opacity(0.3), radius: 10)
                    
                    Text(getMoodDescription(isEditing ? editedMoodValue : entry.moodValue))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(isEditing ? Color.moodSpectrum(value: editedMoodValue) : entry.moodColor)
                }
            }
            
            // Mood selector in edit mode
            if isEditing {
                VStack(alignment: .leading, spacing: 16) {
                    Label("调整心情", systemImage: "heart.fill")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    // Mood selection buttons
                    HStack(spacing: 12) {
                        ForEach(moodOptions, id: \.value) { mood in
                            Button(action: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    editedMoodValue = mood.value
                                    hasUnsavedChanges = true
                                }
                            }) {
                                VStack(spacing: 8) {
                                    Text(mood.emoji)
                                        .font(.system(size: 32))
                                    Text(mood.label)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.primary)
                                }
                                .frame(width: 80, height: 80)
                                // 选中和未选中都走 liquidGlass + mood 色 tint —— 不再饱和实色,
                                // 视觉饱和度对齐首页 spectrum bar(那个是 0.32 透明度叠在玻璃上)。
                                // 区分"已选"靠更强的 tint(0.42 vs 0.12) + 1.05 缩放 + mood 色阴影,
                                // 不再靠"实色 vs 玻璃"的材质对比。
                                .background {
                                    Color.clear
                                        .liquidGlassCard(
                                            cornerRadius: 12,
                                            tint: Color.moodSpectrum(value: mood.value),
                                            tintStrength: editedMoodValue == mood.value ? 0.42 : 0.12,
                                            interactive: true
                                        )
                                }
                                .scaleEffect(editedMoodValue == mood.value ? 1.05 : 1.0)
                                .shadow(color: editedMoodValue == mood.value ? Color.moodSpectrum(value: mood.value).opacity(0.3) : Color.clear, radius: 8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(20)
                // 整个 mood selector 容器换成 liquidGlassCard,和 App 整体玻璃语言对齐。
                .liquidGlassCard(cornerRadius: 16)
                .shadow(color: Color.primary.opacity(0.05), radius: 10, y: 5)
                .transition(.asymmetric(insertion: .scale.combined(with: .opacity), removal: .scale.combined(with: .opacity)))
            }
        }
    }
    
    /// 主题来自 AI 自动抽取（写入/编辑后台流水线里 extractThemes），
    /// 用户手动编辑主题容易污染聚合结果 —— 只做只读展示，非空才渲染。
    @ViewBuilder
    private var themesSection: some View {
        let themes = entry.themeArray
        if !themes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(NSLocalizedString("主题", comment: "Themes label"))
                        .font(.title3)
                        .fontWeight(.semibold)
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(.secondary.opacity(0.6))
                        .accessibilityLabel(NSLocalizedString("AI 自动提取", comment: "AI auto-extracted tag"))
                }
                FlowLayout(spacing: 8) {
                    ForEach(themes, id: \.self) { theme in
                        Text(theme)
                            .font(.footnote)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .liquidGlassCapsule(tint: Color.accentColor)
                    }
                }
            }
        }
    }

    // MARK: - Redesigned blocks

    private var detailBackground: some View {
        // 用 mood 颜色给整页背底染一层极淡的色，让 hero 和内容有呼吸感但不喧宾夺主
        let color = isEditing ? Color.moodSpectrum(value: editedMoodValue) : entry.moodColor
        return LinearGradient(
            colors: [color.opacity(0.10), Color.clear],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 260, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// 顶部 hero：情绪色块 + 日期 / 时间。
    /// 查看 / 编辑两种模式都渲染**同一个 Text**(formatDate + formatTime),
    /// 编辑模式下点击 Text 弹 popover 改日期 —— 这样切换编辑态时日期文本不会从
    /// 长格式跳变到 .compact DatePicker 的短格式,转场无缝。
    @ViewBuilder
    private var heroHeader: some View {
        let displayedDate = isEditing ? editedDate : entry.wrappedDate
        let moodColor = isEditing ? Color.moodSpectrum(value: editedMoodValue) : entry.moodColor

        HStack(alignment: .center, spacing: 14) {
            Circle()
                .fill(moodColor)
                .frame(width: 16, height: 16)
                .shadow(color: moodColor.opacity(0.35), radius: 6, y: 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(formatDate(displayedDate))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    if isEditing {
                        Image(systemName: "calendar")
                            .font(.caption)
                            .foregroundStyle(.secondary.opacity(0.6))
                    }
                }
                Text(formatTime(displayedDate))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            // 编辑模式下整块可点 → 弹 popover 改日期
            .contentShape(Rectangle())
            .onTapGesture {
                guard isEditing else { return }
                showDatePopover = true
            }
            // 用 sheet + .medium detent 而非 popover —— iPhone 上 popover 会被压扁,
            // sheet 给 graphical DatePicker 足够的高度展开。
            .sheet(isPresented: $showDatePopover) {
                NavigationStack {
                    DatePicker(
                        NSLocalizedString("修改时间", comment: "Edit date sheet title"),
                        selection: $editedDate,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.graphical)
                    .padding()
                    .onChange(of: editedDate) { _, _ in hasUnsavedChanges = true }
                    .navigationTitle(NSLocalizedString("修改时间", comment: "Edit date sheet title"))
                    #if canImport(UIKit)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(NSLocalizedString("完成", comment: "Done")) {
                                showDatePopover = false
                            }
                            .fontWeight(.semibold)
                        }
                    }
                }
                // graphical DatePicker(date+time)需要 ~500pt 才能完整放下日历 + 时间转盘,
                // medium detent 在 iPhone Pro 上不够,会把时间挡在底下。固定 560pt 兜底。
                .presentationDetents([.height(560), .large])
                .presentationDragIndicator(.visible)
            }
            .accessibilityLabel(NSLocalizedString("日记时间", comment: "Entry date picker a11y"))
            .accessibilityHint(isEditing ? NSLocalizedString("点击修改时间", comment: "Tap to edit date") : "")

            Spacer(minLength: 0)
        }
    }

    /// 编辑态下的情绪谱条
    @ViewBuilder
    private var moodEditorBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("情绪", comment: "Mood label"))
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(.secondary)
            EditableMoodSpectrumBar(moodValue: $editedMoodValue, isEnabled: true)
                .onChange(of: editedMoodValue) { _, _ in hasUnsavedChanges = true }
                .padding(.vertical, 2)
        }
    }

    /// 摘要：引用块风格（左侧竖条 + 斜体），编辑时内联可写；无摘要且非编辑时折叠掉。
    @ViewBuilder
    private var summaryBlock: some View {
        let hasSummary = !(entry.wrappedSummary ?? "").isEmpty
        if isEditing || hasSummary {
            VStack(alignment: .leading, spacing: 10) {
                if isEditing {
                    Text(NSLocalizedString("摘要", comment: "Summary label"))
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                    TextField(
                        NSLocalizedString("一句话记下这天…", comment: "Summary placeholder"),
                        text: $editedSummary,
                        axis: .vertical
                    )
                    .font(.body)
                    .lineLimit(1...4)
                    .padding(12)
                    .liquidGlassCard(cornerRadius: 12)
                    .onChange(of: editedSummary) { _, _ in hasUnsavedChanges = true }
                } else if let summary = entry.wrappedSummary, !summary.isEmpty {
                    HStack(alignment: .top, spacing: 12) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(entry.moodColor.opacity(0.8))
                            .frame(width: 3)
                        Text(summary)
                            .font(.system(size: 18, weight: .medium))
                            .italic()
                            .foregroundStyle(.primary)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    /// 正文：细标签 + 正文；编辑模式用 liquidGlassCard 做容器。
    @ViewBuilder
    private var entryBodyBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString("记录", comment: "Entry label"))
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(.secondary)
            if isEditing {
                TextEditor(text: $editedText)
                    .frame(minHeight: 220)
                    .font(.system(size: 17))
                    .lineSpacing(4)
                    .padding(10)
                    .scrollContentBackground(.hidden)
                    .liquidGlassCard(cornerRadius: 14)
                    .onChange(of: editedText) { _, _ in hasUnsavedChanges = true }
            } else {
                Text(entry.wrappedText)
                    .font(.system(size: 17))
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    /// 照片：水平滚动 + 圆角 + 轻阴影。
    @ViewBuilder
    private var photosBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString("照片", comment: "Photos label"))
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(entry.imageFileNameArray.enumerated()), id: \.offset) { index, fileName in
                        photoThumbnail(fileName: fileName, index: index)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 136)
        }
    }

    @ViewBuilder
    private func photoThumbnail(fileName: String, index: Int) -> some View {
        // 不再在 body 里 `entry.loadImageData(fileName:)`——那是磁盘 I/O + 可能的 iCloud 下载，
        // 播放进度 30fps 驱动 body 时主线程会被 I/O 连续卡顿。
        // 用一个小 view 持有 @State 并在 .task 里异步加载。
        AsyncPhotoThumbnail(fileName: fileName, index: index) { idx in
            presentImageViewer(at: idx)
        }
    }

    /// 音频：大 play 按钮 + 进度条 + 时间。
    @ViewBuilder
    private func audioBlock(audioFileName: String, audioURL: URL) -> some View {
        let isPlayingThis = audioPlaybackController.isPlaying && audioPlaybackController.currentPlayingFileName == audioFileName
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString("录音", comment: "Recording label"))
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Button {
                    playOrPauseAudio(url: audioURL, fileName: audioFileName)
                } label: {
                    Image(systemName: isPlayingThis ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(entry.moodColor)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(PlainButtonStyle())

                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.18))
                                .frame(height: 5)
                            if audioPlaybackController.currentPlayingFileName == audioFileName && displayableAudioDuration > 0 {
                                Capsule()
                                    .fill(entry.moodColor)
                                    .frame(width: geo.size.width * audioPlaybackController.progress, height: 5)
                            }
                        }
                    }
                    .frame(height: 5)
                    Text(formattedDuration(
                        currentTime: audioPlaybackController.currentPlayingFileName == audioFileName ? audioPlaybackController.currentTime : 0,
                        totalDuration: (audioPlaybackController.currentPlayingFileName == audioFileName && audioPlaybackController.duration > 0) ? audioPlaybackController.duration : displayableAudioDuration
                    ))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .liquidGlassCard(cornerRadius: 14)
            .task(id: audioFileName) {
                displayableAudioDuration = await fetchAudioDuration(url: audioURL) ?? 0.0
            }
        }
    }


    // MARK: - 编辑相关方法
    
    private func startEditing() {
        Log.info("[DiaryDetailView] Starting edit mode", category: .ui)
        editedSummary = entry.wrappedSummary ?? ""
        editedText = entry.wrappedText
        editedMoodValue = entry.moodValue
        editedDate = entry.wrappedDate
        hasUnsavedChanges = false
        
        withAnimation(AnimationConfig.gentleSpring) {
            isEditing = true
        }
        
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
    
    private func cancelEditing() {
        // 防御:用户在编辑模式开过日期 sheet 没关掉就点取消 → sheet 残留 / 下次进编辑闪一下。
        // cancelEditing 是退出编辑态的 single source of truth,在这里 reset 所有编辑专属 UI 状态。
        showDatePopover = false

        withAnimation(AnimationConfig.gentleSpring) {
            isEditing = false
        }
        hasUnsavedChanges = false

        // 隐藏键盘
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
    
    /// 5 个 mood 锚点和首页光谱的色阶严格对齐(0 / 0.25 / 0.5 / 0.75 / 1.0)。
    /// 之前用 0.1 / 0.3 / 0.7 / 0.9 是软化色,导致 pill 颜色和首页 spectrum bar 上同名情绪
    /// 显示出来的颜色不一致 —— 用户在两处看到同一情绪却是不同的红/蓝。统一到光谱端点。
    private var moodOptions: [(emoji: String, label: String, value: Double)] {
        [
            ("😢", "非常低落", 0.0),
            ("😞", "有些低落", 0.25),
            ("😐", "平静", 0.5),
            ("😊", "愉快", 0.75),
            ("😄", "非常开心", 1.0)
        ]
    }
    
    private func getMoodDescription(_ value: Double) -> String {
        switch value {
        case 0..<0.2: return "非常低落"
        case 0.2..<0.4: return "有些低落"
        case 0.4..<0.6: return "平静"
        case 0.6..<0.8: return "愉快"
        case 0.8...1: return "非常开心"
        default: return "平静"
        }
    }
    
    private func saveChanges() {
        // text 变化了就需要在后台重跑 themes + embedding（否则 Insight 主题聚合和
        // Ask Past 的语义检索会继续用旧内容的索引）。先捕获对比值，再写 Core Data。
        let textChanged = entry.wrappedText != editedText
        let entryObjectID = entry.objectID

        entry.summary = editedSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.text = editedText
        entry.moodValue = editedMoodValue
        entry.date = editedDate
        if textChanged {
            entry.recomputeWordCount()   // 本地算，免费，现在就更新
        }

        do {
            // **先 save，再切 UI 状态**。原顺序反了——catch 里只 log，UI 已经切到 "saved"，
            // 用户以为已保存其实没存。save 成功才做"切换到浏览态 / 关键盘 / 触发后台任务"。
            try viewContext.save()

            // 顺序优化(修保存掉帧):
            //   1. 先关键盘 —— 让系统先开始它的 dismiss 动画
            //   2. 再切 isEditing —— 不用 spring(spring 物理重算 + 多视图重排会撞上键盘动画掉帧)
            //   3. 触觉 + 后台任务 放最后
            #if canImport(UIKit)
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            #endif

            withAnimation(.smooth(duration: 0.22)) {
                isEditing = false
            }
            hasUnsavedChanges = false

            #if canImport(UIKit)
            HapticManager.shared.notification(.success)
            #endif

            if textChanged {
                // 快照捕获：Task.detached 是 @Sendable，View struct 不能整个跨线程传。
                // aiService 从 Environment 取，这里捕一个 Sendable 引用传进 static 方法，
                // 便于测试 / Preview 通过 `.environment(\.aiService, MockAIService())` 替换。
                let textSnapshot = editedText
                let ai = aiService
                Task.detached(priority: .utility) {
                    await Self.refreshAIIndex(for: entryObjectID, newText: textSnapshot, ai: ai)
                }
            }
        } catch {
            Log.error("[DiaryDetailView] 保存更改失败: \(error)", category: .ui)
            // **明确告知用户保存失败**——不能静默，否则用户以为改动已入库但下次打开还是旧内容。
            saveError = (error as NSError).localizedDescription
        }
    }

    /// 编辑后台刷新：跑一次 extractThemes + embed，写回 Core Data。
    /// 取 objectID 而不是 entry 引用——viewContext 可能在 Task 跑到时已经切换，直接用 objectID 去
    /// viewContext 重新 fetch 更安全。任何一步失败都静默跳过，不影响用户主动保存的已完成状态。
    ///
    /// 文本空 → 清空 themes/embedding（老的语义索引保留会让 AskPast 检索捞出"空内容带旧主题"的条目）。
    /// 写回前做 staleness guard：用户连续快速保存两次时，两个 Task.detached 都在跑，顺序不保证；
    /// 后提交的（text=v2）可能比先提交的（text=v1）先完成网络调用。没有 guard 的话慢的那条
    /// `setThemes(v1)` 会覆盖快的 `setThemes(v2)`，entry.text 是 v2 但 themes/embedding 是 v1，
    /// 静默污染语义检索。比较 `entry.wrappedText == newText`：只有当前 text 还等于我们当初快照的
    /// 那条才写。
    private static func refreshAIIndex(for objectID: NSManagedObjectID, newText: String, ai: AIServiceProtocol) async {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)

        let themes: [String]
        let embedding: [Float]?
        if trimmed.isEmpty {
            // 用户把内容清空：直接清 themes + embedding，不发网络
            themes = []
            embedding = nil
        } else {
            async let themesTask = ai.extractThemes(text: trimmed)
            async let embeddingTask = ai.embed(text: trimmed)
            (themes, embedding) = await (themesTask, embeddingTask)
        }

        await MainActor.run {
            let context = PersistenceController.shared.container.viewContext
            guard let entry = try? context.existingObject(with: objectID) as? DiaryEntry else {
                Log.error("[DiaryDetailView] refreshAIIndex: 原条目已不存在", category: .ai)
                return
            }
            // Stale-write guard：如果 entry.text 已经被更后的保存改掉了，这次 Task 结果已过期，
            // 直接丢弃不写，让新 Task 的新 themes/embedding 生效。
            // 比较时都做 trim——否则末尾换行 / 空格差异会被误判为"已被更新"。
            let currentTrimmed = entry.wrappedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard currentTrimmed == trimmed else {
                Log.info("[DiaryDetailView] refreshAIIndex: 文本已被更新的保存覆盖，丢弃 stale 结果", category: .ai)
                return
            }

            if trimmed.isEmpty {
                // 用户明确把内容清空了 → 清掉 themes + embedding（这是用户意图）
                entry.setThemes([])
                entry.embedding = nil
            } else {
                // **Partial-failure guard**：`extractThemes` 网络失败返 []、`embed` 失败返 nil，
                // 两种返回值无法区分"真 empty"和"transient 故障"。如果这里遇到任一返回"空/nil"，
                // 就把现有 themes/embedding 全量保留——宁可让用户多等下一次 edit 或 backfill 重试，
                // 也不在 AI 出故障时用空值污染一条已索引好的 entry（否则 themes 清空 / embedding
                // 指向旧文本，Ask Past 检索 ranking 和 theme chips 会对不上直到手动重建）。
                // 两者"都成功"才整组 commit。
                guard !themes.isEmpty, let vector = embedding else {
                    Log.info("[DiaryDetailView] refreshAIIndex: AI 部分失败（themes=\(themes.count), embedding=\(embedding != nil ? "ok" : "nil")），保留原值", category: .ai)
                    return
                }
                entry.setThemes(themes)
                entry.setEmbedding(vector)
            }

            do {
                try context.save()
                Log.info("[DiaryDetailView] refreshAIIndex 完成：themes=\(themes.count), embedding=\(embedding != nil ? "ok" : "nil")", category: .ai)
            } catch {
                Log.error("[DiaryDetailView] refreshAIIndex save 失败: \(error)", category: .ai)
            }
        }
    }
    
    // MARK: - 音频相关方法
    
    private func formattedDuration(currentTime: TimeInterval, totalDuration: TimeInterval) -> String {
        let current = Int(currentTime)
        let total = Int(totalDuration)
        return String(format: "%d:%02d / %d:%02d", 
                     current / 60, current % 60,
                     total / 60, total % 60)
    }
    
    // 辅助函数：获取音频文件时长 - marked async
    private func fetchAudioDuration(url: URL) async -> TimeInterval? {
        let audioAsset = AVURLAsset(url: url)
        // try? handles potential error by returning nil, no do-catch needed here
        return try? await audioAsset.load(.duration).seconds
    }
    
    private func playOrPauseAudio(url: URL, fileName: String) {
        audioPlaybackController.play(url: url, fileName: fileName)
        
        // Removed problematic and unused knownDuration block.
        // Duration loading is handled by .task and AudioPlaybackController internally.

        // 设置播放结束和错误的回调
        audioPlaybackController.onFinishPlaying = { [weak audioPlaybackController] in
            // UI 可以在这里更新，例如重置播放按钮状态
            Log.info("[DiaryDetailView] Playback finished. Controller isPlaying: \(audioPlaybackController?.isPlaying ?? false)", category: .ui)
        }
        audioPlaybackController.onPlayError = { [weak audioPlaybackController] error in // Added weak capture for consistency if needed
            let fileName = audioPlaybackController?.currentPlayingFileName ?? "N/A"
            Log.error("[DiaryDetailView] Audio playback error: \(error.localizedDescription). Controller file: \(fileName)", category: .ui)
            // 可以在这里向用户显示错误信息
        }
    }
}

// Removed #Preview block to avoid macro compilation issues.

// MARK: - FlowLayout
//
// 简单的行内流式布局：把子视图按次序从左到右排列，溢出自动换行。
// 用于主题 chip 这种长度不一的标签列表。

@available(iOS 16.0, macOS 13.0, *)
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(in: maxWidth, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height + spacing } - (rows.isEmpty ? 0 : spacing)
        let width = rows.map { $0.width }.max() ?? 0
        return CGSize(width: min(width, maxWidth), height: max(height, 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(in: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let size = item.subview.sizeThatFits(.unspecified)
                item.subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct RowItem {
        let subview: LayoutSubview
        let size: CGSize
    }
    private struct Row {
        var items: [RowItem] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(in maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            var current = rows[rows.count - 1]
            let prospective = current.width + (current.items.isEmpty ? 0 : spacing) + size.width
            if prospective > maxWidth && !current.items.isEmpty {
                rows.append(Row(items: [RowItem(subview: subview, size: size)], width: size.width, height: size.height))
            } else {
                current.items.append(RowItem(subview: subview, size: size))
                current.width = prospective
                current.height = max(current.height, size.height)
                rows[rows.count - 1] = current
            }
        }
        return rows
    }
}

// MARK: - AsyncPhotoThumbnail
//
// 把"磁盘读一张缩略图"和 body 解耦：body 只声明有一个缩略图要显示，
// 真正的 `Data(contentsOf:)` 在 .task 里跑。原来的实现直接在 body 里做 I/O，
// 播放进度 30fps 会让主线程重复命中磁盘读取。
private struct AsyncPhotoThumbnail: View {
    let fileName: String
    let index: Int
    let onTap: (Int) -> Void
    @State private var imageData: Data?

    var body: some View {
        Group {
            if let data = imageData {
                #if os(iOS)
                if let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                }
                #else
                if let nsImage = NSImage(data: data) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFill()
                }
                #endif
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        }
        .frame(width: 130, height: 130)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.black.opacity(0.1), radius: 6, y: 2)
        .onTapGesture { onTap(index) }
        .task(id: fileName) {
            if imageData == nil {
                let data = await Task.detached(priority: .utility) {
                    DiaryEntry.loadImageData(fileName: fileName)
                }.value
                await MainActor.run { self.imageData = data }
            }
        }
    }
}
