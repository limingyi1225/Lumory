//
//  MacNavigationView.swift
//  Lumory
//
//  Created by Assistant on 6/3/25.
//

import SwiftUI

#if targetEnvironment(macCatalyst)
struct MacNavigationView: View {
    @State private var selectedView: NavigationItem = .home
    @State private var selectedEntry: DiaryEntry?
    @State private var isShowingNewEntry = false
    @State private var searchText = ""
    @State private var selectedDate = Date()
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)],
        animation: .default)
    private var entries: FetchedResults<DiaryEntry>
    
    enum NavigationItem: String, CaseIterable {
        case home = "Home"
        case calendar = "Calendar"
        case moodReport = "Mood Report"
        
        var icon: String {
            switch self {
            case .home: return "house.fill"
            case .calendar: return "calendar"
            case .moodReport: return "chart.line.uptrend.xyaxis"
            }
        }
    }
    
    var body: some View {
        NavigationView {
            HStack(spacing: 0) {
                // Sidebar
                sidebarView
                    .frame(width: 280)
                    .background(Color(UIColor.secondarySystemBackground))
                
                Divider()
                
                // Content area
                contentView
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .sheet(isPresented: $isShowingNewEntry) {
            MacNewEntryView(isPresented: $isShowingNewEntry)
                .frame(minWidth: 600, minHeight: 400)
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToHome)) { _ in
            selectedView = .home
            selectedEntry = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToCalendar)) { _ in
            selectedView = .calendar
            selectedEntry = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToMoodReport)) { _ in
            selectedView = .moodReport
            selectedEntry = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
            // Focus search field
        }
    }
    
    @ViewBuilder
    private var sidebarView: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search entries...", text: $searchText)
                    .textFieldStyle(PlainTextFieldStyle())
            }
            .padding(12)
            .background(Color(UIColor.tertiarySystemBackground))
            .cornerRadius(8)
            .padding()
            
            // Navigation items
            VStack(alignment: .leading, spacing: 2) {
                Text("Navigation")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                
                ForEach(NavigationItem.allCases, id: \.self) { item in
                    navigationButton(for: item)
                }
            }
            .padding(.bottom)
            
            Divider()
                .padding(.horizontal)
            
            // Recent entries
            VStack(alignment: .leading, spacing: 2) {
                Text("Recent Entries")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(entries.prefix(10)) { entry in
                            recentEntryRow(entry)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
            
            Spacer()
            
            // New entry button
            Button(action: { isShowingNewEntry = true }) {
                Label("New Entry", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
    }
    
    @ViewBuilder
    private func navigationButton(for item: NavigationItem) -> some View {
        Button(action: { selectedView = item }) {
            Label(item.rawValue, systemImage: item.icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .buttonStyle(PlainButtonStyle())
        .background(selectedView == item ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(6)
        .padding(.horizontal, 8)
    }
    
    @ViewBuilder
    private func recentEntryRow(_ entry: DiaryEntry) -> some View {
        Button(action: { selectedEntry = entry }) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.content ?? "")
                    .lineLimit(1)
                    .font(.system(size: 13))
                
                HStack {
                    Text(entry.formattedDate)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    MoodIndicator(mood: Int(entry.moodValue * 4 + 1))
                        .frame(width: 16, height: 16)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .buttonStyle(PlainButtonStyle())
        .background(selectedEntry?.id == entry.id ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(6)
    }
    
    @ViewBuilder
    private var contentView: some View {
        if let entry = selectedEntry {
            DiaryDetailView(entry: entry)
                .id(entry.id)
                .focusedSceneValue(\.selectedEntry, $selectedEntry)
        } else {
            // Show the selected navigation view
            switch selectedView {
            case .home:
                MacHomeView()
                    .focusedSceneValue(\.selectedEntry, $selectedEntry)
                    .focusedSceneValue(\.isShowingNewEntry, $isShowingNewEntry)
                    .focusedSceneValue(\.searchText, $searchText)
            case .calendar:
                MacCalendarView(selectedDate: $selectedDate)
                    .focusedSceneValue(\.selectedDate, $selectedDate)
            case .moodReport:
                MacMoodReportView()
            }
        }
    }
}

// Mood indicator for sidebar
struct MoodIndicator: View {
    let mood: Int
    
    var body: some View {
        Circle()
            .fill(Color.moodSpectrum(value: Double(mood - 1) / 4.0))
            .overlay(
                Circle()
                    .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
            )
    }
}
#endif