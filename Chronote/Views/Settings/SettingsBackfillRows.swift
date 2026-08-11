import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Backfill coordinator
//
// `ThemeBackfillService` / `EmbeddingBackfillService` / `PromptSuggestionEngine` 都是进程级单例。
// service 各自能防重复启动，但 OneClick 走 theme → embedding → suggestions 跨三个 service 串行；
// 阶段之间 `progress.isRunning` 有短暂空窗，仍需要一个跨 service 的整体锁和生命周期真源。
//
// coordinator 同时持有阶段、停止标记和 Task。OneClick row 现在在 push 子页里，用户返回后
// row 会销毁；运行态若仍放在 View 的 @State，重进页面就会失去进度和停止入口。
@MainActor
final class BackfillCoordinator: ObservableObject {
    static let shared = BackfillCoordinator()

    enum Stage: Equatable {
        case idle
        case themes
        case embeddings
        case suggestions
        case done
        case failed(String)
    }

    /// 整条串行流期间为 true。即使 Advanced 页面被 pop，shared coordinator 仍保留真值。
    @Published private(set) var isOneClickRunning: Bool = false
    @Published private(set) var stage: Stage = .idle
    @Published private(set) var pendingCount: Int?
    @Published private(set) var isCountingPending: Bool = false

    private var oneClickTask: Task<Void, Never>?
    private var stopRequested = false
    private var pendingCountGeneration = 0

    private init() {}

    func startOneClick() {
        guard !isOneClickRunning,
              !ThemeBackfillService.shared.progress.isRunning,
              !EmbeddingBackfillService.shared.progress.isRunning,
              !PromptSuggestionEngine.shared.isRefreshing else {
            Log.info("[BackfillCoordinator] 已有 rebuild 在跑，忽略并发触发", category: .ui)
            return
        }

        stopRequested = false
        isOneClickRunning = true
        stage = .themes
        oneClickTask = Task { [weak self] in
            guard let self else { return }
            await self.executeOneClick()
        }
    }

    /// 停止完整三阶段 chain。Theme / Embedding 可立即 cancel；Suggestions 没有 task handle，
    /// 只能等待当前单次请求结束，但 sentinel 会阻止它落成 done 或继续任何后续工作。
    func stopOneClick() {
        guard isOneClickRunning else { return }
        stopRequested = true

        switch stage {
        case .themes:
            Task { await ThemeBackfillService.shared.cancel() }
        case .embeddings:
            Task { await EmbeddingBackfillService.shared.cancel() }
        case .suggestions, .idle, .done, .failed:
            break
        }
    }

    /// 拉取两个 backfill 服务的待处理总数。generation 防止页面重进与任务收尾的两次查询
    /// 乱序完成，让较老结果覆盖较新结果。
    func refreshPendingCount() async {
        pendingCountGeneration += 1
        let generation = pendingCountGeneration
        isCountingPending = true

        async let themePending = ThemeBackfillService.shared.pendingCount()
        async let embeddingPending = EmbeddingBackfillService.shared.pendingCount()
        let total = (await themePending) + (await embeddingPending)

        guard generation == pendingCountGeneration else { return }
        pendingCount = total
        isCountingPending = false
    }

    private func executeOneClick() async {
        defer {
            isOneClickRunning = false
            oneClickTask = nil
        }

        if await finishIfStopRequested() { return }

        // wordCount backfill 和主题一起跑。先跑本地的 wordCount，让累计字数最快恢复。
        _ = await WordCountBackfillService.forceBackfill()
        if await finishIfStopRequested() { return }
        _ = await ThemeBackfillService.shared.backfillAll()
        if await finishIfStopRequested() { return }

        stage = .embeddings
        _ = await EmbeddingBackfillService.shared.backfillAll()
        if await finishIfStopRequested() { return }

        stage = .suggestions
        let suggestionGenerated = await PromptSuggestionEngine.shared.forceRefresh()
        if await finishIfStopRequested() { return }

        // 信号不足（<3 条日记）返回 false 是预期行为，不算失败。
        let stats = await InsightsEngine.shared.writingStats()
        let suggestionOK = suggestionGenerated || stats.totalEntries < 3
        let themeFailed = ThemeBackfillService.shared.progress.failed
        let embeddingFailed = EmbeddingBackfillService.shared.progress.failed

        if themeFailed == 0, embeddingFailed == 0, suggestionOK {
            stage = .done
        } else {
            var parts: [String] = []
            if themeFailed > 0 {
                parts.append(String(format: NSLocalizedString("主题 %d 失败", comment: ""), themeFailed))
            }
            if embeddingFailed > 0 {
                parts.append(String(format: NSLocalizedString("向量 %d 失败", comment: ""), embeddingFailed))
            }
            if !suggestionOK {
                parts.append(NSLocalizedString("提示词未生成", comment: ""))
            }
            stage = .failed(parts.joined(separator: "，"))
        }

        await refreshPendingCount()
    }

    private func finishIfStopRequested() async -> Bool {
        guard stopRequested else { return false }
        stopRequested = false
        stage = .idle
        await refreshPendingCount()
        return true
    }
}

// MARK: - One-click rebuild row
//
// 大版本升级后一键把三件事连着跑：重抽主题 → 补向量 → 暖 AI 提示词缓存。
// 组合现成的 singletons，不新起 service。View 只订阅进度；完整编排由 shared coordinator 持有。

struct OneClickRebuildRow: View {
    @StateObject private var themeService = ThemeBackfillService.shared
    @StateObject private var embeddingService = EmbeddingBackfillService.shared
    @StateObject private var suggestionEngine = PromptSuggestionEngine.shared
    @StateObject private var coordinator = BackfillCoordinator.shared

    private var stage: BackfillCoordinator.Stage { coordinator.stage }
    private var pendingCount: Int? { coordinator.pendingCount }
    private var isCountingPending: Bool { coordinator.isCountingPending }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(NSLocalizedString("重建全部 AI 分析", comment: "Rebuild all AI analysis"))
                            .foregroundStyle(Color.primary)
                        if showsRuntimeStatus {
                            Text(statusText)
                                .font(.caption)
                                .foregroundColor(statusColor)
                        }
                    }
                } icon: {
                    Image(systemName: stageIcon)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundColor(stageIconColor)
                        .frame(width: 24)
                }
                Spacer()
                trailing
            }
            // P1-Set-1 整体线性进度条 — 跑 3 阶段时看见"在哪一步、进展百分比",之前只 indeterminate spinner。
            if let fraction = comprehensiveFraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .accessibilityLabel(NSLocalizedString("整体进度", comment: "Overall progress"))
            }
        }
        .task {
            await coordinator.refreshPendingCount()
        }
    }

    /// 三阶段综合分数。
    /// - themes:0 → 0.33(local progress)
    /// - embeddings:0.33 → 0.67(local progress)
    /// - suggestions:**固定 0.80 占位**(单次 LLM call 没分母,条停在 80% 直到 .done)
    /// idle / done / failed 返 nil 让上方条隐藏。
    private var comprehensiveFraction: Double? {
        switch stage {
        case .idle, .done, .failed:
            return nil
        case .themes:
            let p = themeService.progress
            let local = p.total > 0 ? Double(p.processed) / Double(p.total) : 0
            return local * 0.33
        case .embeddings:
            let p = embeddingService.progress
            let local = p.total > 0 ? Double(p.processed) / Double(p.total) : 0
            return 0.33 + local * 0.34
        case .suggestions:
            // 这阶段没分母 —— suggestionEngine 是 1 次 LLM 调用没法分进度,展示 80% 占位让条往前推一点。
            return 0.80
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

    /// 静止时不再放解释性副标题；只有正在执行或失败时才显示必要状态。
    private var showsRuntimeStatus: Bool {
        switch stage {
        case .themes, .embeddings, .suggestions, .failed:
            return true
        case .idle, .done:
            return false
        }
    }

    private var startAccessibilityLabel: String {
        if case .failed = stage {
            return NSLocalizedString("重试重建全部 AI 分析", comment: "Retry all AI analysis rebuild a11y")
        }
        return NSLocalizedString("开始重建全部 AI 分析", comment: "Start all AI analysis rebuild a11y")
    }

    @ViewBuilder
    private var trailing: some View {
        switch stage {
        case .idle, .done, .failed:
            Button {
                #if canImport(UIKit)
                HapticManager.shared.click()
                #endif
                coordinator.startOneClick()
            } label: {
                // P1-Set-7 .failed 态用"重试" + 旋转箭头(idle/done 仍是"开始")。
                Group {
                    if case .failed = stage {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text(NSLocalizedString("重试", comment: "Retry"))
                        }
                        .font(.caption.weight(.semibold))
                    } else {
                        Text(NSLocalizedString("开始", comment: "Start"))
                            .font(.caption.weight(.semibold))
                    }
                }
                .frame(minWidth: 44, minHeight: 44)
            }
            // 是明确的启动动作，使用实色系统按钮；它不使用 Liquid Glass，避免材质叠层。
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            // 另一条 rebuild 在跑(Advanced 的 per-service,或其他 OneClick 实例)→ 禁用,
            // 防撞 `.shared.runningTask` 非 actor-safe 的 race 窗口。
            .disabled(isExternalBackfillActive)
            .accessibilityLabel(startAccessibilityLabel)
        case .themes, .embeddings, .suggestions:
            VStack(alignment: .trailing, spacing: 4) {
                // (2026-05-19 P2-05 audit)运行中显式停止按钮 — 重建可能跑几分钟,之前只有
                // ProgressView spin 没有出口。stage 是 .suggestions 时一条 LLM call 没法 cancel
                // (PromptSuggestionEngine 不持 task handle),只能停 theme/embedding 两个阶段。
                if stage == .themes || stage == .embeddings {
                    Button {
                        #if canImport(UIKit)
                        HapticManager.shared.impact(.light)
                        #endif
                        stopAll()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                                .font(.caption2)
                            Text(NSLocalizedString("停止", comment: "Stop backfill"))
                                .font(.caption.weight(.semibold))
                        }
                        .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(.red)
                    .controlSize(.small)
                    .accessibilityLabel(NSLocalizedString("停止重建全部 AI 分析", comment: "Stop all AI analysis rebuild a11y"))
                } else {
                    ProgressView()
                }
                Text(progressDetail)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
    }

    /// 完整停止请求交给 shared coordinator；页面 pop / 重进不会换掉 sentinel。
    private func stopAll() {
        coordinator.stopOneClick()
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
                return NSLocalizedString("用最新的 AI 重新分析所有日记", comment: "One-click idle subtitle")
            }
            if pendingCount == 0 {
                return NSLocalizedString("索引已是最新,无需重建", comment: "Up to date")
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
            return NSLocalizedString("索引已是最新", comment: "One-click done")
        case .failed(let message):
            // 失败原因可能是:网络挂、后端 5xx、AI rate-limit、JSON 解析错。
            // 用户视角无法区分,统一提示"先检查网络再重试"——网络稳定下重试基本能恢复,
            // 真 AI 错(rate-limit / 5xx)隔一会儿后端也会自愈。
            return String(
                format: NSLocalizedString("部分步骤失败:%@。请检查网络后重试。", comment: "One-click failed with retry hint"),
                message
            )
        }
    }

    private var progressDetail: String {
        switch stage {
        case .themes:
            return "\(themeService.progress.processed)/\(themeService.progress.total)"
        case .embeddings:
            return "\(embeddingService.progress.processed)/\(embeddingService.progress.total)"
        case .suggestions:
            return NSLocalizedString("生成建议中…", comment: "One-click suggestions stage detail")
        default:
            return ""
        }
    }

}

// MARK: - Embedding backfill row

struct EmbeddingBackfillRow: View {
    @StateObject private var service = EmbeddingBackfillService.shared
    // OneClickRow / ThemeBackfillRow / suggestion refresh 在跑时禁用本按钮，
    // 避免不同入口争用同一组进程级 service。
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
                        .foregroundStyle(Color.primary)
                    if !service.progress.isRunning, service.progress.total > 0 {
                        Text(backfillLastRunText(
                            processed: service.progress.processed,
                            failed: service.progress.failed
                        ))
                            .font(.caption)
                            .foregroundStyle(service.progress.failed > 0 ? Color.orange : Color.secondary)
                    }
                }
            } icon: {
                Image(systemName: "sparkle.magnifyingglass")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundColor(.accentColor)
                    .frame(width: 24)
            }
            Spacer()
            if service.progress.isRunning {
                VStack(alignment: .trailing, spacing: 4) {
                    // (2026-05-19 P2-05 audit)per-service 入口同样加 "停止" 按钮,跟主入口对齐。
                    Button {
                        #if canImport(UIKit)
                        HapticManager.shared.impact(.light)
                        #endif
                        if coordinator.isOneClickRunning {
                            coordinator.stopOneClick()
                        } else {
                            Task { await service.cancel() }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                                .font(.caption2)
                            Text(NSLocalizedString("停止", comment: "Stop backfill"))
                                .font(.caption.weight(.semibold))
                        }
                        .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .tint(.red)
                    .controlSize(.small)
                    .accessibilityLabel(coordinator.isOneClickRunning
                        ? NSLocalizedString("停止重建全部 AI 分析", comment: "Stop all AI analysis rebuild a11y")
                        : NSLocalizedString("停止生成语义索引", comment: "Stop embedding index rebuild a11y"))
                    Text("\(service.progress.processed)/\(service.progress.total)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else {
                Button(action: start) {
                    Text(NSLocalizedString("开始", comment: "Start"))
                        .font(.caption.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .disabled(isOtherBackfillActive)
                .accessibilityLabel(NSLocalizedString("开始生成语义索引", comment: "Start embedding index rebuild a11y"))
            }
        }
    }

    private func start() {
        // UI .disabled(isOtherBackfillActive) 已守 button,但 accessibility action /
        // UITest 可绕过 disabled state 调到 action body。defense-in-depth。
        guard !isOtherBackfillActive else { return }
        Task { await service.backfillAll() }
    }
}

// MARK: - Theme backfill row

struct ThemeBackfillRow: View {
    @StateObject private var service = ThemeBackfillService.shared
    // OneClick / Embedding / Suggestion 路径在跑时禁用本菜单。
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
                        .foregroundStyle(Color.primary)
                    if !service.progress.isRunning, service.progress.total > 0 {
                        Text(backfillLastRunText(
                            processed: service.progress.processed,
                            failed: service.progress.failed
                        ))
                            .font(.caption)
                            .foregroundStyle(service.progress.failed > 0 ? Color.orange : Color.secondary)
                    }
                }
            } icon: {
                Image(systemName: "tag.square.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundColor(.accentColor)
                    .frame(width: 24)
            }
            Spacer()
            if service.progress.isRunning {
                VStack(alignment: .trailing, spacing: 4) {
                    // (2026-05-19 P2-05 audit)主题重建同样加 "停止" 按钮。
                    Button {
                        #if canImport(UIKit)
                        HapticManager.shared.impact(.light)
                        #endif
                        if coordinator.isOneClickRunning {
                            coordinator.stopOneClick()
                        } else {
                            Task { await service.cancel() }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                                .font(.caption2)
                            Text(NSLocalizedString("停止", comment: "Stop backfill"))
                                .font(.caption.weight(.semibold))
                        }
                        .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .tint(.red)
                    .controlSize(.small)
                    .accessibilityLabel(coordinator.isOneClickRunning
                        ? NSLocalizedString("停止重建全部 AI 分析", comment: "Stop all AI analysis rebuild a11y")
                        : NSLocalizedString("停止刷新主题", comment: "Stop theme refresh a11y"))
                    Text("\(service.progress.processed)/\(service.progress.total)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else {
                Menu {
                    Button {
                        guard !isOtherBackfillActive else { return }
                        Task { await service.backfillProblems() }
                    } label: {
                        Label(NSLocalizedString("只修有问题的", comment: "Backfill problems only"), systemImage: "wand.and.stars")
                    }
                    Button {
                        guard !isOtherBackfillActive else { return }
                        showAllConfirm = true
                    } label: {
                        Label(NSLocalizedString("全部重抽", comment: "Backfill all"), systemImage: "arrow.clockwise")
                    }
                } label: {
                    // P1-Set-9 加 chevron.down 暗示这是 Menu(下拉两个选项),纯"开始"label 用户以为是单按钮。
                    HStack(spacing: 4) {
                        Text(NSLocalizedString("开始", comment: "Start"))
                        Image(systemName: "chevron.down")
                    }
                    .font(.caption.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .disabled(isOtherBackfillActive)
                .accessibilityLabel(NSLocalizedString("刷新主题选项", comment: "Theme refresh options a11y"))
            }
        }
        .alert(NSLocalizedString("重抽所有日记的主题？", comment: "Backfill all confirm title"),
               isPresented: $showAllConfirm) {
            // P0-Set destructive 按钮 label 必须重复动作动词(Apple HIG)
            // — "确定"/"OK" 用户看到红字下意识犹豫但不知道按了到底是确定什么,改成 "全部重抽" 跟外层 Menu 选项对齐。
            Button(NSLocalizedString("全部重抽", comment: "Backfill all"), role: .destructive) {
                guard !isOtherBackfillActive else { return }
                Task { await service.backfillAll() }
            }
            Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("会调用一次 AI。如果只是想清理『情绪』这类标签，选『只修有问题的』更省。",
                                   comment: "Backfill all confirm message"))
        }
    }
}

private func backfillLastRunText(processed: Int, failed: Int) -> String {
    String(
        format: NSLocalizedString("上次处理 %d 条，失败 %d 条", comment: "Backfill last result"),
        processed,
        failed
    )
}
