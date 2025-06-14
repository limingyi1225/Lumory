//
//  MacMoodAnalysisView.swift
//  Lumory
//
//  Created by Assistant on 6/5/25.
//

import SwiftUI
import Charts
import CoreData

#if targetEnvironment(macCatalyst)
struct MacMoodAnalysisView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @State private var selectedPeriod: Period = .year
    @State private var hoveredDate: Date? = nil
    @State private var aiAnalysis: String = ""
    @State private var isGeneratingAnalysis = false
    @State private var selectedMoodFilter: Int? = nil
    @State private var showingEntryDetail: DiaryEntry? = nil
    
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)])
    private var entries: FetchedResults<DiaryEntry>
    
    private let aiService = AppleRecognitionService(openAIApiKey: AppSecrets.openAIKey)
    
    enum Period: String, CaseIterable {
        case week = "Past Week"
        case month = "Past Month"
        case quarter = "Past 3 Months"
        case year = "Past Year"
        
        var localizedName: String {
            return NSLocalizedString(self.rawValue, comment: "")
        }
        
        var days: Int {
            switch self {
            case .week: return 7
            case .month: return 30
            case .quarter: return 90
            case .year: return 365
            }
        }
        
        var dateFormat: String {
            switch self {
            case .week: return "E"
            case .month: return "MMM d"
            case .quarter: return "MMM"
            case .year: return "MMM"
            }
        }
    }
    
    private var filteredEntries: [DiaryEntry] {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -selectedPeriod.days, to: Date()) ?? Date()
        let filtered = entries.filter { entry in
            (entry.date ?? Date.distantPast) >= cutoffDate
        }

        // Debug information
        print("[MacMoodAnalysisView] Total entries: \(entries.count)")
        print("[MacMoodAnalysisView] Cutoff date: \(cutoffDate)")
        print("[MacMoodAnalysisView] Filtered entries: \(filtered.count)")
        print("[MacMoodAnalysisView] Selected period: \(selectedPeriod.rawValue) (\(selectedPeriod.days) days)")

        if filtered.isEmpty && !entries.isEmpty {
            print("[MacMoodAnalysisView] Warning: No entries found in selected period, but total entries exist")
            // Show recent entries for debugging
            for (index, entry) in entries.prefix(5).enumerated() {
                print("[MacMoodAnalysisView] Entry \(index): date=\(entry.date ?? Date.distantPast), mood=\(entry.moodValue)")
            }
        }

        return filtered
    }
    
    private var moodData: [(date: Date, mood: Double, entries: [DiaryEntry])] {
        Dictionary(grouping: filteredEntries) { entry in
            Calendar.current.startOfDay(for: entry.date ?? Date())
        }
        .compactMap { date, dayEntries in
            let avgMood = dayEntries.reduce(0.0) { $0 + $1.moodValue } / Double(dayEntries.count)
            return (date: date, mood: avgMood, entries: dayEntries)
        }
        .sorted { $0.date < $1.date }
    }
    
    private var moodStats: MoodStatistics {
        guard !filteredEntries.isEmpty else {
            return MoodStatistics(average: 0, highest: 0, lowest: 0, trend: 0, volatility: 0)
        }
        
        let moods = filteredEntries.map { $0.moodValue }
        let average = moods.reduce(0.0, +) / Double(moods.count)
        let highest = moods.max() ?? 0
        let lowest = moods.min() ?? 0
        
        // Calculate trend
        let recentMoods = Array(moods.prefix(moods.count / 3))
        let olderMoods = Array(moods.suffix(moods.count / 3))
        let recentAvg = recentMoods.isEmpty ? 0 : recentMoods.reduce(0.0, +) / Double(recentMoods.count)
        let olderAvg = olderMoods.isEmpty ? 0 : olderMoods.reduce(0.0, +) / Double(olderMoods.count)
        let trend = recentAvg - olderAvg
        
        // Calculate volatility
        let variance = moods.reduce(0.0) { $0 + pow($1 - average, 2) } / Double(moods.count)
        let volatility = sqrt(variance)
        
        return MoodStatistics(average: average, highest: highest, lowest: lowest, trend: trend, volatility: volatility)
    }
    
    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [
                    Color(.systemBackground),
                    Color(.systemBackground).opacity(0.95)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 32) {
                    // Header
                    headerSection
                    
                    // Debug info (temporary)
                    // Commented out debug section that was not implemented
                    // if !entries.isEmpty {
                    //     debugInfoSection
                    // }

                    // Main Chart
                    if !filteredEntries.isEmpty {
                        moodChartSection
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    } else {
                        emptyStateView
                    }
                    
                    // Statistics Grid
                    if !filteredEntries.isEmpty {
                        statisticsGrid
                            .transition(.opacity.combined(with: .scale))
                    }
                    
                    // Mood Pattern Analysis
                    if !filteredEntries.isEmpty {
                        moodPatternSection
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                    
                    // AI Analysis Section
                    if !filteredEntries.isEmpty {
                        aiAnalysisSection
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .move(edge: .bottom).combined(with: .opacity)
                            ))
                    }
                    
                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 32)
                .padding(.top, 24)
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: selectedPeriod)
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: aiAnalysis)
        .sheet(item: $showingEntryDetail) { entry in
            DiaryDetailView(entry: entry, startInEditMode: false)
                .frame(minWidth: 600, minHeight: 400)
        }
    }
    
    @ViewBuilder
    private var headerSection: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(NSLocalizedString("Mood Analysis", comment: ""))
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.primary, Color.primary.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                
                Text(NSLocalizedString("Track your emotional journey over time", comment: ""))
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Period Selector with custom styling
            HStack(spacing: 0) {
                ForEach(Period.allCases, id: \.self) { period in
                    Button(action: { selectedPeriod = period }) {
                        Text(period.localizedName)
                            .font(.system(size: 14, weight: selectedPeriod == period ? .semibold : .regular))
                            .foregroundColor(selectedPeriod == period ? .white : .primary)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(
                                ZStack {
                                    if selectedPeriod == period {
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(Color.accentColor)
                                            .matchedGeometryEffect(id: "selector", in: periodSelectorNamespace)
                                    }
                                }
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.secondarySystemBackground))
            )
        }
    }
    
    @ViewBuilder
    private var moodChartSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label(NSLocalizedString("Mood Trend", comment: ""), systemImage: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 20, weight: .semibold))
                
                Spacer()
                
                if let hoveredDate = hoveredDate,
                   let data = moodData.first(where: { Calendar.current.isDate($0.date, inSameDayAs: hoveredDate) }) {
                    HStack(spacing: 12) {
                        Text(data.date, format: .dateTime.month().day())
                            .font(.system(size: 14, weight: .medium))
                        
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.moodSpectrum(value: data.mood))
                                .frame(width: 12, height: 12)
                            Text(String(format: "%.1f", data.mood * 5))
                                .font(.system(size: 14, weight: .semibold))
                        }
                        
                        Text("\(data.entries.count) \(NSLocalizedString("entries", comment: ""))")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(Color(.secondarySystemBackground))
                            .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                    )
                    .transition(.scale.combined(with: .opacity))
                }
            }
            
            Chart(moodData, id: \.date) { item in
                // Area gradient
                AreaMark(
                    x: .value("Date", item.date),
                    y: .value("Mood", item.mood * 5)
                )
                .foregroundStyle(
                    LinearGradient(
                        stops: [
                            .init(color: Color.moodSpectrum(value: item.mood).opacity(0.3), location: 0),
                            .init(color: Color.moodSpectrum(value: item.mood).opacity(0.05), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)
                
                // Line
                LineMark(
                    x: .value("Date", item.date),
                    y: .value("Mood", item.mood * 5)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: moodData.map { Color.moodSpectrum(value: $0.mood) },
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.catmullRom)
                
                // Points
                PointMark(
                    x: .value("Date", item.date),
                    y: .value("Mood", item.mood * 5)
                )
                .foregroundStyle(Color.moodSpectrum(value: item.mood))
                .symbolSize(hoveredDate != nil && Calendar.current.isDate(item.date, inSameDayAs: hoveredDate!) ? 120 : 60)
            }
            .frame(height: 320)
            .chartYScale(domain: 0...5.5)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: selectedPeriod == .week ? 7 : selectedPeriod == .month ? 6 : 8)) { value in
                    if let date = value.as(Date.self) {
                        AxisValueLabel {
                            Text(date, format: selectedPeriod == .week ? .dateTime.weekday(.abbreviated) : .dateTime.month(.abbreviated).day())
                        }
                        AxisGridLine()
                    }
                }
            }
            .chartYAxis {
                AxisMarks(values: [0, 1, 2, 3, 4, 5]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [5, 5]))
                        .foregroundStyle(Color.secondary.opacity(0.2))
                    
                    if let intValue = value.as(Int.self), intValue > 0 {
                        AxisValueLabel {
                            Text("\(intValue)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Color.moodSpectrum(value: Double(intValue - 1) / 4.0))
                        }
                    }
                }
            }
            .chartBackground { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            if case .active(let location) = phase {
                                if let (date, _) = proxy.value(at: location, as: (Date, Double).self) {
                                    hoveredDate = date
                                }
                            } else {
                                hoveredDate = nil
                            }
                        }
                }
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.secondarySystemBackground))
                .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 5)
        )
    }
    
    @ViewBuilder
    private var statisticsGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 20) {
            StatCard(
                title: NSLocalizedString("Average Mood", comment: ""),
                value: String(format: "%.1f", moodStats.average * 5),
                icon: "face.smiling",
                color: Color.moodSpectrum(value: moodStats.average),
                trend: nil
            )
            
            StatCard(
                title: NSLocalizedString("Mood Trend", comment: ""),
                value: moodStats.trend > 0.1 ? NSLocalizedString("Improving", comment: "") : moodStats.trend < -0.1 ? NSLocalizedString("Declining", comment: "") : NSLocalizedString("Stable", comment: ""),
                icon: moodStats.trend > 0.1 ? "arrow.up.right" : moodStats.trend < -0.1 ? "arrow.down.right" : "arrow.right",
                color: moodStats.trend > 0.1 ? .green : moodStats.trend < -0.1 ? .red : .orange,
                trend: moodStats.trend
            )
            
            StatCard(
                title: NSLocalizedString("Total Entries", comment: ""),
                value: "\(filteredEntries.count)",
                icon: "square.and.pencil",
                color: .blue,
                trend: nil
            )
            
            StatCard(
                title: NSLocalizedString("Consistency", comment: ""),
                value: "\(currentStreak) \(NSLocalizedString("days", comment: ""))",
                icon: "flame.fill",
                color: currentStreak > 7 ? .orange : .gray,
                trend: nil
            )
        }
    }
    
    @ViewBuilder
    private var moodPatternSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(NSLocalizedString("Mood Patterns", comment: ""), systemImage: "brain.head.profile")
                .font(.system(size: 20, weight: .semibold))
            
            HStack(spacing: 16) {
                ForEach(1...5, id: \.self) { mood in
                    MoodPatternCard(
                        mood: mood,
                        entries: filteredEntries.filter { Int($0.moodValue * 4 + 1) == mood },
                        totalEntries: filteredEntries.count,
                        isSelected: selectedMoodFilter == mood,
                        action: {
                            withAnimation(.spring(response: 0.3)) {
                                selectedMoodFilter = selectedMoodFilter == mood ? nil : mood
                            }
                        }
                    )
                }
            }
            
            // Show filtered entries if a mood is selected
            if let selectedMood = selectedMoodFilter {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(String(format: NSLocalizedString("Recent entries with %@", comment: ""), moodName(for: selectedMood)))
                            .font(.system(size: 16, weight: .medium))
                        
                        Spacer()
                        
                        Button(NSLocalizedString("Clear Filter", comment: "")) {
                            withAnimation {
                                selectedMoodFilter = nil
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                    }
                    
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(filteredEntries.filter { Int($0.moodValue * 4 + 1) == selectedMood }.prefix(5)) { entry in
                                EntryPreviewCard(entry: entry) {
                                    showingEntryDetail = entry
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(.secondarySystemBackground).opacity(0.5))
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                ))
            }
        }
    }
    
    @ViewBuilder
    private var aiAnalysisSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label(NSLocalizedString("Mood Analysis Report", comment: ""), systemImage: "doc.text")
                    .font(.system(size: 20, weight: .semibold))
                
                Spacer()
                
                Button(action: { generateAIAnalysis() }) {
                    Label(aiAnalysis.isEmpty ? NSLocalizedString("Generate Report", comment: "") : NSLocalizedString("Regenerate", comment: ""), systemImage: aiAnalysis.isEmpty ? "sparkles" : "arrow.clockwise")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .disabled(isGeneratingAnalysis || filteredEntries.isEmpty)
            }
            
            if isGeneratingAnalysis {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                        .tint(Color.accentColor)
                    
                    Text(NSLocalizedString("Analyzing your emotional patterns...", comment: ""))
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(.secondarySystemBackground).opacity(0.5))
                )
            } else if aiAnalysis.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary.opacity(0.5))
                    
                    Text(NSLocalizedString("Generate an AI-powered analysis of your mood patterns", comment: ""))
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(.secondarySystemBackground).opacity(0.5))
                )
            } else {
                ScrollView {
                    Text(aiAnalysis)
                        .font(.system(size: 14))
                        .lineSpacing(8)
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 400)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(.secondarySystemBackground).opacity(0.8),
                                    Color(.secondarySystemBackground).opacity(0.6)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.accentColor.opacity(0.3),
                                    Color.accentColor.opacity(0.1)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 5)
        )
    }
    
    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 64))
                .foregroundColor(.secondary.opacity(0.5))

            if entries.isEmpty {
                Text(NSLocalizedString("No diary entries found", comment: ""))
                    .font(.system(size: 24, weight: .medium))

                Text(NSLocalizedString("Start writing diary entries to see your mood analysis", comment: ""))
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            } else {
                Text(String(format: NSLocalizedString("No entries in %@", comment: ""), selectedPeriod.localizedName.lowercased()))
                    .font(.system(size: 24, weight: .medium))

                VStack(spacing: 12) {
                    Text(String(format: NSLocalizedString("You have %d total entries, but none in the selected time period.", comment: ""), entries.count))
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)

                    Text(NSLocalizedString("Try selecting a longer time period or write new entries.", comment: ""))
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .multilineTextAlignment(.center)

                // Show period selector buttons for quick access
                HStack(spacing: 12) {
                    ForEach(Period.allCases, id: \.self) { period in
                        Button(period.localizedName) {
                            selectedPeriod = period
                        }
                        .buttonStyle(.bordered)
                        .disabled(selectedPeriod == period)
                    }
                }
                .padding(.top, 16)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 400)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.secondarySystemBackground).opacity(0.5))
        )
    }
    
    // MARK: - Helper Views
    
    @Namespace private var periodSelectorNamespace
    
    private var currentStreak: Int {
        var streak = 0
        let calendar = Calendar.current
        var currentDate = Date()
        
        for _ in 0..<365 {
            let hasEntry = entries.contains { entry in
                calendar.isDate(entry.date ?? Date(), inSameDayAs: currentDate)
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
    
    private func moodName(for mood: Int) -> String {
        switch mood {
        case 1: return NSLocalizedString("Very Low", comment: "")
        case 2: return NSLocalizedString("Low", comment: "")
        case 3: return NSLocalizedString("Neutral", comment: "")
        case 4: return NSLocalizedString("Good", comment: "")
        case 5: return NSLocalizedString("Excellent", comment: "")
        default: return NSLocalizedString("Unknown", comment: "")
        }
    }
    
    private func generateAIAnalysis() {
        guard !filteredEntries.isEmpty else {
            aiAnalysis = NSLocalizedString("No diary entries available for analysis.", comment: "")
            return
        }
        
        guard AppSecrets.isValidKey else {
            aiAnalysis = NSLocalizedString("API configuration error. Please check your settings.", comment: "")
            return
        }
        isGeneratingAnalysis = true
        aiAnalysis = ""
        
        Task {
            let entriesToAnalyze = Array(filteredEntries.prefix(30))
            let dateRange = Date.distantPast...Date.distantFuture
            
            await ReportGenerationService.generateReport(from: entriesToAnalyze, dateRange: dateRange) { chunk in
                DispatchQueue.main.async {
                    self.aiAnalysis += chunk
                }
            }
            
            await MainActor.run {
                isGeneratingAnalysis = false
                if aiAnalysis.isEmpty {
                    aiAnalysis = NSLocalizedString("Unable to generate analysis at this time. Please try again.", comment: "")
                }
            }
        }
    }
}

// MARK: - Supporting Views

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    let trend: Double?
    
    @State private var isHovered = false
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundColor(color)
                    .scaleEffect(isHovered ? 1.1 : 1.0)
                
                Spacer()
                
                if let trend = trend {
                    Image(systemName: trend > 0 ? "arrow.up.right" : trend < 0 ? "arrow.down.right" : "arrow.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(trend > 0 ? .green : trend < 0 ? .red : .orange)
                }
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                
                Text(title)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))
                .shadow(color: isHovered ? color.opacity(0.2) : .clear, radius: 8, x: 0, y: 4)
        )
        .onHover { hovering in
            withAnimation(.spring(response: 0.3)) {
                isHovered = hovering
            }
        }
    }
}

struct MoodPatternCard: View {
    let mood: Int
    let entries: [DiaryEntry]
    let totalEntries: Int
    let isSelected: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    private var percentage: Double {
        guard totalEntries > 0 else { return 0 }
        return Double(entries.count) / Double(totalEntries) * 100
    }
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                // Mood color indicator with percentage
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.moodSpectrum(value: Double(mood - 1) / 4.0))
                        .frame(width: 80, height: 80)
                    
                    Text("\(Int(percentage))%")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                }
                .scaleEffect(isHovered ? 1.1 : 1.0)
                
                VStack(spacing: 4) {
                    Text("\(entries.count)")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    
                    Text(moodName(for: mood))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 180)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color(.secondarySystemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.3)) {
                isHovered = hovering
            }
        }
    }
    
    private func moodName(for mood: Int) -> String {
        switch mood {
        case 1: return NSLocalizedString("Very Low", comment: "")
        case 2: return NSLocalizedString("Low", comment: "")
        case 3: return NSLocalizedString("Neutral", comment: "")
        case 4: return NSLocalizedString("Good", comment: "")
        case 5: return NSLocalizedString("Excellent", comment: "")
        default: return NSLocalizedString("Unknown", comment: "")
        }
    }
}

struct EntryPreviewCard: View {
    let entry: DiaryEntry
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Circle()
                    .fill(entry.moodColor)
                    .frame(width: 8, height: 8)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.summary ?? entry.content ?? "")
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .foregroundColor(.primary)
                    
                    Text(entry.formattedDate)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .opacity(isHovered ? 1 : 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground).opacity(isHovered ? 1 : 0.5))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.3)) {
                isHovered = hovering
            }
        }
    }
}

struct MoodStatistics {
    let average: Double
    let highest: Double
    let lowest: Double
    let trend: Double
    let volatility: Double
}
#endif