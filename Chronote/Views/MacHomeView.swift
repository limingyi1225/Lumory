//
//  MacHomeView.swift
//  Lumory
//
//  Created by Assistant on 6/3/25.
//

import SwiftUI
import CoreData
#if targetEnvironment(macCatalyst)
import UIKit
#endif

#if targetEnvironment(macCatalyst)
struct MacHomeView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var diaryStore = DiaryStore()
    @State private var searchText = ""
    @State private var selectedEntry: DiaryEntry?
    @State private var isShowingNewEntry = false
    @State private var isRecording = false
    @State private var sortOrder: SortOrder = .dateDescending
    @State private var filterMood: Int? = nil
    
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)],
        animation: .default)
    private var entries: FetchedResults<DiaryEntry>
    
    enum SortOrder: String, CaseIterable {
        case dateDescending = "Newest First"
        case dateAscending = "Oldest First"
        case moodDescending = "Happiest First"
        case moodAscending = "Saddest First"
        
        var sortDescriptor: NSSortDescriptor {
            switch self {
            case .dateDescending:
                return NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)
            case .dateAscending:
                return NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: true)
            case .moodDescending:
                return NSSortDescriptor(keyPath: \DiaryEntry.moodValue, ascending: false)
            case .moodAscending:
                return NSSortDescriptor(keyPath: \DiaryEntry.moodValue, ascending: true)
            }
        }
    }
    
    var filteredEntries: [DiaryEntry] {
        let filtered = entries.filter { entry in
            let matchesSearch = searchText.isEmpty || 
                (entry.content?.localizedCaseInsensitiveContains(searchText) ?? false)
            let matchesMood = filterMood == nil || Int(entry.moodValue * 4 + 1) == filterMood!
            return matchesSearch && matchesMood
        }
        
        return filtered.sorted { entry1, entry2 in
            switch sortOrder {
            case .dateDescending:
                return entry1.date > entry2.date
            case .dateAscending:
                return entry1.date < entry2.date
            case .moodDescending:
                return entry1.moodValue > entry2.moodValue
            case .moodAscending:
                return entry1.moodValue < entry2.moodValue
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 16) {
                // Search field
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search entries...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(8)
                .frame(maxWidth: 300)
                
                // Filter controls
                Picker("Sort", selection: $sortOrder) {
                    ForEach(SortOrder.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .frame(width: 150)
                
                Picker("Mood", selection: $filterMood) {
                    Text("All Moods").tag(nil as Int?)
                    ForEach(1...5, id: \.self) { mood in
                        HStack {
                            Circle()
                                .fill(Color.moodSpectrum(value: Double(mood - 1) / 4.0))
                                .frame(width: 10, height: 10)
                            Text("Mood \(mood)")
                        }
                        .tag(mood as Int?)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .frame(width: 120)
                
                Spacer()
                
                // Action buttons
                Button(action: { isShowingNewEntry = true }) {
                    Label("New Entry", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("n", modifiers: .command)
                
                Button(action: toggleRecording) {
                    Label(isRecording ? "Stop Recording" : "Record", 
                          systemImage: isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .foregroundColor(isRecording ? .red : .primary)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("r", modifiers: .command)
            }
            .padding()
            .background(Color(UIColor.systemBackground))
            
            Divider()
            
            // Entry list
            if filteredEntries.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: searchText.isEmpty ? "note.text" : "magnifyingglass")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)
                    
                    Text(searchText.isEmpty ? "No entries yet" : "No matching entries")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    
                    if searchText.isEmpty {
                        Text("Create your first entry to get started")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredEntries) { entry in
                            MacEntryRow(entry: entry, isSelected: selectedEntry?.id == entry.id)
                                .onTapGesture {
                                    selectedEntry = entry
                                }
                                .contextMenu {
                                    Button {
                                        selectedEntry = entry
                                        // Navigate to detail view for editing
                                    } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    
                                    Button {
                                        duplicateEntry(entry)
                                    } label: {
                                        Label("Duplicate", systemImage: "doc.on.doc")
                                    }
                                    
                                    Divider()
                                    
                                    Button {
                                        exportEntry(entry)
                                    } label: {
                                        Label("Export as Text...", systemImage: "square.and.arrow.up")
                                    }
                                    
                                    Button {
                                        copyToClipboard(entry)
                                    } label: {
                                        Label("Copy", systemImage: "doc.on.clipboard")
                                    }
                                    
                                    Divider()
                                    
                                    Button(role: .destructive) {
                                        deleteEntry(entry)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .padding()
                }
            }
        }
        .focusedSceneValue(\.selectedEntry, $selectedEntry)
        .focusedSceneValue(\.isShowingNewEntry, $isShowingNewEntry)
        .focusedSceneValue(\.searchText, $searchText)
        .sheet(isPresented: $isShowingNewEntry) {
            MacNewEntryView(isPresented: $isShowingNewEntry)
                .environment(\.managedObjectContext, viewContext)
        }
        .sheet(item: $selectedEntry) { entry in
            DiaryDetailView(entry: entry)
                .environment(\.managedObjectContext, viewContext)
                .frame(minWidth: 600, minHeight: 500)
        }
        .onReceive(NotificationCenter.default.publisher(for: .startRecording)) { _ in
            if !isRecording {
                toggleRecording()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stopRecording)) { _ in
            if isRecording {
                toggleRecording()
            }
        }
    }
    
    private func toggleRecording() {
        isRecording.toggle()
        // Implement recording logic
    }
    
    private func deleteEntry(_ entry: DiaryEntry) {
        withAnimation {
            viewContext.delete(entry)
            try? viewContext.save()
        }
    }
    
    private func duplicateEntry(_ entry: DiaryEntry) {
        let newEntry = DiaryEntry(context: viewContext)
        newEntry.text = entry.text
        newEntry.moodValue = entry.moodValue
        newEntry.date = Date()
        newEntry.summary = entry.summary
        newEntry.id = UUID()
        
        try? viewContext.save()
    }
    
    private func exportEntry(_ entry: DiaryEntry) {
        let text = """
        Date: \(entry.formattedDate)
        Mood: \(Int(entry.moodValue * 4 + 1))/5
        
        \(entry.text)
        """
        
        // Use UIDocumentPickerViewController for Mac Catalyst
        let fileName = "diary-\(entry.date.formatted(date: .abbreviated, time: .omitted)).txt"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        do {
            try text.write(to: tempURL, atomically: true, encoding: .utf8)
            
            // Note: In a real implementation, you would present a UIDocumentPickerViewController
            // For now, just save to Documents folder
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let destinationURL = documentsPath.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.copyItem(at: tempURL, to: destinationURL)
            print("Exported to: \(destinationURL)")
        } catch {
            print("Export failed: \(error)")
        }
    }
    
    private func copyToClipboard(_ entry: DiaryEntry) {
        // Use UIPasteboard for Mac Catalyst
        UIPasteboard.general.string = entry.text
    }
}

struct MacEntryRow: View {
    let entry: DiaryEntry
    let isSelected: Bool
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 12) {
            // Mood indicator
            Circle()
                .fill(entry.moodColor)
                .frame(width: 24, height: 24)
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                )
            
            // Content
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.content ?? "")
                    .font(.system(size: 14))
                    .lineLimit(2)
                    .foregroundColor(.primary)
                
                HStack {
                    Text(entry.formattedDate)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    
                    if let photos = entry.photos, !photos.isEmpty {
                        Spacer()
                        Label("\(photos.count)", systemImage: "photo")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
            
            // Hover actions
            if isHovered {
                HStack(spacing: 8) {
                    Button(action: { /* Edit */ }) {
                        Image(systemName: "pencil")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: { /* Delete */ }) {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
                .transition(.opacity.combined(with: .scale))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
}
#endif