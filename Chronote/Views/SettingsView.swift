import SwiftUI
import CoreData

struct SettingsView: View {
    @Binding var isSettingsOpen: Bool
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)],
        animation: .default)
    private var entries: FetchedResults<DiaryEntry>
    
    @AppStorage("appLanguage") private var appLanguage: String = Locale.current.identifier
    @State private var showImportSheet = false
    @State private var showDeleteAllAlert = false
    @State private var showDeleteCompleteAlert = false
    @State private var isSyncing = false
    @State private var syncMessage: String? = nil
    
    @EnvironmentObject var importService: CoreDataImportService

    var body: some View {
        #if targetEnvironment(macCatalyst)
        MacSettingsView()
            .environment(\.managedObjectContext, viewContext)
            .environmentObject(importService)
        #else
        NavigationStack {
            Form {
                Section(header: Text(NSLocalizedString("语言", comment: "Language")).textCase(nil)) {
                    Picker("", selection: $appLanguage) {
                        Text("简体中文").tag("zh-Hans")
                        Text("English (US)").tag("en")
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section(header: Text(NSLocalizedString("数据", comment: "Data")).textCase(nil)) {
                    Button {
                        showImportSheet = true
                    } label: {
                        Label(NSLocalizedString("导入日记", comment: "Import diary"), systemImage: "doc.on.clipboard")
                    }
                    Button {
                        showDeleteAllAlert = true
                    } label: {
                        Label(NSLocalizedString("删除所有日记", comment: "Delete all entries"), systemImage: "trash")
                            .foregroundColor(.blue)
                    }
                    .alert(NSLocalizedString("确认删除所有日记？", comment: "Confirm delete all"), isPresented: $showDeleteAllAlert) {
                        Button(NSLocalizedString("删除", comment: "Delete"), role: .destructive) {
                            deleteAllEntries()
                            showDeleteCompleteAlert = true
                        }
                        Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {}
                    } message: {
                        Text(NSLocalizedString("此操作无法撤销，是否确认？", comment: "Cannot undo confirmation"))
                    }
                }

                Section(header: Text(NSLocalizedString("iCloud 同步", comment: "iCloud sync")).textCase(nil)) {
                    Button {
                        performManualSync()
                    } label: {
                        HStack {
                            Label {
                                Text(NSLocalizedString("同步数据", comment: "Sync data"))
                            } icon: {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .imageScale(.large)
                            }
                            Spacer()
                            if isSyncing {
                                ProgressView()
                            } else if syncMessage != nil {
                                Image(systemName: "checkmark")
                                    .imageScale(.large)
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                    .disabled(isSyncing)
                }

                Section(header: Text(NSLocalizedString("关于", comment: "About")).textCase(nil)) {
                    Link(destination: URL(string: "mailto:me@limingyi.com")!) {
                        Label(NSLocalizedString("联系开发者", comment: "Contact developer"), systemImage: "envelope")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(.systemBackground))
            .listRowBackground(
                RoundedRectangle(cornerRadius: UIDevice.isMac ? 8 : 12, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                    .shadow(color: Color.primary.opacity(UIDevice.isMac ? 0.05 : 0.2), radius: UIDevice.isMac ? 4 : 4, x: 0, y: UIDevice.isMac ? 2 : 2)
            )
            .navigationTitle(NSLocalizedString("设置", comment: "Settings"))
            .navigationBarTitleDisplayMode(UIDevice.isMac ? .large : .inline)
            .toolbar {
                if !UIDevice.isMac {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            isSettingsOpen = false
                        } label: {
                            Text(NSLocalizedString("返回", comment: "Back"))
                        }
                    }
                }
            }
            .sheet(isPresented: $showImportSheet) {
                DiaryImportView()
                    .environmentObject(importService)
                    .environment(\.managedObjectContext, viewContext)
            }
            .alert(NSLocalizedString("删除完成", comment: "Deletion complete"), isPresented: $showDeleteCompleteAlert) {
                Button(NSLocalizedString("好", comment: "OK")) { isSettingsOpen = false }
            } message: {
                Text(NSLocalizedString("已删除所有日记", comment: "All entries deleted"))
            }
        }
        #endif
    }

    private func deleteAllEntries() {
        for entry in entries {
            viewContext.delete(entry)
        }
        
        do {
            try viewContext.save()
        } catch {
            print("[SettingsView] 删除所有日记失败: \(error)")
        }
    }

    private func performManualSync() {
        isSyncing = true
        syncMessage = nil
        
        Task {
            do {
                // 触发一次保存，这会让 CloudKit 检查是否有待同步的更改
                try viewContext.save()
                
                // 给用户一些反馈时间
                try await Task.sleep(nanoseconds: 1_500_000_000) // 1.5秒
                
                await MainActor.run {
                    isSyncing = false
                    syncMessage = NSLocalizedString("已同步", comment: "Synced")
                    
                    // 3秒后清除消息
                    Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        await MainActor.run {
                            syncMessage = nil
                        }
                    }
                }
                
                #if canImport(UIKit)
                HapticManager.shared.click()
                #endif
            } catch {
                await MainActor.run {
                    isSyncing = false
                    syncMessage = NSLocalizedString("同步失败", comment: "Sync failed")
                    print("[SettingsView] 手动同步失败: \(error)")
                }
            }
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView(isSettingsOpen: .constant(true))
            .environmentObject(CoreDataImportService())
            .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
    }
} 