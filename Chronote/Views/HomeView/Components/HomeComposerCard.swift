import SwiftUI
import PhotosUI

/// 首页输入卡(光谱下方)。包文本输入 / 录音 row / 照片 row / 压缩失败 banner / 工具栏。
///
/// **状态 ownership 边界**:
/// - 3 个 `@Observable` VM 走 `@Bindable` 由 parent 持。
/// - `AudioRecorder` / `AudioPlaybackController` 是 `@StateObject` 由 parent 持(CLAUDE.md 锁:
///   不能搬进 `@Observable` VM,Observation 宏不 bridge 嵌套 `@Published`)。
/// - 草稿 debounce 任务 + AppGroup defaults 写入由 parent 持(子 view 经 `onInputTextChanged`
///   回调把新值送出去)。
/// - send / 录音生命周期 / playAudio / 转写重试 / 删录音 confirm 都是 parent 行为,经 callback 触发。
@available(iOS 17.0, *)
struct HomeComposerCard: View {
    @Bindable var inputVM: HomeInputViewModel
    @Bindable var recordingVM: HomeRecordingViewModel
    @Bindable var photoVM: HomePhotoViewModel
    @ObservedObject var recorder: AudioRecorder
    @ObservedObject var audioPlaybackController: AudioPlaybackController
    @FocusState.Binding var isInputFocused: Bool
    @Binding var draftEntryDate: Date?

    let inputPlaceholder: String

    /// 文本变化:parent 做 500ms debounce + 写 AppGroup defaults + scenePhase=background 强 flush。
    /// 子 view 不持 task / 不读 defaults,只送新值。
    let onInputTextChanged: (String) -> Void
    /// Send 按钮 tap 入口。parent 跑完整 send pipeline(snapshot + animation + save + 失败回滚)。
    let onSend: () -> Void
    /// 播放某条录音。parent 装 `audioPlaybackController` callbacks 并 play。
    let onPlayRecording: (String) -> Void
    /// 转写失败 banner 上的"重试"。parent 重启 transcription task。
    let onRetryTranscription: () -> Void
    /// Mic 按钮 tap。parent 根据 `recorder.isRecording` 派发 start / stop。
    let onMicTap: () -> Void
    /// PhotosPicker 选择变化。parent cancel 旧压缩 task + 启动新一轮 `loadPhotosWithCompression`。
    let onPhotoSelectionChanged: ([PhotosPickerItem]) -> Void
    /// 删除录音 confirm alert 的"删除"按钮。parent 跑 deleteRecording(target) 完整清理。
    let onDeleteRecordingConfirmed: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appLanguage", store: AppGroup.userDefaults) private var appLanguage: String = {
        Locale.current.identifier.hasPrefix("zh") ? "zh-Hans" : "en"
    }()
    @State private var draftDatePickerPresented = false
    @State private var refocusInputAfterDatePicker = false
    @State private var draftDateBeforePicker: Date?

    var body: some View {
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
            .liquidGlassCard(cornerRadius: LumoryCornerRadius.chip)
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Button {
                    openDraftDatePicker()
                } label: {
                    Label(draftDateDisplayLabel, systemImage: "calendar")
                        .font(.footnote.weight(.medium))
                }
                .accessibilityLabel(draftDateAccessibilityLabel)
                Spacer()
                Button {
                    isInputFocused = false
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                }
                .accessibilityLabel(NSLocalizedString("收起键盘", comment: "Dismiss keyboard"))
            }
        }
        .sheet(isPresented: $draftDatePickerPresented, onDismiss: handleDraftDatePickerDismiss) {
            draftDatePicker
        }
    }

    // MARK: - Text input

    @ViewBuilder
    private var textInputArea: some View {
        // 原生 SwiftUI TextField(axis:.vertical),不再走 UIKit 桥。底部 photo/mic/send 是稳定常驻工具栏;
        // 日期放 keyboard accessory 里做辅助入口,避免常驻 chip 把输入卡变吵。
        // Prompt 颜色按色彩模式分:亮色 secondary 0.50(浅),暗色实 .secondary。
        let promptColor: Color = colorScheme == .dark
            ? Color.secondary
            : Color.secondary.opacity(0.50)

        TextField(
            "",
            text: $inputVM.inputText,
            prompt: Text(inputPlaceholder)
                .font(LumoryFonts.composerPlaceholder)
                .foregroundColor(promptColor),
            axis: .vertical
        )
        .lineLimit(6...20)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(Color.clear)
        .font(LumoryFonts.composerBody)
        .focused($isInputFocused)
        // (2026-05-15 superreview-3 P1)显式 a11y id 让 UI test 能稳定锁定 composer,
        // 而不是 `app.textFields.firstMatch` 撞错搜索栏 / 别的 TextField。
        .accessibilityIdentifier("home.composer.text")
        .onChange(of: inputVM.inputText) { _, newValue in
            // spectrum state 切换是即时 UI 反馈,在 child 内本地处理(纯 VM 写,无外部副作用)。
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

            // 草稿持久化:parent 做 debounce + 空白同步清(防 send 完成后 OOM 还原)+
            // scenePhase=background 强 flush。子 view 不持 task / 不读 defaults。
            onInputTextChanged(newValue)
        }
    }

    private var draftDateDisplayLabel: String {
        guard let date = draftEntryDate else {
            return NSLocalizedString("今天", comment: "Today")
        }
        if Calendar.current.isDateInToday(date) {
            return NSLocalizedString("今天", comment: "Today")
        }
        if Calendar.current.isDateInYesterday(date) {
            return NSLocalizedString("昨天", comment: "Yesterday")
        }
        return LumoryDateFormatters.monthDay(language: appLanguage).string(from: date)
    }

    private var draftDateAccessibilityLabel: String {
        String(
            format: NSLocalizedString("日记日期:%@", comment: "Composer selected entry date accessibility label"),
            draftDateDisplayLabel
        )
    }

    private func openDraftDatePicker() {
        #if canImport(UIKit)
        HapticManager.shared.softNavigate()
        #endif
        draftDateBeforePicker = draftEntryDate
        refocusInputAfterDatePicker = isInputFocused
        isInputFocused = false
        draftDatePickerPresented = true
    }

    private func handleDraftDatePickerDismiss() {
        let didChangeDate = draftDateBeforePicker != draftEntryDate
        draftDateBeforePicker = nil
        if didChangeDate {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                #if canImport(UIKit)
                HapticManager.shared.complete()
                #endif
                LumoryToastCenter.shared.show(
                    String(
                        format: NSLocalizedString("日记日期已设为 %@", comment: "Composer date changed toast"),
                        draftDateDisplayLabel
                    ),
                    severity: .info
                )
            }
        }
        restoreInputFocusIfNeeded()
    }

    private func restoreInputFocusIfNeeded() {
        guard refocusInputAfterDatePicker else { return }
        refocusInputAfterDatePicker = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            isInputFocused = true
        }
    }

    private var draftDateBinding: Binding<Date> {
        Binding(
            get: { draftEntryDate ?? Date() },
            set: { newValue in
                let calendar = Calendar.current
                let today = calendar.startOfDay(for: Date())
                let selectedDay = calendar.startOfDay(for: newValue)
                let day = min(selectedDay, today)
                draftEntryDate = Calendar.current.isDateInToday(day) ? nil : day
            }
        )
    }

    private var draftDatePicker: some View {
        NavigationStack {
            DatePicker(
                NSLocalizedString("日记日期", comment: "Composer date picker title"),
                selection: draftDateBinding,
                in: ...Date(),
                displayedComponents: [.date]
            )
            .datePickerStyle(.graphical)
            .padding()

            Text(
                String(
                    format: NSLocalizedString("会保存为 %@", comment: "Composer date confirmation"),
                    draftDateDisplayLabel
                )
            )
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.bottom, 8)

            .navigationTitle(NSLocalizedString("日记日期", comment: "Composer date picker title"))
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("今天", comment: "Today")) {
                        draftEntryDate = nil
                        draftDatePickerPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("完成", comment: "Done")) {
                        draftDatePickerPresented = false
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.height(460), .large])
        .presentationDragIndicator(.visible)
        .lumorySheetDecoration()
    }

    // MARK: - Recording row + error banners

    @ViewBuilder
    private var recordingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let rec = recordingVM.audioRecordings.first {
                    RecordingRow(
                        recording: rec,
                        controller: audioPlaybackController,
                        isTranscribing: recordingVM.isTranscribing,
                        isRecording: recorder.isRecording,
                        onPlay: { onPlayRecording(rec.fileName) },
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
        .alert(
            NSLocalizedString("删除录音？", comment: "Delete recording confirmation"),
            isPresented: $recordingVM.showingDeleteAlert
        ) {
            Button(NSLocalizedString("删除", comment: "Delete button"), role: .destructive) {
                if let target = recordingVM.deleteTarget {
                    #if canImport(UIKit)
                    HapticManager.shared.destructive()
                    #endif
                    onDeleteRecordingConfirmed(target)
                }
            }
            Button(NSLocalizedString("取消", comment: "Cancel button"), role: .cancel) {
                recordingVM.deleteTarget = nil
            }
        }
    }

    /// 音频播放失败 inline banner。playAudio 的 onPlayError 把文案塞 VM,这里渲染。点 X 清。
    /// §4.3 (2026-05-19) — 走共享 `InlineWarningBanner`,3 处 + AskPast incompleteBanner 全用同一组件。
    @ViewBuilder
    private func audioPlaybackErrorBanner(message: String) -> some View {
        InlineWarningBanner(
            message: message,
            onClose: { recordingVM.audioPlaybackError = nil }
        )
    }

    /// 图片压缩 / 加载失败 inline banner。9 张选 7 成功 → "2 张图片处理失败" 提醒。点 X 清。
    @ViewBuilder
    private var compressionFailureBanner: some View {
        InlineWarningBanner(
            message: String(
                format: NSLocalizedString("有 %d 张图片处理失败", comment: "Photo compression failure banner"),
                photoVM.compressionFailureCount
            ),
            onClose: { photoVM.compressionFailureCount = 0 }
        )
    }

    @ViewBuilder
    private func transcriptionErrorBanner(failure: TranscriptionFailure) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "waveform")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text(transcriptionErrorMessage(for: failure))
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            if failure.isRetryable {
                Button {
                    #if canImport(UIKit)
                    HapticManager.shared.impact(.light)
                    #endif
                    onRetryTranscription()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(NSLocalizedString("transcription.retry", comment: "Retry transcription button"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Color.orange.opacity(0.07),
            in: RoundedRectangle(cornerRadius: LumoryCornerRadius.inline, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LumoryCornerRadius.inline, style: .continuous)
                .stroke(Color.orange.opacity(0.14), lineWidth: 0.5)
        )
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

    // MARK: - Photos row

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
                                            photoVM.suppressNextPhotoSelectionReload = true
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

    private var photoCountLabel: String {
        if photoVM.selectedImageItems.count == 1 {
            return NSLocalizedString("1张照片", comment: "")
        }
        return String(format: NSLocalizedString("%d张照片", comment: ""), photoVM.selectedImageItems.count)
    }

    // MARK: - Keyboard actions bar

    @ViewBuilder
    private var keyboardActionsBar: some View {
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
                .font(LumoryFonts.composerToolbarIcon)
                .foregroundStyle(Color.primary.opacity(0.85))
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(photoVM.selectedImageItems.count >= 9)
        // 跟 mic disabled tap 教育对齐 — 9 张满槽时用户不知道为什么 photo 按钮灰着。
        // overlay tap 在 disabled 时仍接收事件,弹 toast 解释。
        .overlay {
            if photoVM.selectedImageItems.count >= 9 {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        LumoryToastCenter.shared.show(
                            NSLocalizedString("已选 9 张,要再加请先删一张", comment: "Photo slot full"),
                            severity: .info
                        )
                    }
            }
        }
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
            // F1 fix:取消上一轮压缩任务在 parent 内做。child 只把新值送出去。
            onPhotoSelectionChanged(newValue)
        }

        Button {
            onMicTap()
        } label: {
            // .buttonStyle(.plain) 不应用系统默认的 disabled dim,所以同色 mic 在 disabled 时
            // 视觉上跟 enabled 完全一样。显式 opacity 让"已有录音"或"上一条转写在飞"态可见。
            let isMicDisabled = (recordingVM.audioRecordings.count >= 1 && !recorder.isRecording)
                || (recordingVM.isTranscribing && !recorder.isRecording)
            Image(systemName: recorder.isRecording ? "stop.circle.fill" : "mic")
                .font(LumoryFonts.composerToolbarIcon)
                .foregroundStyle(recorder.isRecording ? .red : Color.primary.opacity(0.85))
                .opacity(isMicDisabled ? 0.4 : 1.0)
                .symbolEffect(.bounce, value: recorder.isRecording)
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 已有录音 或 上一条转写还在飞 → disable。HomeView.handleMicTap 顶部也有
        // `guard !recordingVM.isTranscribing` 守卫,这里只是让 UI 视觉/无障碍跟逻辑对齐,
        // 否则用户按了没反应感觉是 bug。
        .disabled((recordingVM.audioRecordings.count >= 1 && !recorder.isRecording)
            || (recordingVM.isTranscribing && !recorder.isRecording))
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
            } else if recordingVM.isTranscribing && !recorder.isRecording {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        LumoryToastCenter.shared.show(
                            NSLocalizedString("转写还在进行,稍后再录", comment: "Transcription in flight"),
                            severity: .info
                        )
                    }
            }
        }
        .accessibilityLabel(recorder.isRecording
            ? NSLocalizedString("停止录音", comment: "Stop recording")
            : NSLocalizedString("开始录音", comment: "Start recording"))
        // (2026-05-15 superreview-4 P2)VoiceOver 用户在 "disabled 但仍可 tap(显示 toast)"
        // 状态听到 "开始录音" 然后激活 → 没反应(toast 不会被朗读) → 以为按钮坏了。
        // hint 是 a11y 提示用户"为什么 disable",VoiceOver 紧跟 label 之后朗读。
        .accessibilityHint({
            if recordingVM.audioRecordings.count >= 1 && !recorder.isRecording {
                return NSLocalizedString("已有录音,删除当前录音才能重录", comment: "Recording slot occupied")
            } else if recordingVM.isTranscribing && !recorder.isRecording {
                return NSLocalizedString("转写还在进行,稍后再录", comment: "Transcription in flight")
            }
            return ""
        }())
        .accessibilityIdentifier("home.keyboard.mic")

        recordingTimerInline

        Spacer()

        // 原生 `.buttonStyle(.glassProminent)` + accent tint。Apple 文档说这是 most prominent
        // action 用的 Liquid Glass style。在 GlassEffectContainer 里 + 外层 liquidGlassCard 提供
        // surface 上下文。渲染成什么样交给 SwiftUI,不手绘装饰。
        Button {
            // 点下时给 soft submit 反馈,完成时仍由 parent 的 handleSendAction 发 success。
            #if canImport(UIKit)
            HapticManager.shared.submit()
            #endif
            onSend()
        } label: {
            if inputVM.sendButtonState == .sending {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.up")
                    .font(LumoryFonts.composerSendIcon)
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

    /// `!isSending` 是重发双点防护(`handleSendAction` 把 isSending flip 到 true 是在第一个
    /// `await MainActor.run` 里,Task 创建后至少一个调度点之后才落地;这窗口里再点一下 send button,
    /// `hasSendableContent` 仍 true 就会进第二次 send 拿旧 snapshot 并发写两条重复)。把 `isSending`
    /// 纳入 UI 级互斥 + parent 的 `handleSendAction` 开头再加一层 guard 兜底,双重保险。
    private var hasSendableContent: Bool {
        (!inputVM.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !recordingVM.audioRecordings.isEmpty
            || !photoVM.selectedImageItems.isEmpty)
            && !recordingVM.isTranscribing
            && !photoVM.isProcessingSelection
            && !inputVM.isSending
    }
}
