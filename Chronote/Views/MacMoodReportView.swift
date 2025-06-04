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
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)])
    private var entries: FetchedResults<DiaryEntry>
    
    enum Period: String, CaseIterable {
        case week = "Week"
        case month = "Month"
        case year = "Year"
        case all = "All Time"
        
        var days: Int {
            switch self {
            case .week: return 7
            case .month: return 30
            case .year: return 365
            case .all: return Int.max
            }
        }
    }
    
    var filteredEntries: [DiaryEntry] {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -selectedPeriod.days, to: Date()) ?? Date()
        return entries.filter { entry in
            return selectedPeriod == .all || entry.date >= cutoffDate
        }
    }
    
    var moodData: [(date: Date, mood: Double)] {
        Dictionary(grouping: filteredEntries) { entry in
            Calendar.current.startOfDay(for: entry.date)
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
                    Text("Mood Report")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Spacer()
                    
                    Picker("Period", selection: $selectedPeriod) {
                        ForEach(Period.allCases, id: \.self) { period in
                            Text(period.rawValue).tag(period)
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
                        value: "\(currentStreak) days",
                        icon: "flame.fill",
                        color: .red
                    )
                }
                .padding(.horizontal)
                
                // Mood trend chart
                VStack(alignment: .leading) {
                    Text("Mood Trend")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .padding(.horizontal)
                    
                    if moodData.isEmpty {
                        Text("No data available for the selected period")
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
                    Text("Mood Distribution")
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
                        Text("Entries with Mood \(selectedMood)")
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
                
                Spacer(minLength: 40)
            }
        }
    }
    
    private var mostCommonMoodText: String {
        guard let mostCommon = moodDistribution.max(by: { $0.value < $1.value }) else { return "N/A" }
        return "Mood \(mostCommon.key)"
    }
    
    private var currentStreak: Int {
        var streak = 0
        let calendar = Calendar.current
        var currentDate = Date()
        
        for _ in 0..<365 {
            let hasEntry = filteredEntries.contains { entry in
                return calendar.isDate(entry.date, inSameDayAs: currentDate)
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