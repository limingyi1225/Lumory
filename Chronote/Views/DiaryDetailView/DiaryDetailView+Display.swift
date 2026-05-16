//
//  DiaryDetailView+Display.swift
//  Lumory
//
//  DiaryDetailView 的渲染层 —— hero / mood editor / summary / 正文 / 录音 / 照片 / 主题 chip
//  + 详情页背景渐变。从主文件抽出来,主文件只剩 state + body + toolbar + alerts/sheets wiring。
//
//  **iOS 26 极简三段式** body 结构:
//    1. 顶部 hero — 日期 + 心情圆点(`heroHeader`)
//    2. 主体 — 摘要 / 正文 / 录音 / 照片(`summaryBlock` / `entryBodyBlock` / `audioBlock` / `photosBlock`)
//    3. 底部 footer — AI 主题 chip(`themesSection`)
//  录音排在照片前:语音日记是正文思绪延伸,照片是独立视觉记忆。
//
//  本扩展的所有 view builder + display-only helpers 都标 `private` —— 它们只在
//  view body 渲染链路内被同文件其他 view builder 互相调用,无跨文件 caller。
//

import SwiftUI

extension DiaryDetailView {

    // MARK: - Themes (footer)

    /// 主题来自 AI 自动抽取(写入/编辑后台流水线里 extractThemes),
    /// 用户手动编辑主题容易污染聚合结果 —— 只做只读展示,非空才渲染。
    /// 主题 chip 用**当天 mood 颜色**,跟页面顶部 mood 圆点 + 摘要竖条同一色系。
    ///
    /// **iOS 26 redesign**:去掉 "主题" + sparkles header,chip 直接展示在页面底部
    /// 作为 footer 元数据。理由:themes 主要价值在 Insights 聚合,单条日记里它是
    /// "AI 给这条日记打的标签",不需要标题引导;chip 视觉本身 self-explanatory。
    /// a11y label 加在第一个 chip 上,告诉 VoiceOver 用户这是 AI 提取的标签组。
    @ViewBuilder
    var themesSection: some View {
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

    var detailBackground: some View {
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
    var heroHeader: some View {
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
    var moodEditorBlock: some View {
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
    var summaryBlock: some View {
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
    var entryBodyBlock: some View {
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
    var photosBlock: some View {
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
    func audioBlock(audioFileName: String, audioURL: URL) -> some View {
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

    // MARK: - Helpers used by Display only

    /// 日期 / 时间走 `LumoryDateFormatters` 共享 language-aware cache,避免每次 body eval new
    /// formatter(播放进度 30fps 驱动 body 时主线程会被 ICU 加载拉满)。
    func formatDate(_ date: Date) -> String {
        LumoryDateFormatters.longDate(language: appLanguage).string(from: date)
    }

    func formatTime(_ date: Date) -> String {
        LumoryDateFormatters.timeShortLocalized(language: appLanguage).string(from: date)
    }

    /// 点缩略图 → 异步加载图片 blob → 弹 viewer。从 photoThumbnail 回调过来,
    /// 主文件 body 里 fullScreenCover/sheet 用 `viewerImages` + `selectedImageIndex` 渲染。
    func presentImageViewer(at index: Int) {
        Task { @MainActor in
            let loaded = await entry.loadAllImageDataAsync()
            guard !loaded.isEmpty else { return }
            viewerImages = loaded
            // **index 安全钳位**:`index` 是缩略图 grid(基于 `imageFileNameArray`)的索引,
            // `loaded` 是异步加载的 blob / fallback 结果,两者 count 不保证相等:
            //   - blob 缺失 / CloudKit 未同步完 → fallback 过滤掉 nil → 比 grid 短
            //   - blob 存在但 encode 时索引已做顺序保持(bug_006 修复后)→ 等长
            // 钳位避免 grid 上点最后一张但 loaded 不够长时,TabView 抓不到 tag 显示空白 + "5 / 3" 这种乱数。
            selectedImageIndex = min(max(index, 0), loaded.count - 1)
            showImageViewer = true
        }
    }
}
