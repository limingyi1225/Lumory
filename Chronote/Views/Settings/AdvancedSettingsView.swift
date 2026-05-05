import SwiftUI
import CoreData
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Advanced sub-page
//
// 不常用的东西全放这里：同步诊断、数据库修复、分项 AI 索引控件、(DEBUG) 样本数据、UI 预览。
// NavigationLink 过来一层深度，平时看不见。

struct AdvancedSettingsView: View {
    @Binding var isSettingsOpen: Bool
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject private var syncMonitor: CloudKitSyncMonitor

    @State private var isRunningDiagnostic = false
    @State private var showDiagnosticSheet = false
    @State private var diagnosticResult: SyncDiagnosticResult?

    @State private var showDatabaseRecoveryAlert = false
    @State private var isRecoveringDatabase = false

    // 立即同步:从主 Settings 搬来,跟"同步诊断"语义连贯,放在"诊断与修复"段顶部 ——
    // 用户察觉同步异常时通常先点这个("再同步一次试试"),再升级到诊断 / 修复。
    @State private var isSyncing = false
    @State private var syncMessage: String?

    var body: some View {
        Form {
            troubleshootingSection
            perServiceIndexSection
        }
        #if os(macOS)
        .listStyle(.plain)
        #else
        .listStyle(.insetGrouped)
        #endif
        .scrollContentBackground(.hidden)
        .navigationTitle(NSLocalizedString("进阶", comment: "Advanced"))
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showDiagnosticSheet) {
            SyncDiagnosticView(result: diagnosticResult)
                .lumorySheetDecoration()
        }
        .alert(NSLocalizedString("数据库修复", comment: "Database repair alert title"), isPresented: $showDatabaseRecoveryAlert) {
            Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) { }
            Button(NSLocalizedString("修复", comment: "Repair"), role: .destructive) { performDatabaseRecovery() }
        } message: {
            Text(NSLocalizedString("如果你遇到了数据库错误，此操作将尝试修复。数据会从 iCloud 恢复。", comment: "Database repair alert body"))
        }
    }

    @ViewBuilder
    private var troubleshootingSection: some View {
        // P1-Set-5 拆两个 Section — "立即同步 / 同步诊断" 是日常操作,"数据库修复" 是危险操作,
        // 之前共一个 Section 视觉权重平等,用户容易误点修复。独立 + 专属 footer 警告。
        Section(
            header: Text(NSLocalizedString("诊断与修复", comment: "Diagnose & repair")),
            footer: Text(NSLocalizedString("只有同步出问题 / 数据显示异常时才需要用到这一层。",
                                           comment: "Troubleshooting footer"))
        ) {
            Button {
                performManualSync()
            } label: {
                HStack {
                    Label {
                        Text(NSLocalizedString("立即同步", comment: "Sync now"))
                            .foregroundStyle(Color.primary)
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(Color.accentColor)
                            .symbolRenderingMode(.hierarchical)
                            .frame(width: 24)
                    }
                    Spacer()
                    if isSyncing {
                        ProgressView()
                    } else if syncMessage != nil {
                        Image(systemName: syncStatusIcon)
                            .foregroundStyle(syncStatusTint)
                    }
                }
            }
            .disabled(isSyncing)

            Button {
                runSyncDiagnostic()
            } label: {
                HStack {
                    Label {
                        Text(NSLocalizedString("同步诊断", comment: "Sync diagnostic"))
                            .foregroundStyle(Color.primary)
                    } icon: {
                        Image(systemName: "stethoscope")
                            .foregroundStyle(Color.accentColor)
                            .symbolRenderingMode(.hierarchical)
                            .frame(width: 24)
                    }
                    Spacer()
                    if isRunningDiagnostic { ProgressView() }
                }
            }
            .disabled(isRunningDiagnostic)
        }

        // P1-Set-5 数据库修复独立 Section — 专属 footer 强调"危险 + 不可撤销 + 仅在严重错时使用"。
        Section(
            footer: Text(NSLocalizedString(
                "仅当 App 启动时报错 / 反复同步失败时使用。会重建本地数据库并尝试从 iCloud 恢复,期间数据不可访问。",
                comment: "Database recovery footer warning"
            ))
        ) {
            Button {
                showDatabaseRecoveryAlert = true
            } label: {
                HStack {
                    Label {
                        Text(NSLocalizedString("数据库修复", comment: "Database recovery"))
                            .foregroundStyle(Color.primary)
                    } icon: {
                        Image(systemName: "wrench.and.screwdriver")
                            .foregroundStyle(Color.semanticWarning)
                            .symbolRenderingMode(.hierarchical)
                            .frame(width: 24)
                    }
                    Spacer()
                    if isRecoveringDatabase { ProgressView() }
                }
            }
            .disabled(isRecoveringDatabase)
        }
    }

    @ViewBuilder
    private var perServiceIndexSection: some View {
        Section(
            header: Text(NSLocalizedString("分项索引", comment: "Per-service index")),
            footer: Text(NSLocalizedString("想只跑其中一个时用。常规升级请用主页的『重建全部 AI 分析』。",
                                           comment: "Per-service footer"))
        ) {
            EmbeddingBackfillRow()
            ThemeBackfillRow()
        }
    }

    // MARK: Actions

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

    private func performDatabaseRecovery() {
        isRecoveringDatabase = true
        DatabaseRecoveryService.shared.performRecovery(for: PersistenceController.shared.container) { result in
            Task { @MainActor in
                self.isRecoveringDatabase = false
                switch result {
                case .success:
                    self.isSettingsOpen = false   // 修复成功关整个 settings，让 App 重载
                case .failure(let error):
                    Log.error("[AdvancedSettings] Database recovery failed: \(error)", category: .ui)
                }
            }
        }
    }

    private var syncStatusIcon: String {
        syncMonitor.syncStatus == .synced ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var syncStatusTint: Color {
        syncMonitor.syncStatus == .synced ? Color.semanticSuccess : Color.semanticWarning
    }

    private func performManualSync() {
        // **真的调 CloudKit**，不是 `save` + 1.5s sleep + 恒假"已同步"。
        // 老实现让同步异常的用户看到绿色"已同步"，反而掩盖问题。
        // 走 CloudKitSyncMonitor.forceSync() 真的和 CloudKit 交互并按事件回调翻状态。
        isSyncing = true
        syncMessage = nil
        syncMonitor.forceSync()

        // 监听 syncMonitor 的状态变化；带 6s 超时兜底，避免长久 spin。
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(6.0)
            while Date() < deadline {
                if syncMonitor.syncStatus == .synced {
                    isSyncing = false
                    syncMessage = NSLocalizedString("已同步", comment: "Synced")
                    #if canImport(UIKit)
                    HapticManager.shared.click()
                    #endif
                    break
                }
                if syncMonitor.syncStatus == .error || syncMonitor.syncStatus == .networkUnavailable ||
                    syncMonitor.syncStatus == .notSignedIn {
                    isSyncing = false
                    syncMessage = syncMonitor.errorMessage ?? NSLocalizedString("同步失败", comment: "Sync failed")
                    Log.error("[AdvancedSettings] 手动同步失败: \(syncMonitor.syncStatus)", category: .ui)
                    break
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            // 超时:不强报错,用户可以再试一次
            if isSyncing {
                isSyncing = false
            }
            // 3 秒后清掉提示
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            syncMessage = nil
        }
    }
}
