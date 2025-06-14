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
    @Environment(\.dismiss) private var dismiss
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
    @State private var showDiagnosticSheet = false
    @State private var diagnosticResult: SyncDiagnosticResult? = nil
    @State private var isRunningDiagnostic = false
    
    @EnvironmentObject var importService: CoreDataImportService
    @EnvironmentObject var syncMonitor: CloudKitSyncMonitor
    
    var body: some View {
        VStack(spacing: 0) {
            // Title bar with close button
            HStack {
                Text(NSLocalizedString("Settings", comment: ""))
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding()
            .background(Color(UIColor.systemBackground))
            
            Divider()
            
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
        }
        .frame(width: 600, height: 500)
        .sheet(isPresented: $showDiagnosticSheet) {
            SyncDiagnosticView(result: diagnosticResult)
        }
    }
    
    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(NSLocalizedString("General", comment: ""))
                .font(.largeTitle)
                .fontWeight(.bold)
            
            GroupBox(label: Label(NSLocalizedString("Language", comment: ""), systemImage: "globe")) {
                Picker(NSLocalizedString("Language", comment: ""), selection: $appLanguage) {
                    Text("简体中文").tag("zh-Hans")
                    Text("English (US)").tag("en")
                }
                .pickerStyle(DefaultPickerStyle())
                .padding(.vertical, 8)
            }
            
            GroupBox(label: Label(NSLocalizedString("Appearance", comment: ""), systemImage: "paintbrush")) {
                Text(NSLocalizedString("Follows system appearance", comment: ""))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            }
        }
    }
    
    private var dataSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(NSLocalizedString("Data Management", comment: ""))
                .font(.largeTitle)
                .fontWeight(.bold)
            
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    Button(action: { showImportSheet = true }) {
                        HStack {
                            Image(systemName: "doc.on.clipboard")
                            Text(NSLocalizedString("Import Entries...", comment: ""))
                            Spacer()
                        }
                    }
                    .buttonStyle(.bordered)
                    
                    Divider()
                    
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(NSLocalizedString("Total Entries:", comment: "")) \(entries.count)")
                                .font(.headline)
                            Text(NSLocalizedString("Delete all diary entries", comment: ""))
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
                        Image(systemName: syncMonitor.syncStatus.iconName)
                            .foregroundColor(colorForSyncStatus(syncMonitor.syncStatus))
                        
                        VStack(alignment: .leading) {
                            Text("Sync Status")
                                .font(.headline)
                            Text(syncMonitor.syncStatus.displayName)
                                .font(.subheadline)
                                .foregroundColor(colorForSyncStatus(syncMonitor.syncStatus))
                        }
                        Spacer()
                        if syncMonitor.syncStatus == .syncing {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Button("Check Status") {
                                syncMonitor.checkCloudKitStatus()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    
                    if let errorMessage = syncMonitor.errorMessage {
                        Divider()
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(4)
                    }
                    
                    if let lastSync = syncMonitor.lastSyncDate {
                        Divider()
                        Text("Last synced: \(lastSync, style: .relative) ago")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    HStack {
                        Button("Force Sync") {
                            syncMonitor.forcSync()
                        }
                        .buttonStyle(.bordered)
                        .disabled(syncMonitor.syncStatus == .syncing)

                        Spacer()

                        Button("Run Diagnostic") {
                            runSyncDiagnostic()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isRunningDiagnostic)

                        if isRunningDiagnostic {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    }
                    
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("iCloud Sync Information")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Text("• Ensure you're signed in to iCloud on all devices")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text("• Sync happens automatically when network is available")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text("• CloudKit container: iCloud.com.Mingyi.Lumory")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Divider()
                    
                    // Backend health check
                    VStack(alignment: .leading, spacing: 8) {
                        Text("AI后端状态")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Text("后端URL: \(AppSecrets.backendURL)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        VStack(spacing: 8) {
                            HStack {
                                Button("测试后端连接") {
                                    Task {
                                        let (_, proxyMessage) = await BackendHealthCheck.testOpenAIProxy()
                                        print("[Backend Test] \(proxyMessage)")
                                    }
                                }
                                .buttonStyle(.bordered)
                                
                                Button("调试报告生成") {
                                    Task {
                                        await ReportTestHelper.debugReportGeneration()
                                    }
                                }
                                .buttonStyle(.bordered)
                                
                                Spacer()
                            }
                            
                            HStack {
                                Button("完整诊断") {
                                    Task {
                                        await DiagnosticHelper.runFullDiagnostic()
                                        DiagnosticHelper.checkCloudKitStatus()
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                
                                Button("UI测试") {
                                    Task {
                                        let result1 = await UITestHelper.testMacReportGeneration()
                                        print("[UI Test] Mac流式结果: \(result1)")
                                        
                                        let result2 = await UITestHelper.testSimpleReportGeneration()
                                        print("[UI Test] 简单版本结果: \(result2)")
                                    }
                                }
                                .buttonStyle(.bordered)
                                
                                Spacer()
                                
                                Text("用于诊断AI报告功能")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
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
            // Delete associated images
            entry.deleteAllImages()
            
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
        case "general": return NSLocalizedString("General", comment: "")
        case "data": return NSLocalizedString("Data Management", comment: "")
        case "sync": return NSLocalizedString("iCloud 同步", comment: "")
        case "about": return NSLocalizedString("About", comment: "")
        default: return ""
        }
    }
    
    private func colorForSyncStatus(_ status: CloudKitSyncMonitor.SyncStatus) -> Color {
        switch status {
        case .synced:
            return .green
        case .syncing:
            return .blue
        case .error, .notSignedIn:
            return .red
        case .networkUnavailable:
            return .orange
        case .unknown:
            return .secondary
        }
    }

    private func runSyncDiagnostic() {
        isRunningDiagnostic = true
        Task {
            let result = await SyncDiagnosticService.performDiagnostic()
            await MainActor.run {
                diagnosticResult = result
                isRunningDiagnostic = false
                showDiagnosticSheet = true
            }
        }
    }
}
#endif