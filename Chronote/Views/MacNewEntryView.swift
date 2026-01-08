//
//  MacNewEntryView.swift
//  Lumory
//
//  Created by Assistant on 6/3/25.
//

import SwiftUI
import PhotosUI

#if targetEnvironment(macCatalyst)
struct MacNewEntryView: View {
    @Binding var isPresented: Bool
    @Environment(\.managedObjectContext) private var viewContext
    @State private var content = ""
    @State private var moodValue = 0.5
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var selectedImages: [Data] = []
    @State private var date = Date()
    @State private var isRecording = false
    @State private var isPaused = false
    @StateObject private var audioRecorder = AudioRecorder()
    private let speechRecognizer = AppleSpeechRecognizer()
    @FocusState private var isContentFocused: Bool
    @State private var showMoodPicker = false
    @State private var animateIn = false
    @State private var currentTab = 0
    @State private var showDatePicker = false
    @State private var currentAudioFileName: String? = nil
    @State private var hasMoodAnalysis = false
    @State private var analyzeTask: Task<Void, Never>? = nil
    @State private var showSendAnimation = false
    private let aiService = AppleRecognitionService(openAIApiKey: AppSecrets.openAIKey)
    @AppStorage("appLanguage") private var appLanguage: String = "en"
    
    private let inspirationalPrompts = [
        "今天有什么特别的事情发生吗？",
        "此刻你的心情是怎样的？",
        "有什么想要记录的瞬间吗？",
        "今天最让你开心的是什么？",
        "现在最想和谁分享你的感受？"
    ]
    
    @State private var currentPrompt = ""
    
    var body: some View {
        VStack(spacing: 0) {
            // Modern header
            headerView
                .background(
                    ZStack {
                        Color(UIColor.systemBackground)
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color.moodSpectrum(value: moodValue).opacity(0.1),
                                Color.clear
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                )
            
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
                        }
                        
                        // Content editor
                        ZStack(alignment: .topLeading) {
                            if content.isEmpty {
                                Text(currentPrompt)
                                    .font(.system(size: 18, weight: .light))
                                    .foregroundColor(.secondary.opacity(0.6))
                                    .italic()
                                .padding(.top, 16)
                                .padding(.horizontal, 4)
                            }
                            
                            TextEditor(text: $content)
                                .font(.system(size: 17))
                                .lineSpacing(6)
                                .focused($isContentFocused)
                                .scrollContentBackground(.hidden)
                                .padding(.vertical, 8)
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
                        
                        // Recording controls
                        recordingControlsView
                    }
                    .padding(24)
                    .frame(width: geometry.size.width * 0.6)
                    
                    Divider()
                    
                    // Right side - Mood and Media
                    VStack(spacing: 24) {
                        // Enhanced Mood section
                        VStack(alignment: .leading, spacing: 20) {
                            HStack {
                                Label("心情记录", systemImage: "heart.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.primary)
                                
                                Spacer()
                                
                            }
                            
                            // Enhanced mood visualization
                            VStack(spacing: 24) {
                                ZStack {
                                    // Background glow effect - more visible
                                    Circle()
                                        .fill(Color.moodSpectrum(value: moodValue).opacity(0.4))
                                        .frame(width: 280, height: 280)
                                        .blur(radius: 60)
                                    
                                    Circle()
                                        .fill(Color.moodSpectrum(value: moodValue).opacity(0.35))
                                        .frame(width: 240, height: 240)
                                        .blur(radius: 45)
                                    
                                    Circle()
                                        .fill(Color.moodSpectrum(value: moodValue).opacity(0.25))
                                        .frame(width: 200, height: 200)
                                        .blur(radius: 30)
                                    
                                    // Main mood circle with animation
                                    Circle()
                                        .fill(
                                            RadialGradient(
                                                gradient: Gradient(stops: [
                                                    .init(color: Color.moodSpectrum(value: moodValue), location: 0.0),
                                                    .init(color: Color.moodSpectrum(value: moodValue).opacity(0.8), location: 0.5),
                                                    .init(color: Color.moodSpectrum(value: moodValue).opacity(0.3), location: 1.0)
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
                                        .shadow(color: Color.moodSpectrum(value: moodValue).opacity(0.4), radius: 15, x: 0, y: 5)
                                        .scaleEffect(hasMoodAnalysis ? 1.0 : 0.95)
                                        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: moodValue)
                                    
                                    if hasMoodAnalysis {
                                        VStack(spacing: 8) {
                                            Text(getMoodEmoji(moodValue))
                                                .font(.system(size: 56))
                                                .animation(.spring(response: 0.4, dampingFraction: 0.6), value: moodValue)
                                            
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
                                }
                                .frame(maxWidth: .infinity)
                                
                                // Enhanced slider section
                                VStack(spacing: 16) {
                                    EditableMoodSpectrumBar(moodValue: $moodValue, isEnabled: true)
                                        .frame(height: 28)
                                        .padding(.horizontal, 8)
                                    
                                    HStack {
                                        ForEach([
                                            ("😢", "悲伤"),
                                            ("😔", "低落"),
                                            ("😐", "平静"),
                                            ("😊", "愉快"),
                                            ("😄", "开心")
                                        ], id: \.0) { emoji, label in
                                            VStack(spacing: 4) {
                                                Text(emoji)
                                                    .font(.system(size: 20))
                                                Text(label)
                                                    .font(.system(size: 10))
                                                    .foregroundColor(.secondary)
                                            }
                                            if emoji != "😄" { Spacer() }
                                        }
                                    }
                                    .padding(.horizontal, 8)
                                }
                            }
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
                                        .stroke(Color.moodSpectrum(value: moodValue).opacity(0.2), lineWidth: 1)
                                )
                        )
                        .animation(.easeInOut(duration: 0.3), value: moodValue)
                        
                        // Photo section
                        photoSection
                        
                        Spacer()
                    }
                    .padding(24)
                    .frame(width: geometry.size.width * 0.4)
                }
            }
        }
        .frame(width: 900, height: 700)
        .background(Color(UIColor.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .scaleEffect(animateIn ? 1 : 0.95)
        .opacity(animateIn ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                animateIn = true
            }
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
            // Analyze mood when content changes - follow iOS logic exactly
            analyzeTask?.cancel()
            
            let trimmedNewValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if trimmedNewValue.isEmpty {
                hasMoodAnalysis = false
                return
            }
            
            // Only analyze if content is substantial enough (similar to iOS)
            if trimmedNewValue.count < 5 {
                return
            }
            
            analyzeTask = Task {
                do {
                    try await Task.sleep(nanoseconds: 500_000_000) // 0.5 second debounce to reduce API calls
                    
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
                        print("[MacNewEntryView onChange Task Error]: \(error)")
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("新建日记")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.primary)
                
                Text("记录此刻的心情与故事")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            HStack(spacing: 16) {
                Button(action: { 
                    withAnimation(.easeOut(duration: 0.2)) {
                        animateIn = false
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        isPresented = false
                    }
                }) {
                    Text("取消")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(UIColor.secondarySystemBackground))
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape)
                
                Button(action: saveEntry) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                        Text("保存日记")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundColor(content.isEmpty ? .secondary : .white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(content.isEmpty ? Color(UIColor.tertiarySystemBackground) : Color.accentColor)
                    )
                }
                .buttonStyle(.plain)
                .disabled(content.isEmpty)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 20)
    }
    
    @ViewBuilder
    private var recordingControlsView: some View {
        HStack(spacing: 16) {
            // Main recording button
            Button(action: handleRecordingAction) {
                HStack(spacing: 12) {
                    Image(systemName: recordingIcon)
                        .font(.system(size: 20))
                        .symbolRenderingMode(.hierarchical)
                    
                    Text(recordingText)
                        .font(.system(size: 15, weight: .medium))
                    
                    if isRecording && !isPaused {
                        // Recording indicator
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                            .overlay(
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 8, height: 8)
                                    .scaleEffect(1.5)
                                    .opacity(0)
                                    .animation(
                                        .easeInOut(duration: 1.5)
                                        .repeatForever(autoreverses: false),
                                        value: isRecording
                                    )
                            )
                    }
                }
                .foregroundColor(isRecording ? .white : .primary)
                .frame(minWidth: 150)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isRecording ? Color.red : Color(UIColor.secondarySystemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            
            // Pause/Resume button (only show when recording)
            if isRecording {
                Button(action: togglePause) {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.primary)
                        .frame(width: 44, height: 44)
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
        }
        .animation(.spring(response: 0.3), value: isRecording)
    }
    
    @ViewBuilder
    private var photoSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("照片", systemImage: "photo.stack")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.secondary)
                
                Spacer()
            }
            
            if selectedImages.isEmpty {
                // Empty state
                VStack(spacing: 12) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.5))
                    
                    Text("添加照片记录美好瞬间")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 120)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(UIColor.quaternarySystemFill))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(style: StrokeStyle(lineWidth: 2, dash: [5]))
                                .foregroundColor(.secondary.opacity(0.2))
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
                                    withAnimation(.spring(response: 0.3)) {
                                        selectedImages.remove(at: index)
                                        if index < selectedPhotos.count {
                                            selectedPhotos.remove(at: index)
                                        }
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
            return isPaused ? "已暂停" : "停止录音"
        }
        return "开始录音"
    }
    
    private func handleRecordingAction() {
        if isRecording {
            // Stop recording
            stopRecording()
        } else {
            // Start recording
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
            // Save the audio file name
            currentAudioFileName = fileName
            
            // Transcribe the recorded audio
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
        case 0..<0.2: return "非常低落"
        case 0.2..<0.4: return "有些低落"
        case 0.4..<0.6: return "平静"
        case 0.6..<0.8: return "愉快"
        case 0.8...1: return "非常开心"
        default: return "平静"
        }
    }
    
    
    private func saveEntry() {
        // 1. 触发发送动画
        withAnimation {
            showSendAnimation = true
        }
        
        // 2. 延迟保存和关闭，让动画播放一会儿
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let newEntry = DiaryEntry(context: viewContext)
            newEntry.id = UUID()
            newEntry.text = content
            newEntry.moodValue = moodValue
            newEntry.date = date
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
                        print("[MacNewEntryView] Saved audio to iCloud: \(audioFileName)")
                        
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
                    print("[MacNewEntryView] 保存图片失败: \(error)")
                }
            }
            if !imageFileNames.isEmpty {
                newEntry.imageFileNames = imageFileNames.joined(separator: ",")
                
                // Also save images data for sync
                newEntry.saveImagesForSync(selectedImages)
            }
            
            do {
                try viewContext.save()
                withAnimation(.easeOut(duration: 0.2)) {
                    animateIn = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    isPresented = false
                }
            } catch {
                print("Error saving entry: \(error)")
            }
        }
    }
}

// Extension to check if character is Chinese
extension Character {
    var isChinese: Bool {
        return ("\u{4E00}" <= self && self <= "\u{9FA5}")
    }
}
#endif