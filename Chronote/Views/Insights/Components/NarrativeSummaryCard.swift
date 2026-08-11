import SwiftUI
import CoreData
import Combine

// MARK: - NarrativeSummaryCard
//
// InsightsView 顶部"AI 浓缩卡" — 收起态只显一行诗意 headline,tap 整卡 present
// NarrativeDetailSheet 进沉浸阅读。**wave15** 改造:删 inline 展开机制,headline
// 跟 body 都由重活模型一并生成,客户端 stream 收完后用 NarrativeStreamSplitter 一次
// split。streaming 期间用 sparks animate + thinking caption 占位。
//
// **生成策略**:.month 由 NarrativePrecomputeService 在写日记后 8s debounce 后台
// 自动重生(且 entryCount ≥ 3 + cache stale 才触发)。前台卡片不因 stale 自动开流 —
// 用户正在看 Insights 时,summary 不应凭空改写。.all/.quarter/.year 也都必须手动点
// "生成回顾"。
//
// **Cache key**:走 NarrativeCacheService 按 rangeKind 查(滚动 dateInterval 精确匹配
// 永远 miss)。v2 老 cache 无 headline → view 层用 NarrativeStreamSplitter.fallbackHeadline
// 取 body 第一句作 placeholder,不强制重生。
//
// **状态机**(优先级从上到下):
//   1. entryCount < 3 → 空态"日记太少"
//   2. isStreaming + 无 stale headline → 中央 thinking caption
//   3. isStreaming + 有 stale headline → 旧 headline 作底 + 下方 thinking 小字
//   4. !isStreaming + 有 headline → 显 headline (tap 进 detail)
//   5. !isStreaming + 无 headline → "生成回顾"按钮
//
// **detail sheet 用 item: 模式**(NarrativeDetailSubject)而非 Bool + force unwrap —
// payload 是 snapshot 拷贝,sheet 期间 parent state 变化(range reload / stream 完成)
// 不影响 detail 渲染。(wave17 已删 detail 内"重新生成"按钮,对应的 sheet-close intent
// 回调流同步移除。)

/// detail sheet 的 lumoryAdaptiveModal item — payload snapshot 拷贝 + UUID id。
struct NarrativeDetailSubject: Identifiable {
    let id = UUID()
    let payload: AIConversation.NarrativePayload
}

struct NarrativeSummaryCard: View {
    let range: TimeRange
    let dateInterval: DateInterval
    let entryCount: Int
    let mostRecentEntryDate: Date?

    @Environment(\.managedObjectContext) private var viewContext

    @State private var cachedNarrative: AIConversation.NarrativePayload?
    @State private var sparkBreathing: Bool = false
    /// detail sheet present subject。non-nil = sheet 显示中。
    @State private var detailSubject: NarrativeDetailSubject?
    // wave17 — detail 右上角"重新生成"按钮已删,对应的 sheet-close dispatch 同步移除。
    // 想重生成走 Settings 的"清除 AI 回顾缓存" → 卡 fallback 到"生成回顾" CTA → tap 再走流。

    // wave18 — streaming 生命周期从卡片 @State 抬进 NarrativeGenerationCoordinator 单例:
    // 切 range / 关 Insights sheet 不再打断生成。卡片退化成观察者 —— isStreaming /
    // streamFailureReason 从 coordinator 派生,生成结果走 CoreData save → hydrateFromCache 回灌。
    private let coordinator = NarrativeGenerationCoordinator.shared

    var body: some View {
        Group {
            if entryCount < 3 {
                emptyTooFewView
            } else {
                contentCard
            }
        }
        .task(id: range) {
            // wave18 — range 切换**不再 cancel 在飞 stream**。streaming 生命周期归
            // NarrativeGenerationCoordinator,切 range 时它在后台继续跑完 + persist;卡片
            // 只重置自己的纯 UI 动画态,按新 range 重新 hydrate cache。
            sparkBreathing = false
            hydrateFromCache()

            // 前台不自动重生:即便 cache stale,也保持已有文案稳定。否则滚动时间窗口
            // / 后台写入时序会让用户没操作时看到 summary 当场改写。需要更新时由
            // 写日记后的 NarrativePrecomputeService 后台生成,或用户主动点"重新生成"。
        }
        // **P0 fix (2026-05-14)**:`entryCount` / `mostRecentEntryDate` 是 InsightsView 异步
        // `reload()` 回填的 prop;range 切换瞬间它们仍是**上一个 range** 的值(SWR 命中时
        // InsightsView 故意不 reset 成 nil 以免闪 skeleton,见 InsightsView.reload 注释)。
        // 只靠 `.task(id: range)` hydrate → 会拿上个 range 的 entryCount 跑 staleness 判定,
        // `isOutdatedForCurrentEntries` 里 entryCount delta / mostRecent 判定命中 →
        // 把本 range 的真 cache 误判 outdated 抹成 nil;range 没再变就不会重 hydrate,
        // summary 永久消失。(用户现象:月→无 summary 的"年"→回月,summary 没了;
        // 月→entryCount 恰好相等的"季"→回月却正常 —— 同一个 bug 的两面。)
        // 补 onChange:reload 回填本 range 正确的 entryCount/mostRecent 后重新 hydrate cache。
        .onChange(of: entryCount) { _, _ in
            hydrateFromCache()
        }
        .onChange(of: mostRecentEntryDate) { _, _ in
            hydrateFromCache()
        }
        // wave18 — 生成结束(coordinator 把 range 移出 generating)立即从 viewContext 回灌刚
        // 写盘的 narrative。coordinator 的 persist 在「移出 generating」之前完成,所以这里
        // hydrate 能 fetch 到 fresh record,不必等 .onReceive 的 150ms debounce,避免「生成
        // 回顾」CTA 闪一帧。
        .onChange(of: isStreaming) { _, streaming in
            if !streaming {
                hydrateFromCache()
            }
        }
        // **P0 fix (2026-05-13 superreview)**:`.NSManagedObjectContextDidSave` 由 saving context 的
        // 线程 post(NarrativePrecomputeService 的 bg.save 在 bg queue / InsightsEngine 的
        // performBackgroundTask 同样);`.NSPersistentStoreRemoteChange` 由 store 后台 post。
        // SwiftUI `.onReceive` 不带主线程 hop,closure 内直接调 `NarrativeCacheService.latest(... in: viewContext)`
        // 会在 bg 线程访问主 viewContext → CoreData multithreading violation。
        //
        // **P1 fix (2026-05-13 superreview round 2)**:加 entity filter + debounce —— 之前
        // 任何 save 都触发主线程 fetch + 32 JSON decode(CloudKit pull 一阵几十次 save → 100-150ms
        // 主线程占用 + 首屏 narrative 闪烁 + 滚动掉帧)。filter 只在 inserted/updated/deleted
        // 含 AIConversation 时才触发;debounce 150ms 收尾批量保存。
        //
        // Set<NSManagedObject> 的 `is AIConversation` class check + Hashable 走 objectID,
        // 都跨线程安全,filter 跑在 posting thread OK。debounce(scheduler: .main) 自动 hop 主线程。
        .onReceive(
            NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave)
                .filter { note in
                    guard let userInfo = note.userInfo else { return false }
                    let inserted = userInfo[NSInsertedObjectsKey] as? Set<NSManagedObject> ?? []
                    let updated = userInfo[NSUpdatedObjectsKey] as? Set<NSManagedObject> ?? []
                    let deleted = userInfo[NSDeletedObjectsKey] as? Set<NSManagedObject> ?? []
                    return inserted.contains(where: { $0 is AIConversation })
                        || updated.contains(where: { $0 is AIConversation })
                        || deleted.contains(where: { $0 is AIConversation })
                }
                .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
        ) { _ in
            hydrateFromCache()
        }
        .onReceive(
            // RemoteChange notification userInfo 不带 inserted/updated/deleted Set,只 carrying
            // NSPersistentHistoryToken — 没法 entity-filter。靠 debounce 250ms 把 CloudKit pull
            // 一阵 burst 收成一次 hydrate。
            NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)
                .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
        ) { _ in
            hydrateFromCache()
        }
        .onReceive(NotificationCenter.default.publisher(for: .lumoryNarrativeCacheInvalidated)) { _ in
            hydrateFromCache()
        }
        // **不挂 .onDisappear cancel stream**:streaming 生命周期归 NarrativeGenerationCoordinator
        // (一个 @MainActor 单例),不随本卡 view 实例存亡。下滑看主题、切 range、关 Insights
        // sheet —— 生成都在后台继续跑完 + persist;重开 InsightsView 新卡片观察
        // coordinator.generating 仍能显示「生成中」skeleton,完成后走 onChange / onReceive 回灌。
        // (wave18 前 stream 锁在卡片 @State:切 range 会 cancel、关 sheet 状态丢失 ——
        // 见 NarrativeGenerationCoordinator.swift 顶部注释。)
        .lumoryAdaptiveModal(item: $detailSubject) { subject in
            NarrativeDetailSheet(payload: subject.payload) {
                Task { await startGeneration() }
            }
                .environment(\.managedObjectContext, viewContext)
        }
    }

    // MARK: - State predicates

    /// 视觉层 — shimmer / sparks 呼吸读这个。用户主动 ∪ 后台 precompute,让"写完日记立刻
    /// 进 Insights"也能看到 shimmer。
    private var isStreaming: Bool {
        coordinator.generating.contains(range) || coordinator.precomputing.contains(range)
    }

    /// 交互层 — 整卡 tap guard 读这个。**仅**用户主动 start 时屏蔽 tap(他在等自己触发的结果);
    /// 后台 precompute 是 silent,用户不知道在跑,屏蔽 tap 会变成"卡片莫名点不动" → 不该锁 tap
    /// 进 NarrativeDetailSheet 看旧 narrative,也不该锁"生成回顾"按钮。
    private var blocksUserTap: Bool {
        coordinator.generating.contains(range)
    }

    /// 本 range 上一次生成失败 / 截断且**没产出可持久化 body** 的原因。`occurredAt` 比
    /// `cachedNarrative.generatedAt` 早 → 说明之后有更新的 cache 写进来了(重试成功 /
    /// precompute 后台补上),失败标记作废。
    private var streamFailureReason: String? {
        guard let failure = coordinator.streamFailure[range] else { return nil }
        if let generatedAt = cachedNarrative?.generatedAt, generatedAt >= failure.occurredAt {
            return nil
        }
        return failure.reason
    }

    /// incomplete = 在飞失败标记 || 已持久化 payload 自带 incomplete。
    private var isIncomplete: Bool {
        streamFailureReason != nil || (cachedNarrative?.isIncomplete ?? false)
    }

    private var incompleteReason: String {
        streamFailureReason ?? cachedNarrative?.truncatedReason ?? ""
    }

    private func hydrateFromCache() {
        let latest = NarrativeCacheService.latest(for: range, in: viewContext)
        let payload: AIConversation.NarrativePayload?
        if let latest,
           !NarrativeCacheService.isOutdatedForCurrentEntries(
               range: range,
               payload: latest.payload,
               createdAt: latest.createdAt,
               mostRecentEntryDate: mostRecentEntryDate,
               currentEntryCount: entryCount
            ) {
                payload = latest.payload
            } else {
                payload = nil
            }
        // **P1 fix (2026-05-13 superreview)**:之前用 `headline?.isEmpty == false` 过滤导致
        // v2 老 cache(rangeKind != nil + headline == nil)和 v3 incomplete(stream 失败但
        // 已有部分 body)被整个抹掉,`displayHeadline` 的 fallback body 路径永远跑不到。
        // 改用 body 判定:有 body 就 hydrate 进 cachedNarrative,headline 缺失由 displayHeadline
        // 内部 `NarrativeStreamSplitter.fallbackHeadline` 兜底。
        // (wave18:isIncomplete / incompleteReason 改成从 coordinator + cachedNarrative 派生的
        // 计算属性,这里不再写 transient state。)
        cachedNarrative = (payload?.body.isEmpty == false) ? payload : nil
    }

    /// 给收起态卡显示 + detail sheet 标题用。优先 cached headline;v2 老 cache headline=nil
    /// → fallback body 第一段第一句作 placeholder(NarrativeStreamSplitter.fallbackHeadline)。
    private var displayHeadline: String {
        if let h = cachedNarrative?.headline, !h.isEmpty { return h }
        if let body = cachedNarrative?.body, !body.isEmpty {
            return NarrativeStreamSplitter.fallbackHeadline(fromBody: body)
        }
        return ""
    }

    // MARK: - 主卡

    private var contentCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Direction A 重构 (2026-05-12):headline 跟 metadataCaption 包成内 VStack 紧贴
            // (spacing: 6),作为一组"hero 内容";incompleteFooter 仍在外 VStack 14pt 距外的
            // 位置(只在 incomplete + 有 headline 时显)。
            VStack(alignment: .leading, spacing: 6) {
                // wave15 v2 — 删整个 headerRow(单独 sparks 在左上,后面空着难看)。
                // headline 改主位放顶部,sparks 移到底部 footerHint 跟"沉浸阅读" + 右箭头
                // 配成一行 affordance —— 用户一眼看到"这卡可点击进全文"。
                // streaming 时 footer 整体隐藏,让 skeleton 自己说话。
                Group {
                    if isStreaming && displayHeadline.isEmpty {
                        // 还没有任何 headline(无 stale 旧版作底)→ shimmer skeleton 占位。
                        NarrativeSkeletonLoader()
                    } else if isStreaming && !displayHeadline.isEmpty {
                        // 有 stale 旧 headline → 旧版作底 + 下方一行细 shimmer 暗示"新版在路上"
                        VStack(alignment: .leading, spacing: 10) {
                            headlineView
                            NarrativeSkeletonLoader(compact: true)
                        }
                    } else if !displayHeadline.isEmpty {
                        headlineView
                    } else if isIncomplete {
                        // **codex review fix**:首次 stream 失败(.failed → coordinator 把
                        // streamFailure[range] 挂上、body 空不写盘)。现在不能默默走 notGeneratedView,
                        // 否则用户看到的状态是"没生成过",根本不知道刚才失败了。显错误 + 重试按钮。
                        streamFailedView
                    } else {
                        notGeneratedView
                    }
                }

                // metadata caption — 一行细字 "最近 30 天 · 12 篇" 跟 headline 紧贴,
                // 把 WritingHeatmap 退场的"本期 entries"信息接过来。Direction A 设计。
                metadataCaption
            }

            // **codex review fix**:displayHeadline 空时也显 incompleteFooter — 否则
            // 半截但没有 body / headline 的失败状态被吞掉。但失败 + 空 headline 已由
            // streamFailedView 接管,这里只在"有 headline + incomplete"显 footer 提示。
            if isIncomplete && !displayHeadline.isEmpty {
                incompleteFooter
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        // wave16 (2026-05-13):去 accent tint + accent shadow 改 `.insightsCard()` —— 用户反馈
        // "浅蓝色突兀,跟下面 heatmap 不一组"。中性玻璃 + primary shadow 0.05 跟 WritingHeatmap
        // 同一 dashboard token,色系统一。hero 感靠字号 + padding + 第一位排序,不靠 tint。
        .insightsCard(cornerRadius: LumoryCornerRadius.card)
        .contentShape(Rectangle())
        .onTapGesture {
            // 整卡是 button — tap 行为按状态 dispatch:
            //   - 有 headline + cached payload → present detail sheet
            //   - 其他(未生成 / 失败但无 cached headline)→ 触发流(失败时即重试)
            //   - streaming:给轻反馈 + toast,避免用户以为卡片坏了
            //
            // failed 状态下 streamFailedView 内嵌"重试"按钮自带 hit-test,onTapGesture 不会
            // 截断它;卡空白区域 tap 也走 startGeneration,跟按钮语义一致。
            // (2026-05-13 superreview:之前 `else if isIncomplete` / `else if !isIncomplete`
            // body 完全相同 + 注释跟实际行为相反,合并掉。)
            guard !blocksUserTap else {
                HapticManager.shared.impact(.soft)
                LumoryToastCenter.shared.show(
                    NSLocalizedString("正在生成中,稍后再点", comment: "Toast when narrative card is tapped while streaming"),
                    severity: .info
                )
                return
            }
            HapticManager.shared.impact(.light)
            if !displayHeadline.isEmpty, let payload = cachedNarrative {
                detailSubject = NarrativeDetailSubject(payload: payload)
            } else {
                Task { await startGeneration() }
            }
        }
        // VoiceOver:整卡是个隐式 button(自定义 onTapGesture 不带 trait),手动加 isButton + hint
        // 否则 VO 用户读不到"双击展开沉浸阅读"语义,完全错过 detail sheet 入口。
        // a11y hint 状态化 — 未生成态读"双击生成本期回顾",有内容时读"双击打开沉浸阅读"。
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(
            displayHeadline.isEmpty && cachedNarrative == nil
                ? NSLocalizedString("narrative.summary.tapToGenerate.a11y", comment: "A11y hint when card tap triggers generation")
                : NSLocalizedString("narrative.summary.tapToOpen", comment: "Hint when summary card tap opens detail sheet")
        )
        .padding(.horizontal, 16)
    }

    // MARK: - ✨ gutter 对齐常量
    //
    // headlineView / notGeneratedView 都是 `[✨][文字][↗]` 三列。给 ✨ 固定 gutter 宽,
    // metadataCaption 用 `(gutter + 行内 spacing)` 缩进 → "最近 N 天 · M 篇" 跟 headline /
    // "生成回顾" 文字左缘对齐(之前 metadataCaption 从卡 padding 边起,跟 ✨ 对齐而非文字)。
    private static let sparkGutterWidth: CGFloat = 20
    private static let sparkRowSpacing: CGFloat = 8

    // MARK: - Headline(主态三段式 — sparks + 诗意大字 + arrow)

    /// 收起态主态行:`[✨] [headline] [↗]` 三列 HStack,firstTextBaseline 让 icon 跟
    /// headline 第一行字底对齐。整行充满卡宽度,headline `lineLimit(2)` 自然 wrap。
    /// arrow 只在非 streaming 时显(streaming 时 tap 没用,显出来反而误导)。
    /// sparks 在 streaming 时慢呼吸,避免系统 variableColor 默认频率太急。
    private var headlineView: some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.sparkRowSpacing) {
            Image(systemName: "sparkles")
                .font(LumoryFonts.narrativeEyebrow)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .frame(width: Self.sparkGutterWidth)
                .opacity(isStreaming && sparkBreathing ? 0.46 : 1)
                .accessibilityHidden(true)

            Text(displayHeadline)
                // Direction A 升级 (2026-05-12):16 → 19pt — 让 hero headline 真正承担 hero
                // 视觉份量,而不是被下面"事实层"卡片压住。serif + medium 保留诗意感,
                // lineSpacing 配合放大微调到 5。
                .font(LumoryFonts.narrativeHeadline)
                .lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
                .textSelection(.enabled)
                .animation(.smooth(duration: 0.4), value: displayHeadline)

            // `arrow.up.right` 只在"有 headline 可点开沉浸阅读"时显;streaming 时
            // 整卡只给"正在生成中"轻反馈,不提供中断入口。
            if !isStreaming {
                Image(systemName: "arrow.up.right")
                    .font(LumoryFonts.narrativeMeta)
                    .foregroundStyle(Color.accentColor.opacity(0.6))
                    .accessibilityHidden(true)
            }
        }
        .onAppear {
            updateSparkBreathing(isStreaming)
        }
        .onChange(of: isStreaming) { _, streaming in
            updateSparkBreathing(streaming)
        }
    }

    private func updateSparkBreathing(_ streaming: Bool) {
        sparkBreathing = false
        guard streaming else { return }
        withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
            sparkBreathing = true
        }
    }

    // MARK: - Metadata caption(Direction A — hero 卡底部细字行)

    /// 一行 caption "最近 30 天 · 12 篇" 紧贴 headline 下方,接过原 WritingHeatmap heroRow
    /// 退场后的"本期 entries"信息。range.label 给 range 全名(避免歧义),entryCount 是
    /// **range-scoped**(reload 时 engine.entryCount(in:) 算的)。caption 一律在 contentCard
    /// 显(entryCount >= 3 时),空 state / streaming / failed / not-generated 都不影响。
    private var metadataCaption: some View {
        Text(metadataText)
            .font(.caption)
            .foregroundStyle(.secondary)
            // 跟 headlineView / notGeneratedView 的文字左缘对齐 —— 缩进 ✨ gutter + 行内 spacing,
            // 而不是从卡 padding 边起(那样会跟 ✨ icon 对齐,跟上面一行文字错开)。
            .padding(.leading, Self.sparkGutterWidth + Self.sparkRowSpacing)
            .accessibilityHidden(true) // 已经在父级 a11y 里
    }

    private var metadataText: String {
        String(
            format: NSLocalizedString("narrative.summary.metadataFormat", comment: "Hero caption: range · count"),
            range.label,
            entryCount
        )
    }

    // MARK: - 未生成态(三段式跟 headline 同款 layout,只是文字是 CTA placeholder)

    /// 跟 `headlineView` 同款 `[✨] [text] [↗]` 三列,文字换成"生成回顾" placeholder 风。
    /// 整卡 onTapGesture 在未生成态下 dispatch 到 startGeneration — 不再做嵌套紫色 capsule
    /// 按钮(那是用按钮重复表达卡本身可点击,头重脚轻)。
    private var notGeneratedView: some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.sparkRowSpacing) {
            Image(systemName: "sparkles")
                .font(LumoryFonts.narrativeEyebrow)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .frame(width: Self.sparkGutterWidth)
                .accessibilityHidden(true)

            // 用 system 字体 + secondary 浅色 — 跟 headline 衬线诗意大字形成 placeholder
            // 视觉层次(Apple HIG 标准做法,像 SearchField placeholder)。
            // 字号 15 → 17 (2026-05-12) 配合 headline 19pt 升级,placeholder 仍小一档保留视觉层次。
            Text(NSLocalizedString("narrative.summary.cta.generate", comment: ""))
                .font(.headline.weight(.medium))
                .foregroundStyle(Color.primary.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "arrow.up.right")
                .font(LumoryFonts.narrativeMeta)
                .foregroundStyle(Color.accentColor.opacity(0.6))
                .accessibilityHidden(true)
        }
    }

    // MARK: - Stream failed view(首次生成失败 — 无 cache 可作 fallback)

    private var streamFailedView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.subheadline)
                Text(NSLocalizedString("narrative.summary.streamFailed", comment: "Stream failed hint"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !incompleteReason.isEmpty {
                Text(String(
                    format: NSLocalizedString("narrative.summary.streamFailedReason", comment: "Stream failed reason"),
                    incompleteReason
                ))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            Button {
                HapticManager.shared.impact(.light)
                Task { await startGeneration() }
            } label: {
                Text(NSLocalizedString("narrative.summary.regenerate", comment: ""))
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .foregroundStyle(Color.white)
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(PressableScaleButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Incomplete 提示 + 重试

    private var incompleteFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
            Text(NSLocalizedString("narrative.summary.incomplete", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                HapticManager.shared.impact(.light)
                Task { await startGeneration() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .accessibilityLabel(NSLocalizedString("narrative.summary.regenerate", comment: ""))
        }
        .padding(.top, 4)
    }

    // MARK: - Empty(日记 < 3)

    private var emptyTooFewView: some View {
        EmptyStateView(
            systemImage: "sparkles",
            title: NSLocalizedString("narrative.summary.empty.tooFew", comment: ""),
            size: .compact
        )
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        // wave16 — 去 accent tint, 跟主 contentCard 视觉一致
        .insightsCard(cornerRadius: LumoryCornerRadius.card)
        .padding(.horizontal, 16)
    }

    // MARK: - Streaming

    /// 把生成委托给 NarrativeGenerationCoordinator(单例,不随本卡 view 实例存亡)。同 range
    /// 已有在飞 task → coordinator 当「重试」cancel 旧的再起。结果不靠返回值 —— coordinator
    /// persist 到 viewContext 后,卡片靠 `.onChange(of: isStreaming)` / `.onReceive` 回灌。
    private func startGeneration() async {
        await coordinator.start(
            range: range,
            dateInterval: dateInterval,
            entryCount: entryCount,
            mostRecentEntryDate: mostRecentEntryDate
        )
    }
}

// MARK: - NarrativeSkeletonLoader
//
// 生成回顾期间的占位 — **不要再用 "正在 xxx" / "AI 在 xxx" 文字**(用户决定,2026-05-10)。
// shimmer 占位条自带"正在加载"语义,既不打断 ambient 节奏,也不把 AI 实现细节糊到用户脸上。
//
// 视觉:两条圆角占位 bar,宽度递减(模拟段首长 / 段尾短的真实排版),accent tint 微弱底色 +
// 一条对角线 highlight 从左到右慢慢扫光。sparkles 只做呼吸感,这里 shimmer 补
// "内容在路上"的视觉信号,两者职责分明不重复。
//
// `compact` mode 用在"已有 stale 旧 headline + 新版生成中"的状态 — 此时旧 headline 已经在
// 上方,skeleton 收成单行细 bar 只暗示"下面还有更新",避免双重视觉占位。

private struct NarrativeSkeletonLoader: View {
    /// true: 单行 echo 形态,跟 stale headline 共存时用
    var compact: Bool = false

    @State private var sweepPhase: CGFloat = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if compact {
                shimmerBar(widthFraction: 0.74, height: 8)
            } else {
                // 两条不等宽 — 模拟"诗意 headline"的不规则换行节奏,而不是规整的 N 行段落。
                shimmerBar(widthFraction: 0.92, height: 14)
                shimmerBar(widthFraction: 0.64, height: 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, compact ? 0 : 4)
        // a11y:整个 skeleton 是个 isolated element,VoiceOver 报"正在生成回顾"。
        // 单条 shimmer bar 不应该被分别朗读(SwiftUI 默认会把 shape 当 decorative,但 combine
        // 后能拿到一个稳定的 hint label)。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NSLocalizedString("narrative.summary.loading.a11y", comment: "A11y while generating summary"))
        .onAppear {
            // 2.4s 周期左→右循环扫光,比原来更安静,避免跟 spark 呼吸互相抢。
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                sweepPhase = 2
            }
        }
    }

    @ViewBuilder
    private func shimmerBar(widthFraction: CGFloat, height: CGFloat) -> some View {
        GeometryReader { geo in
            let barWidth = geo.size.width * widthFraction
            ZStack(alignment: .leading) {
                // 底色 — accent 极淡 tint,避开纯灰显得脏。
                Capsule()
                    .fill(Color.accentColor.opacity(0.14))

                // sweep highlight — 一条比 bar 短的渐变带,从左外扫到右外。
                // mask 在 Capsule 形状内,sweep 不会出底色 capsule 边界。
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0),
                                Color.white.opacity(0.45),
                                Color.white.opacity(0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: barWidth * 0.45)
                    // sweepPhase: -1 → 2,把 sweep 从 bar 左外 (-0.5 * width) 推到右外。
                    // 用 barWidth 而非 geo.width — sweep 跟着 bar 走不超出。
                    .offset(x: barWidth * sweepPhase - barWidth * 0.225)
                    .blendMode(.plusLighter)
            }
            .frame(width: barWidth, height: height)
            .clipShape(Capsule())
        }
        .frame(height: height)
    }
}
