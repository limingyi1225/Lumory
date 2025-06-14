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
    @State private var isShowingSettings = false
    @State private var searchText = ""
    @State private var selectedDate = Date()
    @State private var databaseRecreationObserver: NSObjectProtocol?
    @Environment(\.managedObjectContext) private var viewContext
    @AppStorage("appLanguage") private var appLanguage: String = "en"
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)],
        animation: nil)
    private var entries: FetchedResults<DiaryEntry>
    
    enum NavigationItem: String, CaseIterable {
        case home
        case calendar
        case moodAnalysis
        
        var title: String {
            switch self {
            case .home: return NSLocalizedString("主页", comment: "")
            case .calendar: return NSLocalizedString("日历", comment: "")
            case .moodAnalysis: return NSLocalizedString("心情分析", comment: "")
            }
        }
        
        var icon: String {
            switch self {
            case .home: return "house.fill"
            case .calendar: return "calendar"
            case .moodAnalysis: return "chart.line.uptrend.xyaxis"
            }
        }
    }
    
    var body: some View {
        NavigationSplitView {
            sidebarView
        } detail: {
            VStack(spacing: 0) {
                // Custom toolbar
                HStack {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                            .font(.system(size: 14))
                        
                        TextField(NSLocalizedString("搜索日记...", comment: ""), text: $searchText)
                            .textFieldStyle(.plain)
                        
                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                    .font(.system(size: 14))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(UIColor.tertiarySystemFill))
                    .cornerRadius(8)
                    .frame(maxWidth: 300)
                    
                    Spacer()
                    
                    Button(action: {
                        selectedView = .home
                        selectedEntry = nil
                    }) {
                        Image(systemName: "plus.circle")
                    }
                    .help("New Entry")
                    .disabled(selectedView == .home && selectedEntry == nil)
                    
                    Button(action: { isShowingSettings = true }) {
                        Image(systemName: "gearshape")
                    }
                    .help("Settings")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(UIColor.systemBackground))
                .overlay(Divider(), alignment: .bottom)
                
                // Content
                contentView
                    .navigationBarHidden(true)
            }
        }
        .onAppear {
            print("[MacNavigationView] View appeared successfully")
            setupDatabaseRecreationObserver()
        }
        .onDisappear {
            removeDatabaseRecreationObserver()
        }
        .sheet(isPresented: $isShowingSettings) {
            MacSettingsView()
                .frame(minWidth: 600, minHeight: 500)
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
            selectedView = .moodAnalysis
            selectedEntry = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
            // Focus search field
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { _ in
            isShowingSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .diaryEntryDeleted)) { notification in
            if let deletedId = notification.object as? UUID,
               selectedEntry?.id == deletedId {
                selectedEntry = nil
            }
        }
    }
    
    @ViewBuilder
    private var sidebarView: some View {
        VStack(spacing: 0) {
            
            // Navigation items
            VStack(alignment: .leading, spacing: 2) {
                Text(NSLocalizedString("导航", comment: ""))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                    .padding(.top, 16)
                
                ForEach(NavigationItem.allCases, id: \.self) { item in
                    navigationButton(for: item)
                }
            }
            .padding(.bottom)
            
            Divider()
                .padding(.horizontal)
            
            // All entries with sections by date
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(NSLocalizedString("All Entries", comment: ""))
                        .font(.headline)
                        .fontWeight(.semibold)
                    Spacer()
                    Text("\(filteredEntriesCount)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.secondary.opacity(0.2))
                        )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                
                ScrollView {
                    LazyVStack(spacing: 8, pinnedViews: .sectionHeaders) {
                        ForEach(groupedEntries, id: \.key) { dateKey, dateEntries in
                            Section(header: dateHeaderView(for: dateKey)) {
                                ForEach(dateEntries) { entry in
                                    entryRow(entry)
                                        .id(entry.id)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
            
            Spacer()
            
        }
    }
    
    @ViewBuilder
    private func navigationButton(for item: NavigationItem) -> some View {
        Button(action: { 
            selectedView = item
            selectedEntry = nil
        }) {
            Label(item.title, systemImage: item.icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .background(selectedView == item && selectedEntry == nil ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(6)
        .padding(.horizontal, 8)
    }
    
    private var filteredEntriesCount: Int {
        if searchText.isEmpty {
            return entries.count
        } else {
            return entries.filter { entry in
                let text = (entry.text ?? "").lowercased()
                let summary = (entry.summary ?? "").lowercased()
                let searchLower = searchText.lowercased()
                return text.contains(searchLower) || summary.contains(searchLower)
            }.count
        }
    }
    
    // Grouped entries by date - optimized with caching
    private var groupedEntries: [(key: Date, value: [DiaryEntry])] {
        let filtered: [DiaryEntry]
        if searchText.isEmpty {
            filtered = Array(entries)
        } else {
            let searchResults = entries.filter { entry in
                let text = (entry.text ?? "").lowercased()
                let summary = (entry.summary ?? "").lowercased()
                let searchLower = searchText.lowercased()
                return text.contains(searchLower) || summary.contains(searchLower)
            }
            filtered = Array(searchResults)
        }
        
        let grouped = Dictionary(grouping: filtered) { entry in
            Calendar.current.startOfDay(for: entry.wrappedDate)
        }
        return grouped.sorted { $0.key > $1.key }
    }
    
    @ViewBuilder
    private func dateHeaderView(for date: Date) -> some View {
        HStack {
            Text(formatDateHeader(date))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
    
    @ViewBuilder
    private func entryRow(_ entry: DiaryEntry) -> some View {
        Button(action: { selectedEntry = entry }) {
            HStack(spacing: 12) {
                // Time
                Text(formatTime(entry.wrappedDate))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .leading)
                
                // Mood indicator
                Circle()
                    .fill(entry.moodColor)
                    .frame(width: 8, height: 8)
                
                // Content preview
                VStack(alignment: .leading, spacing: 2) {
                    if let summary = entry.wrappedSummary, !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                    } else {
                        Text(entry.content ?? "")
                            .font(.system(size: 13))
                            .lineLimit(1)
                    }
                }
                
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selectedEntry?.id == entry.id ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(selectedEntry?.id == entry.id ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }
    
    private func formatDateHeader(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: appLanguage)
        
        if Calendar.current.isDateInToday(date) {
            return NSLocalizedString("今天", comment: "")
        } else if Calendar.current.isDateInYesterday(date) {
            return NSLocalizedString("昨天", comment: "")
        } else if Calendar.current.isDate(date, equalTo: Date(), toGranularity: .weekOfYear) {
            formatter.dateFormat = "EEEE"
            return formatter.string(from: date)
        } else {
            if appLanguage.hasPrefix("zh") {
                formatter.dateFormat = "M月d日 EEEE"
            } else {
                formatter.dateStyle = .medium
            }
            return formatter.string(from: date)
        }
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: appLanguage)
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    @ViewBuilder
    private var contentView: some View {
        // Main content for NavigationSplitView detail
        if let entry = selectedEntry {
            DiaryDetailView(entry: entry, showUnifiedToolbar: true)
                .id(entry.id)
                .focusedSceneValue(\.selectedEntry, $selectedEntry)
                .onDisappear {
                    // Check if entry still exists
                    if entry.managedObjectContext == nil {
                        selectedEntry = nil
                    }
                }
        } else {
            // Show the selected navigation view
            switch selectedView {
            case .home:
                MacHomeView()
                    .focusedSceneValue(\.selectedEntry, $selectedEntry)
            case .calendar:
                MacCalendarView(selectedDate: $selectedDate)
                    .focusedSceneValue(\.selectedDate, $selectedDate)
            case .moodAnalysis:
                MacMoodAnalysisView()
                    .onAppear {
                        NSLog("[MacNavigationView] MacMoodAnalysisView appeared")
                        print("🔍 MacMoodAnalysisView is being displayed")
                    }
            }
        }
    }
    
    // MARK: - Database Recreation Observer
    
    private func setupDatabaseRecreationObserver() {
        databaseRecreationObserver = NotificationCenter.default.addObserver(
            forName: .databaseRecreated,
            object: nil,
            queue: .main
        ) { _ in
            print("[MacNavigationView] Database recreated notification received")
            handleDatabaseRecreation()
        }
    }
    
    private func removeDatabaseRecreationObserver() {
        if let observer = databaseRecreationObserver {
            NotificationCenter.default.removeObserver(observer)
            databaseRecreationObserver = nil
        }
    }
    
    private func handleDatabaseRecreation() {
        // Clear any references to deleted objects
        selectedEntry = nil
        
        // Reset to home view
        selectedView = .home
        
        // Clear search
        searchText = ""
        
        // Force Core Data to refresh
        viewContext.refreshAllObjects()
        
        print("[MacNavigationView] Database recreation handled - state cleared and context refreshed")
    }
}

// Mood indicator for sidebar
struct SidebarMoodIndicator: View {
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
