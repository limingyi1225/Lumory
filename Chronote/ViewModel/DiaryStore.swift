import Foundation
import Combine

/// 负责加载、保存日记，调用 AI 生成摘要与情绪分析
/// @deprecated 此类已被 Core Data 替代，仅保留用于兼容性
@MainActor
final class DiaryStore: ObservableObject {
    @Published private(set) var entries: [LegacyDiaryEntry] = []
    @Published var isImporting: Bool = false
    @Published var importProgress: Double = 0.0

    private let saveURL: URL
    let aiService: AIServiceProtocol

    init(useAppleRecognizer: Bool = true) { // Default to Apple Recognizer
        if useAppleRecognizer {
            self.aiService = AppleRecognitionService(openAIApiKey: AppSecrets.openAIKey)
        } else {
            self.aiService = OpenAIService(apiKey: AppSecrets.openAIKey)
        }
        // Documents/diary.json
        self.saveURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("diary.json")
        load()
    }

    // MARK: - Public API

    func addEntry(text: String, audioFileName: String?, moodValue: Double? = nil) async {
        // 并行调用摘要与情绪(如果未提供)以提升性能
        let entry: LegacyDiaryEntry
        if let moodValue {
            let summary = await aiService.summarize(text: text)
            entry = LegacyDiaryEntry(id: UUID(), date: Date(), text: text, summary: summary, moodValue: moodValue, audioFileName: audioFileName)
        } else {
            let (summary, mood) = await aiService.analyzeAndSummarize(text: text)
            entry = LegacyDiaryEntry(id: UUID(), date: Date(), text: text, summary: summary, moodValue: mood, audioFileName: audioFileName)
        }
        entries.append(entry)
        save()
    }

    func delete(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        save()
    }

    // 新增删除单条日记的方法
    func delete(entry: LegacyDiaryEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries.remove(at: index)
            save()
        }
    }

    // 新增删除所有日记的方法
    func deleteAll() {
        entries.removeAll()
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: saveURL.path) else { return }
        do {
            let data = try Data(contentsOf: saveURL)
            let decoded = try JSONDecoder().decode([LegacyDiaryEntry].self, from: data)
            self.entries = decoded
        } catch {
            print("[DiaryStore] Load error: \(error)")
        }
    }

    private func save() {
        // 异步后台保存，避免阻塞主线程
        let entriesCopy = entries
        let urlCopy = saveURL
        Task.detached(priority: .background) {
            do {
                let data = try JSONEncoder().encode(entriesCopy)
                try data.write(to: urlCopy)
            } catch {
                print("[DiaryStore] Save error: \(error)")
            }
        }
    }

    // MARK: - Query

    func entries(on date: Date) -> [LegacyDiaryEntry] {
        let cal = Calendar.current
        return entries.filter { cal.isDate($0.date, inSameDayAs: date) }
    }

    func recent(limit: Int = 5) -> [LegacyDiaryEntry] {
        return entries.sorted { $0.date > $1.date }.prefix(limit).map { $0 }
    }

    func entries(in range: ClosedRange<Date>) -> [LegacyDiaryEntry] {
        return entries.filter { range.contains($0.date) }
    }

    // MARK: - Import

    /// 根据用户粘贴的原始文本批量导入日记。
    /// 该方法会调用 GPT-4.1-mini 解析日期与正文，然后对每篇日记执行摘要与情绪分析。
    /// 整个流程在主线程上串行执行，已使用 async/await 避免阻塞 UI。
    @MainActor
    func importEntries(from rawText: String) async {
        print("[DiaryStore] importEntries: rawText length = \(rawText.count)")
        isImporting = true
        importProgress = 0.0
        let parsed = await DiaryImportService.parse(rawText: rawText)
        print("[DiaryStore] importEntries: parsed count = \(parsed.count)")
        guard !parsed.isEmpty else {
            print("[DiaryStore] importEntries: parsed isEmpty, abort import")
            isImporting = false
            importProgress = 0.0
            return }

        let total = parsed.count
        for (index, (date, text)) in parsed.enumerated() {
            // 先执行摘要
            let summary = await aiService.summarize(text: text)
            // 再执行心情分析
            let moodValue = await aiService.analyzeMood(text: text)
            // 创建并导入条目
            let entry = LegacyDiaryEntry(id: UUID(), date: date, text: text, summary: summary, moodValue: moodValue, audioFileName: nil)
            entries.append(entry)
            // 保存并更新进度
            save()
            importProgress = Double(index + 1) / Double(total)
            print("[DiaryStore] importEntries: imported entry \(index + 1)/\(total)")
        }
        // 导入完成后
        isImporting = false
        importProgress = 1.0
        print("[DiaryStore] importEntries: import completed, total entries = \(entries.count)")
    }
} 