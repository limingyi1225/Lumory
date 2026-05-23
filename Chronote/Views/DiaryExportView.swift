import SwiftUI
import CoreData

struct DiaryExportView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    
    // (2026-05-15 megareview P1-8)`fetchBatchSize: 100` 防多年用户开导出 sheet 时 fault 整张表
    // 进 row cache。export 本体走 `runExport()` 内 Task,这里 sheet 只显示 count + date range,
    // batch 拉头页就够。完整 OOM 修复(stream-to-file)是 epic 改动,先用 batchSize 兜底。
    @FetchRequest(fetchRequest: {
        let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)]
        request.fetchBatchSize = 100
        return request
    }()) private var entries: FetchedResults<DiaryEntry>
    
    @State private var isExporting = false
    @State private var showExportError = false
    /// 持有当前 export task,Cancel 按钮调 `cancel()` 让 task 尽快收手并跳过弹 share sheet。
    /// 否则 dismiss 后 task 仍跑完,弹出来的 ActivityVC 会浮在(已 dismissed 的)父 view 之上。
    @State private var exportTask: Task<Void, Never>?
    
    private var dateRange: String {
        // sortDescriptors 按 date desc(line 13)→ first 是最新,last 是最早,O(1) 访问。
        // 老实现 `entries.compactMap { $0.date }.min/max` 会 fault 整张表进 row cache,
        // 跟同一 patch 加的 `fetchBatchSize: 100` 直接对冲(优化空转)。
        guard let newest = entries.first?.date,
              let oldest = entries.last?.date else {
            return NSLocalizedString("无日记", comment: "No entries")
        }
        let formatter = LumoryDateFormatters.mediumDate
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
                // P0-3 玻璃化 — 替 secondarySystemBackground 实色,跟主页玻璃语言一致。
                .liquidGlassCard(cornerRadius: LumoryCornerRadius.inline)
                
                // Description
                Text(NSLocalizedString("导出后将生成一个文本文件，包含所有日记的日期、心情和内容。", comment: "Export description"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                // Progress indicator —— 大库 1-2s 之前 button-only spinner 像挂死;给中央条 + 文案明确"在导出"。
                if isExporting {
                    HStack(spacing: 12) {
                        ProgressView()
                            .progressViewStyle(.circular)
                        Text(String(format: NSLocalizedString("正在导出 %d 条日记…", comment: "Export progress"), entries.count))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .center)
                    // P0-3 玻璃化 — 跟上方 info card 同语言。
                    .liquidGlassCard(cornerRadius: LumoryCornerRadius.inline)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Spacer()
                
                // Buttons
                HStack {
                    Button(NSLocalizedString("取消", comment: "Cancel")) {
                        exportTask?.cancel()
                        exportTask = nil
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
        .lumoryToastOverlay()
    }
    
    private func performExport() {
        isExporting = true

        // (2026-05-15 superreview-3 P1)整段后台跑。fetch 走 background context dict-fetch
        // (不实例化 NSManagedObject 不触发主线程 fault),sort / lines.joined / 写盘也都在
        // detached task 上。主 actor 零开销。`PersistenceController.shared` 是 Lumory idiom
        // (`StreakMilestoneService` / `WidgetSnapshotService` 都这么走)。
        let persistence = PersistenceController.shared

        exportTask = Task.detached(priority: .userInitiated) {
            let snapshots = await DiaryExportService.fetchAllSnapshots(persistence: persistence)
            if Task.isCancelled { return }

            // Generate content
            let content = DiaryExportService.generateExportContent(from: snapshots)
            // 用户 Cancel 按钮 → cancel 这个 task。share sheet 不弹,文件不创建。
            if Task.isCancelled { return }

            // Create file
            if let fileURL = DiaryExportService.createExportFile(content: content) {
                // 用户在 createExportFile 写完盘 → 弹 share sheet 之间 cancel 了 → 文件已经落到磁盘。
                // 这里删掉,避免 export tmp 文件孤儿。share sheet 不弹。
                if Task.isCancelled {
                    try? FileManager.default.removeItem(at: fileURL)
                    return
                }
                let exportedCount = snapshots.count
                await MainActor.run {
                    isExporting = false
                    #if canImport(UIKit)
                    HapticManager.shared.notification(.success)
                    // §5.10 (2026-05-19) — 成功路径之前直接弹 share sheet 跳过 confirmation 反馈,
                    // 用户看不到"导出了多少条"。给个 toast 跟 import 完成的 alert 形成对称。
                    LumoryToastCenter.shared.show(
                        String(
                            format: NSLocalizedString("已导出 %d 条日记", comment: "Export success toast with count"),
                            exportedCount
                        ),
                        severity: .success
                    )
                    #endif
                }
                // 让成功 toast 先有一拍可见,再弹系统分享菜单盖住当前 sheet。延迟仍挂在
                // exportTask 上,用户若在这一拍里取消/关闭,不会再弹孤儿分享菜单。
                try? await Task.sleep(nanoseconds: 600_000_000)
                if Task.isCancelled {
                    try? FileManager.default.removeItem(at: fileURL)
                    return
                }
                await MainActor.run {
                    exportTask = nil
                    #if canImport(UIKit)
                    presentShareSheet(for: fileURL)
                    #endif
                }
            } else {
                // 以前这里只把 spinner 关掉，用户看不到任何失败提示——静默失败。
                // 弹个 alert 让用户知道出了问题，可以重试。
                await MainActor.run {
                    isExporting = false
                    exportTask = nil
                    showExportError = true
                }
            }
        }
    }
    
    #if canImport(UIKit)
    private func presentShareSheet(for fileURL: URL) {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let rootViewController = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController
                ?? windowScene.windows.first?.rootViewController else {
            LumoryToastCenter.shared.show(
                NSLocalizedString("导出完成,但现在无法打开分享菜单。回到 Lumory 后可以重新导出。", comment: "Export completed but share sheet could not be presented"),
                severity: .warning
            )
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
