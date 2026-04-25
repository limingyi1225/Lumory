import SwiftUI
import CoreData

struct DiaryExportView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)]
    ) private var entries: FetchedResults<DiaryEntry>
    
    @State private var isExporting = false
    @State private var showExportError = false
    
    private var dateRange: String {
        guard !entries.isEmpty else { return NSLocalizedString("无日记", comment: "No entries") }
        
        let dates = entries.compactMap { $0.date }
        guard let oldest = dates.min(), let newest = dates.max() else {
            return NSLocalizedString("无日记", comment: "No entries")
        }
        
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        
        return "\(formatter.string(from: oldest)) - \(formatter.string(from: newest))"
    }
    
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                Text(NSLocalizedString("导出日记", comment: "Export diary"))
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                // Info section
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "doc.text")
                            .foregroundColor(.accentColor)
                        Text(NSLocalizedString("日记数量", comment: "Entry count"))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(entries.count)")
                            .fontWeight(.semibold)
                    }
                    
                    Divider()
                    
                    HStack {
                        Image(systemName: "calendar")
                            .foregroundColor(.accentColor)
                        Text(NSLocalizedString("日期范围", comment: "Date range"))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(dateRange)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                    }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
                
                // Description
                Text(NSLocalizedString("导出后将生成一个文本文件，包含所有日记的日期、心情和内容。", comment: "Export description"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                // Buttons
                HStack {
                    Button(NSLocalizedString("取消", comment: "Cancel")) {
                        dismiss()
                    }
                    .foregroundColor(.primary)
                    
                    Spacer()
                    
                    Button {
                        performExport()
                    } label: {
                        if isExporting {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                        } else {
                            Text(NSLocalizedString("导出", comment: "Export"))
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(entries.isEmpty || isExporting)
                }
            }
            .padding()
            .navigationBarTitleDisplayMode(.inline)
            .alert(NSLocalizedString("导出失败", comment: "Export failed"), isPresented: $showExportError) {
                Button(NSLocalizedString("好", comment: "OK"), role: .cancel) {}
            } message: {
                Text(NSLocalizedString("无法创建导出文件，请检查存储空间后重试。", comment: "Export error message"))
            }
        }
        .interactiveDismissDisabled(isExporting)
    }
    
    private func performExport() {
        isExporting = true
        
        Task {
            // Generate content
            let entriesArray = Array(entries)
            let content = DiaryExportService.generateExportContent(from: entriesArray)
            
            // Create file
            if let fileURL = DiaryExportService.createExportFile(content: content) {
                await MainActor.run {
                    isExporting = false
                    #if canImport(UIKit)
                    HapticManager.shared.click()
                    // 直接弹出分享菜单
                    presentShareSheet(for: fileURL)
                    #endif
                }
            } else {
                // 以前这里只把 spinner 关掉，用户看不到任何失败提示——静默失败。
                // 弹个 alert 让用户知道出了问题，可以重试。
                await MainActor.run {
                    isExporting = false
                    showExportError = true
                }
            }
        }
    }
    
    #if canImport(UIKit)
    private func presentShareSheet(for fileURL: URL) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = windowScene.windows.first?.rootViewController else {
            return
        }
        
        // 找到最顶层的 presented view controller
        var topController = rootViewController
        while let presented = topController.presentedViewController {
            topController = presented
        }
        
        let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        
        // iPad popover 兼容
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = topController.view
            popover.sourceRect = CGRect(x: topController.view.bounds.midX, y: topController.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        
        topController.present(activityVC, animated: true)
    }
    #endif
}

#Preview {
    DiaryExportView()
        .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
}
