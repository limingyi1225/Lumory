//
//  MacCalendarView.swift
//  Lumory
//
//  Created by Assistant on 6/3/25.
//

import SwiftUI
import CoreData

#if targetEnvironment(macCatalyst)
struct MacCalendarView: View {
    @Binding var selectedDate: Date
    @State private var displayedMonth = Date()
    @State private var selectedEntry: DiaryEntry?
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)])
    private var entries: FetchedResults<DiaryEntry>
    
    private let calendar = Calendar.current
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()
    
    var body: some View {
        HStack(spacing: 0) {
            // Calendar view
            VStack(spacing: 0) {
                // Month navigation
                HStack {
                    Button(action: previousMonth) {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
                    
                    Spacer()
                    
                    Text(dateFormatter.string(from: displayedMonth))
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Spacer()
                    
                    Button(action: nextMonth) {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                }
                .padding()
                
                // Calendar grid
                CalendarGrid(
                    displayedMonth: displayedMonth,
                    selectedDate: $selectedDate,
                    entries: entries
                )
                .padding(.horizontal)
                
                Spacer()
            }
            .frame(minWidth: 400)
            
            Divider()
            
            // Entry list for selected date
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Text(formatDateForDisplay(selectedDate))
                        .font(.title3)
                        .fontWeight(.medium)
                    
                    Spacer()
                    
                    Button(action: { /* New entry for this date */ }) {
                        Label("New Entry", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
                
                Divider()
                
                // Entries for selected date
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(entriesForDate(selectedDate)) { entry in
                            MacCalendarEntryRow(entry: entry, isSelected: selectedEntry?.id == entry.id)
                                .onTapGesture {
                                    selectedEntry = entry
                                }
                        }
                        
                        if entriesForDate(selectedDate).isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "note.text")
                                    .font(.system(size: 40))
                                    .foregroundColor(.secondary)
                                
                                Text("No entries for this date")
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                        }
                    }
                    .padding()
                }
            }
            .frame(minWidth: 300)
        }
        .sheet(item: $selectedEntry) { entry in
            DiaryDetailView(entry: entry)
                .environment(\.managedObjectContext, viewContext)
                .frame(minWidth: 600, minHeight: 500)
        }
    }
    
    private func previousMonth() {
        withAnimation {
            displayedMonth = calendar.date(byAdding: .month, value: -1, to: displayedMonth) ?? displayedMonth
        }
    }
    
    private func nextMonth() {
        withAnimation {
            displayedMonth = calendar.date(byAdding: .month, value: 1, to: displayedMonth) ?? displayedMonth
        }
    }
    
    private func entriesForDate(_ date: Date) -> [DiaryEntry] {
        entries.filter { entry in
            return calendar.isDate(entry.date, inSameDayAs: date)
        }
    }
    
    private func formatDateForDisplay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

struct CalendarGrid: View {
    let displayedMonth: Date
    @Binding var selectedDate: Date
    let entries: FetchedResults<DiaryEntry>
    
    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible()), count: 7)
    private let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    
    var body: some View {
        VStack(spacing: 16) {
            // Weekday headers
            HStack {
                ForEach(weekdays, id: \.self) { day in
                    Text(day)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            
            // Calendar days
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(getDaysInMonth(), id: \.self) { date in
                    if let date = date {
                        CalendarDayCell(
                            date: date,
                            isSelected: calendar.isDate(date, inSameDayAs: selectedDate),
                            isToday: calendar.isDateInToday(date),
                            entries: entriesForDate(date),
                            action: { selectedDate = date }
                        )
                    } else {
                        Color.clear
                            .frame(height: 60)
                    }
                }
            }
        }
    }
    
    private func getDaysInMonth() -> [Date?] {
        guard let monthRange = calendar.range(of: .day, in: .month, for: displayedMonth),
              let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth))
        else { return [] }
        
        let firstWeekday = calendar.component(.weekday, from: firstOfMonth) - 1
        var days: [Date?] = Array(repeating: nil, count: firstWeekday)
        
        for day in monthRange {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: firstOfMonth) {
                days.append(date)
            }
        }
        
        // Fill remaining days to complete the grid
        while days.count % 7 != 0 {
            days.append(nil)
        }
        
        return days
    }
    
    private func entriesForDate(_ date: Date) -> [DiaryEntry] {
        entries.filter { entry in
            return calendar.isDate(entry.date, inSameDayAs: date)
        }
    }
}

struct CalendarDayCell: View {
    let date: Date
    let isSelected: Bool
    let isToday: Bool
    let entries: [DiaryEntry]
    let action: () -> Void
    
    @State private var isHovered = false
    
    private var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter
    }
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(dayFormatter.string(from: date))
                    .font(.system(size: 16, weight: isToday ? .bold : .regular))
                    .foregroundColor(isToday ? .accentColor : .primary)
                
                if !entries.isEmpty {
                    HStack(spacing: 2) {
                        ForEach(entries.prefix(3)) { entry in
                            Circle()
                                .fill(entry.moodColor)
                                .frame(width: 6, height: 6)
                        }
                        
                        if entries.count > 3 {
                            Text("+\(entries.count - 3)")
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(height: 60)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.2) : 
                          (isHovered ? Color(UIColor.secondarySystemBackground) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isToday ? Color.accentColor : Color.clear,
                        lineWidth: 2
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
}

struct MacCalendarEntryRow: View {
    let entry: DiaryEntry
    let isSelected: Bool
    @State private var isHovered = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(entry.moodColor)
                    .frame(width: 16, height: 16)
                
                Text(formatTime(entry.date))
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
            }
            
            Text(entry.content ?? "")
                .font(.system(size: 13))
                .lineLimit(3)
                .foregroundColor(.primary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : 
                      (isHovered ? Color(UIColor.secondarySystemBackground) : Color.clear))
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
    
    private func formatTime(_ date: Date?) -> String {
        guard let date = date else { return "" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
#endif