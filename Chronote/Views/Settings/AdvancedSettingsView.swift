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
    /// (2026-05-19 P1-09 audit)数据库修复失败时弹这条 alert。原先只 Log.error,用户看不到任何
    /// 反馈,以为按钮没响应或者修复完了。失败 = 严重,必须把"为什么失败 + 下一步"明确告知。
    @State private var databaseRecoveryFailureMessage: String?

    // 立即同步:从主 Settings 搬来,跟"同步诊断"语义连贯,放在"诊断与修复"段顶部 ——
    // 用户察觉同步异常时通常先点这个("再同步一次试试"),再升级到诊断 / 修复。
    @State private var isSyncing = false
    @State private var syncMessage: String?

    // 清除 AI 回顾缓存(2026-05-14 从主 Settings 搬进进阶 —— 低频维护操作,不该跟
    // 导入/导出/删除全部同档摆在主层)。
    @State private var showResetNarrativeAlert = false
    @State private var isResettingNarrative = false
    @State private var resetNarrativeFailureMessage: String?

    var body: some View {
        Form {
            troubleshootingSection
            perServiceIndexSection
            narrativeCacheSection
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
        // F8 — iPad fullScreenCover(同步诊断报告内容长,iPad formSheet 太窄)
        .lumoryAdaptiveModal(isPresented: $showDiagnosticSheet) {
            SyncDiagnosticView(result: diagnosticResult)
        }
        // (E-06 superreview 2026-05-19) 旧文案"会从 iCloud 恢复"承诺得太满。`DatabaseRecoveryService`
        // 走的是"重建本地 store + 等 CloudKit 重新下载",**离线 / 同步未完成时本地写过的日记会丢**。
        // destructive operation 必须明示这条 data-loss 风险。按钮 label 也改成"重建并恢复"让动作意图
        // 跟实现一致。
        .alert(NSLocalizedString("数据库修复", comment: "Database repair alert title"), isPresented: $showDatabaseRecoveryAlert) {
            Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) { }
            Button(NSLocalizedString("重建并从 iCloud 恢复", comment: "Database repair confirm button"),
                   role: .destructive) { performDatabaseRecovery() }
        } message: {
            Text(NSLocalizedString(
                "如果你遇到了数据库错误,此操作将重建本地数据库并从 iCloud 重新下载所有日记。\n\n⚠️ 任何尚未同步到 iCloud 的本地修改会丢失。建议先在「立即同步」确认状态正常后再操作。",
                comment: "Database repair alert body with unsynced-loss disclosure"
            ))
        }
        // (2026-05-19 P1-09 audit)修复失败 alert — DatabaseRecoveryService 返 .failure 时弹出来,
        // 把错误描述 + 下一步告诉用户,而不是 silent Log.error 让用户摸不到头脑。
        .alert(
            NSLocalizedString("数据库修复失败", comment: "Database recovery failed alert title"),
            isPresented: Binding(
                get: { databaseRecoveryFailureMessage != nil },
                set: { if !$0 { databaseRecoveryFailureMessage = nil } }
            )
        ) {
            Button(NSLocalizedString("好", comment: "OK"), role: .cancel) {
                databaseRecoveryFailureMessage = nil
            }
        } message: {
            Text(databaseRecoveryFailureMessage ?? "")
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

    // MARK: - AI 回顾缓存

    /// 「清除 AI 回顾缓存」(2026-05-14 从主 Settings 搬来)。只删 `AIConversation` kind=.narrative,
    /// **不动** askPast 对话历史 + 不动日记本身。删完用户回 InsightsView,NarrativeSummaryCard
    /// 的 .task hydrate 发现 cache nil → 显「生成回顾」CTA。toast 反馈靠 SettingsView 根的
    /// `.lumoryToastOverlay()`(本页是它 NavigationStack 内 push 的子页)。
    @ViewBuilder
    private var narrativeCacheSection: some View {
        Section(
            header: Text(NSLocalizedString("AI 回顾", comment: "AI narrative section")),
            footer: Text(NSLocalizedString(
                "清除后 Insights「历史回顾」里的「故事」记录会全部消失,下次进入可重新生成。日记本身不受影响。",
                comment: "Reset narrative cache footer"
            ))
        ) {
            Button {
                showResetNarrativeAlert = true
            } label: {
                HStack {
                    Label {
                        Text(NSLocalizedString("清除 AI 回顾缓存", comment: "Reset narrative cache"))
                            .foregroundStyle(Color.primary)
                    } icon: {
                        Image(systemName: "sparkles")
                            .foregroundStyle(Color.semanticDestructive)
                            .symbolRenderingMode(.hierarchical)
                            .frame(width: 24)
                    }
                    Spacer()
                    if isResettingNarrative { ProgressView() }
                }
            }
            .disabled(isResettingNarrative)
            .alert(
                NSLocalizedString("清除 AI 回顾缓存？", comment: "Confirm reset narrative cache"),
                isPresented: $showResetNarrativeAlert
            ) {
                Button(NSLocalizedString("清除", comment: "Reset"), role: .destructive) {
                    #if canImport(UIKit)
                    HapticManager.shared.notification(.warning)
                    #endif
                    Task { await resetNarrativeCache() }
                }
                Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {}
            } message: {
                Text(NSLocalizedString("将清除全部已生成的 AI 回顾,Insights「历史回顾」里的「故事」记录会一并消失。下次进入 Insights 时可以重新生成。日记本身不受影响,此操作不可撤销。", comment: "Reset narrative cache message"))
            }
            .alert(
                NSLocalizedString("清除失败", comment: "Reset failed alert title"),
                isPresented: Binding(
                    get: { resetNarrativeFailureMessage != nil },
                    set: { if !$0 { resetNarrativeFailureMessage = nil } }
                )
            ) {
                Button(NSLocalizedString("好", comment: "OK"), role: .cancel) {
                    resetNarrativeFailureMessage = nil
                }
            } message: {
                Text(resetNarrativeFailureMessage ?? "")
            }
        }
    }

    // MARK: Actions

    /// 清除 AIConversation 表里 kind=.narrative 的 record。**不动** askPast 对话历史 + 不动日记本身。
    ///
    /// **race fix**(2026-05-13 superreview P0-3):删之前先 await NarrativePrecomputeService 的
    /// cancel+bump,杜绝"写完日记 → 60s debounce 中 → 用户点 Reset → 老 task 在 stream 完成后
    /// 写回新 narrative,reset 失效"的窗口。
    ///
    /// 有删除 → "已清除 N 条" toast;0 条 → "没有可清除的回顾" toast,不静默成功让用户怀疑按钮坏了。
    @MainActor
    private func resetNarrativeCache() async {
        isResettingNarrative = true
        defer { isResettingNarrative = false }
        await NarrativePrecomputeService.shared.cancelPendingAndBumpGeneration()
        // wave18 — 同时 cancel 用户主动触发的在飞生成(NarrativeGenerationCoordinator),
        // 否则它会在下面 delete + save 后写回一条 narrative,清除失效。
        await NarrativeGenerationCoordinator.shared.cancelAll()
        let request = NSFetchRequest<AIConversation>(entityName: "AIConversation")
        request.predicate = NSPredicate(format: "kind == %@", AIConversation.Kind.narrative.rawValue)
        do {
            let narratives = try viewContext.fetch(request)
            let count = narratives.count
            for narrative in narratives {
                viewContext.delete(narrative)
            }
            try viewContext.save()
            #if canImport(UIKit)
            HapticManager.shared.notification(.success)
            #endif
            if count > 0 {
                LumoryToastCenter.shared.show(
                    String(format: NSLocalizedString("settings.resetNarrative.cleared", value: "已清除 %d 条 AI 回顾", comment: "Reset narrative cache toast with count"), count),
                    severity: .success
                )
            } else {
                LumoryToastCenter.shared.show(
                    NSLocalizedString("settings.resetNarrative.empty", value: "没有可清除的 AI 回顾", comment: "Reset narrative cache toast when nothing existed"),
                    severity: .info
                )
            }
        } catch {
            viewContext.rollback()
            Log.error("[AdvancedSettings] 清除 AI 回顾缓存失败: \(error)", category: .ui)
            resetNarrativeFailureMessage = String(
                format: NSLocalizedString("清除 AI 回顾缓存失败。请稍后重试。错误:%@", comment: "Reset narrative cache failure message"),
                error.localizedDescription
            )
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

    private func performDatabaseRecovery() {
        isRecoveringDatabase = true
        DatabaseRecoveryService.shared.performRecovery(for: PersistenceController.shared.container) { result in
            Task { @MainActor in
                self.isRecoveringDatabase = false
                switch result {
                case .success:
                    #if canImport(UIKit)
                    HapticManager.shared.notification(.success)
                    #endif
                    self.isSettingsOpen = false   // 修复成功关整个 settings，让 App 重载
                case .failure(let error):
                    // (2026-05-19 P1-09 audit)失败必须告知用户。文案合"为什么 + 下一步":
                    // 重启 App 通常能让 PersistenceController 重新走启动检测路径自愈;不行再联系开发者。
                    Log.error("[AdvancedSettings] Database recovery failed: \(error)", category: .ui)
                    #if canImport(UIKit)
                    HapticManager.shared.notification(.error)
                    #endif
                    self.databaseRecoveryFailureMessage = String(
                        format: NSLocalizedString(
                            "数据库修复未能完成。错误:%@\n\n请退出 App 重新打开。如果问题持续,可在『关于 → 联系开发者』反馈。",
                            comment: "Database recovery failed body with error"
                        ),
                        error.localizedDescription
                    )
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
            // (E-05 superreview 2026-05-19) 6s 超时分支不再静默 —— 旧实现 spinner 消失之后没有任何
            // 反馈,跟"已同步"成功路径肉眼无法区分,用户不知道按了"立即同步"到底成没成。
            // 改成显式 syncMessage,让"超时 / 后台仍在跑"这件事被看见。
            if isSyncing {
                isSyncing = false
                syncMessage = NSLocalizedString(
                    "同步未在 6 秒内完成,可能还在后台进行,请稍后再试。",
                    comment: "Sync now 6s timeout message"
                )
            }
            // 3 秒后清掉提示
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            syncMessage = nil
        }
    }
}
