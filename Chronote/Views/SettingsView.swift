import SwiftUI
import CoreData
#if canImport(UIKit)
import UIKit
#endif

// MARK: - SettingsView
//
// 按频率分三层：
// 1) 主层：常用 —— AI 一键索引、数据、iCloud、语言、关于
// 2) 进阶子页：诊断 / 修复 / 分项索引 / DEBUG 工具
//
// 视觉去掉原来的 `listRowBackground(RoundedRectangle + shadow(0.2))` 重阴影，
// 让 iOS 26 inset-grouped 原生样式发挥作用，和首页的 Liquid Glass 对齐。

struct SettingsView: View {
    @Binding var isSettingsOpen: Bool
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)]
    ) private var entries: FetchedResults<DiaryEntry>

    @AppStorage("appLanguage") private var appLanguage: String = {
        Locale.current.identifier.hasPrefix("zh") ? "zh-Hans" : "en"
    }()

    // 各种模态 / 确认态
    @State private var showImportSheet = false
    @State private var showExportSheet = false
    @State private var showDeleteAllAlert = false
    @State private var showDeleteCompleteAlert = false
    @State private var isDeletingAllEntries = false
    @State private var isSyncing = false
    @State private var syncMessage: String?

    @EnvironmentObject var importService: CoreDataImportService
    @EnvironmentObject var syncMonitor: CloudKitSyncMonitor

    var body: some View {
        NavigationStack {
            Form {
                appHeaderSection
                aiIndexSection
                dataSection
                syncSection
                languageSection
                advancedSection
                aboutSection
            }
            #if os(macOS)
            .listStyle(.plain)
            #else
            .listStyle(.insetGrouped)
            #endif
            .scrollContentBackground(.hidden)
            .background(backgroundGradient.ignoresSafeArea())
            .navigationTitle(NSLocalizedString("设置", comment: "Settings"))
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(NSLocalizedString("完成", comment: "Done")) {
                        isSettingsOpen = false
                    }
                    .fontWeight(.semibold)
                }
            }
            #endif
            .sheet(isPresented: $showImportSheet) {
                DiaryImportView()
                    .environmentObject(importService)
                    .environment(\.managedObjectContext, viewContext)
            }
            .sheet(isPresented: $showExportSheet) {
                DiaryExportView()
                    .environment(\.managedObjectContext, viewContext)
            }
            .alert(NSLocalizedString("删除完成", comment: "Deletion complete"), isPresented: $showDeleteCompleteAlert) {
                Button(NSLocalizedString("好", comment: "OK")) { isSettingsOpen = false }
            } message: {
                Text(NSLocalizedString("已删除所有日记", comment: "All entries deleted"))
            }
        }
    }

    // MARK: - Header

    /// 顶部：App 图标 + 名字 + 版本 + 条目计数。纯装饰，没有按钮。
    @ViewBuilder
    private var appHeaderSection: some View {
        Section {
            HStack(spacing: 14) {
                Image("LumoryIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: Color.primary.opacity(0.1), radius: 4, y: 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(NSLocalizedString("Lumory", comment: "App name"))
                        .font(.title3.weight(.semibold))
                    Text(versionString)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(String(format: NSLocalizedString("%d 条日记", comment: "Entry count"), entries.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 6)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
    }

    // MARK: - AI Index (prominent)

    @ViewBuilder
    private var aiIndexSection: some View {
        Section(header: sectionHeader("AI")) {
            OneClickRebuildRow()
        }
    }

    // MARK: - Data

    @ViewBuilder
    private var dataSection: some View {
        Section(header: sectionHeader(NSLocalizedString("数据", comment: "Data"))) {
            Button {
                showImportSheet = true
            } label: {
                settingsLabel(NSLocalizedString("导入日记", comment: "Import"), icon: "square.and.arrow.down", tint: .accentColor)
            }

            Button {
                showExportSheet = true
            } label: {
                settingsLabel(NSLocalizedString("导出日记", comment: "Export"), icon: "square.and.arrow.up", tint: .accentColor)
            }

            Button {
                showDeleteAllAlert = true
            } label: {
                HStack {
                    settingsLabel(NSLocalizedString("删除所有日记", comment: "Delete all"), icon: "trash", tint: .red)
                    if isDeletingAllEntries {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isDeletingAllEntries)
            .alert(NSLocalizedString("确认删除所有日记？", comment: "Confirm delete all"), isPresented: $showDeleteAllAlert) {
                Button(NSLocalizedString("删除", comment: "Delete"), role: .destructive) {
                    Task {
                        let didDelete = await deleteAllEntries()
                        if didDelete {
                            showDeleteCompleteAlert = true
                        }
                    }
                }
                Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {}
            } message: {
                Text(NSLocalizedString("此操作无法撤销。", comment: "Cannot undo"))
            }
        }
    }

    // MARK: - iCloud

    @ViewBuilder
    private var syncSection: some View {
        Section(header: sectionHeader("iCloud")) {
            Button {
                performManualSync()
            } label: {
                HStack {
                    settingsLabel(
                        NSLocalizedString("立即同步", comment: "Sync now"),
                        icon: "arrow.triangle.2.circlepath",
                        tint: .accentColor
                    )
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
        }
    }

    // MARK: - Language

    @ViewBuilder
    private var languageSection: some View {
        Section(header: sectionHeader(NSLocalizedString("语言", comment: "Language"))) {
            Picker("", selection: $appLanguage) {
                Text("简体中文").tag("zh-Hans")
                Text("English (US)").tag("en")
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    // MARK: - Advanced

    @ViewBuilder
    private var advancedSection: some View {
        Section(header: sectionHeader(NSLocalizedString("进阶", comment: "Advanced"))) {
            NavigationLink {
                AdvancedSettingsView(isSettingsOpen: $isSettingsOpen)
                    .environment(\.managedObjectContext, viewContext)
            } label: {
                settingsLabel(
                    NSLocalizedString("诊断、修复与分项控制", comment: "Advanced tools"),
                    icon: "slider.horizontal.3",
                    tint: .secondary
                )
            }
        }
    }

    // MARK: - About

    @ViewBuilder
    private var aboutSection: some View {
        Section(header: sectionHeader(NSLocalizedString("关于", comment: "About"))) {
            if let contactURL = URL(string: "mailto:me@limingyi.com") {
                Link(destination: contactURL) {
                    settingsLabel(
                        NSLocalizedString("联系开发者", comment: "Contact developer"),
                        icon: "envelope",
                        tint: .accentColor
                    )
                }
            }
        }
    }

    // MARK: - Small helpers

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }

    private func settingsLabel(_ title: String, icon: String, tint: Color) -> some View {
        Label {
            Text(title)
                .foregroundStyle(Color.primary)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 24)
        }
    }

    private var versionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    private var syncStatusIcon: String {
        syncMonitor.syncStatus == .synced ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var syncStatusTint: Color {
        syncMonitor.syncStatus == .synced ? Color.moodSpectrum(value: 0.85) : .orange
    }

    /// 很淡的顶部 mood-tinted 渐变，让 Settings 和首页保持同一种空气感。
    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color.accentColor.opacity(0.08),
                Color.clear
            ],
            startPoint: .top,
            endPoint: .center
        )
    }

    // MARK: - Actions

    private func deleteAllEntries() async -> Bool {
        isDeletingAllEntries = true
        defer { isDeletingAllEntries = false }

        let attachmentSnapshots = entries.map {
            EntryAttachmentSnapshot(imageFileNames: $0.imageFileNameArray, audioFileName: $0.audioFileName)
        }
        for entry in entries {
            viewContext.delete(entry)
        }
        do {
            try viewContext.save()
        } catch {
            Log.error("[SettingsView] 删除所有日记失败: \(error)", category: .ui)
            viewContext.rollback()
            return false
        }

        await Task.detached(priority: .utility) {
            for snapshot in attachmentSnapshots {
                for fileName in snapshot.imageFileNames {
                    do {
                        try DiaryEntry.deleteImageFromDocuments(fileName)
                    } catch {
                        Log.error("[SettingsView] 删除图片附件失败 \(fileName): \(error)", category: .ui)
                    }
                }
                if let audioFileName = snapshot.audioFileName, !audioFileName.isEmpty {
                    DiaryEntry.deleteAudioFromDocuments(audioFileName)
                }
            }
        }.value
        return true
    }

    private func performManualSync() {
        // **真的调 CloudKit**，不再是 `save` + 1.5s sleep + 恒假"已同步"。
        // 老实现让同步异常的用户看到绿色"已同步"，反而掩盖问题。
        // 现在走 CloudKitSyncMonitor.forceSync()，它会真的和 CloudKit 交互并按事件回调翻状态。
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
                    Log.error("[SettingsView] 手动同步失败: \(syncMonitor.syncStatus)", category: .ui)
                    break
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            // 超时：不强报错，用户可以再试一次
            if isSyncing {
                isSyncing = false
            }
            // 3 秒后清掉提示
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            syncMessage = nil
        }
    }
}

private struct EntryAttachmentSnapshot: Sendable {
    let imageFileNames: [String]
    let audioFileName: String?
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView(isSettingsOpen: .constant(true))
            .environmentObject(CoreDataImportService())
            .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
    }
}

// MARK: - Advanced sub-page
//
// 不常用的东西全放这里：同步诊断、数据库修复、分项 AI 索引控件、(DEBUG) 样本数据、UI 预览。
// NavigationLink 过来一层深度，平时看不见。

private struct AdvancedSettingsView: View {
    @Binding var isSettingsOpen: Bool
    @Environment(\.managedObjectContext) private var viewContext

    @State private var isRunningDiagnostic = false
    @State private var showDiagnosticSheet = false
    @State private var diagnosticResult: SyncDiagnosticResult?

    @State private var showDatabaseRecoveryAlert = false
    @State private var isRecoveringDatabase = false

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
        Section(
            header: header(NSLocalizedString("诊断与修复", comment: "Diagnose & repair")),
            footer: Text(NSLocalizedString("只有同步出问题 / 数据显示异常时才需要用到这一层。",
                                           comment: "Troubleshooting footer"))
        ) {
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

            Button {
                showDatabaseRecoveryAlert = true
            } label: {
                HStack {
                    Label {
                        Text(NSLocalizedString("数据库修复", comment: "Database recovery"))
                            .foregroundStyle(Color.primary)
                    } icon: {
                        Image(systemName: "wrench.and.screwdriver")
                            .foregroundStyle(.orange)
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
            header: header(NSLocalizedString("分项索引", comment: "Per-service index")),
            footer: Text(NSLocalizedString("想只跑其中一个时用。常规升级请用主页的『一键重建索引』。",
                                           comment: "Per-service footer"))
        ) {
            EmbeddingBackfillRow()
            ThemeBackfillRow()
        }
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(.secondary)
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
        Task {
            await MainActor.run {
                DatabaseRecoveryService.shared.performRecovery(for: PersistenceController.shared.container) { result in
                    DispatchQueue.main.async {
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
        }
    }
}

// MARK: - Backfill coordinator
//
// CLAUDE.md 点名的 `.shared.runningTask` race 的 UI 层解。
// `ThemeBackfillService` / `EmbeddingBackfillService` / `PromptSuggestionEngine` 都是
// 进程级单例且**非 actor-safe**(run() 的 `runningTask != nil` 检查没锁);OneClickRebuildRow
// 走 theme → embedding → suggestions 串行,阶段之间 `progress.isRunning` 有 sub-ms 窗口都
// 为 false,若此时用户从 AdvancedSettings 触发 per-service rebuild,会撞上 silent-drop。
//
// 这里用一个 `@Published` flag 跨 view 广播"OneClick 整体串行期间",让三个 rebuild 入口
// 通过观察这个 flag + 各自 service 的 `isRunning` 互相 disable。
@MainActor
private final class BackfillCoordinator: ObservableObject {
    static let shared = BackfillCoordinator()

    /// OneClickRebuildRow.runAll() 整条串行流期间为 true。defer 复位,异常路径也安全。
    @Published private(set) var isOneClickRunning: Bool = false

    private init() {}

    func runOneClick(_ operation: () async -> Void) async {
        guard !isOneClickRunning else {
            Log.info("[BackfillCoordinator] 已有一键重建在跑,忽略并发触发", category: .ui)
            return
        }
        isOneClickRunning = true
        defer { isOneClickRunning = false }
        await operation()
    }
}

// MARK: - One-click rebuild row
//
// 大版本升级后一键把三件事连着跑：重抽主题 → 补向量 → 暖 AI 提示词缓存。
// 组合现成的 singletons，不新起 service —— 三个 @StateObject 订阅进度；
// 编排在一个 Task 里按阶段切换。

private struct OneClickRebuildRow: View {
    @StateObject private var themeService = ThemeBackfillService.shared
    @StateObject private var embeddingService = EmbeddingBackfillService.shared
    @StateObject private var suggestionEngine = PromptSuggestionEngine.shared
    @StateObject private var coordinator = BackfillCoordinator.shared

    @State private var stage: Stage = .idle
    /// 待索引条目数 —— 进入设置时 / 重建完成后刷新一次。nil = 还没查过,不显示数字。
    @State private var pendingCount: Int?
    @State private var isCountingPending: Bool = false

    private enum Stage: Equatable {
        case idle
        case themes
        case embeddings
        case suggestions
        case done
        case failed(String)
    }

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(NSLocalizedString("一键重建索引", comment: "One-click rebuild"))
                        .font(.body.weight(.medium))
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(statusColor)
                }
            } icon: {
                Image(systemName: stageIcon)
                    .imageScale(.large)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundColor(stageIconColor)
                    .frame(width: 24)
            }
            Spacer()
            trailing
        }
        .task {
            await refreshPendingCount()
        }
    }

    private var stageIcon: String {
        switch stage {
        case .failed:
            // .failed 必须独立分支 —— 之前和 .idle/.done 共用,凑巧 pendingCount = 0 时
            // 显示 ✓,误导用户以为成功了。
            return "exclamationmark.triangle.fill"
        case .idle, .done:
            if pendingCount == 0 { return "checkmark.seal.fill" }
            return "wand.and.stars"
        case .themes, .embeddings, .suggestions:
            return "wand.and.stars"
        }
    }

    private var stageIconColor: Color {
        switch stage {
        case .failed:
            return .orange
        case .idle, .done:
            if pendingCount == 0 { return Color.moodSpectrum(value: 0.85) }
            return .accentColor
        case .themes, .embeddings, .suggestions:
            return .accentColor
        }
    }

    private var statusColor: Color {
        switch stage {
        case .failed:
            return .orange.opacity(0.9)
        case .idle:
            if let pendingCount, pendingCount == 0 {
                return Color.moodSpectrum(value: 0.85).opacity(0.85)
            }
            return .secondary
        default:
            return .secondary
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch stage {
        case .idle, .done, .failed:
            Button {
                #if canImport(UIKit)
                HapticManager.shared.click()
                #endif
                Task { await runAll() }
            } label: {
                Text(NSLocalizedString("一键开始", comment: "Start one-click"))
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.glassProminent)
            // 另一条 rebuild 在跑(Advanced 的 per-service,或其他 OneClick 实例)→ 禁用,
            // 防撞 `.shared.runningTask` 非 actor-safe 的 race 窗口。
            .disabled(isExternalBackfillActive)
        case .themes, .embeddings, .suggestions:
            VStack(alignment: .trailing, spacing: 4) {
                ProgressView()
                Text(progressDetail)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
    }

    /// 本 row 当前不在 OneClick 运行态(那时 trailing 另走进度分支)时,外部是否有 rebuild 在跑。
    /// `coordinator.isOneClickRunning` 覆盖 OneClick 阶段间隙(service.isRunning 暂时全 false
    /// 的那几 ms);两个 service 的 `progress.isRunning` 覆盖 AdvancedSettings 入口;
    /// `suggestionEngine.isRefreshing` 覆盖 suggestions 阶段。
    private var isExternalBackfillActive: Bool {
        coordinator.isOneClickRunning
            || themeService.progress.isRunning
            || embeddingService.progress.isRunning
            || suggestionEngine.isRefreshing
    }

    private var statusText: String {
        switch stage {
        case .idle:
            // 还没查过 → 模糊文案;有待索引 → 提示数量;0 → 明确"无需重建"。
            guard let pendingCount else {
                if isCountingPending {
                    return NSLocalizedString("正在检查待索引条目…", comment: "Checking pending")
                }
                return NSLocalizedString("对存量日记跑一遍最新的 AI 管线", comment: "One-click idle subtitle")
            }
            if pendingCount == 0 {
                return NSLocalizedString("索引已是最新,无需重建 ✓", comment: "Up to date")
            }
            // 用"项"而不是"条" —— pendingCount 是主题待修 + 向量待补的**和**,
            // 一篇日记可能两边都需要,会被算两次。"项"更诚实(任务数,不是日记数)。
            return String(
                format: NSLocalizedString("有 %d 项索引待更新,建议运行一次", comment: "Pending count"),
                pendingCount
            )
        case .themes:
            return NSLocalizedString("第 1 / 3 步：重抽主题…", comment: "One-click stage 1")
        case .embeddings:
            return NSLocalizedString("第 2 / 3 步：补全语义向量…", comment: "One-click stage 2")
        case .suggestions:
            return NSLocalizedString("第 3 / 3 步：生成个性化提示词…", comment: "One-click stage 3")
        case .done:
            return NSLocalizedString("索引已是最新 ✓", comment: "One-click done")
        case .failed(let message):
            return String(format: NSLocalizedString("部分步骤失败：%@", comment: "One-click failed"), message)
        }
    }

    /// 拉取两个 backfill 服务的待处理总数。一次并发 + 求和。
    private func refreshPendingCount() async {
        isCountingPending = true
        async let themePending = ThemeBackfillService.shared.pendingCount()
        async let embeddingPending = EmbeddingBackfillService.shared.pendingCount()
        let total = (await themePending) + (await embeddingPending)
        pendingCount = total
        isCountingPending = false
    }

    private var progressDetail: String {
        switch stage {
        case .themes:
            return "\(themeService.progress.processed)/\(themeService.progress.total)"
        case .embeddings:
            return "\(embeddingService.progress.processed)/\(embeddingService.progress.total)"
        case .suggestions:
            return NSLocalizedString("AI 写作中", comment: "One-click suggestions stage detail")
        default:
            return ""
        }
    }

    private func runAll() async {
        // 重入 guard：按钮 UI 已隐藏 start button 在 running 状态里，但 `stage = .themes` 到
        // 第一个 await 之间如果再被触发会并行跑两条，两路都抢同一个 ThemeBackfillService.shared
        // 的 progress 计数器。bail 掉后来的调用。
        switch stage {
        case .themes, .embeddings, .suggestions:
            Log.info("[OneClickRebuild] 已有 rebuild 在跑，忽略重复触发", category: .ui)
            return
        default: break
        }
        // 兜底:Advanced 的 per-service 入口/另一条 OneClick 正在跑(按钮 disabled 之后仍
        // 可能因观察时延被触发)→ 直接早退。
        guard !isExternalBackfillActive else {
            Log.info("[OneClickRebuild] 另一路 rebuild 已在跑(Advanced 或并发 OneClick)，忽略", category: .ui)
            return
        }

        await coordinator.runOneClick {
            stage = .themes
            // wordCount backfill 和主题一起跑——两者都扫全表，挂一块儿不额外往返。
            // 先跑 wordCount：不依赖网络，几十 ms 搞定；顺序上放最前面让"累计字数"最快恢复。
            _ = await WordCountBackfillService.forceBackfill()
            _ = await ThemeBackfillService.shared.backfillAll()

            stage = .embeddings
            _ = await EmbeddingBackfillService.shared.backfillAll()

            stage = .suggestions
            // forceRefresh 现在返回 Bool：true 表示真的生成了新 bundle；false 表示失败或信号不够。
            // 旧的 `current != nil` 判定在 AI 失败时会被旧 cache 误判成成功。
            let suggestionGenerated = await PromptSuggestionEngine.shared.forceRefresh()
            // 信号不足（<3 条日记）走的也是 false，但这是预期行为不算失败——拿 writingStats 兜底判定一次。
            let stats = await InsightsEngine.shared.writingStats()
            let suggestionOk = suggestionGenerated || stats.totalEntries < 3

            let themeFailed = themeService.progress.failed
            let embeddingFailed = embeddingService.progress.failed

            if themeFailed == 0, embeddingFailed == 0, suggestionOk {
                stage = .done
            } else {
                var parts: [String] = []
                if themeFailed > 0 { parts.append(String(format: NSLocalizedString("主题 %d 失败", comment: ""), themeFailed)) }
                if embeddingFailed > 0 { parts.append(String(format: NSLocalizedString("向量 %d 失败", comment: ""), embeddingFailed)) }
                if !suggestionOk { parts.append(NSLocalizedString("提示词未生成", comment: "")) }
                stage = .failed(parts.joined(separator: "，"))
            }

            // 跑完后回到 idle 之前刷一遍 pending —— 用户立刻能看到"已是最新 ✓"。
            await refreshPendingCount()
        }
    }
}

// MARK: - Embedding backfill row

private struct EmbeddingBackfillRow: View {
    @StateObject private var service = EmbeddingBackfillService.shared
    // OneClickRow / ThemeBackfillRow / suggestion refresh 在跑时禁用本按钮,
    // 避免与 `.shared.runningTask` 的非 actor-safe 入队撞 race。
    @StateObject private var themeService = ThemeBackfillService.shared
    @StateObject private var suggestionEngine = PromptSuggestionEngine.shared
    @StateObject private var coordinator = BackfillCoordinator.shared

    private var isOtherBackfillActive: Bool {
        coordinator.isOneClickRunning
            || themeService.progress.isRunning
            || suggestionEngine.isRefreshing
    }

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(NSLocalizedString("生成语义索引", comment: "Build embedding index"))
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } icon: {
                Image(systemName: "sparkle.magnifyingglass")
                    .imageScale(.large)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundColor(.accentColor)
                    .frame(width: 24)
            }
            Spacer()
            if service.progress.isRunning {
                VStack(alignment: .trailing, spacing: 4) {
                    ProgressView()
                    Text("\(service.progress.processed)/\(service.progress.total)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else {
                Button(action: start) {
                    Text(NSLocalizedString("开始", comment: "Start"))
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.glass)
                .disabled(isOtherBackfillActive)
            }
        }
    }

    private var statusText: String {
        if service.progress.isRunning {
            return String(
                format: NSLocalizedString("进度 %d%%（失败 %d）", comment: "Backfill progress"),
                Int(service.progress.fraction * 100),
                service.progress.failed
            )
        }
        if service.progress.total > 0 {
            return String(
                format: NSLocalizedString("上次处理 %d 条，失败 %d 条", comment: "Backfill last result"),
                service.progress.processed,
                service.progress.failed
            )
        }
        return NSLocalizedString("为历史日记生成语义向量，用于语义搜索和 Ask Your Past", comment: "Backfill subtitle")
    }

    private func start() {
        Task { await service.backfillAll() }
    }
}

// MARK: - Theme backfill row

private struct ThemeBackfillRow: View {
    @StateObject private var service = ThemeBackfillService.shared
    // 同样的 `.shared.runningTask` race —— OneClick / Embedding / Suggestion 路径在跑时
    // 禁用本菜单。
    @StateObject private var embeddingService = EmbeddingBackfillService.shared
    @StateObject private var suggestionEngine = PromptSuggestionEngine.shared
    @StateObject private var coordinator = BackfillCoordinator.shared
    @State private var showAllConfirm = false

    private var isOtherBackfillActive: Bool {
        coordinator.isOneClickRunning
            || embeddingService.progress.isRunning
            || suggestionEngine.isRefreshing
    }

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(NSLocalizedString("刷新主题", comment: "Refresh themes"))
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } icon: {
                Image(systemName: "tag.square.fill")
                    .imageScale(.large)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundColor(.accentColor)
                    .frame(width: 24)
            }
            Spacer()
            if service.progress.isRunning {
                VStack(alignment: .trailing, spacing: 4) {
                    ProgressView()
                    Text("\(service.progress.processed)/\(service.progress.total)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else {
                Menu {
                    Button {
                        Task { await service.backfillProblems() }
                    } label: {
                        Label(NSLocalizedString("只修有问题的", comment: "Backfill problems only"), systemImage: "wand.and.stars")
                    }
                    Button {
                        showAllConfirm = true
                    } label: {
                        Label(NSLocalizedString("全部重抽", comment: "Backfill all"), systemImage: "arrow.clockwise")
                    }
                } label: {
                    Text(NSLocalizedString("开始", comment: "Start"))
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.glass)
                .disabled(isOtherBackfillActive)
            }
        }
        .alert(NSLocalizedString("重抽所有日记的主题？", comment: "Backfill all confirm title"),
               isPresented: $showAllConfirm) {
            Button(NSLocalizedString("确定", comment: "Confirm"), role: .destructive) {
                Task { await service.backfillAll() }
            }
            Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("会调用一次 AI。如果只是想清理『情绪』这类标签，选『只修有问题的』更省。",
                                   comment: "Backfill all confirm message"))
        }
    }

    private var statusText: String {
        if service.progress.isRunning {
            return String(
                format: NSLocalizedString("进度 %d%%（失败 %d）", comment: "Backfill progress"),
                Int(service.progress.fraction * 100),
                service.progress.failed
            )
        }
        if service.progress.total > 0 {
            return String(
                format: NSLocalizedString("上次处理 %d 条，失败 %d 条", comment: "Backfill last result"),
                service.progress.processed,
                service.progress.failed
            )
        }
        return NSLocalizedString("用新的提取逻辑把存量日记的主题重新整理。",
                                 comment: "Theme backfill subtitle")
    }
}
