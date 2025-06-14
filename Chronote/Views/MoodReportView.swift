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
                       // 解包 Optional Date，避免插值时出现 Optional(...) 调用
                       let entryDate = firstEntry.date ?? Date()
                       print("[MoodReportView.onAppear] Successfully fetched first entry with date: \(entryDate)")
                       self.startDate = entryDate
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
        print("[MoodReportView] 开始生成报告")
        isGenerating = true
        let range = startDate...endDate
        let filteredEntries = entries.filter { range.contains($0.date ?? Date()) }
        print("[MoodReportView] 筛选后的日记条目数量: \(filteredEntries.count)")
        
        // 检查DiaryEntry对象的状态
        for (index, entry) in filteredEntries.prefix(3).enumerated() {
            print("[MoodReportView] 条目\(index): isFault=\(entry.isFault), id=\(entry.id?.uuidString ?? "nil")")
            print("[MoodReportView] 条目\(index): date=\(entry.date != nil ? "有" : "无"), text长度=\(entry.text?.count ?? 0)")
        }
        
        guard !filteredEntries.isEmpty else {
            report = NSLocalizedString("该时间段内没有日记数据。", comment: "No data for time period")
            isGenerating = false
            return
        }
        do {
            print("[MoodReportView] 开始使用完全独立的报告生成服务")
            
            // 使用完全独立的报告生成服务，避免任何CloudKit干扰
            let result = try await withTimeout(seconds: 60) {
                return await ReportGenerationService.generateReport(from: Array(filteredEntries), dateRange: range)
            }
            
            print("[MoodReportView] AI服务返回结果: \(result != nil ? "成功" : "失败")")
            if let aiReport = result, !aiReport.isEmpty {
                print("[MoodReportView] 报告生成成功，长度: \(aiReport.count)")
                report = aiReport
            } else {
                print("[MoodReportView] 报告为空或nil")
                report = "分析完成但没有生成洞察报告。这可能是由于内容不足或暂时的服务问题。"
            }
        } catch {
            print("[MoodReportView] 报告生成失败: \(error.localizedDescription)")
            if error.localizedDescription.contains("502") {
                report = "后端网关错误(502)，服务器可能临时不可用，请稍后再试。"
            } else if error.localizedDescription.contains("503") {
                report = "后端服务暂时不可用(503)，请稍后再试。"
            } else if error.localizedDescription.contains("504") {
                report = "后端网关超时(504)，请稍后再试。"
            } else if error.localizedDescription.contains("cancelled") {
                report = "报告生成被取消，请重试。"
            } else {
                report = "生成报告时遇到错误：\(error.localizedDescription)。请稍后再试。"
            }
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
    
    // Helper function to add timeout
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                return try await operation()
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NSError(domain: "TimeoutError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Operation timed out"])
            }
            
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

#Preview {
    MoodReportView()
        .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
} 