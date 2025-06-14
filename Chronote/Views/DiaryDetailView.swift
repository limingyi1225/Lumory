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
    @State private var showDeleteAlert = false
    @StateObject private var audioPlaybackController = AudioPlaybackController() // 新的控制器
    @State private var displayableAudioDuration: TimeInterval = 0.0 // State for fetched duration
    
    // 编辑模式相关状态
    @State private var isEditing = false
    @State private var editedSummary: String = ""
    @State private var editedText: String = ""
    @State private var editedMoodValue: Double = 0.5
    @State private var hasUnsavedChanges = false
    @State private var showDiscardChangesAlert = false
    @Environment(\.colorScheme) private var colorScheme
    
    // Animation states
    @State private var animateIn = false
    @State private var showContent = false
    @State private var expandedSections: Set<String> = ["内容", "摘要"]
    @State private var shareButtonPressed = false
    @State private var showImageViewer = false
    @State private var selectedImageIndex = 0
    
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
        Group {
            // Check if entry is still valid
            if entry.managedObjectContext == nil {
                // Entry has been deleted, just show a placeholder
                Text(NSLocalizedString("正在返回...", comment: "Returning message"))
                    .onAppear {
                        dismiss()
                    }
            } else {
                #if targetEnvironment(macCatalyst)
                // Mac-specific design
                macDetailView
                #else
                // iOS design
                ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 日期和心情
                    HStack {
                        // 心情圆点，编辑与展示通用映射
                        Circle()
                            .fill(isEditing ? Color.moodSpectrum(value: editedMoodValue) : entry.moodColor)
                            .frame(width: 12, height: 12)
                        Text(formatDate(entry.wrappedDate))
                            .font(.headline)
                        Spacer()
                        Text(formatTime(entry.wrappedDate))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    // Action buttons (only show in edit mode)
                    if isEditing {
                        HStack(spacing: 12) {
                            Button(action: {
                                if hasUnsavedChanges {
                                    showDiscardChangesAlert = true
                                } else {
                                    cancelEditing()
                                }
                            }) {
                                Text(NSLocalizedString("取消", comment: "Cancel button"))
                                    .font(.system(size: 15))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                    )
                            }
                            
                            Button(action: saveChanges) {
                                Text(NSLocalizedString("保存", comment: "Save button"))
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(Color.accentColor)
                                    )
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    
                    // 心情滑块（编辑模式）
                    if isEditing {
                        MoodSpectrumSlider(moodValue: $editedMoodValue, showKnob: true)
                            .frame(height: 12)
                            .padding(.vertical)
                    }
                    
                    // 摘要部分
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(NSLocalizedString("摘要", comment: "Summary label"))
                                .font(.title3)
                                .fontWeight(.semibold)
                            if !isEditing && (entry.wrappedSummary ?? "").isEmpty {
                                Text(NSLocalizedString("(未设置)", comment: "Not set label"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        if isEditing {
                            TextField(NSLocalizedString("添加摘要...", comment: "Add summary placeholder"), text: $editedSummary)
                                .textFieldStyle(PlainTextFieldStyle())
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(systemGray6Color)
                                )
                                .onChange(of: editedSummary) { _, _ in
                                    hasUnsavedChanges = true
                                }
                        } else if let summary = entry.wrappedSummary, !summary.isEmpty {
                            Text(summary)
                                .font(.body)
                        }
                    }
                    
                    // 日记内容部分
                    VStack(alignment: .leading, spacing: 8) {
                        Text(NSLocalizedString("我的记录", comment: "My entry label"))
                            .font(.title3)
                            .fontWeight(.semibold)
                        
                        if isEditing {
                            TextEditor(text: $editedText)
                                .frame(minHeight: 200)
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(systemGray6Color)
                                )
                                .scrollContentBackground(.hidden)
                                .onChange(of: editedText) { _, _ in
                                    hasUnsavedChanges = true
                                }
                        } else {
                            Text(entry.wrappedText)
                                .font(.body)
                        }
                    }
                    
                    // 图片显示部分
                    if !entry.imageFileNameArray.isEmpty {
                        Divider().padding(.vertical, 8)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text(NSLocalizedString("照片", comment: "Photos label"))
                                .font(.title3)
                                .fontWeight(.semibold)
                            
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(Array(entry.imageFileNameArray.enumerated()), id: \.offset) { index, fileName in
                                        if let imageData = entry.loadImageData(fileName: fileName) {
                                            Group {
                                                #if os(iOS)
                                                if let uiImage = UIImage(data: imageData) {
                                                    Image(uiImage: uiImage)
                                                        .resizable()
                                                        .scaledToFill()
                                                        .frame(width: 120, height: 120)
                                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                                        .onTapGesture {
                                                            selectedImageIndex = index
                                                            showImageViewer = true
                                                        }
                                                }
                                                #else
                                                if let nsImage = NSImage(data: imageData) {
                                                    Image(nsImage: nsImage)
                                                        .resizable()
                                                        .scaledToFill()
                                                        .frame(width: 120, height: 120)
                                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                                        .onTapGesture {
                                                            selectedImageIndex = index
                                                            showImageViewer = true
                                                        }
                                                }
                                                #endif
                                            }
                                        } else {
                                            // Debug placeholder for missing images
                                            RoundedRectangle(cornerRadius: 10)
                                                .fill(Color.gray.opacity(0.3))
                                                .frame(width: 120, height: 120)
                                                .overlay(
                                                    Text("图片加载失败")
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                )
                                        }
                                    }
                                }
                                .padding(.horizontal, 4)
                            }
                            .frame(height: 128)
                        }
                        .onAppear {
                            print("[DiaryDetailView] Image file names: \(entry.imageFileNameArray)")
                            print("[DiaryDetailView] Image count: \(entry.imageFileNameArray.count)")
                        }
                    }
                    
                    // 音频播放器部分 - 类似于 RecordingRow
                    if let audioFileName = entry.audioFileName, let audioURL = entry.audioURL() {
                        Divider().padding(.vertical, 8)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text(NSLocalizedString("录音", comment: "Recording label"))
                                .font(.title3)
                                .fontWeight(.semibold)

                            HStack(spacing: 8) {
                                Image(systemName: "waveform")
                                    .foregroundColor(.blue)
                                
                                Text(formattedDuration(
                                    currentTime: audioPlaybackController.currentPlayingFileName == audioFileName ? audioPlaybackController.currentTime : 0,
                                    totalDuration: (audioPlaybackController.currentPlayingFileName == audioFileName && audioPlaybackController.duration > 0) ? audioPlaybackController.duration : displayableAudioDuration
                                ))
                                    .font(.caption)
                                    .monospacedDigit()
                                
                                Spacer()
                                
                                Button(action: {
                                    playOrPauseAudio(url: audioURL, fileName: audioFileName)
                                }) {
                                    Image(systemName: audioPlaybackController.isPlaying && audioPlaybackController.currentPlayingFileName == audioFileName ? "pause.circle.fill" : "play.circle.fill")
                                        .font(.system(size: 28)) // Slightly larger for easier tapping
                                        .foregroundColor(.accentColor)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(systemGray6Color)
                                    if audioPlaybackController.currentPlayingFileName == audioFileName && displayableAudioDuration > 0 { // Use displayableAudioDuration for condition
                                        GeometryReader { geo in
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(Color.blue.opacity(0.3))
                                                .frame(width: geo.size.width * audioPlaybackController.progress)
                                        }
                                    }
                                }
                            )
                            // Task to fetch duration when audioFileName changes or view appears
                            .task(id: audioFileName) {
                                displayableAudioDuration = await fetchAudioDuration(url: audioURL) ?? 0.0
                            }
                        }
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
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
                    
                    // Delete associated images
                    entry.deleteAllImages()
                    
                    // Delete the entry
                    viewContext.delete(entry)
                    
                    // Save and dismiss immediately
                    do {
                        try viewContext.save()
                        #if canImport(UIKit)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        #endif
                    } catch {
                        print("[DiaryDetailView] 删除日记失败: \(error)")
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
            .onDisappear {
                // 当视图消失时停止播放，避免音频在后台继续
                audioPlaybackController.stopPlayback(clearCurrentFile: true)
            }
            .navigationBarBackButtonHidden(isEditing)
            .interactiveDismissDisabled(isEditing && hasUnsavedChanges)
            #if os(iOS)
            .fullScreenCover(isPresented: $showImageViewer) {
                let images = entry.loadAllImageData()
                if !images.isEmpty {
                    ImageViewerView(
                        images: images,
                        selectedIndex: $selectedImageIndex,
                        isPresented: $showImageViewer
                    )
                }
            }
            #else
            .sheet(isPresented: $showImageViewer) {
                let images = entry.loadAllImageData()
                if !images.isEmpty {
                    ImageViewerView(
                        images: images,
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
            #endif
            }
        }
    }
    
    #if targetEnvironment(macCatalyst)
    @ViewBuilder
    private var macDetailView: some View {
        if showUnifiedToolbar {
            VStack(spacing: 0) {
                // Unified toolbar
                HStack(spacing: 20) {
                    // Left side - Back button and title
                    HStack(spacing: 12) {
                        Button(action: { 
                            // Post notification to clear selection
                            NotificationCenter.default.post(name: .diaryEntryDeleted, object: entry.id)
                        }) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        
                        Text("日记详情")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.primary)
                    }
                    
                    Spacer()
                    
                    // Right side - Action buttons
                    HStack(spacing: 12) {
                        if !isEditing {
                            Button(action: startEditing) {
                                HStack(spacing: 6) {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 14))
                                    Text("编辑")
                                        .font(.system(size: 14, weight: .medium))
                                }
                                .foregroundColor(.accentColor)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(Color.accentColor.opacity(0.1))
                                )
                            }
                            .buttonStyle(.plain)
                            
                            Button(action: { showDeleteAlert = true }) {
                                Image(systemName: "trash")
                                    .font(.system(size: 16))
                                    .foregroundColor(.red)
                                    .frame(width: 32, height: 32)
                                    .background(
                                        Circle()
                                            .fill(Color.red.opacity(0.1))
                                    )
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button(action: {
                                if hasUnsavedChanges {
                                    showDiscardChangesAlert = true
                                } else {
                                    cancelEditing()
                                }
                            }) {
                                Text("取消")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule()
                                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            
                            Button(action: saveChanges) {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 14))
                                    Text("保存")
                                        .font(.system(size: 14, weight: .medium))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(Color.accentColor)
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(!hasUnsavedChanges)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(
                    ZStack {
                        Color(UIColor.systemBackground)
                        // Subtle gradient overlay
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color(UIColor.systemBackground),
                                Color(UIColor.systemBackground).opacity(0.95)
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                )
                
                Divider()
                
                // Content area
                ZStack {
                    // Beautiful gradient background
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color(UIColor.systemBackground),
                            Color(UIColor.systemBackground).opacity(0.98),
                            entry.moodColor.opacity(0.05)
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .ignoresSafeArea()
                    
                    ScrollView {
                        VStack(spacing: 32) {
                            // Header section with mood visualization
                            headerSection
                                .opacity(showContent ? 1 : 0)
                                .offset(y: showContent ? 0 : 20)
                            
                            // Main content sections
                            VStack(spacing: 24) {
                                if let summary = entry.wrappedSummary, !summary.isEmpty || isEditing {
                                    summarySection
                                }
                                
                                contentSection
                                
                                if !entry.imageFileNameArray.isEmpty {
                                    imageSection
                                }
                                
                                if let audioFileName = entry.audioFileName, let audioURL = entry.audioURL() {
                                    audioSection(audioFileName: audioFileName, audioURL: audioURL)
                                }
                            }
                            .opacity(showContent ? 1 : 0)
                            .offset(y: showContent ? 0 : 30)
                        }
                        .padding(40)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .navigationTitle("")
            .navigationBarHidden(true)
            .onAppear {
                // Animate in
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                    animateIn = true
                }
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.2)) {
                    showContent = true
                }
            }
            .alert(NSLocalizedString("确认删除此日记？", comment: "Delete diary confirmation"), isPresented: $showDeleteAlert) {
                Button(NSLocalizedString("删除", comment: "Delete button"), role: .destructive) {
                    audioPlaybackController.stopPlayback(clearCurrentFile: true)
                    
                    // Delete associated images
                    entry.deleteAllImages()
                    
                    viewContext.delete(entry)
                    
                    do {
                        try viewContext.save()
                        #if canImport(UIKit)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        #endif
                        
                        // For Mac, post notification to clear selection
                        #if targetEnvironment(macCatalyst)
                        NotificationCenter.default.post(name: .diaryEntryDeleted, object: entry.id)
                        #endif
                    } catch {
                        print("[DiaryDetailView] 删除日记失败: \(error)")
                    }
                    
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
            .fullScreenCover(isPresented: $showImageViewer) {
                let images = entry.loadAllImageData()
                if !images.isEmpty {
                    ImageViewerView(
                        images: images,
                        selectedIndex: $selectedImageIndex,
                        isPresented: $showImageViewer
                    )
                }
            }
        } else {
            // Original macDetailView code without unified toolbar
            ZStack {
                // Beautiful gradient background
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(UIColor.systemBackground),
                        Color(UIColor.systemBackground).opacity(0.98),
                        entry.moodColor.opacity(0.05)
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 32) {
                        // Edit button for Mac
                        HStack {
                            Spacer()
                            
                            if !isEditing {
                                HStack(spacing: 12) {
                                    Button(action: startEditing) {
                                        Label("编辑", systemImage: "pencil")
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundColor(.accentColor)
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 8)
                                            .background(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .fill(Color(UIColor.secondarySystemBackground))
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    
                                    Button(action: { showDeleteAlert = true }) {
                                        Label("删除", systemImage: "trash")
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundColor(.red)
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 8)
                                            .contentShape(Rectangle())
                                            .background(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .stroke(Color.red.opacity(0.3), lineWidth: 1)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            } else {
                                HStack(spacing: 12) {
                                    Button(action: {
                                        if hasUnsavedChanges {
                                            showDiscardChangesAlert = true
                                        } else {
                                            cancelEditing()
                                        }
                                    }) {
                                        Text("取消")
                                            .font(.system(size: 15))
                                            .foregroundColor(.secondary)
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 8)
                                            .background(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    
                                    Button(action: saveChanges) {
                                        Text("保存")
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 8)
                                            .background(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .fill(Color.accentColor)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal, 40)
                        
                        // Header section with mood visualization
                        headerSection
                            .opacity(showContent ? 1 : 0)
                            .offset(y: showContent ? 0 : 20)
                        
                        // Main content sections
                        VStack(spacing: 24) {
                            if let summary = entry.wrappedSummary, !summary.isEmpty || isEditing {
                                summarySection
                            }
                            
                            contentSection
                            
                            if !entry.imageFileNameArray.isEmpty {
                                imageSection
                            }
                            
                            if let audioFileName = entry.audioFileName, let audioURL = entry.audioURL() {
                                audioSection(audioFileName: audioFileName, audioURL: audioURL)
                            }
                        }
                        .opacity(showContent ? 1 : 0)
                        .offset(y: showContent ? 0 : 30)
                    }
                    .padding(40)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle("")
            .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 16) {
                    if isEditing {
                        Button(action: {
                            if hasUnsavedChanges {
                                showDiscardChangesAlert = true
                            } else {
                                cancelEditing()
                            }
                        }) {
                            Text("取消")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 16) {
                    if !isEditing {
                        // Share button
                        Button(action: {
                            shareButtonPressed = true
                            // Implement share functionality
                        }) {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundColor(.secondary)
                                .scaleEffect(shareButtonPressed ? 0.8 : 1)
                        }
                        .buttonStyle(.plain)
                        .animation(.spring(response: 0.3), value: shareButtonPressed)
                        
                        // Edit button
                        Button(action: startEditing) {
                            Label("编辑", systemImage: "pencil")
                                .font(.system(size: 15))
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                    } else {
                        // Save button
                        Button(action: saveChanges) {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                Text("保存")
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(hasUnsavedChanges ? Color.accentColor : Color.gray.opacity(0.3))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    
                    // Delete button
                    Button(role: .destructive, action: { showDeleteAlert = true }) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onAppear {
            // Animate in
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                animateIn = true
            }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.2)) {
                showContent = true
            }
        }
        .alert(NSLocalizedString("确认删除此日记？", comment: "Delete diary confirmation"), isPresented: $showDeleteAlert) {
            Button(NSLocalizedString("删除", comment: "Delete button"), role: .destructive) {
                audioPlaybackController.stopPlayback(clearCurrentFile: true)
                
                // Delete associated images
                entry.deleteAllImages()
                
                viewContext.delete(entry)
                
                do {
                    try viewContext.save()
                    #if canImport(UIKit)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    #endif
                    
                    // For Mac, post notification to clear selection
                    #if targetEnvironment(macCatalyst)
                    NotificationCenter.default.post(name: .diaryEntryDeleted, object: entry.id)
                    #endif
                } catch {
                    print("[DiaryDetailView] 删除日记失败: \(error)")
                }
                
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
        .fullScreenCover(isPresented: $showImageViewer) {
            let images = entry.loadAllImageData()
            if !images.isEmpty {
                ImageViewerView(
                    images: images,
                    selectedIndex: $selectedImageIndex,
                    isPresented: $showImageViewer
                )
            }
        }
    }
    }
    #endif
    
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
                                        .foregroundColor(editedMoodValue == mood.value ? .white : .primary)
                                }
                                .frame(width: 80, height: 80)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(editedMoodValue == mood.value ? Color.moodSpectrum(value: mood.value) : Color(UIColor.tertiarySystemBackground))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(editedMoodValue == mood.value ? Color.clear : Color.primary.opacity(0.1), lineWidth: 1)
                                )
                                .scaleEffect(editedMoodValue == mood.value ? 1.05 : 1.0)
                                .shadow(color: editedMoodValue == mood.value ? Color.moodSpectrum(value: mood.value).opacity(0.3) : Color.clear, radius: 8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(UIColor.secondarySystemBackground))
                        .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 5)
                )
                .transition(.asymmetric(insertion: .scale.combined(with: .opacity), removal: .scale.combined(with: .opacity)))
            }
        }
    }
    
    @ViewBuilder
    private var summarySection: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expandedSections.contains("摘要") },
            set: { isExpanded in
                if isExpanded {
                    expandedSections.insert("摘要")
                } else {
                    expandedSections.remove("摘要")
                }
            }
        )) {
            if isEditing {
                TextField(NSLocalizedString("添加摘要...", comment: "Add summary placeholder"), text: $editedSummary)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 16))
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(UIColor.tertiarySystemBackground))
                    )
                    .onChange(of: editedSummary) { _, _ in
                        hasUnsavedChanges = true
                    }
            } else if let summary = entry.wrappedSummary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 16))
                    .lineSpacing(4)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } label: {
            HStack {
                Label("摘要", systemImage: "text.quote")
                    .font(.title3)
                    .fontWeight(.semibold)
                
                if !isEditing && (entry.wrappedSummary ?? "").isEmpty {
                    Text("(未设置)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
        }
        .tint(.primary)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.secondarySystemBackground))
                .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 5)
        )
    }
    
    @ViewBuilder
    private var contentSection: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expandedSections.contains("内容") },
            set: { isExpanded in
                if isExpanded {
                    expandedSections.insert("内容")
                } else {
                    expandedSections.remove("内容")
                }
            }
        )) {
            if isEditing {
                TextEditor(text: $editedText)
                    .font(.system(size: 16))
                    .lineSpacing(4)
                    .frame(minHeight: 300)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(UIColor.tertiarySystemBackground))
                    )
                    .scrollContentBackground(.hidden)
                    .onChange(of: editedText) { _, _ in
                        hasUnsavedChanges = true
                    }
            } else {
                Text(entry.wrappedText)
                    .font(.system(size: 16))
                    .lineSpacing(6)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } label: {
            HStack {
                Label("我的记录", systemImage: "doc.text")
                    .font(.title3)
                    .fontWeight(.semibold)
                
                Spacer()
            }
        }
        .tint(.primary)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.secondarySystemBackground))
                .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 5)
        )
    }
    
    @ViewBuilder
    private var imageSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("照片", systemImage: "photo.stack")
                    .font(.title3)
                    .fontWeight(.semibold)
                
                Spacer()
            }
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(entry.imageFileNameArray, id: \.self) { fileName in
                        if let imageData = entry.loadImageData(fileName: fileName),
                           let uiImage = UIImage(data: imageData) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 150, height: 150)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .shadow(color: Color.black.opacity(0.1), radius: 5, x: 0, y: 2)
                                .onTapGesture {
                                    let images = entry.loadAllImageData()
                                    if !images.isEmpty {
                                        selectedImageIndex = entry.imageFileNameArray.firstIndex(of: fileName) ?? 0
                                        showImageViewer = true
                                    }
                                }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            .frame(height: 158)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.secondarySystemBackground))
                .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 5)
        )
    }
    
    @ViewBuilder
    private func audioSection(audioFileName: String, audioURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("录音", systemImage: "waveform")
                    .font(.title3)
                    .fontWeight(.semibold)
                
                Spacer()
            }
            
            HStack(spacing: 16) {
                // Play/Pause button
                Button(action: {
                    playOrPauseAudio(url: audioURL, fileName: audioFileName)
                }) {
                    Image(systemName: audioPlaybackController.isPlaying && audioPlaybackController.currentPlayingFileName == audioFileName ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.accentColor)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(PlainButtonStyle())
                
                // Progress view
                VStack(alignment: .leading, spacing: 8) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            // Background track
                            Capsule()
                                .fill(Color.secondary.opacity(0.2))
                                .frame(height: 6)
                            
                            // Progress
                            if audioPlaybackController.currentPlayingFileName == audioFileName && displayableAudioDuration > 0 {
                                Capsule()
                                    .fill(Color.accentColor)
                                    .frame(width: geo.size.width * audioPlaybackController.progress, height: 6)
                            }
                        }
                    }
                    .frame(height: 6)
                    
                    // Time labels
                    HStack {
                        Text(formattedDuration(
                            currentTime: audioPlaybackController.currentPlayingFileName == audioFileName ? audioPlaybackController.currentTime : 0,
                            totalDuration: (audioPlaybackController.currentPlayingFileName == audioFileName && audioPlaybackController.duration > 0) ? audioPlaybackController.duration : displayableAudioDuration
                        ))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                        
                        Spacer()
                    }
                }
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(UIColor.tertiarySystemBackground))
            )
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.secondarySystemBackground))
                .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 5)
        )
        .task(id: audioFileName) {
            displayableAudioDuration = await fetchAudioDuration(url: audioURL) ?? 0.0
        }
    }

    // MARK: - 编辑相关方法
    
    private func startEditing() {
        print("[DiaryDetailView] Starting edit mode")
        editedSummary = entry.wrappedSummary ?? ""
        editedText = entry.wrappedText
        editedMoodValue = entry.moodValue
        hasUnsavedChanges = false
        
        withAnimation(AnimationConfig.gentleSpring) {
            isEditing = true
        }
        
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
    
    private func cancelEditing() {
        withAnimation(AnimationConfig.gentleSpring) {
            isEditing = false
        }
        hasUnsavedChanges = false
        
        // 隐藏键盘
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
    
    private var moodOptions: [(emoji: String, label: String, value: Double)] {
        [
            ("😢", "非常低落", 0.1),
            ("😞", "有些低落", 0.3),
            ("😐", "平静", 0.5),
            ("😊", "愉快", 0.7),
            ("😄", "非常开心", 0.9)
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
        // 更新 Core Data
        entry.summary = editedSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.text = editedText
        entry.moodValue = editedMoodValue
        
        do {
            try viewContext.save()
            
            withAnimation(AnimationConfig.gentleSpring) {
                isEditing = false
            }
            hasUnsavedChanges = false
            
            #if canImport(UIKit)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            #endif
            
            // 隐藏键盘
            #if canImport(UIKit)
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            #endif
        } catch {
            print("[DiaryDetailView] 保存更改失败: \(error)")
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
            print("[DiaryDetailView] Playback finished. Controller isPlaying: \(audioPlaybackController?.isPlaying ?? false)")
        }
        audioPlaybackController.onPlayError = { [weak audioPlaybackController] error in // Added weak capture for consistency if needed
            let fileName = audioPlaybackController?.currentPlayingFileName ?? "N/A"
            print("[DiaryDetailView] Audio playback error: \(error.localizedDescription). Controller file: \(fileName)")
            // 可以在这里向用户显示错误信息
        }
    }
}

// Removed #Preview block to avoid macro compilation issues. 