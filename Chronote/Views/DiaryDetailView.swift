import SwiftUI
import AVFoundation
import CoreData
#if canImport(UIKit)
import UIKit
#endif

struct DiaryDetailView: View {
    // **Property visibility 约定**:本 struct 的 stored prop 全部 `internal`(无 modifier),
    // 让 `DiaryDetailView+Display.swift` / `+Edit.swift` / `+Audio.swift` 几个 extension 文件
    // 能跨文件访问 state。Swift `private` 在 extension 是 file-scoped,跨文件够不到 —— 因此
    // 本 struct 把 state 提升到 internal。仅纯 view-builder computed var(如 `detailBackground` /
    // `heroHeader`)在 +Display.swift 内部仍 `private`,因为只在 view body 渲染链路内使用。
    @ObservedObject var entry: DiaryEntry
    var startInEditMode: Bool = false
    var onDeleted: (() -> Void)? = nil
    @Environment(\.managedObjectContext) var viewContext
    @Environment(\.dismiss) var dismiss
    @Environment(\.aiService) var aiService
    // showDeleteAlert 已移除 — 删除走 4 秒撤销 toast,不再有 alert。
    @StateObject var audioPlaybackController = AudioPlaybackController() // 新的控制器
    @State var displayableAudioDuration: TimeInterval = 0.0 // State for fetched duration

    // 编辑模式相关状态
    @State var isEditing = false
    @State var editedSummary: String = ""
    @State var editedText: String = ""
    @State var editedMoodValue: Double = 0.5
    @State var editedDate: Date = Date()
    @State var hasUnsavedChanges = false
    /// 保存失败时向用户展示的错误消息；非 nil 时弹 alert。
    @State var saveError: String?
    @State var showDiscardChangesAlert = false
    /// 编辑态下日期 picker 的 popover 显隐 —— 让查看 / 编辑两种模式渲染同一个 Text,
    /// 只是编辑模式下点击 Text 弹 popover,避免 .compact DatePicker 切换时日期格式跳变。
    @State var showDatePopover: Bool = false
    @Environment(\.colorScheme) var colorScheme

    // Animation states
    @State var animateIn = false
    @State var showContent = false
    @State var showImageViewer = false
    @State var selectedImageIndex = 0
    /// Image viewer 的图片数据：在点击缩略图时异步加载，加载完成后再呈现 viewer，
    /// 避免在 cover/sheet body 里做同步 I/O 阻塞主线程。
    @State var viewerImages: [Data] = []

    // `presentImageViewer` / `deleteEntry` 已抽到 `DiaryDetailView/DiaryDetailView+Display.swift`
    // 和 `DiaryDetailView+Edit.swift`。

    @AppStorage("appLanguage", store: AppGroup.userDefaults) var appLanguage: String = {
        let currentLocale = Locale.current.identifier
        if currentLocale.hasPrefix("zh") {
            return "zh-Hans"
        } else {
            return "en"
        }
    }()
    
    // `formatDate` / `formatTime` 已抽到 `DiaryDetailView+Display.swift`(只在 hero header 用)。

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
                // 2026-05-19 wave19 + user feedback (2026-05-19 round 2) — 分享下线;阅读态显
                // **编辑 + 删除两个独立 ToolbarItem**(原本同 HStack 被 iOS 26 自动合并成单个
                // glass capsule,跟用户期望"两个独立按钮"不齐)。声明顺序:**编辑先 / 删除后**,
                // SwiftUI 把后声明的 trailing item 渲染在更右 → trash 靠右,符合"删除最远端"语义。
                // 编辑态收成单"保存"按钮。删除依赖 EntryDeletionUndoService 4 秒撤销 toast 兜底。
                if isEditing {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(NSLocalizedString("保存", comment: "Save button")) {
                            HapticManager.shared.impact(.light)
                            saveChanges()
                        }
                        .fontWeight(.semibold)
                    }
                } else {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            startEditing()
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .accessibilityLabel(NSLocalizedString("编辑", comment: "Edit"))
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(role: .destructive) {
                            // 删除直接执行 — 4 秒撤销 toast 替代 confirmation。
                            deleteEntry()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel(NSLocalizedString("删除", comment: "Delete"))
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

    // `themesSection` / `detailBackground` / `heroHeader` / `moodEditorBlock` / `summaryBlock` /
    // `entryBodyBlock` / `photosBlock` / `audioBlock` / `presentImageViewer` / `formatDate` /
    // `formatTime` 已抽到 `DiaryDetailView/DiaryDetailView+Display.swift`。
    // 编辑相关(`startEditing` / `cancelEditing` / `saveChanges` / `refreshAIIndex` / `deleteEntry`)
    // 抽到 `DiaryDetailView+Edit.swift`。音频(`fetchAudioDuration` / `playOrPauseAudio`)抽到
    // `DiaryDetailView+Audio.swift`。`AsyncPhotoThumbnail` 独立到 `Views/Components/`。

}

// Removed #Preview block to avoid macro compilation issues.
// `AsyncPhotoThumbnail` 已抽到 `Views/Components/AsyncPhotoThumbnail.swift`(internal,跨文件可见)。
