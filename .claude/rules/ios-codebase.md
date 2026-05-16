---
paths:
  - "Chronote/**"
  - "LumoryWidgets/**"
  - "LumoryWidgetShared/**"
---

# Lumory iOS 端 — 架构 + 关键 service + 踩过的坑

主 App 源码在 `Chronote/`(历史目录名,产品/target/scheme 都叫 `Lumory`)。两个 target:`Lumory`(主 App)+ `LumoryWidgets`(.appex)+ 双 target 共编 `LumoryWidgetShared/`。

## 启动序列([ChronoteApp.swift:45](Chronote/ChronoteApp.swift:45) `init()` 起)

- `PersistenceController.shared` 同步初始化(store 加载失败走 `DatabaseRecoveryService`)。
- `DataMigrationService.performMigrationIfNeeded()` 放 `Task.detached(.userInitiated)` —— **绝不要**挪回 `init()` 同步调用,会触发 watchdog。
- 权限请求(只剩麦克风,SFSpeech 已移除)、动画预热、图片迁到 iCloud([ChronoteApp.swift:199](Chronote/ChronoteApp.swift:199) `migrateExistingImagesToiCloud`)、`WordCountBackfillService.backfillIfNeeded()`([ChronoteApp.swift:118](Chronote/ChronoteApp.swift:118))。
- `EmbeddingBackfillService` / `ThemeBackfillService` **不 auto**(历史上自动跑踩过 actor-safety + 弱网失败率坑)。

## CloudKit

容器 `iCloud.com.Mingyi.Lumory`,`CloudKit` + `CloudDocuments` capabilities,`aps-environment=production`,`UIBackgroundModes=remote-notification`。远端变更通过 `NSPersistentStoreRemoteChange` 驱动 `WordCountBackfill`。

## 场景切换(`onChange(of: scenePhase)` 起 [ChronoteApp.swift:379](Chronote/ChronoteApp.swift:379))

- `.background`:flush `viewContext` 防输入丢失 + `EntryDeletionUndoService.shared.commitPendingNow()` 兜底防 attachment 孤儿。
- `.active`:`syncMonitor.checkCloudKitStatus()`([ChronoteApp.swift:426](Chronote/ChronoteApp.swift:426))+ `ReminderService.shared.requestReschedule()`([ChronoteApp.swift:430](Chronote/ChronoteApp.swift:430),内部已对 `!isEnabled` 早返,只 cancel pending 不跑 CoreData fetch)。

## Model 层(`Chronote/Model/`)

- CoreData entity `DiaryEntry` 字段:`id / date / text / moodValue / summary / audioFileName / imageFileNames / imagesData / themes(CSV,≤6 tag 去重)/ embedding(Data,V1 格式 [4B 'EMB1'][4B LE dim][N*Float32 LE],legacy 裸 dump 兼容)/ wordCount(Int32)`。
- `PersistenceController` — `cachedModel` 静态共享 `NSManagedObjectModel` 防 Core Data ambiguity SIGABRT(2026-04-29 锁死,见下方"测试套 SIGABRT" 段)。
- `DiaryEntry+Extensions` — 业务逻辑入口:themes 清洗、embedding 编解码、图片三层回退、`recomputeWordCount`。
- `DiaryEntryData`(跨线程 DTO)/ `LegacyDiaryEntry`(v2 JSON 源模型)。

## Services(`Chronote/Services/`)关键文件

写日记 / 删日记 / 派生缓存清理:
- [EntryCreationService.swift](Chronote/Services/EntryCreationService.swift) — `@MainActor enum`。`create(_:in:viewContext:ai:aliasJudge:requestReminderReschedule:) async -> Result(.saved(UUID) / .failed)`。3 个 `*OffMain` helper `nonisolated static`(audio iCloud / image disk / NSKeyedArchiver sync blob)+ `performAIWriteback async -> Bool`(stale-write guard + fire-and-forget 生产 / 单测可 await)。`aliasJudge` 默认调 `ThemeAliasJudgeService.shared.judgeAfterWrite`,`requestReminderReschedule` 默认调 `ReminderService.shared.requestReschedule`(注入闭包让单测能传 `{}` 防 reminder 偷调 `.shared`)。
- [EntryDeletionUndoService.swift](Chronote/Services/EntryDeletionUndoService.swift) — 单例 `@MainActor`,4 秒撤销窗口 + attachment 延迟清。`register(snapshot:)` 启动撤销 task,`undo(into:)` 从快照重建 entry 并调 `EntryWipeOrchestrator.performSingleDeleteCleanup()`,`commitPendingNow()` 兜底清。
- [EntryWipeOrchestrator.swift](Chronote/Services/EntryWipeOrchestrator.swift) — `@MainActor enum`。**派生缓存清理唯一入口**。两条 API:
  - `performBulkWipeCleanup() async`:5 件套 — `ReminderService.requestReschedule + ThemeAliasResolver.resetForBulkEntryWipe(保留 negativePairs)+ PromptSuggestionEngine.clearCache + InsightsResultCache.clear + WidgetSnapshotService.clear(写 empty + reload widget,`await` 因后台 grace 切 unstructured Task)`。callsite:`SettingsEntryDeletionService.deleteAll` / `DatabaseRecoveryService.executeRecovery`。
  - `performSingleDeleteCleanup()`:4 件 — Reminder reschedule + Prompt cache clear + Insights cache clear + alias 孤儿清理(fire-and-forget)+ `WidgetSnapshotService.invalidateCaches()`。**不**主动 clear widget,依赖 `NSManagedObjectContextDidSave` 观察者重抓。callsite:`HomeView.deleteEntry` / `DiaryDetailView` / `ThemeFilteredEntriesView` / `PointDetailSheet`。
  - `EntryDeletionUndoService.undo` 也调 `performSingleDeleteCleanup()` —— 撤销复盘"集合变化"。
  - **写新删除路径必须走这俩 API**,不要重新硬编码五/四件套 — 漏一个 → banner / 通知 body / 别名管理页 / Insights / 主屏 widget 引用 ghost entry。

AI / 文本 / 嵌入:
- [AIService.swift](Chronote/Services/AIService.swift) — `AIServiceProtocol` + `MockAIService`(单测用)。
- [OpenAIService.swift](Chronote/Services/OpenAIService.swift) + [Services/OpenAI/](Chronote/Services/OpenAI/) — 生产实现,`.shared` singleton,走后端代理。Wave11 拆 7 文件:`OpenAIService.swift`(主入口)+ `OpenAI/SSEParser.swift / OpenAIService+Streaming.swift / +OneShotAI.swift / +Suggestions.swift / +ThemeAlias.swift / +Import.swift`。**2026-05-16 加 testability seam**:`init(session: URLSession = .sharedRetrySession, appSharedSecret: String = AppSecrets.appSharedSecret)`,生产默认参数 fall back 全局单例(行为不变),MockURLProtocol 测试可注入 mock session + dummy secret 完全解耦真后端。5 处 callsite(chat / chatThrowing / streaming×2 / oneShotAI)走 `self.session` + `applyBackendAuth(sharedSecret:)`;empty-secret guard 统一 `BackendErrorMapper.missingSharedSecretError()`(domain="BackendError" code=401)。`OpenAIService+Import.swift` 的 `encodeImportPayload(rawText:today:calendar:)` 强制 `Calendar(identifier: .gregorian)` + 继承 caller `timeZone` + POSIX locale —— `client_today` / `client_year` 必须同 timeZone,避免纽约 23:00 = UTC 跨日的 5/16 误归本年。
- [ThemeAliasResolver.swift](Chronote/Services/ThemeAliasResolver.swift) — **主题别名映射唯一真源** facade(2026-05-16 round 1 拆出 `ThemeAliasStore`)。`@MainActor` ObservableObject + `.shared` singleton,callsite 22+ 处不动。负责:**mutation 业务逻辑**(enqueue / confirm / reject / mergeThemes / unmerge / deleteGroup / clearAllPending / resetForBulkEntryWipe / resetNegativePairs / markAutoScanned / cleanupOrphanedPending / purgePending)+ **queue/throttle/cool-down**(sessionDismissCount / coolUntilExpiryTimer / scheduleCoolUntilExpiry C4 fix)+ **UI signal**(redDotVisible / NotificationCenter.post(.themeAliasMapDidChange))。**关键不变量**:(1) 每个 mutation 前显式 `objectWillChange.send()` —— store 不是 ObservableObject,SwiftUI 不会自动追;(2) 每次写 `coolUntil` 后调 `scheduleCoolUntilExpiry()`(原 didSet 在 Store 拆出后没了);(3) `reject` + bumpDismissCount 用 `coolUntilForBumpedDismiss()` pure helper 合并到**单次** `store.update`,保证"一次业务 mutation 一次 save / 一次 rebuildIndex" 契约。read API + pure helpers 全部 forward 到 store。
- [ThemeAliasStore.swift](Chronote/Services/ThemeAliasStore.swift) — **数据层 + 持久化**(2026-05-16 从 Resolver 拆出)。`@MainActor final class` **非** ObservableObject,5 个 `private(set) var` 字段(groups / negativePairs / pending / coolUntil / didAutoScanOnce)+ `aliasToCanonical` reverse index + UserDefaults 持久化(key `lumory.themeAliasStore.v1`)。**单一 mutation 入口** `update((inout State) -> Void)`:caller 在 inout 闭包内修改 state,退出后**自动一次** `rebuildIndex()` + `save()`。纯读 API(`canonicalize` / `snapshotIndex` / `knownLowercasedTagsCovered` / `isNegative` / `collateralLabels`)+ 静态 helpers(`pairKey` / `aliasToCanonicalLowerLookup` — 后者契约:canonical 自指必须返 nil,只命中 alias bucket)。decode 失败 → corrupted backup rotate 留 2 个。**不修改 entry.themes CSV** —— alias 是纯展示层。注入点只两处:`InsightsEngine.aggregateThemes` 和 `ContextPromptGenerator.fetchEntries`。
- [ThemeAliasJudgeService.swift](Chronote/Services/ThemeAliasJudgeService.swift) — 把 "AI 判断 → 入待审队列"封起来。两条入口:`judgeAfterWrite(entryID:newTags:)`(写日记后调,**60s soft throttle**)/ `scanAllHistory()`(Settings "扫描已有主题",**模型 gpt-5.5 + reasoning=medium**)。两条都不阻塞,失败静默。
- [InsightsEngine.swift](Chronote/Services/InsightsEngine.swift) — Insights / Ask-Your-Past / 写作伙伴 统一聚合入口,`performBackgroundTask` 读 CoreData,只返值类型。
- [InsightsResultCache.swift](Chronote/Services/InsightsResultCache.swift) — Insights sheet SWR 缓存(`@MainActor` 单例,key=`TimeRange`)。`reload()` 命中即 hydrate 跳过 isLoading,后台仍跑 query 完成后覆盖。**不主动失效**(reload 总盖掉);例外:`EntryWipeOrchestrator` 单/批删都会 `clear()`。
- [ContextPromptGenerator.swift](Chronote/Services/ContextPromptGenerator.swift) · [PromptSuggestionEngine.swift](Chronote/Services/PromptSuggestionEngine.swift) — 提示 / 建议生成。

Narrative 生成流水线(2026-05 wave17/18 抬出来的):
- [NarrativeGenerationCoordinator.swift](Chronote/Services/NarrativeGenerationCoordinator.swift) — `@MainActor @Observable` 单例,管 per-range narrative 生成生命周期。两套独立状态:`generating: Set<TimeRange>`(用户主动 start/重试)+ `precomputing: Set<TimeRange>`(`NarrativePrecomputeService` 后台调 `beginPrecompute/endPrecompute` 透出来的信号)。卡片把两者并集投到 `isStreaming` 渲染 shimmer,**`blocksUserTap` 只读 `generating`**(precompute 是 silent 后台,屏蔽 tap 会让用户莫名点不动)。per-range `streamGeneration` 世代号防 supersession。`cancelAll() async` 是清缓存 / 删日记入口的兜底,**清 generating + precomputing + tasks 三件套**。
- [NarrativePrecomputeService.swift](Chronote/Services/NarrativePrecomputeService.swift) — `actor`,写日记后 60s debounce 在后台预生成 `.month` narrative。debounce 用 `Task.detached(.background)`(`Task { }` 在 actor 内不继承 isolation,显式 detached 让"不抢主线程优先级 + 非 structured" 两层意图明确)。**立刻** `beginPrecompute(.month)` 给 UI 占位,不等 60s + 30s stream 走完;`endPrecomputingIfCurrent` 走 generation 守卫确保 supersede 老 task 不清掉新 task 的 shimmer。`cancelPendingAndBumpGeneration()` 兜底清 `.month` precomputing。
- [NarrativeStreamAccumulator.swift](Chronote/Services/NarrativeStreamAccumulator.swift) — 值类型 `struct: Sendable`,`.chunk` / `.truncated` 共享状态机,`NarrativePrecomputeService` + `NarrativeGenerationCoordinator` 两边消费 SSE 时调。`.failed` / `.done` 故意留给 caller 自己处理(两边语义不同:precompute 失败 abort + backoff;coordinator 把 reason 塞 accumulator 后 `break streamLoop` 退出 = `.failed` 是 terminal event,服务器不会再 yield `.done`)。`markTruncated(reason: "")` 空字符串静默吞(防 UI 渲染空白失败 banner),所有 emitter 必须保证 reason 非空(`localizedDescription` 空时 fallback 到 `NSLocalizedString("narrative.generation.failed", ...)`)。
- [NarrativeCacheService.swift](Chronote/Services/NarrativeCacheService.swift) / [NarrativeStreamSplitter.swift](Chronote/Services/NarrativeStreamSplitter.swift) — `latest(for:in:)` / `isStale` / done 后一次 split rawOutput。

录音 / 转写 / 网络:
- [AudioRecorder.swift](Chronote/Services/AudioRecorder.swift) — `AVAudio` 本地录音(AAC m4a / 16kHz mono)。`interruptedRecordingFileName` 单次消费透出中断段落给 HomeView。
- [Transcriber.swift](Chronote/Services/Transcriber.swift) 协议 + [OpenAITranscriber.swift](Chronote/Services/OpenAITranscriber.swift) 实现(走后端代理 `gpt-4o-mini-transcribe`)+ [BackendErrorMapper.swift](Chronote/Services/BackendErrorMapper.swift) 共享错误映射。失败 UX 用 inline banner + 重试按钮(`recordingVM.transcriptionError`),不再用 alert。**没有** Apple SFSpeechRecognizer fallback。**2026-05-16 加 testability seam**(跟 OpenAIService 对齐):`init(session: URLSession = .sharedRetrySession, appSharedSecret: String = AppSecrets.appSharedSecret)`,生产 callsite `OpenAITranscriber()` 零参 init 走默认 fall back,行为字节级等价旧实现。
- [NetworkRetryHelper.swift](Chronote/Services/NetworkRetryHelper.swift) — SSE / HTTP 重试。每轮 attempt 前会 `try Task.checkCancellation()`。
- [AppSecrets.swift](Chronote/Services/AppSecrets.swift) — 后端 URL + `X-App-Secret` 共享密钥(走 xcconfig 注入链,见根 CLAUDE.md "Secrets")。

CloudKit / 数据库 / 导入导出:
- [CloudKitSyncMonitor.swift](Chronote/Services/CloudKitSyncMonitor.swift) · [SyncDiagnosticService.swift](Chronote/Services/SyncDiagnosticService.swift) — CloudKit 状态。
- [DatabaseRecoveryService.swift](Chronote/Services/DatabaseRecoveryService.swift) — 启动时 store 加载失败的恢复(带备份与用户弹窗)。
- [DataMigrationService.swift](Chronote/Services/DataMigrationService.swift) — v2 JSON → CoreData 一次性迁移(启动时 `Task.detached`)。
- `*BackfillService.swift` — `WordCountBackfillService`(启动 + remote-change 自动跑);`EmbeddingBackfillService` / `ThemeBackfillService` **不 auto**,由用户主动触发(Settings 一键重建索引或单独入口)。`runningTask` `@MainActor` 隔离,所有 start/cancel race 锁死。
- [CoreDataImportService.swift](Chronote/Services/CoreDataImportService.swift) · [DiaryExportService.swift](Chronote/Services/DiaryExportService.swift) — 导入导出。**导入解析**走 `AIService.parseImportedDiaries`,没有独立 `DiaryImportService`。
- [UITestSampleData.swift](Chronote/Services/UITestSampleData.swift) — `#if DEBUG`,启动参数 `-LumoryUITestSampleData YES` 让 `PersistenceController.shared` 自动构造 in-memory store(NSInMemoryStoreType + url=/dev/null,完全旁路 CloudKit),`seedIfNeeded` 种 30 条手写 + ~60 条模板化样例。Guard 强制要求 NSInMemoryStoreType。

提醒 / 通知 / Widget:
- [ReminderService.swift](Chronote/Services/ReminderService.swift) — **周期型提醒**(完全本地通知,不走推送)。`frequency`(daily / every3Days / weekly)+ hour:minute,周期从 `anchorDate` 起每 N 天一块。周期内有日记 → fulfilled 无 reminder;周期末未写 → 当天 hour:minute 提醒 + 挂 8 条未来 cycle-end 兜底(`maxFutureFallbacks=8` 远低于 iOS 64 上限)。`requestReschedule()` 在 `!isEnabled` 时只 cancel pending 不跑 CoreData fetch。`useContextualBody` Toggle **新装机默认 off**(privacy-first)+ legacy 用户保护 sentinel migration。`cycleBounds(referenceDate:anchor:frequency:calendar:)` `nonisolated static` 给单测注入 UTC `Calendar`。`cancelAllPendingReminderNotifications` 必须**两条都跑**:pending + delivered(用户关 reminder 后通知中心还堆着旧 reminder 一直能看到)。
- **`ReminderNotificationRouter`**([Chronote/Services/ReminderNotificationRouter.swift](Chronote/Services/ReminderNotificationRouter.swift),2026-05 commit 1a82c0f 从 `ReminderService.swift` 顶部拆独立文件)— **全局 `UNUserNotificationCenterDelegate` 单例**,在 [ChronoteApp.swift:51](Chronote/ChronoteApp.swift:51) 设置。**它接管 App 内所有通知点击和前台展示**。`didReceive`(用户点击)→ `shouldFocusComposer` 判定后 hop `Task { @MainActor in composeFocusRequestID = UUID() }`,HomeView 接住清屏 + 焦点写日记。`willPresent`(前台收到)→ reminder 类放行 `[.banner, .list, .sound]`,非 reminder 沿用默认压制 `[]`。**没有 `willPresent` = 前台通知完全不显示**(无 banner / 无声音)。
- [WidgetSnapshotService.swift](Chronote/Services/WidgetSnapshotService.swift) — **`actor`**,把 CoreData 状态投影成 `LumoryWidgetShared/WidgetSnapshot` JSON,落到 App Group 容器,`WidgetCenter.reloadTimelines(...)` reload。`requestRefresh(persistence:bypassDebounce:)` 内部 250ms debounce + `isInMemory` guard。触发入口:`PersistenceController.init` 挂的 `NSManagedObjectContextDidSave`(filter own coordinator,只挂 `!inMemory` store)+ `NSPersistentStoreRemoteChange` + `ChronoteApp.init` 启动一次 + `EntryWipeOrchestrator.performBulkWipeCleanup` 的 `clear()`。Fetch 配 `NSDictionaryResultType` + `propertiesToFetch=["date","moodValue"]`,**不实例化 NSManagedObject**。`generation: Int` 世代号防 stale write 覆盖刚清的 empty。Content digest dedup(`contentDigest(snap)` 不含 generatedAt)防反复 throttle。`date <= now` predicate 挡住未来 entry。**Prompt 隐私决定 2026-05-04 锁死**:`prompt` 字段渲染主屏 widget headline 不加 opt-in toggle(藏到 toggle 后默认 OFF 等于砍功能);`WidgetSnapshotService.performRefresh` 顶部有锁死注释。
- [LumoryURLRouter.swift](Chronote/Services/LumoryURLRouter.swift) — deep-link 解析。**接两个 scheme**:`mingyi-lumory://`(canonical,widget tap 用)+ `lumory://`(legacy 兼容)。`acceptedSchemes` 在 `route(for:)` 顶部声明,跟 `Lumory-Info.plist` 的 `CFBundleURLSchemes` 一一对齐。**纯函数 `route(for:)` + side-effect `handle(_:)` 分离**,前者单测覆盖,后者调 `ReminderNotificationRouter.requestComposeFocus()`。

其他:
- [HapticManager.swift](Chronote/Services/HapticManager.swift) — 触觉反馈统一入口。
- [StreakMilestoneService.swift](Chronote/Services/StreakMilestoneService.swift) — `evaluateAfterSave(persistence:latestEntryMood:)` fire-and-forget 后台 fetch 算 streak,命中 7/14/30/60/100/(+100) 且之前没庆祝过 → set pendingMilestone,ChronoteApp ZStack 顶层 overlay 自动渲染。

## Views(`Chronote/Views/`)

- [HomeView.swift](Chronote/Views/HomeView.swift) + `HomeView/`:**主文件 519 行**(2026-05-16 从 1433 行拆下来),只剩 state 声明 + view body / mainContentView / mainListContent / sub-view builders + 必要 lifecycle wiring。3 个 `@Observable` VM(`HomeInputViewModel` / `HomeRecordingViewModel` / `HomePhotoViewModel`)+ **6 个 `HomeView+*.swift` extension 文件**(按功能区切分,2026-05-16 拆):`+Search.swift`(handleSearchQueryChange / keywordHits / searchResultsList / searchResultRow / removeDeletedEntryFromSearchResults)/ `+Recording.swift`(handleMicTap / handleStopRecording / processStoppedRecording / startTranscription / retryTranscription / deleteRecording / deleteAudioFileFromDocuments / separatorBeforeAppendingTranscription)/ `+Audio.swift`(playAudio / resolvedAudioURL / hideKeyboard)/ `+Send.swift`(SendSnapshot + handleSendAction 7 步发送流水线)/ `+Entry.swift`(deleteEntry 4 秒撤销 toast + handleDatabaseRecreation)/ `+Helpers.swift`(草稿 debounce / persistDraft / 占位语 / pull-to-refresh / 通知点击 focus / 照片压缩)。`Components/` 下 `HomeComposerCard`(输入卡 + 录音 row + 照片 row + 工具栏,`@Bindable` VM + `@ObservedObject` recorder/playbackController + `@FocusState.Binding` + callbacks 边界)/ `HomeTimelineList`(含 `HomeTimelineEmptyState`)/ `HomeTimelineRow` / `HomeTimelineCard` / `RecordingRow` / `InputPhotoThumbnail` / `DiaryPreviewView` / `DiaryEntryRow`(后者放在 HomeView/Components 但实际只被 Insights 用,首页改用 HomeTimelineRow)。**`HomeView` struct 大部分 stored prop 是 internal**(无 modifier)而非 private,因为 Swift `private` 在 extension 是 file-scoped,跨文件够不到。主 struct 顶部有约定注释。**注意:`recorder` / `audioPlaybackController` 故意留 HomeView 作 `@StateObject`,不搬进 @Observable VM —— Observation 宏不 bridge 嵌套 `ObservableObject` 的 `@Published`,搬进去 UI 就不 react 了。** 草稿 debounce task / scenePhase=background flush 留 `+Helpers.swift`,child 经 `onInputTextChanged` callback 把新值送出来。Home 顶部 `safeAreaInset(.top)` 挂 [ThemeAliasBanner](Chronote/Views/Components/ThemeAliasBanner.swift),录音/转写/发送/输入态时不弹。
- `Insights/` — `InsightsView` · `AskPastView` · `TimeRange` · `PointDetailSheet` · `ThemeFilteredEntriesView` · `ThemeMergeIntoSheet`(三个 sheet 从 InsightsView 拆出,closure 回调跟 parent),组件见 `Insights/Components/`(`WritingHeatmap`、`ThemeCardList`、`NarrativeSummaryCard`、`NarrativeDetailSheet`、`ConversationHistoryView`、`CitationEntryCard`)。Narrative pipeline 相关 service:`NarrativeGenerationCoordinator` / `NarrativePrecomputeService` / `NarrativeStreamAccumulator` / `NarrativeCacheService` / `NarrativeStreamSplitter`(详见 Services "Narrative 生成流水线" 段)。
- **`NarrativeSummaryCard` 状态拆分(2026-05-15 wave18 d1164d1)**:`isStreaming`(视觉层 = `coordinator.generating ∪ coordinator.precomputing`)vs `blocksUserTap`(交互层 = **仅** `coordinator.generating`)。precompute 是 silent 后台,屏蔽 tap 会让用户莫名"卡片点不动",**不要**让 `blocksUserTap` 读 precomputing 集合。两者解耦后:写完日记立刻进 Insights 看到 shimmer(走 precomputing 信号),但仍能 tap 进 detail 看旧 narrative。
- `Settings/` — `AdvancedSettingsView` · `SettingsBackfillRows`(`@MainActor BackfillCoordinator` + `OneClickRebuildRow` / `EmbeddingBackfillRow` / `ThemeBackfillRow`)· `SettingsEntryDeletionService`(`@MainActor enum`,`deleteAll(entries:viewContext:) async -> Bool`,内含五件套 + 私有 `EntryAttachmentSnapshot: Sendable`)。
- 其他 View:[DiaryDetailView.swift](Chronote/Views/DiaryDetailView.swift) · [SettingsView.swift](Chronote/Views/SettingsView.swift) · [SyncDiagnosticView.swift](Chronote/Views/SyncDiagnosticView.swift) · [DiaryImportView.swift](Chronote/Views/DiaryImportView.swift) · [DiaryExportView.swift](Chronote/Views/DiaryExportView.swift) · `ImageViewerView.swift` · [ThemeAliasManagementView.swift](Chronote/Views/ThemeAliasManagementView.swift)(主题别名管理:扫描/待审/已合并三段)· `LockScreenView.swift`。
- `Components/` — 跨 view 共享:`MoodSpectrumBar`、`MarkdownText`、`ThumbnailImageDecoder`、`SuggestionTargetPickerSheet`、`PressableScaleButtonStyle`、`ThemeAliasBanner`(顶部软提示,liquidGlass + 5s 折叠)、`AudioPlaybackController`(HomeView + DiaryDetailView 各持一份独立 `@StateObject`,共享类型不共享实例)、`FlowLayout`、`LumoryToast`(全局 toast 单源 `LumoryToastCenter.shared`,`@Observable`)、`AudioMeterBar`、`StreakMilestoneCelebration`、`LumoryAdaptivePresentation`(sheet/iPad 适配 + `lumorySheetDecoration()` 自动加 `Color(UIColor.systemBackground)` 纯白底 + 28pt 圆角)。
- `Shared/` — `EmptyStateView`、`Animations/BreathingDots`。

## Extensions / Utils

- `Extensions/` — `Color+MoodSpectrum`、`Image+Compression`。
- `Utils/` — `AnimationConfig`(token 详见 `views-design-tokens.md` rule)/ `LiquidGlass`(含 `LumoryCornerRadius { card 16 / chip 22 / inline 12 }`)/ `LocalizationHelper`/ `Log` / `MoodLabels` / `PerformanceOptimization` / `LumoryDateFormatters`(11 个 system-locale 共享 `DateFormatter` + 6 个 language-aware accessor;**3 个 POSIX-locked token**:`fileTimestamp`(文件名)/ `isoDatePOSIX`(LLM prompt 防本地数字系)/ `httpDate`(RFC 7231 Retry-After);收编范围已从 view 层扩到 service 层,DiaryExportService / NetworkRetryHelper / OpenAIService+Streaming 都用共享 cache,**仍保留 inline 的**只剩 prompt-specific 中文格式 / ISO 周指纹 / ISO8601DateFormatter)。

## Widget(`LumoryWidgets/` + `LumoryWidgetShared/`)

- `LumoryWidgetShared/` — **双 target 共享 sources**(同时编进 Lumory 主 App + LumoryWidgets extension),**只 import Foundation**。文件:`AppGroupConstants` / `LumoryWidgetKind` / `WidgetSnapshot`(Codable DTO)/ `WidgetSnapshotStore`(纯文件 IO,App Group 容器内 `Library/Application Support/Widget/snapshot.json`,`overrideURL` testing seam)/ `WidgetTodayContext`(纯函数,算 `wroteToday` + `effectiveStreak`,给 widget provider 和单测共用)。**禁止**引 UIKit / CoreData / WidgetKit / AppSecrets / 主 App service —— 一污染就编不过。
- `LumoryWidgets/` — extension target。`LumoryWidgetsBundle`(`@main`,注册两个 widget)/ `QuickWriteWidget` + `QuickWriteEntryView`(small / medium / large 三档主屏 widget)/ `LockStreakWidget`(锁屏 streak widget,accessoryCircular / accessoryRectangular / accessoryInline)/ `QuickWriteProvider`(TimelineProvider,提供两条 entry @ now / @ next-midnight+5min,跨午夜让系统自然翻"今天未写")/ `MoodColor`(复制自 `Color+MoodSpectrum.swift`)。Info.plist 只声明 `NSExtensionPointIdentifier=com.apple.widgetkit-extension`;entitlement 只挂 App Group(**不**挂 CloudKit)。
- **Widget V2 schema 已删所有日记正文字段**(V1 的 `lastEntryDisplayText` / showSnippets toggle / scrubSnippetsImmediately 全砍)。**残留 PII**:`prompt` 字段是 AI 基于近期 themes/mood 生成的第二人称短句,渲染主屏 `QuickWriteWidget` headline,默认 ON 无 opt-in。补法对齐 reminder `useContextualBody`(加 `lumory.widget.useContextualPrompt` UserDefaults key + Settings 行)在 P1 backlog 没顺手做。
- **Widget 跨设备同步限制**:CloudKit 同步路径 → 主 App 进程必须正在跑(前台/后台/被 background processing 唤醒)才会收到 `NSPersistentStoreRemoteChange` → 触发 `WidgetSnapshotService` 重写 snapshot。**主 App 长期被杀的情况下 widget 看不到新内容**,这是 WidgetKit 固有限制,不是 bug。

## 本地化

中(`zh-Hans.lproj`)/ 英(`en.lproj`),由 `@AppStorage("appLanguage", store: AppGroup.userDefaults)` 切换 —— **主 App + widget extension 共用 App Group `group.Mingyi.Lumory` 这个 UserDefaults suite**,不是 `.standard`。`Bundle.appLanguageBundle` 在 `LumoryWidgetShared/LocalizationHelper.swift`,读取链 `AppGroup.userDefaults` → `UserDefaults.standard`(老用户迁移期 fallback)→ `Locale.current.identifier`。`ChronoteApp.init` 里有 idempotent 一次性 copy 把老用户 `.standard` 的旧值搬到 App Group。

---

# 踩过的坑(iOS / Swift / Xcode 通用)

## CoreData / 持久化

- **CoreData 迁移**不要同步跑在 `init()`。回填用 `*BackfillService` 模式:`WordCountBackfillService` 走后台 context `fetch(predicate: wordCount == 0)` + 遍历 + save(无 UserDefaults flag,天然幂等)。`Embedding/ThemeBackfillService` 的 `runningTask` 已改 `@MainActor` 隔离。
- **`PersistenceController(inMemory: true)` 在测试套出现 N 次 → SIGABRT**:每次走 `NSPersistentCloudKitContainer(name: "Model")` 重新加载 .xcdatamodeld 生成新 `NSManagedObjectModel`,Core Data `+[DiaryEntry entity]` "Failed to find a unique match"。修法:`PersistenceController.cachedModel` 静态共享 `NSManagedObjectModel`,所有实例传 `managedObjectModel:` 复用(2026-04-29 落地)。看 `~/Library/Logs/DiagnosticReports/Lumory-*.ips` 有 Core Data 栈先怀疑这条。
- **从 main thread 调 `bg.performAndWait` 时不能在 block 内 `DispatchQueue.main.sync`** —— main 在等 bg,立即死锁(SIGTRAP)。模式:用 `var` 把 batch delete 的 `objectIDs` 暂存,等 `performAndWait` 返回(回到 main 自然态)再 merge。`UITestSampleData.seedIfNeeded` 是参考实现。

## SwiftUI

- **`@Environment` 只能在 instance scope 访问**。`private static func` / 属性初始化器里用会报 "instance member cannot be used on type"。静态辅助方法需要 AIService 时,在调用点 `let ai = aiService` 捕获后作参数传(参见 `DiaryDetailView.refreshAIIndex(... ai:)`)。
- **`@FetchRequest(animation:)` 不要用**。和 List 原生 row-removal + `withAnimation { delete }` 三层叠加会错位。当前用 `@FetchRequest(sortDescriptors:)` 无 animation + `ForEach(entries, id: \.objectID)`,动画由 `withAnimation` 单层控制。
- **`.sheet` 必须挂在比"sheet 触发条件"更稳定的视图上**。`Group { if let x, !busy { content().sheet(isPresented: $showing) }}` 这种结构 —— sheet 打开期间 `optional` 变 nil 或 `busy` 翻 true,**整个 content 子树被 SwiftUI 拆掉,sheet 跟着死**,用户搜索/选择被无声打断。修法:把 `.sheet(item: $subject)` 挂到条件渲染外层(`Group` 之上)。`ThemeAliasBanner.body` 是参考实现 —— 历史踩过两遍。
- **SwiftUI `Toggle` 的 binding setter 是 sync nonisolated,关键 cleanup 必须 async + two-pass cancel**。`Binding<Bool>.set` 框架级 sync 不能 await;触发 async cleanup 只能 closure 体内 `Task { @MainActor in ... }`,closure 立刻返回。问题:用户拨完 toggle 立刻锁屏 / 杀 App,iOS 给 ~5s background grace,task 可能没跑完进程就 suspend → cleanup 丢失。`ReminderService.disable()` 踩过(用户关 reminder 后每天还收到通知)。修法:**(a) 关键 cleanup 入口函数改 async,Setter 起 Task 体内 `await` 整段**;**(b) 两步式 cancel 抓 in-flight `await center.add` race** —— 先 await 清一次,再 `await oldTask?.value` 让正在 `center.add` 的老 task 跑完,再 await 清一次抓 race 新增。
- **冷启动通知点击的 cold-launch 消费需要 `.task` + `.onChange` 双路**,只挂 `.onAppear` 不够。路径:用户锁屏点 reminder → `userNotificationCenter(_:didReceive:)` 后台 queue 触发 → hop `Task { @MainActor in composeFocusRequestID = UUID() }` 异步 → `.onAppear` 跑时 requestID 可能还 nil → router hop 完成 → `.onChange` fire 救场。**`.task` 在 view 完整 wired-up 后跑,read-and-clear 配合 `.onChange` 双路兜底**,`consumeComposeFocusRequest()` 单次消费保证不重复 focus。HomeView 是参考实现。

## Swift Concurrency

- **NSManagedObject Sendable + Swift 6 兼容防御**(项目当前 `SWIFT_VERSION = 5.0`,strict concurrency 没显式开):`NSManagedObject` 在 iOS 上**不是** `Sendable`。`async` 函数返回 `[DiaryEntry]` / 单个 `DiaryEntry` 必然跨 await boundary,Swift 6 模式编译报错。修法:**函数整体标 `@MainActor`** + 把 `MainActor.run { ... }` wrapper 直接拆掉(冗余,函数已锁主线程)。后台 fetch 仍走 `performBackgroundTask` 拿 `[NSManagedObjectID]`(Sendable),回 main 后 `viewContext.existingObject(with:)` 物化。参考 `HomeView.keywordHits` / `PointDetailSheet` / `ThemeFilteredEntriesView` 同 idiom(全文搜行号会漂,grep 函数名)。
- **`@MainActor` 类的 `static let` / `static func` 也继承 actor 隔离**。从 `Task.detached` 调静态成员会报 `main actor-isolated static method '...' cannot be called from outside of the actor`(Swift 6 直接 error)。修法:静态成员显式 `nonisolated`(参考 [OpenAITranscriber.prepareUpload](Chronote/Services/OpenAITranscriber.swift) — 25 MB 文件读取 + multipart 拼装放后台 Task,主线程只发 URLRequest)。
- **Race-prevention 用世代号别用 `var task: Task!` self-reference**。`var newTask: Task<Void, Never>!; newTask = Task { ... 用 newTask ... }` 在 strict concurrency 触发 `'newTask' mutated after capture by sendable closure` warning(Swift 6 error)。修法:在 class 里加 `var someGen: Int = 0`,每次 `someGen &+= 1` + 闭包捕获 `let myGen = someGen`,完成后 `if self.someGen == myGen { ... }`。两处实例:`ReminderService.currentRescheduleGen`、`ThemeAliasJudgeService.scanGen`。
- **Fire-and-forget `Task { await foo() }` 调用方不持 handle → `foo` 内部 `Task.isCancelled` guard 永不触发,是死代码**。要真 cancel 必须把 Task 存成 ivar(`var fooTask: Task<Void, Never>?`)+ 调用方主动 `cancel()`。fire-and-forget 路径只留语义级守卫(stale-write 防御:`entryStillExists` / 世代号 gen check)更清晰。`ThemeAliasJudgeService.judgeAfterWrite` 是参考实现。
- **`Task` 是 struct,identity check 用 `==` 不是 `===`** —— `Task: Hashable` since Swift 5.5。`===` 编不过(Task 不是 class)。世代号模式比 task identity 更稳。
- **跨 actor / await 边界传递的值类型显式 `: Sendable`**(2026-05-15 superreview-4 P2):即使全 String / Bool / String? 自动满足,显式 conform 把契约锁住 —— future 加一个非 Sendable 字段 Swift 6 strict 会**直接编译错**,而不是沉默退化成"自动 Sendable 不再满足"。参考 [NarrativeStreamAccumulator](Chronote/Services/NarrativeStreamAccumulator.swift) `struct NarrativeStreamAccumulator: Sendable`。
- **`Task { ... }` 在 actor 内不继承 actor isolation**(踩坑容易踩懵):`func foo() async` 是 actor-isolated,但里面 `Task { try? await Task.sleep(...); await self.bar() }` 的 task body 跑在 task 自己的 executor 上,sleep / 普通操作不 hop 回 actor,**只有显式 `await self.something`** 才 hop。这是想要的语义但不直观。改写成 `Task.detached(priority: .background) { ... }` 让"不继承 isolation + 后台优先级"两层意图都显眼,reader 一眼看出是 unstructured 后台任务而非 structured concurrency 子任务。参考 [NarrativePrecomputeService.requestRefreshIfNeeded](Chronote/Services/NarrativePrecomputeService.swift) 的 debounce 链。

## 主题别名 / 业务约定

- **主题别名(ThemeAliasResolver)是展示层,不动 entry.themes**。alias map 在 `aggregateThemes` / `ContextPromptGenerator.fetchEntries` 注入,把 `["宝贝", "Abby"]` 折成同一 canonical bucket;**entry 的 themes CSV 永远保留原文**,用户改主意 unmerge 立即生效。绝对不要写"扫描完成自动 setThemes"这种逻辑 —— 历史上 EmbeddingBackfill 自动改写踩过 actor-safety + 弱网失败率坑,体感是"AI 索引出问题",root 是写时无中间态保护。on-write judge 走 `ThemeAliasJudgeService.judgeAfterWrite`,**模型 gpt-5.5 + reasoning=medium**(mini 抓不到跨语言昵称,low 抓不全),fire-and-forget,失败仅日志。一次性 scan 走 `scanAllHistory`,接受人工 confirm/custom/reject,绝不自动合并。

## 通知 / Reminder

- **本地通知不要 schedule badge counter**。`ReminderService` 只用 `.alert + .sound`,不写 `content.badge` —— badge 数字一旦设了得自己维护清零,状态机一旦设错 App icon 一直挂红 1。
- **`UNCalendarNotificationTrigger(repeats: false)` + 同 identifier 重 schedule = 覆盖**。智能 reminder reschedule 模式靠这个:每次 user 进入 active / 写完日记,**先按 prefix `lumory.reminder.` cancel 所有 pending**,再根据当下状态决定要不要挂今天 + 明天的 one-shot。如果用 `repeats: true` 就没法做"达标了今天不发"的智能逻辑。
- **`UNUserNotificationCenter` 有两个独立 list:`pending` 和 `delivered`,清理必须两个都做**。`pending` 是等 trigger 的(还没 fire);`delivered` 是已 fire 落在通知中心 / 锁屏摘要里展示的。`removePendingNotificationRequests` 不清 delivered。
- **`UNUserNotificationCenterDelegate` 必须实现 `willPresent`,否则前台通知静默**。iOS 默认 = "App 在前台时,通知**不**展示 banner / 不响 sound / 不进通知列表"。手动放行 reminder 类 `[.banner, .list, .sound]`,非 reminder `[]`。`didReceive`(用户点击)路径要单独实现,管 cold launch 和后台点击。两条不互通,缺一全前台通知失效。

## 转写 / 语音

- **转写后追加句末标点必须 guard "末尾已终结"**。`gpt-4o-mini-transcribe` 自带句末标点,SFSpeech 时代的"无条件追加 `.` / `。`"代码迁过来后会双标点("test.." / "你好。。")。修法:`endingPunctuation: Set<Character>` 含 `. 。 ? ? ! ! …` **加上闭合引号 / 括号**(`" ' " ' 」 』 》 ) ） 】 ] }`)。中文写作惯例句末标点放在闭合符号内(`他说"你好。"`),外面再补 `.` 反而怪。参考 `HomeView.startTranscription`。

## SSE 客户端

- **SSE 在客户端**:`OpenAIService.SSEParser` 负责底层解析(支持多行 data: 累加 + `:` 注释行 + 可选空格 + `[DONE]` 识别);`NetworkRetryHelper` 负责传输层异常重试。流式事件走 `AIServiceProtocol.streamReportEvents` / `askEvents` 返回 `AsyncStream<StreamEvent>`,UI 消费端(`NarrativeSummaryCard` / `AskPastView`)和后台消费端(`NarrativePrecomputeService`)在看到 `.truncated` 时 set `isIncomplete` flag 显示/持久化警示状态,**不再**把中文错误字符串当 chunk 吐出去。
- **千万别把 byte→line 切分换回 `URLSession.AsyncBytes.lines`**。Apple ship 的 `AsyncLineSequence` 在 iOS 26 / 部分版本**不为空行 yield `""`**,SSEParser 依赖空行触发 dispatch —— 一旦空行被吞,所有 `data:` event 粘成一坨,EOF 时 decoder 拿到 `{json1}\n{json2}\n...` 多个 JSON 拼起来的怪物,抛 `invalidEvent(byteCount:)` 且**整流一字未 yield**。自家替换实现是 `SSEParser.byteLineSequence`(按 `\n` 切 + 吞 CRLF 的 `\r` + 空行如实 yield)。诊断:服务端 PM2 日志若 `statusCode 200` 且没 `upstream stream errored`,字节就是干净的,bug 在客户端解析。

## 本地化字符串

- **`Lumory-Info.plist` 里改的 `NS*UsageDescription` 会被本地化覆盖**。`Chronote/zh-Hans.lproj/InfoPlist.strings` 和 `en.lproj/InfoPlist.strings` 里的同名 key 在运行时**完全盖过** root plist 的英文 fallback —— 改隐私文案必须**三个文件一起改**(root + zh + en),否则中文 / 英文用户看到的还是旧文案,合规审核会出事。
- **`NSLocalizedString` 必须双语 locale 都加,key 是中文也不能省 zh 那条**。iOS 找不到 key 会沿 fallback 链落到**开发区域 locale**(本项目 en),所以「`zh-Hans` 漏 + `en` 有英文值」→ **中文用户会看到英文**(典型症状:Settings 某行突然蹦出英文)。「en 漏 + key 是中文」→ 英文用户看到原始中文 key。审核改动里新加的 NSLocalizedString 用一行扫:
  ```bash
  git diff HEAD -- Chronote/ | grep -oE '^\+.*NSLocalizedString\("[^"]+"' | grep -oE '"[^"]+"' | sort -u | while read k; do
    grep -qF "$k =" Chronote/en.lproj/Localizable.strings || echo "EN MISSING: $k"
    grep -qF "$k =" Chronote/zh-Hans.lproj/Localizable.strings || echo "ZH MISSING: $k"
  done
  ```
  zh 那条值 = key 也得显式写一行(`"全部清空" = "全部清空";`)。
- **送给 LLM 的日期 / 文件名 / HTTP header 不能走 `Locale.current`**(2026-05-15 superreview-4):阿拉伯 / 波斯 / 缅甸数字系下 `DateFormatter` 默认 locale 渲染 `٢٠٢٦-٠٥-٠٣`,LLM 见非 ASCII 数字可能误读或 prompt 漂移;文件名跨设备 / iCloud 共享时本地数字也碍事;Retry-After 等 HTTP 解析必须 RFC 7231 ASCII。`LumoryDateFormatters` 提供 3 个 POSIX-locked token 兜底:**`isoDatePOSIX`**(LLM prompt 专用)/ **`fileTimestamp`**(`yyyy-MM-dd_HHmmss_SSS`)/ **`httpDate`**(RFC 7231)。**新加给 LLM 的日期一律走 POSIX token,不要新建 `let f = DateFormatter()`**;内部诊断 / view 显示该用 `Locale.current` 的就用现成的 `isoDate` / `monthDay` 等。

## 默认 / sentinel

- **默认 true 的 `Bool` UserDefaults 不能用 `defaults.bool(forKey:)`** —— 缺省返 false,与"显式关"撞。用 `(defaults.object(forKey: key) as? Bool) ?? true`。参考 `ReminderService.useContextualBody`。
- **Bool UserDefaults 默认值翻转有 silent regression 风险,要 sentinel migration**。旧代码靠"读时合成默认值"(没显式写到盘),后续把代码默认值翻转 → 老用户启动时全部静默翻向新默认。修法:用同 feature 的另一个 key(已激活过的存在性标志,如 `enabledKey`)做 sentinel —— 当前 key 缺 + sentinel 已写 → 老用户 → 一次性写**旧默认**锁住体验;两个都缺 → 真新装机 → 走新默认。`ReminderService.loadUseContextualBody` 是参考实现。

## Xcode / 项目配置

- **iOS 部署目标 26.0**(`IPHONEOS_DEPLOYMENT_TARGET` 在 8 个 config 里均一致)。可用 `@Observable` 宏、`@Entry`、`@State<AnyObject>` 语义。
- **Xcode 项目用 PBXFileSystemSynchronizedRootGroup**(共 5 个:`Chronote/` / `ChronoteTests/` / `ChronoteUITests/` / `LumoryWidgets/` / `LumoryWidgetShared/`):新加 .swift 直接放目录里就被对应 target 自动包含,**不要**手编 `project.pbxproj`。
- **xcconfig 注入自定义 Info.plist key 的三个坑**:
  1. `INFOPLIST_KEY_*` build setting 只对 Apple 已知 plist key(`NS*UsageDescription` / `CFBundle*`)有效,自定义 key 必须直接在 `Lumory-Info.plist` 写 `<string>$(VAR_NAME)</string>` 让 Xcode 在 build 时变量替换。
  2. Run Script PBXShellScriptBuildPhase 默认 `showEnvVarsInLog = 1`,会把所有 build setting `export VAR=value` echo 到 xcodebuild 日志(包括 secret)。涉及 secret 时 pbxproj 里手动加 `showEnvVarsInLog = 0;`。
  3. `PBXFileSystemSynchronizedRootGroup` 只自动收 `Chronote/` 下的 swift,**根目录的 xcconfig 不会被识别**。需要手动加 `PBXFileReference`(`lastKnownFileType = text.xcconfig`)到 PBXFileReference section + 加到 root PBXGroup children + 在 project-level Debug + Release 的 XCBuildConfiguration 里写 `baseConfigurationReference = <FILE_ID>`。
- **Info.plist 的 ATS 例外**已删(历史上为旧明文 origin `64.176.209.155` 留的,现在全 HTTPS 走 `lumory.isaabby.com`,不再需要)。

## 日志 API

- **`Log.warning(...)` 不是 `Log.warn`**(后者编译报 "type 'Log' has no member 'warn'")。`Log.Category` 仅 8 个:`general / ai / network / persistence / sync / audio / ui / migration`,新分类要先在 `Log.swift` 注册。
