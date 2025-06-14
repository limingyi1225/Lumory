//
//  MacMoodReportView.swift
//  Lumory
//
//  Created by Assistant on 6/3/25.
//

import SwiftUI
import Charts
import CoreData

#if targetEnvironment(macCatalyst)
struct MacMoodReportView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @State private var selectedPeriod: Period = .week
    @State private var selectedMoodLevel: Int? = nil
    @State private var aiReport: String = ""
    @State private var isGeneratingReport = false
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)])
    private var entries: FetchedResults<DiaryEntry>
    
    private let aiService = AppleRecognitionService(openAIApiKey: AppSecrets.openAIKey)
    
    enum Period: String, CaseIterable {
        case week = "Week"
        case month = "Month"
        case year = "Year"
        case all = "All Time"
        
        var localizedName: String {
            return NSLocalizedString(self.rawValue, comment: "")
        }
        
        var days: Int {
            switch self {
            case .week: return 7
            case .month: return 30
            case .year: return 365
            case .all: return Int.max
            }
        }
    }
    
    // Memoized filtered entries for better performance
    private var filteredEntries: [DiaryEntry] {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -selectedPeriod.days, to: Date()) ?? Date()
        return entries.filter { entry in
            return selectedPeriod == .all || (entry.date ?? Date.distantPast) >= cutoffDate
        }
    }
    
    var moodData: [(date: Date, mood: Double)] {
        Dictionary(grouping: filteredEntries) { entry in
            Calendar.current.startOfDay(for: entry.date ?? Date())
        }
        .compactMap { date, entries in
            let avgMood = entries.reduce(0.0) { $0 + $1.moodValue } / Double(entries.count)
            return (date: date, mood: avgMood)
        }
        .sorted { $0.date < $1.date }
    }
    
    var moodDistribution: [Int: Int] {
        var distribution = [Int: Int]()
        for mood in 1...5 {
            distribution[mood] = filteredEntries.filter { Int($0.moodValue * 4 + 1) == mood }.count
        }
        return distribution
    }
    
    var averageMood: Double {
        guard !filteredEntries.isEmpty else { return 0 }
        let total = filteredEntries.reduce(0.0) { $0 + $1.moodValue * 5 }
        return Double(total) / Double(filteredEntries.count)
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header with period selector
                HStack {
                    Text(NSLocalizedString("Mood Report", comment: ""))
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Spacer()
                    
                    Picker(NSLocalizedString("Period", comment: ""), selection: $selectedPeriod) {
                        ForEach(Period.allCases, id: \.self) { period in
                            Text(period.localizedName).tag(period)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .frame(width: 300)
                }
                .padding(.horizontal)
                .padding(.top)
                
                // Summary cards
                HStack(spacing: 20) {
                    SummaryCard(
                        title: "Total Entries",
                        value: "\(filteredEntries.count)",
                        icon: "note.text",
                        color: .blue
                    )
                    
                    SummaryCard(
                        title: "Average Mood",
                        value: String(format: "%.1f", averageMood),
                        icon: "face.smiling",
                        color: Color.moodSpectrum(value: (averageMood - 1) / 4.0)
                    )
                    
                    SummaryCard(
                        title: "Most Common",
                        value: mostCommonMoodText,
                        icon: "star.fill",
                        color: .orange
                    )
                    
                    SummaryCard(
                        title: "Streak",
                        value: "\(currentStreak) \(NSLocalizedString("days", comment: ""))",
                        icon: "flame.fill",
                        color: .red
                    )
                }
                .padding(.horizontal)
                
                // Mood trend chart
                VStack(alignment: .leading) {
                    Text(NSLocalizedString("Mood Trend", comment: ""))
                        .font(.title2)
                        .fontWeight(.semibold)
                        .padding(.horizontal)
                    
                    if moodData.isEmpty {
                        Text(NSLocalizedString("No data available for the selected period", comment: ""))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        Chart(moodData, id: \.date) { item in
                            LineMark(
                                x: .value("Date", item.date),
                                y: .value("Mood", item.mood)
                            )
                            .foregroundStyle(Color.accentColor)
                            .interpolationMethod(.catmullRom)
                            
                            AreaMark(
                                x: .value("Date", item.date),
                                y: .value("Mood", item.mood)
                            )
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color.accentColor.opacity(0.3), Color.accentColor.opacity(0.05)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .interpolationMethod(.catmullRom)
                        }
                        .frame(height: 300)
                        .padding(.horizontal)
                        .chartYScale(domain: 0...6)
                        .chartYAxis {
                            AxisMarks(values: [1, 2, 3, 4, 5]) { value in
                                AxisGridLine()
                                AxisValueLabel {
                                    if let intValue = value.as(Int.self) {
                                        Image(systemName: moodIcon(for: intValue))
                                            .foregroundColor(Color.moodSpectrum(value: Double(intValue - 1) / 4.0))
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.vertical)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal)
                
                // Mood distribution
                VStack(alignment: .leading) {
                    Text(NSLocalizedString("Mood Distribution", comment: ""))
                        .font(.title2)
                        .fontWeight(.semibold)
                        .padding(.horizontal)
                    
                    HStack(spacing: 16) {
                        ForEach(1...5, id: \.self) { mood in
                            MoodDistributionBar(
                                mood: mood,
                                count: moodDistribution[mood] ?? 0,
                                total: filteredEntries.count,
                                isSelected: selectedMoodLevel == mood
                            ) {
                                selectedMoodLevel = selectedMoodLevel == mood ? nil : mood
                            }
                        }
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal)
                }
                
                // Recent entries with selected mood
                if let selectedMood = selectedMoodLevel {
                    VStack(alignment: .leading) {
                        Text(String(format: NSLocalizedString("Entries with Mood %d", comment: ""), selectedMood))
                            .font(.title2)
                            .fontWeight(.semibold)
                            .padding(.horizontal)
                        
                        ScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(filteredEntries.filter { Int($0.moodValue * 4 + 1) == selectedMood }.prefix(10)) { entry in
                                    MacMoodEntryRow(entry: entry)
                                }
                            }
                            .padding()
                        }
                        .frame(maxHeight: 300)
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(12)
                        .padding(.horizontal)
                    }
                }
                
                // AI Generated Report Section
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(NSLocalizedString("AI Analysis", comment: ""))
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        Spacer()
                        
                        Button(action: generateAIReport) {
                            Label(isGeneratingReport ? NSLocalizedString("Generating...", comment: "") : NSLocalizedString("Generate Report", comment: ""), 
                                  systemImage: "sparkles")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isGeneratingReport || filteredEntries.isEmpty)
                    }
                    .padding(.horizontal)
                    
                    if !aiReport.isEmpty {
                        ScrollView {
                            Text(aiReport)
                                .font(.system(size: 14))
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 300)
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(12)
                        .padding(.horizontal)
                    } else if isGeneratingReport {
                        VStack {
                            ProgressView()
                                .scaleEffect(1.2)
                            Text(NSLocalizedString("Analyzing your mood patterns...", comment: ""))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, 8)
                        }
                        .frame(maxWidth: .infinity, minHeight: 200)
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(12)
                        .padding(.horizontal)
                    }
                }
                
                Spacer(minLength: 40)
            }
        }
        .onChange(of: selectedPeriod) { _, _ in
            aiReport = ""
            selectedMoodLevel = nil
        }
    }
    
    private var mostCommonMoodText: String {
        guard let mostCommon = moodDistribution.max(by: { $0.value < $1.value }) else { return NSLocalizedString("N/A", comment: "") }
        return String(format: NSLocalizedString("Mood %d", comment: ""), mostCommon.key)
    }
    
    private var currentStreak: Int {
        var streak = 0
        let calendar = Calendar.current
        var currentDate = Date()
        
        for _ in 0..<365 {
            let hasEntry = filteredEntries.contains { entry in
                return calendar.isDate(entry.date ?? Date(), inSameDayAs: currentDate)
            }
            
            if hasEntry {
                streak += 1
                currentDate = calendar.date(byAdding: .day, value: -1, to: currentDate) ?? currentDate
            } else {
                break
            }
        }
        
        return streak
    }
    
    private func moodIcon(for mood: Int) -> String {
        switch mood {
        case 1: return "face.dashed"
        case 2: return "face.frowning"
        case 3: return "face.smiling"
        case 4: return "face.happy"
        case 5: return "face.grinning"
        default: return "face.smiling"
        }
    }
    
    private func generateAIReport() {
        guard !filteredEntries.isEmpty else { 
            aiReport = NSLocalizedString("No diary entries available for analysis.", comment: "")
            return 
        }
        
        // Check API key validity first
        guard AppSecrets.isValidKey else {
            aiReport = NSLocalizedString("API configuration error. Please check your API key settings.", comment: "")
            return
        }
        
        isGeneratingReport = true
        aiReport = ""
        
        Task {
            let entriesToAnalyze = Array(filteredEntries.prefix(30)) // Analyze up to 30 entries
            
            do {
                print("[MacMoodReportView] 开始使用完全独立的报告生成服务")
                
                // 构建日期范围用于过滤
                let dateRange = Date.distantPast...Date.distantFuture
                
                // 使用完全独立的报告生成服务，避免任何CloudKit干扰
                try await withTimeout(seconds: 60) {
                    await ReportGenerationService.generateReport(from: entriesToAnalyze, dateRange: dateRange) { chunk in
                        print("[MacMoodReportView] 收到内容块: '\(chunk.prefix(50))...'")
                        DispatchQueue.main.async {
                            self.aiReport += chunk
                            print("[MacMoodReportView] 当前报告总长度: \(self.aiReport.count)")
                        }
                    }
                }
                
                await MainActor.run {
                    print("[MacMoodReportView] 报告生成完成，最终长度: \(aiReport.count)")
                    isGeneratingReport = false
                    // If report is still empty, show a default message
                    if aiReport.isEmpty {
                        print("[MacMoodReportView] 报告为空，显示默认消息")
                        aiReport = NSLocalizedString("分析完成但没有生成洞察报告。这可能是由于内容不足或暂时的服务问题。请尝试重新生成或检查网络连接。", comment: "")
                    } else {
                        print("[MacMoodReportView] 报告生成成功")
                    }
                }
            } catch {
                await MainActor.run {
                    isGeneratingReport = false
                    if error.localizedDescription.contains("401") {
                        aiReport = NSLocalizedString("Authentication failed. Please check your API key and account balance.", comment: "")
                    } else if error.localizedDescription.contains("cancelled") {
                        aiReport = NSLocalizedString("Report generation was cancelled. Please try again.", comment: "")
                    } else {
                        aiReport = String(format: NSLocalizedString("Unable to generate report: %@. Please try again later.", comment: ""), error.localizedDescription)
                    }
                }
            }
        }
    }
    
    // Helper function to add timeout
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NSError(domain: "Timeout", code: -1, userInfo: [NSLocalizedDescriptionKey: "Operation timed out"])
            }
            
            guard let result = try await group.next() else {
                throw NSError(domain: "TaskGroup", code: -1, userInfo: [NSLocalizedDescriptionKey: "No result"])
            }
            
            group.cancelAll()
            return result
        }
    }
}

struct SummaryCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundColor(color)
            
            Text(value)
                .font(.system(size: 24, weight: .bold))
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}

struct MoodDistributionBar: View {
    let mood: Int
    let count: Int
    let total: Int
    let isSelected: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    private var percentage: Double {
        guard total > 0 else { return 0 }
        return Double(count) / Double(total) * 100
    }
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Text("\(count)")
                    .font(.system(size: 16, weight: .bold))
                
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        Spacer()
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.moodSpectrum(value: Double(mood - 1) / 4.0))
                            .frame(height: max(20, geometry.size.height * percentage / 100))
                            .scaleEffect(x: isHovered ? 1.1 : 1.0)
                    }
                }
                .frame(height: 150)
                
                Image(systemName: moodIcon(for: mood))
                    .font(.system(size: 20))
                    .foregroundColor(Color.moodSpectrum(value: Double(mood - 1) / 4.0))
                
                Text("\(Int(percentage))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
    
    private func moodIcon(for mood: Int) -> String {
        switch mood {
        case 1: return "face.dashed"
        case 2: return "face.frowning"
        case 3: return "face.smiling"
        case 4: return "face.happy"
        case 5: return "face.grinning"
        default: return "face.smiling"
        }
    }
}

struct MacMoodEntryRow: View {
    let entry: DiaryEntry
    
    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(entry.moodColor)
                .frame(width: 20, height: 20)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.content ?? "")
                    .font(.system(size: 13))
                    .lineLimit(1)
                
                Text(entry.formattedDate)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(UIColor.secondarySystemBackground).opacity(0.5))
        .cornerRadius(8)
    }
}
#endif