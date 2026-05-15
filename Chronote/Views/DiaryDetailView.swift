import SwiftUI
import AVFoundation
import CoreData
#if canImport(UIKit)
import UIKit
#endif

private func deleteDiaryDetailAttachmentFiles(imageFileNames: [String], audioFileName: String?) {
    for fileName in imageFileNames {
        do {
            try DiaryEntry.deleteImageFromDocuments(fileName)
        } catch {
            Log.error("[DiaryDetailView] 删除图片附件失败 \(fileName): \(error)", category: .ui)
        }
    }
    if let audioFileName, !audioFileName.isEmpty {
        DiaryEntry.deleteAudioFromDocuments(audioFileName)
    }
}

struct DiaryDetailView: View {
    @ObservedObject var entry: DiaryEntry
    var startInEditMode: Bool = false
    var onDeleted: (() -> Void)? = nil
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.aiService) private var aiService
    // showDeleteAlert 已移除 — 删除走 4 秒撤销 toast,不再有 alert。
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

    private func deleteEntry() {
        audioPlaybackController.stopPlayback(clearCurrentFile: true)

        // P1-Home-6 撤销 — 跟 HomeView.deleteEntry 同 pattern。snapshot 在 delete 之前抓,
        // attachment 文件不立刻删,4 秒后由 EntryDeletionUndoService.commitPendingNow 跑。
        let snapshot = EntryDeletionSnapshot(entry: entry)
        viewContext.delete(entry)

        do {
            try viewContext.save()
            HapticManager.shared.impact(.medium)
            // 单删派生缓存清理统一走 EntryWipeOrchestrator。
            EntryWipeOrchestrator.performSingleDeleteCleanup()
            onDeleted?()

            // 注册到 undo service + 弹带"撤销"按钮 toast。dismiss 后 root overlay / 父视图 overlay
            // 接管 toast 渲染(InsightsView / Home 都已挂 lumoryToastOverlay)。
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
            dismiss()
        } catch {
            viewContext.rollback()
            Log.error("[DiaryDetailView] 删除日记失败: \(error)", category: .ui)
            saveError = NSLocalizedString("删除失败,可能是磁盘空间不足或同步冲突。请稍后重试。", comment: "Generic delete failure fallback")
        }
    }
    
    @AppStorage("appLanguage", store: AppGroup.userDefaults) private var appLanguage: String = {
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
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language)
        switch kind {
        case .longDate:
            formatter.dateStyle = .long
            formatter.timeStyle = .none
        case .shortTime:
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        }
        detailFormatterCache[key] = formatter
        return formatter
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
            if entry.managedObjectContext == nil || entry.isDeleted {
                // Entry has been deleted, just show a placeholder
                Text(NSLocalizedString("正在返回...", comment: "Returning message"))
                    .onAppear {
                        dismiss()
                    }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        // iOS 26 极简三段式:
                        // 1. 顶部 hero — 日期 + 心情 + 摘要(一句话定调)
                        // 2. 主体 — 正文 + 录音 + 照片(连贯的日记内容,无 section label)
                        // 3. 底部 footer — AI 抽出的主题 chip(元数据,弱化)
                        // 录音排在照片前:语音日记往往是正文思绪延伸,照片是独立视觉记忆。
                        heroHeader
                        if isEditing {
                            moodEditorBlock
                        }
                        summaryBlock
                        entryBodyBlock
                        if let audioFileName = entry.audioFileName, let audioURL = entry.audioURL() {
                            audioBlock(audioFileName: audioFileName, audioURL: audioURL)
                        }
                        if !entry.imageFileNameArray.isEmpty {
                            photosBlock
                        }
                        themesSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
                    // F7 — iPad 阅读宽度限定。日记正文 + summary + themes + 图片网格,720pt formContentMaxWidth
                    // 是表单/单栏内容的舒适宽度,跟 Insights 的 narrative 760 / list 900 区分(详情更紧凑)
                    .lumoryReadableContent(maxWidth: LumoryAdaptivePresentation.formContentMaxWidth)
                }
                // iOS 26 顶部边缘软渐隐 — 详情滚动到顶时跟 navigation chrome 自然过渡。
                .scrollEdgeEffectStyle(.soft, for: .top)
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
                // P1-Home-9 右上误触防护 — 编辑态显示明确"保存";阅读态把"编辑+删除"塞进
                // ellipsis Menu,把 destructive 删除从主按钮区移走,防误触红色按钮。
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isEditing {
                        Button(NSLocalizedString("保存", comment: "Save button")) {
                            HapticManager.shared.impact(.light)
                            saveChanges()
                        }
                        .fontWeight(.semibold)
                    } else {
                        Menu {
                            Button {
                                startEditing()
                            } label: {
                                Label(NSLocalizedString("编辑", comment: "Edit button"), systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                // 删除直接执行 — 4 秒撤销 toast 替代 confirmation。Detail 会 dismiss,
                                // toast 在父视图(Home / Insights sheet)的 root overlay 渲染。
                                deleteEntry()
                            } label: {
                                Label(NSLocalizedString("删除", comment: "Delete button"), systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel(NSLocalizedString("更多操作", comment: "More actions"))
                    }
                }
#endif
            }
            // 删除 confirmation 已移除 — 4 秒撤销 toast 替代。
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
            // P0-2 Detail 可被嵌套到 Insights→ThemeFilteredEntries→Detail 的 sheet 路径里,
            // 那条路径上 root toast overlay 被压在 sheet 之下,保存 toast 看不见。在这层重挂兜底。
            .lumoryToastOverlay()
            .navigationBarBackButtonHidden(isEditing)
            .interactiveDismissDisabled(isEditing && hasUnsavedChanges)
            // **P2 fix (2026-05-13 superreview round 2)**:fullScreenCover dismiss 后 `viewerImages`
            // 仍持有 5 张 12MP HEIC ≈ 25MB 常驻 parent State,InsightsView 滚动时长期占用峰内存。
            // onDismiss 显式清空让 Swift ARC 回收 Data buffer。
            #if os(iOS)
            .fullScreenCover(isPresented: $showImageViewer, onDismiss: { viewerImages = [] }) {
                if !viewerImages.isEmpty {
                    ImageViewerView(
                        images: viewerImages,
                        selectedIndex: $selectedImageIndex,
                        isPresented: $showImageViewer
                    )
                }
            }
            #else
            .sheet(isPresented: $showImageViewer, onDismiss: { viewerImages = [] }) {
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

    /// 主题来自 AI 自动抽取(写入/编辑后台流水线里 extractThemes),
    /// 用户手动编辑主题容易污染聚合结果 —— 只做只读展示,非空才渲染。
    /// 主题 chip 用**当天 mood 颜色**,跟页面顶部 mood 圆点 + 摘要竖条同一色系。
    ///
    /// **iOS 26 redesign**:去掉 "主题" + sparkles header,chip 直接展示在页面底部
    /// 作为 footer 元数据。理由:themes 主要价值在 Insights 聚合,单条日记里它是
    /// "AI 给这条日记打的标签",不需要标题引导;chip 视觉本身 self-explanatory。
    /// a11y label 加在第一个 chip 上,告诉 VoiceOver 用户这是 AI 提取的标签组。
    @ViewBuilder
    private var themesSection: some View {
        let themes = entry.themeArray
        if !themes.isEmpty {
            let moodTint = Color.moodSpectrum(value: entry.moodValue)
            FlowLayout(spacing: 8) {
                // **P2 fix (2026-05-13 superreview)**:`DiaryEntry.themeArray` 不 dedup
                // (Model/DiaryEntry+Extensions.swift:56-59 只 split+trim),legacy 或导入路径
                // 可能落入重复 theme → `id: \.element` ForEach 报 id collision warning + 渲染
                // 不稳。`id: \.offset` 用位置作 id,renaming/reorder 不破坏。
                ForEach(Array(themes.enumerated()), id: \.offset) { index, theme in
                    Text(theme)
                        .font(.footnote)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .liquidGlassCapsule(tint: moodTint)
                        .accessibilityLabel(index == 0
                            ? String(format: NSLocalizedString("AI 提取的主题:%@", comment: "First theme chip a11y label"), theme)
                            : theme)
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
                        .font(LumoryFonts.diaryHeroTitle)
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
                .lumorySheetDecoration()
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
                        // F9 — entry.summary 字号语义化(.title3 = 20pt baseline,detail 页 hero 元素最大;跟 row/preview 字号阶梯一致)
                        Text(summary)
                            .font(.title3.weight(.medium))
                            .italic()
                            .foregroundStyle(.primary)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    /// 正文。**iOS 26 redesign**:阅读态直接渲染 `.body`(17pt 语义字号,Dynamic Type 友好),
    /// 不带 "记录" caption label —— 一坨正文本身就是日记内容,标签是多余 chrome。
    /// 编辑态保留 caption label + TextEditor 大空白容器,让用户明确"在编辑哪个字段"。
    @ViewBuilder
    private var entryBodyBlock: some View {
        if isEditing {
            VStack(alignment: .leading, spacing: 10) {
                Text(NSLocalizedString("记录", comment: "Entry label"))
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                TextEditor(text: $editedText)
                    .frame(minHeight: 220)
                    .font(.body)
                    .lineSpacing(4)
                    .padding(10)
                    .scrollContentBackground(.hidden)
                    .liquidGlassCard(cornerRadius: LumoryCornerRadius.card)
                    .onChange(of: editedText) { _, _ in hasUnsavedChanges = true }
            }
        } else {
            Text(entry.wrappedText)
                .font(.body)
                .lineSpacing(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    /// 照片:水平滚动缩略图。**iOS 26 redesign**:无 "照片" caption label,
    /// 缩略图视觉本身 self-evident,标签是多余 chrome。
    @ViewBuilder
    private var photosBlock: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(entry.imageFileNameArray.enumerated()), id: \.offset) { index, fileName in
                    photoThumbnail(fileName: fileName, index: index)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: 136)
        .accessibilityLabel(NSLocalizedString("照片", comment: "Photos a11y label"))
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

    /// 录音:大 play 按钮 + 进度条 + 时间。**iOS 26 redesign**:无 "录音" caption label,
    /// play 按钮 + 波形进度条 + 时长读数本身就是 audio player 的通用视觉语言。
    @ViewBuilder
    private func audioBlock(audioFileName: String, audioURL: URL) -> some View {
        let isPlayingThis = audioPlaybackController.isPlaying && audioPlaybackController.currentPlayingFileName == audioFileName
        HStack(spacing: 14) {
            Button {
                playOrPauseAudio(url: audioURL, fileName: audioFileName)
            } label: {
                Image(systemName: isPlayingThis ? "pause.circle.fill" : "play.circle.fill")
                    .font(LumoryFonts.diaryImagePlaceholder)
                    .foregroundStyle(entry.moodColor)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel(isPlayingThis
                ? NSLocalizedString("暂停录音", comment: "Pause recording a11y")
                : NSLocalizedString("播放录音", comment: "Play recording a11y"))

            VStack(alignment: .leading, spacing: 6) {
                let isCurrentFile = audioPlaybackController.currentPlayingFileName == audioFileName
                let playbackTime = isCurrentFile ? audioPlaybackController.currentTime : 0
                let playbackDuration = isCurrentFile && audioPlaybackController.duration > 0
                    ? audioPlaybackController.duration
                    : displayableAudioDuration
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.18))
                            .frame(height: 5)
                        if isCurrentFile && displayableAudioDuration > 0 {
                            Capsule()
                                .fill(entry.moodColor)
                                .frame(width: geo.size.width * audioPlaybackController.progress, height: 5)
                        }
                    }
                }
                .frame(height: 5)
                Text(formattedDuration(
                    currentTime: playbackTime,
                    totalDuration: playbackDuration
                ))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .liquidGlassCard(cornerRadius: LumoryCornerRadius.card)
        .task(id: audioFileName) {
            displayableAudioDuration = await fetchAudioDuration(url: audioURL) ?? 0.0
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

        HapticManager.shared.impact(.light)
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
    
    private func saveChanges() {
        // **P1 fix (2026-05-15 megareview)**:`body` 顶部已 guard `entry.isDeleted` 自动 dismiss,
        // 但键盘升起 + body 不重 eval 期间,CloudKit pull 删了这条 entry → 用户点保存 →
        // 写入 tombstoned object → 要么静默"复活"、要么 save 抛 merge conflict 被显示为模糊"保存失败"。
        // 这里再 guard 一次,有效兜底"body guard 之后到 save 调用之间"的 race 窗口。
        guard !entry.isDeleted, entry.managedObjectContext != nil else {
            Log.info("[DiaryDetailView] entry 在保存前已被删除/失效, 跳过 save 并 dismiss", category: .ui)
            dismiss()
            return
        }
        // text 变化了就需要在后台重跑 themes + embedding（否则 Insight 主题聚合和
        // Ask Past 的语义检索会继续用旧内容的索引）。先捕获对比值，再写 Core Data。
        let textChanged = entry.wrappedText != editedText
        let dateChanged = entry.date != editedDate
        let moodChanged = entry.moodValue != editedMoodValue
        let normalizedSummary = editedSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let summaryChanged = (entry.summary ?? "") != normalizedSummary
        let narrativeInputChanged = textChanged || dateChanged || moodChanged || summaryChanged
        let entryObjectID = entry.objectID

        entry.summary = normalizedSummary
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

            // 改 date 可能让 entry 移入/移出当前固定周期(cycle-based,锚点对齐),
            // 进而改变 wroteCurrentCycle → reminder 要重排。
            if dateChanged {
                ReminderService.shared.requestReschedule()
            }

            // **改 date 还可能改变 streak 算法的全 unique-days 集合** —— widget cheap fingerprint 仅看
            // (count, latestDate, latestMood, prompt),改老 entry 的 date 不在 fingerprint 范围内,
            // 短路会让 widget streak 不更新。改 mood 也类似(若改的是非最新 entry 的 mood,fingerprint 也不变,
            // 但实际 widget 头像色不受影响 — 只 latest mood 决定;留个保险)。invalidate 让下次 refresh
            // 强制 full path 重抓。NSManagedObjectContextDidSave observer 会 schedule 下一次 refresh。
            if dateChanged || moodChanged {
                Task { await WidgetSnapshotService.shared.invalidateCaches() }
            }

            if dateChanged {
                StreakMilestoneService.shared.evaluateAfterSave(
                    persistence: PersistenceController.shared,
                    latestEntryMood: editedMoodValue
                )
            }

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
            // P0-2 全局 toast —— Detail 保存原本只 haptic,新加 visual feedback。
            LumoryToastCenter.shared.show(
                NSLocalizedString("已保存", comment: "Toast after diary entry edit saved"),
                severity: .success
            )

            if textChanged {
                // 快照捕获：Task.detached 是 @Sendable，View struct 不能整个跨线程传。
                // aiService 从 Environment 取，这里捕一个 Sendable 引用传进 static 方法，
                // 便于测试 / Preview 通过 `.environment(\.aiService, MockAIService())` 替换。
                let textSnapshot = editedText
                let ai = aiService
                Task(priority: .utility) {
                    await Self.refreshAIIndex(for: entryObjectID, newText: textSnapshot, ai: ai)
                }
            }
            if narrativeInputChanged {
                // Narrative 输入包含日期 / 心情 / 摘要 / 正文。任一项变化都要让旧回顾退出
                // 浓缩卡 cache,否则会继续显示旧日期、旧心情或旧摘要语义。
                Task { await EntryWipeOrchestrator.invalidateNarrativeCacheOnEntryChange() }
            }
        } catch {
            Log.error("[DiaryDetailView] 保存更改失败: \(error)", category: .ui)
            // **P1 fix (2026-05-15 megareview)**:save 抛异常时,前面 line 638-644 已经把 editedText/
            // editedDate/editedMoodValue/normalizedSummary 写进 in-memory entry。如果不 rollback,
            // 用户屏幕显示的还是脏写值(看起来像保存成功),下次重开才发现是旧内容。`viewContext.rollback()`
            // 把 in-memory 状态拨回 disk 真值,跟 `deleteEntry` catch 的处理对齐。
            viewContext.rollback()
            // **明确告知用户保存失败**——不能静默，否则用户以为改动已入库但下次打开还是旧内容。
            // 用人话 fallback 而不是 NSError.localizedDescription("Cocoa error 134200" 类技术码对终端用户毫无意义)。
            saveError = NSLocalizedString("保存失败,可能是磁盘空间不足或同步冲突。请稍后重试。", comment: "Generic save failure fallback")
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

        // 把"是否真的提交了 themes" + entryID 一起跨出 MainActor.run。
        // 如果 stale guard 丢了写入,我们仍要 short-circuit 后面的 alias judge,
        // 否则会基于 ghost 数据生成建议。codex review 标记为 high-priority 修。
        let postWrite: (committed: Bool, entryID: UUID?) = await MainActor.run {
            let context = PersistenceController.shared.container.viewContext
            guard let entry = try? context.existingObject(with: objectID) as? DiaryEntry else {
                Log.error("[DiaryDetailView] refreshAIIndex: 原条目已不存在", category: .ai)
                return (false, nil)
            }
            // Stale-write guard：如果 entry.text 已经被更后的保存改掉了，这次 Task 结果已过期，
            // 直接丢弃不写，让新 Task 的新 themes/embedding 生效。
            // 比较时都做 trim——否则末尾换行 / 空格差异会被误判为"已被更新"。
            let currentTrimmed = entry.wrappedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard currentTrimmed == trimmed else {
                Log.info("[DiaryDetailView] refreshAIIndex: 文本已被更新的保存覆盖，丢弃 stale 结果", category: .ai)
                return (false, entry.id)
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
                    return (false, entry.id)
                }
                entry.setThemes(themes)
                entry.setEmbedding(vector)
            }

            do {
                try context.save()
                Log.info("[DiaryDetailView] refreshAIIndex 完成：themes=\(themes.count), embedding=\(embedding != nil ? "ok" : "nil")", category: .ai)
                return (true, entry.id)
            } catch {
                Log.error("[DiaryDetailView] refreshAIIndex save 失败: \(error)", category: .ai)
                return (false, entry.id)
            }
        }

        // Theme alias judge —— **仅当 themes 真写入时才跑**(stale-write 或 partial-failure 时跳过)。
        if postWrite.committed, !themes.isEmpty, let entryID = postWrite.entryID {
            await ThemeAliasJudgeService.shared.judgeAfterWrite(
                entryID: entryID,
                newTags: themes
            )
        }
    }

    // MARK: - 音频相关方法

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

// MARK: - AsyncPhotoThumbnail
//
// 把"磁盘读一张缩略图"和 body 解耦：body 只声明有一个缩略图要显示，
// 真正的 `Data(contentsOf:)` 在 .task 里跑。原来的实现直接在 body 里做 I/O，
// 播放进度 30fps 会让主线程重复命中磁盘读取。
private struct AsyncPhotoThumbnail: View {
    let fileName: String
    let index: Int
    let onTap: (Int) -> Void
    @State private var thumbnailImage: ThumbnailImageDecoder.PlatformImage?

    var body: some View {
        Group {
            if let thumbnailImage {
                #if os(iOS)
                Image(uiImage: thumbnailImage)
                    .resizable()
                    .scaledToFill()
                #elseif canImport(AppKit)
                Image(nsImage: thumbnailImage)
                    .resizable()
                    .scaledToFill()
                #endif
            } else {
                RoundedRectangle(cornerRadius: LumoryCornerRadius.card, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        }
        .frame(width: 130, height: 130)
        .clipShape(RoundedRectangle(cornerRadius: LumoryCornerRadius.card, style: .continuous))
        // P1-Dark-5 用 .primary.opacity 而不是 .black.opacity — 暗色下 .primary 是白色,
        // 阴影成"白光"显示在暗背景上,符合 OLED 暗色 lift effect 直觉;.black.opacity 在暗背景零效果。
        .shadow(color: Color.primary.opacity(0.15), radius: 6, y: 2)
        .onTapGesture { onTap(index) }
        .task(id: fileName) {
            if thumbnailImage == nil {
                let image = await Task.detached(priority: .utility) { () -> ThumbnailImageDecoder.PlatformImage? in
                    guard let data = DiaryEntry.loadImageData(fileName: fileName) else { return nil }
                    return ThumbnailImageDecoder.decode(data: data, maxPixelSize: 390)
                }.value
                await MainActor.run { self.thumbnailImage = image }
            }
        }
    }
}
