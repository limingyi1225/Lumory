import SwiftUI
import CoreData
import Combine
import PhotosUI

@MainActor
final class HomeViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var inputText = ""
    @Published var inputMoodScore: Double? = nil
    @Published var showEmptyPrompt = false
    @Published var moodProgress: Double = 0.5
    @Published var hasMoodValue = false
    @Published var isCreatingEntry = false
    @Published var isAnalyzing = false
    @Published var lastGeneratedMood: Double = 0.5
    @Published var showSettings = false
    @Published var selectedImages: [Data] = []
    @Published var showImagePicker = false
    @Published var recordings: [Recording] = []
    @Published var isTranscribing = false
    @Published var transcriptionError: String?
    
    // MARK: - Services
    private let audioRecorder = AudioRecorder()
    let audioPlaybackController = AudioPlaybackController()
    private let hapticManager = HapticManager.shared
    
    // MARK: - Private Properties
    private var moodAnalysisTask: Task<Void, Never>?
    private let aiService: AIServiceProtocol
    private let recognitionService: AppleRecognitionService
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Computed Properties
    var canCreateEntry: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !recordings.isEmpty ||
        !selectedImages.isEmpty
    }
    
    var isRecording: Bool {
        audioRecorder.isRecording
    }
    
    var amplitude: Float {
        audioRecorder.amplitude
    }
    
    // MARK: - Initialization
    init() {
        self.aiService = OpenAIService(apiKey: AppSecrets.openAIKey)
        self.recognitionService = AppleRecognitionService(openAIApiKey: AppSecrets.openAIKey)
        setupSubscriptions()
    }
    
    private func setupSubscriptions() {
        // Monitor text changes for mood analysis
        $inputText
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] text in
                if !text.isEmpty {
                    self?.analyzeMood(for: text)
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Recording Methods
    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }
    
    private func startRecording() {
        hapticManager.click()
        audioRecorder.startRecording()
    }
    
    private func stopRecording() {
        guard let fileName = audioRecorder.stopRecording() else {
            print("[HomeViewModel] Recording too short or failed")
            return
        }
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = documentsPath.appendingPathComponent(fileName)
        
        let newRecording = Recording(
            id: UUID().uuidString,
            fileName: fileName,
            duration: audioRecorder.duration
        )
        
        recordings.append(newRecording)
        transcribeRecording(at: fileURL)
    }
    
    private func transcribeRecording(at url: URL) {
        isTranscribing = true
        transcriptionError = nil
        
        Task {
            do {
                let localeIdentifier = Locale.current.identifier
                guard let transcription = await recognitionService.transcribeAudio(fileURL: url, localeIdentifier: localeIdentifier) else {
                    throw NSError(domain: "Transcription", code: -1, userInfo: [NSLocalizedDescriptionKey: "转录失败"])
                }
                
                await MainActor.run {
                    if !inputText.isEmpty {
                        inputText += "\n\n"
                    }
                    inputText += transcription
                    isTranscribing = false
                }
            } catch {
                await MainActor.run {
                    transcriptionError = error.localizedDescription
                    isTranscribing = false
                }
            }
        }
    }
    
    // MARK: - Mood Analysis
    private func analyzeMood(for text: String) {
        moodAnalysisTask?.cancel()
        
        guard !text.isEmpty else {
            withAnimation(.easeInOut(duration: 0.5)) {
                hasMoodValue = false
            }
            return
        }
        
        isAnalyzing = true
        
        moodAnalysisTask = Task { [weak self] in
            guard let self = self else { return }
            
            let mood = await self.aiService.analyzeMood(text: text)
            
            guard !Task.isCancelled else { return }
            
            await MainActor.run {
                self.lastGeneratedMood = mood
                self.inputMoodScore = mood
                
                withAnimation(AnimationConfig.bouncySpring) {
                    self.moodProgress = mood
                    self.hasMoodValue = true
                }
                
                self.isAnalyzing = false
            }
        }
    }
    
    // MARK: - Entry Creation
    func createEntry(context: NSManagedObjectContext) async -> Bool {
        guard canCreateEntry else { return false }
        
        isCreatingEntry = true
        
        do {
            let entry = DiaryEntry(context: context)
            entry.id = UUID()
            entry.date = Date()
            entry.text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Set mood
            if let moodScore = inputMoodScore {
                entry.moodValue = moodScore
            } else {
                entry.moodValue = 0.5
            }
            
            // Save images
            if !selectedImages.isEmpty {
                var imageFileNames: [String] = []

                for imageData in selectedImages {
                    let fileName = try DiaryEntry.saveImageToDocuments(imageData)
                    imageFileNames.append(fileName)
                }

                entry.imageFileNames = imageFileNames.joined(separator: ",")
                entry.saveImagesForSync(selectedImages)
            }
            
            // Save audio
            if let firstRecording = recordings.first {
                entry.audioFileName = firstRecording.fileName
            }
            
            // Generate summary if there's text
            if !entry.text!.isEmpty {
                if let summary = await aiService.summarize(text: entry.text!) {
                    entry.summary = summary
                }
            }
            
            try context.save()
            
            // Clean up
            clearInputState()
            
            // Clean up extra recordings
            for (index, recording) in recordings.enumerated() {
                if index > 0 { // Keep first recording, delete others
                    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent(recording.fileName)
                    try? FileManager.default.removeItem(at: url)
                }
            }
            
            isCreatingEntry = false
            return true
            
        } catch {
            print("[HomeViewModel] Failed to save entry: \(error)")
            isCreatingEntry = false
            return false
        }
    }
    
    func clearInputState() {
        inputText = ""
        inputMoodScore = nil
        moodProgress = 0.5
        hasMoodValue = false
        selectedImages = []
        recordings = []
        showEmptyPrompt = false
    }
    
    // MARK: - Image Management
    func removeImage(at index: Int) {
        guard selectedImages.indices.contains(index) else { return }
        selectedImages.remove(at: index)
    }
    
    func removeRecording(_ recording: Recording) {
        recordings.removeAll { $0.id == recording.id }
        
        // Delete file
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = documentsPath.appendingPathComponent(recording.fileName)
        try? FileManager.default.removeItem(at: fileURL)
    }
    
    // MARK: - Cleanup
    func cleanup() {
        audioRecorder.cleanup()
        moodAnalysisTask?.cancel()
        cancellables.removeAll()
    }
    
    deinit {
        // Cancel all tasks immediately
        moodAnalysisTask?.cancel()
        cancellables.removeAll()
        // Note: audioRecorder and audioPlaybackController will clean up in their own deinits
    }
}