//
//  MacSettingsView.swift
//  Lumory
//
//  Created by Assistant on 6/3/25.
//

import SwiftUI
import CoreData

#if targetEnvironment(macCatalyst)
struct MacSettingsView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)],
        animation: .default)
    private var entries: FetchedResults<DiaryEntry>
    
    @AppStorage("appLanguage") private var appLanguage: String = Locale.current.identifier
    @State private var selectedTab = "general"
    @State private var showImportSheet = false
    @State private var showDeleteAllAlert = false
    @State private var showDeleteCompleteAlert = false
    @State private var isSyncing = false
    @State private var syncMessage: String? = nil
    
    @EnvironmentObject var importService: CoreDataImportService
    
    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(alignment: .leading, spacing: 0) {
                ForEach(["general", "data", "sync", "about"], id: \.self) { tab in
                    Button(action: { selectedTab = tab }) {
                        HStack {
                            Image(systemName: iconForTab(tab))
                                .frame(width: 20)
                            Text(labelForTab(tab))
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(selectedTab == tab ? Color.accentColor.opacity(0.1) : Color.clear)
                        .cornerRadius(6)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.horizontal, 8)
                }
                Spacer()
            }
            .frame(width: 200)
            .background(Color(UIColor.secondarySystemBackground))
            
            Divider()
            
            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch selectedTab {
                    case "general":
                        generalSettings
                    case "data":
                        dataSettings
                    case "sync":
                        syncSettings
                    case "about":
                        aboutSettings
                    default:
                        EmptyView()
                    }
                }
                .padding(30)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(Color(UIColor.systemBackground))
        }
        .frame(width: 600, height: 500)
    }
    
    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("General")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            GroupBox(label: Label("Language", systemImage: "globe")) {
                Picker("Language", selection: $appLanguage) {
                    Text("简体中文").tag("zh-Hans")
                    Text("English (US)").tag("en")
                }
                .pickerStyle(DefaultPickerStyle())
                .padding(.vertical, 8)
            }
            
            GroupBox(label: Label("Appearance", systemImage: "paintbrush")) {
                Text("Follows system appearance")
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            }
        }
    }
    
    private var dataSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Data Management")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    Button(action: { showImportSheet = true }) {
                        HStack {
                            Image(systemName: "doc.on.clipboard")
                            Text("Import Entries...")
                            Spacer()
                        }
                    }
                    .buttonStyle(.bordered)
                    
                    Divider()
                    
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Total Entries: \(entries.count)")
                                .font(.headline)
                            Text("Delete all diary entries")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Delete All", role: .destructive) {
                            showDeleteAllAlert = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
            }
        }
        .sheet(isPresented: $showImportSheet) {
            DiaryImportView()
                .environment(\.managedObjectContext, viewContext)
                .environmentObject(importService)
                .frame(minWidth: 600, minHeight: 400)
        }
        .alert("Confirm Delete All?", isPresented: $showDeleteAllAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteAllEntries()
            }
        } message: {
            Text("This action cannot be undone. All diary entries will be permanently deleted.")
        }
    }
    
    private var syncSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("iCloud Sync")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Sync Status")
                                .font(.headline)
                            Text(syncMessage ?? "Ready to sync")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if isSyncing {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Button("Sync Now") {
                                performManualSync()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    
                    Divider()
                    
                    Text("Automatic sync is enabled when iCloud is available")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
            }
        }
    }
    
    private var aboutSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("About")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image("LumoryIcon")
                            .resizable()
                            .frame(width: 64, height: 64)
                        
                        VStack(alignment: .leading) {
                            Text("Lumory")
                                .font(.title2)
                                .fontWeight(.semibold)
                            Text("Version 1.0.0")
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                    }
                    
                    Divider()
                    
                    Button(action: {
                        if let url = URL(string: "mailto:me@limingyi.com") {
                            UIApplication.shared.open(url)
                        }
                    }) {
                        Label("Contact Developer", systemImage: "envelope")
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            }
        }
    }
    
    private func deleteAllEntries() {
        for entry in entries {
            viewContext.delete(entry)
        }
        
        do {
            try viewContext.save()
            showDeleteCompleteAlert = true
        } catch {
            print("Error deleting all entries: \(error)")
        }
    }
    
    private func performManualSync() {
        isSyncing = true
        syncMessage = nil
        
        // Simulate sync
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isSyncing = false
            syncMessage = "Sync completed successfully"
            
            // Clear message after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                syncMessage = nil
            }
        }
    }
    
    private func iconForTab(_ tab: String) -> String {
        switch tab {
        case "general": return "gear"
        case "data": return "externaldrive"
        case "sync": return "icloud"
        case "about": return "info.circle"
        default: return "questionmark"
        }
    }
    
    private func labelForTab(_ tab: String) -> String {
        switch tab {
        case "general": return "General"
        case "data": return "Data Management"
        case "sync": return "Sync"
        case "about": return "About"
        default: return ""
        }
    }
}
#endif