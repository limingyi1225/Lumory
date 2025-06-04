import SwiftUI
import AVFoundation // Re-add AVFoundation for AVURLAsset
import CoreData
// AVFoundation will be implicitly imported via AudioPlaybackController if needed,
// but it's good practice to keep it if direct AVAudioSession manipulation happens.
// For now, let's assume AudioPlaybackController handles session.
// import AVFoundation 

struct DiaryDetailView: View {
    @ObservedObject var entry: DiaryEntry
    var startInEditMode: Bool = false
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
        // Check if entry is still valid
        if entry.managedObjectContext == nil {
            // Entry has been deleted, just show a placeholder
            Text(NSLocalizedString("正在返回...", comment: "Returning message"))
                .onAppear {
                    dismiss()
                }
        } else {
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
                                        .fill(Color(.systemGray6))
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
                                        .fill(Color(.systemGray6))
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
                                        .fill(Color(.systemGray6))
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
            .navigationBarTitleDisplayMode(.inline) // More compact title
            .toolbar {
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
            }
            .alert(NSLocalizedString("确认删除此日记？", comment: "Delete diary confirmation"), isPresented: $showDeleteAlert) {
                Button(NSLocalizedString("删除", comment: "Delete button"), role: .destructive) {
                    // Stop audio and perform deletion
                    audioPlaybackController.stopPlayback(clearCurrentFile: true)
                    
                    // Delete the entry
                    viewContext.delete(entry)
                    
                    // Save and dismiss immediately
                    do {
                        try viewContext.save()
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
            .onAppear {
                // 如果需要直接进入编辑模式
                if startInEditMode && !isEditing {
                    startEditing()
                }
            }
        }
    }

    // MARK: - 编辑相关方法
    
    private func startEditing() {
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