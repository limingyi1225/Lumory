import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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
final class BackfillCoordinator: ObservableObject {
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

struct OneClickRebuildRow: View {
    @StateObject private var themeService = ThemeBackfillService.shared
    @StateObject private var embeddingService = EmbeddingBackfillService.shared
    @StateObject private var suggestionEngine = PromptSuggestionEngine.shared
    @StateObject private var coordinator = BackfillCoordinator.shared

    @State private var stage: Stage = .idle
    /// 待索引条目数 —— 进入设置时 / 重建完成后刷新一次。nil = 还没查过,不显示数字。
    @State private var pendingCount: Int?
    @State private var isCountingPending: Bool = false
    /// (2026-05-19 superreview P1)stopAll 用的 stop sentinel — runAll 在每阶段 await 后读这个,
    /// 一旦置 true 就立刻 stage=.idle return,后续 .embeddings / .suggestions 阶段不再启动。
    /// 不用 Task.checkCancellation 因为 runAll 在 coordinator.runOneClick 内,外层 Task 没存 handle。
    @State private var oneClickStopRequested: Bool = false

    private enum Stage: Equatable {
        case idle
        case themes
        case embeddings
        case suggestions
        case done
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(NSLocalizedString("重建全部 AI 分析", comment: "Rebuild all AI analysis"))
                            .foregroundStyle(Color.primary)
                        Text(statusText)
                            .font(.caption)
                            .foregroundColor(statusColor)
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
            await refreshPendingCount()
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
                // P1-Set-7 .failed 态用"重试" + 旋转箭头(idle/done 仍是"开始")。
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
            // P1-Set-6 buttonStyle 统一 .glass(原来 OneClick 用 prominent / 单独 row 用 regular,
            // 两者并列时层级跳)。视觉层级靠 Section 位置 + 文字传达。
            .buttonStyle(.glass)
            // 另一条 rebuild 在跑(Advanced 的 per-service,或其他 OneClick 实例)→ 禁用,
            // 防撞 `.shared.runningTask` 非 actor-safe 的 race 窗口。
            .disabled(isExternalBackfillActive)
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
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel(NSLocalizedString("停止重建", comment: "Stop rebuild a11y"))
                } else {
                    ProgressView()
                }
                Text(progressDetail)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
    }

    /// (2026-05-19 P2-05 audit + superreview P1)停止 OneClick 三阶段 chain。
    /// 关键:**只 cancel 当前 service 不够** — runAll 是 sequential await chain,前一阶段返
    /// 后立刻起下一阶段。设 oneClickStopRequested=true 让 runAll 在阶段间隙 short-circuit。
    /// 不主动翻 stage=.idle:runAll 内部 stop check 会自己翻,避免跟 service progress publish 的
    /// 终态写入 race(service.cancel() 不清 runningRunID,publish(...isRunning:false) 仍会到达)。
    private func stopAll() {
        oneClickStopRequested = true
        switch stage {
        case .themes:
            themeService.cancel()
        case .embeddings:
            embeddingService.cancel()
        case .suggestions:
            // suggestions 阶段是单次 LLM call,没 task handle;无法 cancel,只能等它自己结束。
            // 设 stopRequested 后 runAll 跑完该 await 立刻 short-circuit 出 .done/.idle。
            break
        default:
            oneClickStopRequested = false  // idle/done/failed 不该被点,清回去
            return
        }
        Task { await refreshPendingCount() }
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
            return NSLocalizedString("生成建议中…", comment: "One-click suggestions stage detail")
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

        // 进入 runOneClick 前重置 sentinel(防上一轮 stopAll 残留 true)
        oneClickStopRequested = false

        await coordinator.runOneClick {
            stage = .themes
            // wordCount backfill 和主题一起跑——两者都扫全表，挂一块儿不额外往返。
            // 先跑 wordCount：不依赖网络，几十 ms 搞定；顺序上放最前面让"累计字数"最快恢复。
            _ = await WordCountBackfillService.forceBackfill()
            _ = await ThemeBackfillService.shared.backfillAll()

            // (2026-05-19 superreview P1)stop check 1:theme 阶段结束后用户若按停止,
            // 立刻 short-circuit,不再起 embedding 阶段。
            if oneClickStopRequested {
                stage = .idle
                oneClickStopRequested = false
                await refreshPendingCount()
                return
            }

            stage = .embeddings
            _ = await EmbeddingBackfillService.shared.backfillAll()

            // stop check 2:embedding 阶段结束后停止 → 不再起 suggestions。
            if oneClickStopRequested {
                stage = .idle
                oneClickStopRequested = false
                await refreshPendingCount()
                return
            }

            stage = .suggestions
            // forceRefresh 现在返回 Bool：true 表示真的生成了新 bundle；false 表示失败或信号不够。
            // 旧的 `current != nil` 判定在 AI 失败时会被旧 cache 误判成成功。
            let suggestionGenerated = await PromptSuggestionEngine.shared.forceRefresh()

            // stop check 3:suggestions 完成后若用户曾按停止,跳过 done 翻 .idle。
            if oneClickStopRequested {
                stage = .idle
                oneClickStopRequested = false
                await refreshPendingCount()
                return
            }
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

struct EmbeddingBackfillRow: View {
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
                        .foregroundStyle(Color.primary)
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
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
                        service.cancel()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                                .font(.caption2)
                            Text(NSLocalizedString("停止", comment: "Stop backfill"))
                                .font(.caption.weight(.semibold))
                        }
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel(NSLocalizedString("停止重建", comment: "Stop rebuild a11y"))
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
        // UI .disabled(isOtherBackfillActive) 已守 button,但 accessibility action /
        // UITest 可绕过 disabled state 调到 action body。defense-in-depth。
        guard !isOtherBackfillActive else { return }
        Task { await service.backfillAll() }
    }
}

// MARK: - Theme backfill row

struct ThemeBackfillRow: View {
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
                        .foregroundStyle(Color.primary)
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
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
                        service.cancel()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                                .font(.caption2)
                            Text(NSLocalizedString("停止", comment: "Stop backfill"))
                                .font(.caption.weight(.semibold))
                        }
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel(NSLocalizedString("停止重建", comment: "Stop rebuild a11y"))
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
                }
                .buttonStyle(.glass)
                .disabled(isOtherBackfillActive)
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
