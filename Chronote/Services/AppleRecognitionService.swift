import Foundation

@available(iOS 15.0, macOS 12.0, *)
class AppleRecognitionService: AIServiceProtocol {
    private let appleSpeechRecognizer = AppleSpeechRecognizer()
    private let openAIService: OpenAIService // For other AI functions

    init(openAIApiKey: String) {
        self.openAIService = OpenAIService(apiKey: openAIApiKey)
    }

    func summarize(text: String) async -> String? {
        return await openAIService.summarize(text: text)
    }

    func analyzeMood(text: String) async -> Double {
        return await openAIService.analyzeMood(text: text)
    }

    func generateReport(entries: [DiaryEntry]) async -> String? {
        return await openAIService.generateReport(entries: entries)
    }

    func generateReport(entries: [DiaryEntry], onChunk: @escaping (String) -> Void) async {
        await openAIService.generateReport(entries: entries, onChunk: onChunk)
    }
    
    func generateReportFromData(entries: [DiaryEntryData]) async -> String? {
        return await openAIService.generateReportFromData(entries: entries)
    }
    
    func generateReportFromData(entries: [DiaryEntryData], onChunk: @escaping (String) -> Void) async {
        await openAIService.generateReportFromData(entries: entries, onChunk: onChunk)
    }

    func transcribeAudio(fileURL: URL, localeIdentifier: String) async -> String? {
        return await appleSpeechRecognizer.transcribeAudio(fileURL: fileURL, localeIdentifier: localeIdentifier)
    }

    func analyzeAndSummarize(text: String) async -> (summary: String?, mood: Double) {
        return await openAIService.analyzeAndSummarize(text: text)
    }
} 