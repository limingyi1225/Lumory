import SwiftUI
import CoreData

struct MoodReportView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)],
        animation: .default)
    private var entries: FetchedResults<DiaryEntry>
    
    // AI 服务
    private let aiService = AppleRecognitionService(openAIApiKey: AppSecrets.openAIKey)

    @Environment(\.dismiss) private var dismiss

    @State private var startDate: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date() // Default, will be overridden
    @State private var endDate: Date = Date()
    @State private var report: String? = nil
    @State private var isGenerating = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text(NSLocalizedString("选择时间范围", comment: "Select time range"))) {
                    DatePicker(NSLocalizedString("开始日期", comment: "Start date"), selection: $startDate, displayedComponents: .date)
                    DatePicker(NSLocalizedString("结束日期", comment: "End date"), selection: $endDate, displayedComponents: .date)
                }

                if let report {
                    Section(header: Text(NSLocalizedString("AI 分析总结", comment: "AI analysis summary"))) {
                        if report.contains("**") {
                            styledReport(report).textSelection(.enabled)
                        } else {
                            Text(report).textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("情绪报告", comment: "Emotional report"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if isGenerating {
                        ProgressView()
                    } else {
                        Button(NSLocalizedString("生成", comment: "Generate")) {
                            Task { await generate() }
                        }
                    }
                }

                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("关闭", comment: "Close")) { dismiss() }
                }
            }
            .onAppear {
                // Logic to set initial startDate moved to onAppear
                let context = PersistenceController.shared.container.viewContext
                let fetchRequest: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
                fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: true)]
                fetchRequest.fetchLimit = 1
                print("[MoodReportView.onAppear] Attempting to fetch the first diary entry...")
                do {
                   if let firstEntry = try context.fetch(fetchRequest).first {
                       print("[MoodReportView.onAppear] Successfully fetched first entry with date: \(firstEntry.date)")
                       self.startDate = firstEntry.date
                   } else {
                       print("[MoodReportView.onAppear] No diary entries found. Defaulting to one week ago.")
                       // startDate already defaults to one week ago if no entries
                   }
                } catch {
                   print("[MoodReportView.onAppear] Error fetching first diary entry: \(error). Defaulting to one week ago.")
                   // startDate already defaults to one week ago in case of error
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func generate() async {
        guard startDate <= endDate else { return }
        isGenerating = true
        let range = startDate...endDate
        let filteredEntries = entries.filter { range.contains($0.date) }
        guard !filteredEntries.isEmpty else {
            report = NSLocalizedString("该时间段内没有日记数据。", comment: "No data for time period")
            isGenerating = false
            return
        }
        if let aiReport = await aiService.generateReport(entries: Array(filteredEntries)) {
            report = aiReport
        } else {
            report = NSLocalizedString("生成报告失败，请稍后再试。", comment: "Report generation failed")
        }
        isGenerating = false
    }

    private func styledReport(_ s: String) -> Text {
        let parts = s.components(separatedBy: "**")
        return parts.enumerated().reduce(Text(""), { result, pair in
            let (index, substring) = pair
            let piece: Text = index.isMultiple(of: 2) ? Text(substring) : Text(substring).bold()
            return result + piece
        })
    }
}

#Preview {
    MoodReportView()
        .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
} 