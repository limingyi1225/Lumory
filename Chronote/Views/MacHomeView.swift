//
//  MacHomeView.swift
//  Lumory
//
//  Created by Assistant on 6/3/25.
//

import SwiftUI
import CoreData
import PhotosUI
#if targetEnvironment(macCatalyst)
import UIKit
#endif

#if targetEnvironment(macCatalyst)
struct MacHomeView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @State private var content = ""
    @State private var moodValue = 0.5
    @State private var isRecording = false
    @State private var isPaused = false
    @StateObject private var audioRecorder = AudioRecorder()
    private let speechRecognizer = AppleSpeechRecognizer()
    @FocusState private var isContentFocused: Bool
    @State private var hasMoodAnalysis = false
    @State private var isAnalyzing = false
    @State private var summary = ""
    @State private var analyzeTask: Task<Void, Never>? = nil
    private let aiService = AppleRecognitionService(openAIApiKey: AppSecrets.openAIKey)
    @State private var currentAudioFileName: String? = nil
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var selectedImages: [Data] = []
    @State private var date = Date()
    @State private var showDatePicker = false
    @State private var animateIn = false
    @State private var isSaving = false
    @State private var showKeyboardShortcutHint = true
    @State private var isPressingShortcut = false
    @State private var isShowingSettings = false
    @AppStorage("appLanguage") private var appLanguage: String = "en"
    
    private var inspirationalPrompts: [String] {
        [
            NSLocalizedString("今天有什么特别的事情发生吗？", comment: ""),
            NSLocalizedString("此刻你的心情是怎样的？", comment: ""),
            NSLocalizedString("有什么想要记录的瞬间吗？", comment: ""),
            NSLocalizedString("今天最让你开心的是什么？", comment: ""),
            NSLocalizedString("现在最想和谁分享你的感受？", comment: "")
        ]
    }
    
    @State private var currentPrompt = ""
    
    private var saveButtonContent: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
            Text(NSLocalizedString("保存日记", comment: ""))
                .font(.system(size: 15, weight: .medium))
        }
        .foregroundColor(content.isEmpty ? .secondary : .white)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(content.isEmpty ? Color(UIColor.tertiarySystemBackground) : Color.accentColor)
                .scaleEffect(isPressingShortcut ? 0.95 : 1.0)
        )
        .scaleEffect(isPressingShortcut ? 0.98 : 1.0)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Main content
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    // Left side - Content editor
                    VStack(spacing: 20) {
                        // Date selector
                        HStack {
                            Button(action: { showDatePicker.toggle() }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "calendar")
                                        .font(.system(size: 16))
                                    Text(formatDetailedDate(date))
                                        .font(.system(size: 15, weight: .medium))
                                }
                                .foregroundColor(.primary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(UIColor.secondarySystemBackground))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showDatePicker) {
                                DatePicker("", selection: $date, displayedComponents: [.date, .hourAndMinute])
                                    .datePickerStyle(.graphical)
                                    .frame(width: 320)
                                    .padding()
                            }
                            
                            Spacer()
                            Button(action: saveEntry) {
                                saveButtonContent
                            }
                            .buttonStyle(.plain)
                            .disabled(content.isEmpty || isSaving)
                            .keyboardShortcut(.return, modifiers: .command)
                            .help("保存日记 (⌘↩)")
                            .animation(.easeInOut(duration: 0.2), value: isPressingShortcut)
                        }
                        
                        // Content editor
                        ZStack(alignment: .topLeading) {
                            if content.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(currentPrompt)
                                        .font(.system(size: 18, weight: .light))
                                        .foregroundColor(.secondary.opacity(0.6))
                                        .italic()
                                    
                                    if showKeyboardShortcutHint {
                                        HStack(spacing: 4) {
                                            Image(systemName: "keyboard")
                                                .font(.system(size: 12))
                                            Text("⌘↩ \(NSLocalizedString("保存日记", comment: ""))")
                                                .font(.system(size: 12))
                                        }
                                        .foregroundColor(.secondary.opacity(0.3))
                                        .padding(.top, 8)
                                        .transition(.opacity.combined(with: .scale))
                                    }
                                }
                                .padding(.top, 16)
                                .padding(.horizontal, 4)
                            }
                            
                            TextEditor(text: $content)
                                .font(.system(size: 17))
                                .lineSpacing(6)
                                .focused($isContentFocused)
                                .scrollContentBackground(.hidden)
                                .padding(.vertical, 8)
                                .onSubmit {
                                    // This will be called when pressing Enter without modifiers
                                    // We don't want to save in this case, just let the TextEditor handle it
                                }
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(UIColor.secondarySystemBackground))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(
                                            isContentFocused ? 
                                            Color.moodSpectrum(value: moodValue).opacity(0.5) : 
                                            Color.primary.opacity(0.1),
                                            lineWidth: isContentFocused ? 2 : 1
                                        )
                                )
                        )
                        .animation(.easeInOut(duration: 0.2), value: isContentFocused)
                        
                        // Action buttons
                        HStack(spacing: 12) {
                            // Recording button
                            Button(action: handleRecordingAction) {
                                HStack(spacing: 8) {
                                    Image(systemName: recordingIcon)
                                        .font(.system(size: 16))
                                        .symbolRenderingMode(.hierarchical)
                                    
                                    Text(recordingText)
                                        .font(.system(size: 14, weight: .medium))
                                    
                                    if isRecording && !isPaused {
                                        Circle()
                                            .fill(Color.red)
                                            .frame(width: 6, height: 6)
                                            .overlay(
                                                Circle()
                                                    .fill(Color.red)
                                                    .frame(width: 6, height: 6)
                                                    .scaleEffect(1.5)
                                                    .opacity(0)
                                                    .animation(
                                                        isRecording ? AnimationConfig.breathingAnimation : nil,
                                                        value: isRecording
                                                    )
                                            )
                                    }
                                }
                                .foregroundColor(isRecording ? .white : .primary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(isRecording ? Color.red : Color(UIColor.secondarySystemBackground))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            
                            // Pause button when recording
                            if isRecording {
                                Button(action: togglePause) {
                                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                                        .font(.system(size: 16))
                                        .foregroundColor(.primary)
                                        .frame(width: 36, height: 36)
                                        .contentShape(Circle())
                                        .background(
                                            Circle()
                                                .fill(Color(UIColor.secondarySystemBackground))
                                        )
                                        .overlay(
                                            Circle()
                                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                                .transition(.scale.combined(with: .opacity))
                            }
                            
                            Spacer()
                            
                            // Clear button
                            Button(action: { 
                                content = ""
                                selectedImages = []
                                selectedPhotos = []
                                hasMoodAnalysis = false
                                moodValue = 0.5
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "xmark.circle")
                                        .font(.system(size: 16))
                                    Text(NSLocalizedString("清空", comment: ""))
                                        .font(.system(size: 14))
                                }
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(UIColor.tertiarySystemBackground))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(content.isEmpty && selectedImages.isEmpty)
                        }
                        .animation(AnimationConfig.gentleSpring, value: isRecording)
                    }
                    .padding(24)
                    .frame(width: geometry.size.width * 0.6)
                    
                    Divider()
                    
                    // Right side - Mood and Media
                    VStack(spacing: 24) {
                        moodSection
                        photoSection
                        Spacer()
                    }
                    .padding(24)
                    .frame(width: geometry.size.width * 0.4)
                }
            }
        }
        .background(Color(UIColor.systemBackground))
        .onAppear {
            animateIn = true
            isContentFocused = true
            currentPrompt = inspirationalPrompts.randomElement() ?? ""
        }
        .onChange(of: selectedPhotos) { oldValue, newValue in
            Task {
                selectedImages = []
                for item in newValue {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        selectedImages.append(data)
                    }
                }
            }
        }
        .onChange(of: content) { oldValue, newValue in
            // Hide keyboard shortcut hint once user starts typing
            if !newValue.isEmpty && showKeyboardShortcutHint {
                showKeyboardShortcutHint = false
            }
            
            // Analyze mood when content changes
            analyzeTask?.cancel()
            
            let trimmedNewValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if trimmedNewValue.isEmpty {
                hasMoodAnalysis = false
                return
            }
            
            if trimmedNewValue.count < 5 {
                return
            }
            
            analyzeTask = Task {
                do {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    
                    if Task.isCancelled {
                        return
                    }
                    
                    let mood = await aiService.analyzeMood(text: trimmedNewValue)
                    
                    if Task.isCancelled {
                        return
                    }
                    
                    await MainActor.run {
                        moodValue = mood
                        hasMoodAnalysis = true
                    }
                    
                } catch {
                    if !(error is CancellationError) {
                        print("[MacHomeView onChange Task Error]: \(error)")
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            MacSettingsView()
                .frame(minWidth: 600, minHeight: 500)
        }
    }
    
    @ViewBuilder
    private var moodSection: some View {
        // Enhanced Mood section
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label(NSLocalizedString("心情记录", comment: ""), systemImage: "heart.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.primary)
                
                Spacer()
            }
            
            // Enhanced mood visualization with fixed height
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                ZStack {
                    // Background glow effect - always show for consistent size
                    Circle()
                        .fill(hasMoodAnalysis ? Color.moodSpectrum(value: moodValue).opacity(0.3) : Color.clear)
                        .frame(width: 260, height: 260)
                        .blur(radius: 50)
                    
                    Circle()
                        .fill(hasMoodAnalysis ? Color.moodSpectrum(value: moodValue).opacity(0.2) : Color.clear)
                        .frame(width: 220, height: 220)
                        .blur(radius: 35)
                    
                    Circle()
                        .fill(hasMoodAnalysis ? Color.moodSpectrum(value: moodValue).opacity(0.15) : Color.clear)
                        .frame(width: 200, height: 200)
                        .blur(radius: 25)
                    
                    // Main mood circle with animation
                    Circle()
                        .fill(
                            hasMoodAnalysis ?
                            RadialGradient(
                                gradient: Gradient(stops: [
                                    .init(color: Color.moodSpectrum(value: moodValue), location: 0.0),
                                    .init(color: Color.moodSpectrum(value: moodValue).opacity(0.8), location: 0.5),
                                    .init(color: Color.moodSpectrum(value: moodValue).opacity(0.3), location: 1.0)
                                ]),
                                center: .center,
                                startRadius: 20,
                                endRadius: 80
                            ) :
                            RadialGradient(
                                gradient: Gradient(colors: [
                                    Color.blue.opacity(0.2),
                                    Color.blue.opacity(0.05)
                                ]),
                                center: .center,
                                startRadius: 20,
                                endRadius: 80
                            )
                        )
                        .frame(width: 160, height: 160)
                        .overlay(
                            Circle()
                                .stroke(
                                    LinearGradient(
                                        gradient: Gradient(colors: [
                                            Color.white.opacity(0.3),
                                            Color.white.opacity(0.1)
                                        ]),
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 2
                                )
                        )
                        .shadow(color: hasMoodAnalysis ? Color.moodSpectrum(value: moodValue).opacity(0.4) : Color.blue.opacity(0.15), radius: 15, x: 0, y: 5)
                        .animation(AnimationConfig.gentleSpring, value: moodValue)
                    
                    VStack(spacing: 8) {
                        if hasMoodAnalysis {
                            Text(getMoodEmoji(moodValue))
                                .font(.system(size: 56))
                                .animation(AnimationConfig.gentleSpring, value: moodValue)
                            
                            Text(getMoodDescription(moodValue))
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(Color.black.opacity(0.2))
                                )
                        }
                    }
                    .frame(width: 160, height: 160)
                }
                .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 200, maxHeight: .infinity)
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color(UIColor.tertiarySystemBackground),
                            Color(UIColor.tertiarySystemBackground).opacity(0.95)
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(hasMoodAnalysis ? Color.moodSpectrum(value: moodValue).opacity(0.2) : Color.blue.opacity(0.15), lineWidth: 1)
                )
        )
        .animation(.easeInOut(duration: 0.3), value: moodValue)
    }
    
    @ViewBuilder
    private var photoSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(NSLocalizedString("照片", comment: ""), systemImage: "photo.stack")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.secondary)
                
                Spacer()
            }
            
            if selectedImages.isEmpty {
                // Empty state
                VStack(spacing: 16) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.5))
                    
                    VStack(spacing: 6) {
                        Text(NSLocalizedString("拖拽图片到此处", comment: ""))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.primary.opacity(0.8))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 140)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                                .foregroundColor(Color.blue.opacity(0.2))
                        )
                )
                .onImageDrop { imageData in
                    selectedImages.append(imageData)
                }
            } else {
                // Photo grid
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 12) {
                    ForEach(selectedImages.indices, id: \.self) { index in
                        if let uiImage = UIImage(data: selectedImages[index]) {
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 80, height: 80)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                
                                Button(action: {
                                    selectedImages.remove(at: index)
                                    if index < selectedPhotos.count {
                                        selectedPhotos.remove(at: index)
                                    }
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 18))
                                        .foregroundColor(.white)
                                        .background(
                                            Circle()
                                                .fill(Color.black.opacity(0.6))
                                        )
                                }
                                .buttonStyle(.plain)
                                .padding(4)
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.tertiarySystemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
        )
        .onImageDrop { imageData in
            selectedImages.append(imageData)
        }
    }
    
    // Helper functions
    private var recordingIcon: String {
        if isRecording {
            return isPaused ? "mic.slash.fill" : "stop.circle.fill"
        }
        return "mic.circle.fill"
    }
    
    private var recordingText: String {
        if isRecording {
            return isPaused ? NSLocalizedString("已暂停", comment: "") : NSLocalizedString("停止录音", comment: "")
        }
        return NSLocalizedString("开始录音", comment: "")
    }
    
    private func handleRecordingAction() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }
    
    private func startRecording() {
        audioRecorder.startRecording()
        isRecording = true
        isPaused = false
    }
    
    private func stopRecording() {
        if let fileName = audioRecorder.stopRecording() {
            currentAudioFileName = fileName
            
            Task {
                let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let audioURL = documentsURL.appendingPathComponent(fileName)
                if let transcribedText = await speechRecognizer.transcribeAudio(fileURL: audioURL, localeIdentifier: "zh-CN") {
                    content += (content.isEmpty ? "" : "\n\n") + transcribedText
                }
            }
        }
        isRecording = false
        isPaused = false
    }
    
    private func togglePause() {
        if isPaused {
            audioRecorder.resumeRecording()
        } else {
            audioRecorder.pauseRecording()
        }
        isPaused.toggle()
    }
    
    
    private func formatDetailedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: appLanguage)
        
        if appLanguage.hasPrefix("zh") {
            formatter.dateFormat = "yyyy年M月d日 EEEE HH:mm"
        } else {
            formatter.dateStyle = .full
            formatter.timeStyle = .short
        }
        
        return formatter.string(from: date)
    }
    
    private func getMoodEmoji(_ value: Double) -> String {
        switch value {
        case 0..<0.2: return "😢"
        case 0.2..<0.4: return "😔"
        case 0.4..<0.6: return "😐"
        case 0.6..<0.8: return "😊"
        case 0.8...1: return "😄"
        default: return "😐"
        }
    }
    
    private func getMoodDescription(_ value: Double) -> String {
        switch value {
        case 0..<0.2: return NSLocalizedString("非常低落", comment: "")
        case 0.2..<0.4: return NSLocalizedString("有些低落", comment: "")
        case 0.4..<0.6: return NSLocalizedString("平静", comment: "")
        case 0.6..<0.8: return NSLocalizedString("愉快", comment: "")
        case 0.8...1: return NSLocalizedString("非常开心", comment: "")
        default: return NSLocalizedString("平静", comment: "")
        }
    }
    
    
    private func saveEntry() {
        // Provide haptic feedback on save
        #if canImport(UIKit)
        HapticManager.shared.click()
        #endif
        
        // Animate button press
        isPressingShortcut = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isPressingShortcut = false
        }
        
        Task {
            await MainActor.run {
                isSaving = true
            }
            
            // If mood hasn't been analyzed yet and there's content, analyze it first
            var finalMoodValue = moodValue
            if !hasMoodAnalysis && !content.isEmpty {
                finalMoodValue = await aiService.analyzeMood(text: content)
            }
            
            // Generate summary if not already present
            var finalSummary = summary
            if finalSummary.isEmpty && !content.isEmpty {
                finalSummary = await aiService.summarize(text: content) ?? ""
            }
            
            let newEntry = DiaryEntry(context: viewContext)
            newEntry.id = UUID()
            newEntry.text = content
            newEntry.moodValue = finalMoodValue
            newEntry.date = date
            newEntry.summary = finalSummary
            // Copy audio file to iCloud if needed
            if let audioFileName = currentAudioFileName {
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
                        print("[MacHomeView] Saved audio to iCloud: \(audioFileName)")
                        
                        // Delete from local after successful copy
                        try? FileManager.default.removeItem(at: localURL)
                    }
                }
                
                newEntry.audioFileName = audioFileName
            }
            
            // 保存图片
            var imageFileNames: [String] = []
            for (index, imageData) in selectedImages.enumerated() {
                let fileName = "img_\(newEntry.id?.uuidString ?? UUID().uuidString)_\(index).jpg"
                do {
                    let savedFileName = try DiaryEntry.saveImageToDocuments(imageData, fileName: fileName)
                    imageFileNames.append(savedFileName)
                } catch {
                    print("[MacHomeView] 保存图片失败: \(error)")
                }
            }
            if !imageFileNames.isEmpty {
                newEntry.imageFileNames = imageFileNames.joined(separator: ",")
                
                // Also save images data for sync
                newEntry.saveImagesForSync(selectedImages)
            }
            
            do {
                try viewContext.save()
                print("Entry saved successfully, CloudKit will sync automatically")
                
                // Clear the form after saving
                await MainActor.run {
                    isSaving = false
                    content = ""
                    moodValue = 0.5
                    summary = ""
                    hasMoodAnalysis = false
                    isContentFocused = true
                    currentAudioFileName = nil
                    selectedImages = []
                    selectedPhotos = []
                    // Reset keyboard shortcut hint for next entry
                    showKeyboardShortcutHint = true
                    
                    // Success haptic feedback
                    #if canImport(UIKit)
                    HapticManager.shared.click()
                    #endif
                }
            } catch {
                print("Error saving entry: \(error)")
                await MainActor.run {
                    isSaving = false
                }
            }
        }
    }
}
#endif
