import Foundation
import CoreData

/// 删除日记后必跑的"派生缓存清理"统一入口。
///
/// **历史背景**:CLAUDE.md 反复 callout 的"五件套清理" — 删 entry 的路径必须同步清掉
/// `ReminderService` / `ThemeAliasResolver` / `PromptSuggestionEngine` / `InsightsResultCache` /
/// `WidgetSnapshotService`,漏一个就会有 banner / 通知 body / 别名管理页 / Insights / 主屏 widget
/// 引用已删 entry 的 ghost 数据。
///
/// 之前 4 处 callsite 各自硬编码:
///   - `SettingsEntryDeletionService.deleteAll`(批量清空)
///   - `DatabaseRecoveryService.executeRecovery`(DB 重建)
///   - `HomeView.deleteEntry`(单删)
///   - `DiaryDetailView.deleteEntry`(单删)
///
/// 任何一处少调一个就静默踩坑。这里收口成两条 API:
///   - `performBulkWipeCleanup()` — 整体清空(包括 widget snapshot 文件 + alias reset)
///   - `performSingleDeleteCleanup()` — 单条删除(轻量;widget 走 save 观察者自动刷,alias 走孤儿清理)
///
/// **顺序**:Reminder reschedule 依赖最新的 entry 集合 → 先调;`Widget.clear()` `await` 等其完成,
/// 防 unstructured Task 被 background grace 切掉残留旧 snapshot。
@MainActor
enum EntryWipeOrchestrator {
    /// 批量清空(用户主动 deleteAll / 数据库重建)。**全 5 件套都跑**,negativePairs 保留(用户主观偏好,
    /// 与 entry 存在与否无关)。
    ///
    /// 调用方负责:**已经成功 commit `viewContext.save()`**;`viewContext` 中的 entry 已 delete。
    /// 本函数只负责派生缓存清理,不动 CoreData。
    ///
    /// `await` 直到所有清理完成 — 调用方应在 `viewContext.save()` 成功分支 await 它,失败分支 rollback 不调。
    static func performBulkWipeCleanup() async {
        // **P1 fix (2026-05-13 superreview)**:写日记后触发 60s NarrativePrecompute debounce 窗口内
        // → 用户立刻删全部日记 → 老 task 完成 stream 后写一条 narrative 引用 ghost entry IDs。
        // SettingsView.resetNarrativeCache 单独的"清除 AI 回顾缓存"按钮已修过这条 race
        // ([SettingsView.swift:654]),bulk wipe 路径(SettingsEntryDeletionService.deleteAll +
        // DatabaseRecoveryService.completeRecreateRecovery)漏。await 等老 task 完整退出 +
        // 世代号推过去后才继续 5 件套清理。
        await NarrativePrecomputeService.shared.cancelPendingAndBumpGeneration()
        ReminderService.shared.requestReschedule()
        ThemeAliasResolver.shared.resetForBulkEntryWipe()
        PromptSuggestionEngine.shared.clearCache()
        InsightsResultCache.shared.clear()
        // Widget.clear 是 actor sync body + 写 App Group 文件 + WidgetCenter.reload。
        // 几 ms 内完成,但用户立刻锁屏 / 杀 App 时 unstructured Task 会被截 → 必须 await 而非 fire-and-forget。
        await WidgetSnapshotService.shared.clear()
    }

    /// 单条删除。比 bulkWipe 轻,但比"未抽 orchestrator 之前"严格:
    ///
    /// **行为变化(故意)**:抽 orchestrator 前 Home/Detail 单删只跑 `requestReschedule` +
    /// `cleanupOrphanedPending`(2 件)。megareview BUG-P1 #1 指出这漏了 Insights / Prompt cache 的清理:
    /// 删一条被 Insights 引用过 / Prompt placeholder 取过样的 entry 后,SWR cache + per-day prompt
    /// cache 仍指向已删数据,UI 显示 ghost 几秒到一天。本 orchestrator 把单删扩到 4 件清理修复这条。
    /// 副作用:每次单删都触发 prompt cache 重新计算 + Insights 下次开 sheet 走 skeleton 而非 warm cache。
    /// 这两个 trade-off 都接受 — 数据正确性大于"warm cache 闪一下"。
    ///
    /// **不动 widget snapshot file**:bulk path 主动 `await Widget.clear()` 是因为整个 widget 的依据
    /// 数据要从盘上抹掉;单删依赖 `NSManagedObjectContextDidSave` 观察者已经 schedule 一次
    /// `requestRefresh` 把 widget 从 CoreData 重抓,不需要主动 clear。
    ///
    /// 调用方负责:`viewContext.save()` 已成功;entry 已 delete。
    static func performSingleDeleteCleanup() {
        ReminderService.shared.requestReschedule()
        PromptSuggestionEngine.shared.clearCache()
        InsightsResultCache.shared.clear()
        // alias 孤儿清理是后台扫,fire-and-forget — 命中率低、不阻 UI。
        // ThemeAliasResolver 是 @MainActor singleton,unstructured Task hop 到 main 跑 cleanupOrphanedPending,
        // 该函数内有自身的 fetch-failure / generation guard,不依赖 Task.isCancelled。
        Task { await ThemeAliasResolver.shared.cleanupOrphanedPending() }
        // **WidgetSnapshotService 自己持有 per-day cachedPrompt + cheap fingerprint** —— `PromptSuggestionEngine.clearCache()`
        // 清的是主 App prompt cache,**不影响** widget 进程 actor 内的 cachedPrompt。删完 entry 后 widget 仍可能
        // 在今天剩余时间显示用已删 entry 算的 placeholder。`invalidateCaches()` 让下一次 widget refresh
        // 走 full path 重抓。
        Task { await WidgetSnapshotService.shared.invalidateCaches() }
        // 单删一篇日记后,现有 narrative body 可能引用 ghost entry 内容。这里只让旧
        // narrative 退出"浓缩卡 cache"资格,不删除 AIConversation 历史记录。
        Task { await Self.invalidateNarrativeCacheOnEntryChange() }
    }

    /// **entry 内容变化(单删 / 编辑文字 / 日期 / 心情 / 摘要)时**调:cancel 在飞 precompute
    /// 防 ghost 写盘 + 标记旧 narrative 不再当浓缩卡 cache 使用。
    ///
    /// 单条 entry 内容变(文字改写 / mood 改 / themes 改)足以让现存 narrative 的 body
    /// 引用过期。旧 AIConversation 仍保留在历史回顾里,但 `NarrativeCacheService.latest`
    /// 会跳过 invalidation marker 之前的记录。
    static func invalidateNarrativeCacheOnEntryChange() async {
        // **P2 fix (2026-05-14 codex review)**:marker + 通知必须在 await cancel **之前**写。
        // `cancelPendingAndBumpGeneration` 内 `await task?.value` 会等在飞的 precompute stream
        // 退出 —— 这期间若 invalidation marker 还没写,用户编辑/删除后立刻打开 Insights,
        // `NarrativeCacheService.latest()` 仍会命中编辑前的旧 narrative(ghost content window)。
        // marker 是同步写 UserDefaults,提前即可关掉这个窗口;cancel + 世代号仍负责挡住在飞
        // task 写盘(它还有 `invalidatedBefore >= streamStartTime` guard 兜底)。
        NarrativeCacheService.markInvalidatedForEntryChange()
        NotificationCenter.default.post(name: .lumoryNarrativeCacheInvalidated, object: nil)
        await NarrativePrecomputeService.shared.cancelPendingAndBumpGeneration()
    }
}
