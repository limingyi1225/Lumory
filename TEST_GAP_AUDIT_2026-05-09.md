# Lumory Test Gap Audit — 2026-05-09

> 6 路 Opus subagent 并行审计产出。按问题域切片,互不重叠。本报告合并、去重、按 P0/P1/P2 分级。
>
> **2026-05-09 codex 复审修订**:5 处误判已修正(`SyncDiagnostic` 措辞 / `MoodSpectrum` workaround 诚实标注 / `streamReportEvents_truncated` 归因更正 / 后端 rate-limit setup 建议更新 / `ThemeAliasResolver.confirm` 两条已被现有测试覆盖,从 P1 撤销)。第一批已落地 7 条 = 87 个新测试 pass。

## 总览

| 切片 | P0 | P1 | P2 | 关键 seam blocker |
|---|---|---|---|---|
| AI / SSE / 网络 / 转写 | 6 | 4 | 3 | `OpenAIService.chatThrowing` 升 internal |
| Persistence / Backfill / 导入导出 / 删除 | 5 | 11 | 5 | `DataMigrationService` 缺 DI |
| Reminder / Widget / Streak / AppLock / Router | 5 | 9 | 4 | `AppLockService` 缺 LAContext seam · UN center mock |
| Insights / Theme / Prompt / Sync | 5 | 8 | 6 | `ContextPromptGenerator` private 函数暴露 |
| 后端 (Node / Express) | 8 | 8 | 6 | logger / installKey 模块化 |
| UI / Widget extension / Utils / Components | 3 | 5 | 9 | NarrativeReader/AskPast event handler 抽 pure helper |

**合计 ~110 条候选,3 条已在 `CLAUDE.md` Follow-up backlog 记账(标 `[已记账]`)**。

**已记账 backlog(`CLAUDE.md`)**:
1. `parseImportedDiaries` 错误路径 + `StreamEvent.truncated` 端到端消费侧测试
2. `ReminderService.currentRescheduleGen` race(同等也波及 `disable()` 2-pass cancel)
3. `ThemeAliasResolver` 拆分(代码层,跟测试间接相关)

**现有测试基线**(避免重复劳动):
- `ChronoteTests/ChronoteTests.swift`:**38 个 test suite,~196 个 `@Test` 方法**(cosine、bucketing、mood series、streak、time range、modal、correlation、theme aggregation、rank retrieval、score parsing、suggestion fingerprint、suggestion bundle codable、parse suggestion、sanitize themes、prompt cache freshness/clear、context prompt streak、embedding codec、SSE parser、network retry、narrative text blocks、theme alias agg/canonicalization/resolver、theme management、theme alias judge、reminder body/routing/migration/contextual body/cycleBounds、streak milestone、judge privacy、alias resolver invariants、round2 fixes、persistence cached model、DST streak、leap year cycle bounds)
- `ChronoteTests/DatabaseRecoveryServiceTests.swift`:2 个
- `ChronoteTests/LumoryURLRouterTests.swift`:8 个
- `ChronoteTests/WidgetSnapshotTests.swift`:13 个
- `ChronoteUITests/ScreenshotTests.swift` + `iPadAdaptiveModalSmokeTests.swift`
- `server/index.test.js`:13 个

---

## 🎯 落地建议:第一批 7 条(2026-05-09 已落地,87 个新测试全 pass)

实际拿下来 7 条,1 条延后:

1. ✅ **`MoodSpectrum` ↔ `MoodColor` parity** — 走 reference 复刻 workaround(测试 target 不能 import widget extension)。**重要**:reference 只能锁"主 App + reference 一致",**不能直接锁 widget 漂移** — 漂移防御靠"改 widget 时同步改主 App + 测试 reference"的 CLAUDE.md norm + code review。文件顶部已标注。**root-cause fix**:把算法搬进 shared module,需要先升级 `LumoryWidgetShared` 到 "Foundation+SwiftUI"(当前坚持 Foundation-only 边界);widget 文件顶部明确说"还没值得"。
2. ✅ **`WidgetTodayContext` future-date guard**
3. ✅ **`ReminderService.loadUseContextualBody` legacy sentinel migration**
4. ✅ **`SyncDiagnosticService` 纯部分** — 仅 `SyncIssue.isCritical` + `generateDiagnosticReport` + `SyncDiagnosticSeverity.displayName`(都是纯逻辑/纯函数)。**`performDiagnostic()` 不在覆盖范围**(它碰 CloudKit / FileManager / Persistence,不是纯函数)。
5. ⏸️ **`PromptSuggestionEngine.randomHomePlaceholder` 边界** — **延后**。它需要 `setBundleForTesting` seam 或走 `forceRefresh` 让 `current` 落地,**不是零 setup**;归到 batch-2 跟其他 seam refactor 一起做。
6. ✅ **`NetworkRetryHelper` 429/501 retryable + Retry-After 解析** — 函数虽然 `private static`,但走端到端 `performWithRetry { throw <error> }` + 测量 attempt 之间 wall-clock delay 反推 helper 行为,**实测可行**。`clampsAtMaxRetryAfterDelay` 真等 30s(单测耗时 30s,可接受 trade-off)。
7. ✅ **`DiaryEntry+Extensions.decodeEmbeddingVector` misaligned buffer**
8. ✅ **`LegacyDiaryEntry` 缺字段容错**

接下来做 seam refactor(`chatThrowing` + `AppLockService` + `NarrativeReader/AskPast` event helper),再补剩余 P0。

---

## 🔧 解锁多条测试的 seam refactor(性价比排序)

| Seam | 解锁测试数 | 工作量 | 备注 |
|---|---|---|---|
| `OpenAIService.chatThrowing` 升 internal + `parseImportedDiaries` 接 `chatPerform` 参数 | 4+ | 5 行 | 解锁 backlog #1 |
| `AppLockService` 注入 `LAContext`(或 `authenticate` 闭包) | 3 | 10 行 | 整文件目前 0 测 |
| 抽 `NarrativeReader` / `AskPastView` event switch 成 pure helper | 2 (P0) | 20 行 | 解锁 backlog #1 view 侧 |
| `WidgetSnapshotService` 加 `forceWriteForTesting` / digest 暴露 | 4 | 10 行 | digest dedup / fingerprint 全套 |
| `DataMigrationService` 改 `static func performIfNeeded(persistence:defaults:)` | 2 | 15 行 | 1 处 callsite 改 |
| `ContextPromptGenerator` `topThemePrompt`/`moodSwingPrompt` 升 `internal static` | 2 | 2 行 | |
| `ReminderService` UN center protocol 抽象 | 2 已记账 | 较大 | 跟 ReminderService 拆分一起做 |

---

# P0 优先级清单(强烈建议补)

## 切片 1:AI / SSE / 网络 / 转写

### [P0] `Chronote/Services/NetworkRetryHelper.swift:75-91` — `BackendError_429_isRetryable` + `BackendError_501_isNotRetryable`
- WHY:helper 内部 `isRetryableError` 决定 429/502/503/504/500-599 是否重试(501 被显式排除)。CLAUDE.md 后端踩过坑 "429 没列 retryable → backfill 撞到 429 静默丢 entry";没有锁这条 invariant 的回归测试。
- Setup:单元级别——直接 throw `BackendErrorMapper.error(forStatus: 429)` 进 `performWithRetry`,验证 `attempts > 1`;再 throw 501 验证 `attempts == 1`。无 mock URLSession。

### [P0] `Chronote/Services/NetworkRetryHelper.swift:129-150` — `retryAfterDelay_parsesSecondsAndHTTPDate_clampsAtMax`
- WHY:`Retry-After` header 既可能是数字 ("60") 也可能是 HTTP-date ("Wed, 21 Oct 2026 07:28:00 GMT");若解析坏了会 fallback 指数回退,在维护窗口期反复撞墙。`maxRetryAfterDelay=30s` clamp 也无人锁。
- Setup:`delayBeforeRetry` 目前 `private static`,需引 `@testable import` 或暴露 internal seam。

### [P0] `Chronote/Services/OpenAIService.swift:1772-1802` — `parseImportedDiaries_*_mapping` 系列 4 条 [已记账]
- WHY:backlog #1。这是隐藏在 chatThrowing 之后的纯 catch-mapping 逻辑,目前完全无测。CLAUDE.md "reviewer 第二轮指出旧路径把 401/429/offline 全归 noContent",catch 顺序改坏静默回退。
- Setup:`chatThrowing` 是 `private`,需 `internal` 化或让 `parseImportedDiaries` 接 `chatPerform: ((String) async throws -> String)? = nil` injection seam。

### [P0] `Chronote/Services/OpenAITranscriber.swift:131-145` — `prepareUpload_rejectsZeroByte` / `_rejectsOver25MB` / `_throwsAudioReadFailedOnMissingFile`
- WHY:25 MB 上限是后端硬约束,文件预检失败决定是否给重试按钮;0 字节判定覆盖损坏录音。
- Setup:`#if DEBUG` `internal` seam + tmp 文件,无网络。

### [P0] `Chronote/Services/OpenAITranscriber.swift:189-211` — `multipartBody_containsBoundaryAndCorrectMIME` / `_endsWithClosingBoundary`
- WHY:multipart 是 hand-rolled byte-level —— 漏 `\r\n` 或 boundary 名拼错,服务端 400 + 用户看"转写失败"。后端 multer MIME 严格,客户端拼错不易调试。
- Setup:同上 seam,解 body 成 String。

### [P0] `Chronote/Views/Insights/Components/NarrativeReader.swift` + `Chronote/Views/Insights/AskPastView.swift` — `.truncated` 消费侧 view-state 测试 [已记账]
- 归因更正:**生产 `OpenAIService.streamReportEvents` 已经会 emit `.truncated`** event(非缺失)。真正缺的是 view 侧消费 — 验证 `NarrativeReader` / `AskPastView` 收到 `.truncated` 后正确把 `isIncomplete` flag 翻 true,而不是把警告字符串当 chunk 拼进正文。
- WHY:backlog #1。CLAUDE.md "看到 `.truncated` 时 set `isIncomplete` flag 显示警示条,**不再**把中文错误字符串当 chunk 吐出去"。
- **Mock 准备**:`MockAIService` 默认**不会** yield `.truncated`,需要自写 `TruncatingMockAIService: AIServiceProtocol` yield `.chunk("a"), .chunk("b"), .truncated(reason:"x")`。
- Setup blocker:view 侧消费的 `for-await switch` 内嵌在 view 的 `.task` modifier 里,需要先抽成 nonisolated static helper(`applyEvent(_:to:&state)`)才能不依赖 SwiftUI runtime 测。见"seam refactor"段第 3 项。

---

## 切片 2:Persistence / Backfill / 导入导出 / 删除

### [P0] `Chronote/Model/PersistenceController.swift:62` (cachedModel) — `inMemoryStores_concurrentInit_doNotCorruptModel`
- WHY:已有 1 测断言 `===`,但只覆盖**串行**两次 init。SIGABRT 真实场景是**并行**(测试套并发 fork) → 加 `withTaskGroup` 同时起 4-8 个 `PersistenceController(inMemory:true)` 断言全部成功 + model 仍 ===。
- Setup:in-memory only,纯 Swift Testing。

### [P0] `Chronote/Services/EntryDeletionUndoService.swift:99` — `register_sameEntryTwice_ignoresSecondAndPreservesUndoWindow`
- WHY:reviewer Wave-A BUG-P0,已加 guard 但**无回归测**。register 同一 snapshot.id 两次,第二次必须 ignore(不 commit pending,不重启 4s task,attachment 不被预清)。
- Setup:`@MainActor` + 自定义 `EntryDeletionSnapshot` 直接构造(无需 NSManagedObject)。

### [P0] `Chronote/Services/EntryDeletionUndoService.swift:118` — `undo_callsPerformSingleDeleteCleanup_invalidatesDerivedCaches`
- WHY:reviewer Wave-A BUG-P0 修复关键路径,无测。
- Setup:in-memory PC + viewContext insert/save/delete entry → `register(snapshot:)` → `undo(into:viewContext)` → 间接断言 `InsightsResultCache.shared.snapshot(for:.month) == nil`。

### [P0] `Chronote/Services/DataMigrationService.swift:48` — `migration_processKilledBetweenSaveAndFlagSet_doesNotDoubleImport`
- WHY:CLAUDE.md 明示"async 写法下数据翻倍"。
- Setup:**service 缺 DI**(hardcoded `PersistenceController.shared` + 直接 `AppGroup.userDefaults`),P0 测试受阻 → 顺手把 service 改成 `static func performMigrationIfNeeded(persistence:defaults:)`,代价小、解锁多条测试。

### [P0] `Chronote/Services/EntryWipeOrchestrator.swift:55` — `performSingleDeleteCleanup_doesNotClearWidgetSnapshot_butInvalidatesCaches` / `performBulkWipeCleanup_clearsWidgetAndResetsAlias`
- WHY:CLAUDE.md 反复 callout 的 4 件 vs 5 件清单是**唯一防漏机制**。
- Setup:`WidgetSnapshotStore.overrideURL` 写一份 snapshot → 单删后 snapshot 仍在(只 invalidate 不 clear),批删后 snapshot 是 empty digest。`@MainActor` + override URL + 真实 actor。

---

## 切片 3:Reminder / Widget / Streak / AppLock / Router

### [P0] `Chronote/Services/AppLockService.swift:108-124` — `unlock_whenCanEvaluatePolicyFalse_autoDisablesToAvoidPermanentLockout`
- WHY:fail-safe ("device 丢 passcode → 别让用户卡死在锁屏") 是用户与 wedged install 之间唯一防线。零覆盖。
- Setup:inject `LAContext` via init seam(需要加),或抽 `canEvaluatePolicy()` 成 injectable closure。**整文件 0 测**,小 refactor 解锁多条。

### [P0] `Chronote/Services/AppLockService.swift:68-90` — `enableThenDisableDuringAuth_disableWins`
- WHY:generation-race contract(codex P0-class,跟 `ReminderService.currentRescheduleGen` 同模式)。User 拨开 → Face ID prompt → 取消 → 拨关 → 原 `enable()` 在 `await authenticate` 后 resume **不能** commit `isEnabled=true`。
- Setup:同上 seam。

### [P0] `LumoryWidgets/MoodColor.swift` vs `Chronote/Extensions/Color+MoodSpectrum.swift` — `moodSpectrum_widgetVsMainAppMatchAcrossSampledStops` ✅ 已落地(workaround)
- WHY:文件明文"必须同步改两边"。无任何防漂移保护。
- **诚实标注(2026-05-09)**:测试 target 不能链接 widget extension(`@testable import LumoryWidgets` 不可行),所以**真正的 widget 算法漂移检测无法靠测试达成**。当前 `MoodSpectrumParityTests.swift` 是 stop-gap:在测试文件里手抄一份 widget 算法当 reference,断言"主 App vs reference 一致"。漂移防御靠"改 widget 时同步改主 App + 测试 reference"的 CLAUDE.md norm + code review。文件顶部 30 行注释已明文标注三角不变量。
- **Root-cause fix 选项**(都没做):(a) 把算法搬进 shared module — 但 `LumoryWidgetShared` 当前坚持 Foundation-only,需要先升级到 "Foundation+SwiftUI" 或开新 `LumoryWidgetUI/` target,widget 文件顶部明确说"还没值得";(b) 让 `ChronoteTests` target 把 `LumoryWidgets/MoodColor.swift` 也 compile 进去 — 需要手编 `project.pbxproj`(CLAUDE.md 警告"不要手编")。
- Setup:13 个采样点 RGB 通道 epsilon=1e-4 比对。无 actor / 无 persistence。

### [P0] `Chronote/Services/ReminderService.swift:289-301` — `loadUseContextualBody_legacyUserWithEnabledKeyButMissingContextualKey_writesTrue`
- WHY:sentinel migration path 是保护**每个**老 reminder 用户的命脉。`ReminderUseContextualBodyDefaultTests` 只覆盖 fresh install + 显式值,**legacy 分支零覆盖**。CLAUDE.md 点名 "sentinel migration"。
- Setup:纯 `nonisolated static`,fresh suite 预设 `lumory.reminder.enabled` → 调 `loadUseContextualBody` → expect true + 验证副作用写入。

### [P0] `LumoryWidgetShared/WidgetTodayContext.swift:34-35` — `todayContext_futureLastEntryDate_doesNotInheritStreak`
- WHY:`daysAgo >= 0` guard 注释明示防 CK 同步未来 entry 漏 streak。现有测试有今天/昨天/2 天前/空,**无 future**。
- Setup:纯函数,asOf < lastEntryDate → expect `effectiveStreak == 0`。

---

## 切片 4:Insights / Theme / Prompt / Sync

### [P0] `Chronote/Services/SyncDiagnosticService.swift:182` — `generateDiagnosticReport_includesAllIssuesAndRecommendations` ✅ 已落地
- WHY:`generateDiagnosticReport` 是纯函数(吃 `SyncDiagnosticResult`,吐 String);`SyncIssue.isCritical` 也是纯逻辑。**注意:`performDiagnostic()` 不是纯函数**(碰 CloudKit / FileManager / Persistence),不在此条覆盖范围。覆盖范围是 service 内**纯逻辑部分**而非"整套"。
- Setup:**无**(纯值类型构造 + 字符串断言),零 CK / 零 mock。
- 已实现:`SyncDiagnosticServiceTests.swift` 3 个 suite 共 15 测(`SyncIssueIsCriticalTests` / `GenerateDiagnosticReportTests` / `SyncDiagnosticSeverityDisplayNameTests`)。

### [P0] `Chronote/Services/SyncDiagnosticService.swift:82` — `severity_isDerivedFromCriticalIssues` (✅ 间接覆盖)
- WHY:`iCloudNotSignedIn / coreDataStoreCorrupted / cloudKitMisconfigured` 任一存在 → critical。**这条逻辑 inline 在 `performDiagnostic` 里**,无法不动 production 代码直接抽测。**已通过测 `SyncIssue.isCritical` 表本身**间接覆盖 — 派生函数依赖的所有谓词已锁,未来抽 `static func severity(for issues:)` helper 时可直接补全端到端测。

### [P0] `Chronote/Services/PromptSuggestionEngine.swift:155` — `randomHomePlaceholder_emptyPool_returnsNil` / `singleItemPool_returnsThatItem` / `consecutiveCallsAvoidImmediateRepeat`
- WHY:`current` nil / placeholders 空时该返 nil(让 caller fallback);`pool.count == 1` 走 short-path;`lastPlaceholderIndex` 防重逻辑。**ReminderService 通知 body 直接消费这个**(`notificationBody` fallback 路径),返回错的字符串上锁屏。
- Setup:`@MainActor` engine,需要构造 `SuggestionBundle` + `init(insights: ai:)` 注入 mock(MockAIService 已有),走 `forceRefresh` 让 `current` 落地 — 或暴露 `setBundleForTesting`。

### [P0] `Chronote/Services/ContextPromptGenerator.swift:111` — `topThemePrompt_aliasFolded_picksMergedCanonical`
- WHY:现有 `ContextPromptAliasCanonicalizationTests` 只测 `canonicalize` 静态函数,**没测策略层**。修过的策略 `topThemePrompt` 用 `daysByTheme` 按独立天计数 — 如果 fetchEntries 的 alias 折叠漏 `["Abby","宝贝"]` → "宝贝" 被算成第二个独立 theme,sparkline / placeholder 拿到错的 top theme。
- Setup:`fetchEntries` 是 private,需 expose `internal static topThemePrompt(...)` 或全栈走 `generate()` + 真 PersistenceController(in-memory)。

### [P0] `Chronote/Services/ThemeAliasResolver.swift:582` — `cleanupOrphanedPending_withAliasGroup_keepsPendingTouchingGroupCanonical`
- WHY:codex P1 #10 的回归,文件注释明文 "alias-aware:活跃标签做一次 canonicalize,把 group canonical 也算'活'"。currently 唯一一条 cleanupOrphan 测试只覆盖 race snapshot 行为,**alias-aware 路径完全没单测**。回归就是"用户合并 Abby + 宝贝 后所有日记只写'宝贝',pending(亲爱的, Abby) 被误删"。
- Setup:`@MainActor` resolver + 真 PersistenceController(in-memory)预先 seed entry.themes 含 "宝贝"。

---

## 切片 5:后端 (Node / Express)

### [P0] `/api/openai/audio/transcriptions` 服务端 hardcode `gpt-4o-mini-transcribe`
- 测试名:`transcription_modelIsServerSideHardcoded_regardlessOfClientField`
- WHY:CLAUDE.md 明确 "信任边界在服务端,防客户端篡改改更贵模型"。client multipart 字段塞 `model=gpt-4-transcribe-pro` 必须被忽略。无测试 → 未来 refactor 把 `req.body.model` 透传是 silent regression,直接打用户钱包。
- Setup:axios mock 拦 `/audio/transcriptions` POST,断言 upstream `FormData` 里 `model` field === `gpt-4o-mini-transcribe`。

### [P0] `/api/openai/audio/transcriptions` MIME 白名单
- 测试名:`transcription_rejectsNonAllowlistedMime_with415`
- WHY:白名单是 X-App-Secret 之外**第二道防线**,挡任意文件冒充音频。`audio/x-aiff` / `application/octet-stream` / `image/jpeg` 必须 415,`audio/mp4` / `audio/m4a` / `audio/wav` 必须 200。Multer fileFilter `cb(null, false)` 路径目前完全无覆盖。
- Setup:`form-data` npm + axios mock 上游;断言被白名单拒掉的请求**不**触发 axios adapter(早断)。

### [P0] `/api/openai/audio/transcriptions` language 字段 ISO-639-1 校验
- 测试名:`transcription_dropsNonISO639_1LanguageValues`
- WHY:`/^[a-z]{2}$/` 校验是 OpenAI 严格规则的镜像(`zh-Hans` / `EN` / `english` 都该被丢弃,不透传防上游 400)。
- Setup:axios mock 拦 form,断言 `language=zh-Hans` → upstream form 没 language;`language=en` → 有;`language=ZH` → 没有。

### [P0] `/api/openai/audio/transcriptions` 25 MB body limit
- 测试名:`transcription_rejectsOversize_with413`
- WHY:multer `LIMIT_FILE_SIZE` 路径独立返 413 + `code: file_too_large`(客户端 banner 文案分支靠这个 code)。
- Setup:multipart upload 26 MB Buffer,断言 status 413 + body `error.code === 'file_too_large'`。

### [P0] 转写双层限流:per-install 10/min + per-IP 60/min
- 测试名:`transcription_perInstallLimit10_doesNotBlockOtherInstallsUntilPerIPCap60`
- WHY:CLAUDE.md "per-install 触顶第 11 个 install 还能调到 IP cap"。两道桶顺序错(per-IP 在 per-install 前)→ 11 个不同 install-id 仍能撞死 IP cap。
- Setup:axios mock 让上游秒返 200;循环 10 次同 install-id → 第 11 次同 install 应 429;然后换 install-id 第 11-60 次应通过。**坑**:`express-rate-limit` 默认 `MemoryStore` 是 **module singleton**,新 `app.listen` 实例**不会**重置桶。可行解(按推荐度):(a) 每个测试 `beforeEach` 调 `limiter.resetKey(key)` 或 `MemoryStore.resetAll()`(express-rate-limit 自带 API,最低成本);(b) 不同 `X-Forwarded-For` IP per 测试(per-IP key 隔离);(c) child_process spawn fresh process(贵但可靠);(d) 注入可控时间源 mock `Date.now`。设 `process.env.GLOBAL_IP_LIMIT_MAX=999` 防全局 IP cap 干扰。

### [P0] chat per-install 120 vs 全局 IP `GLOBAL_IP_LIMIT_MAX` 隔离
- 测试名:`chat_perInstallLimitIsolatesInstalls_butGlobalIPCapProtectsSharedNAT`
- WHY:Limiter 双层是核心设计(防单 install 撞上限 + 防 install-id 轮换攻击)。
- Setup:`GLOBAL_IP_LIMIT_MAX=3`(已设好),用这个就能在 4 个不同 install-id 时 fire 全局 cap。

### [P0] embeddings 8192 char cap + 300/min/install
- 测试名:`embeddings_rejectsInputOverMax_with413` 和 `embeddings_perInstallRateLimit_firesAt301st`
- WHY:embedding 路径**完全无 endpoint 测试覆盖**(只有间接 401 / non-empty input 测试)。
- Setup:char cap 测试纯 supertest 风格(到达 axios 前 413);rate limit 同上。

### [P0] `/health` 不走 X-App-Secret 鉴权
- 测试名:`health_responds200_withoutAppSecret`
- WHY:PM2 / nginx / Cloudflare 健康探活靠这个,如果 future 不小心把 `requireAppSecret` middleware mount 到 `/` 而不是 `/api`,健康检查直接挂,触发 PM2 unstable_restarts。
- Setup:`http.request` GET `/health`,无 header,断言 200 + `{ status: 'ok' }`。

---

## 切片 6:UI / Widget / Utils / Components

### [P0] `Chronote/Extensions/Color+MoodSpectrum.swift:6` + `LumoryWidgets/MoodColor.swift:11` — `MoodSpectrumParityTests.widgetCopyMatchesMainAtSampleRange`
- (与"切片 3"Color parity 重复条目,合并优先级)
- Setup:**最便宜测试 + 最防漂移**。两个文件分属不同 target,不能 import,但 SwiftUI Color 在 sRGB 色域可通过 UIColor + CGColor.components 抽 `(r,g,b,a)` 比对。需要在主 App test target 内重写 MoodColor 同算法引用,然后 13 个采样点。

### [P0] `Chronote/Views/Insights/Components/NarrativeReader.swift:178-204` — `NarrativeReaderEventConsumptionTests.{truncatedSetsIsIncomplete, failedSetsErrorBanner, doneEndsStreaming, chunkAppendsToTrailing, cancelClearsRunID}` [已记账]
- WHY:backlog 已点名("view-state 观察侧测试基建未落地")。流截断 → banner 出是用户最关心的"AI 没说完"信号,目前零断言。
- Setup:难。`engine.streamNarrativeEvents` 是 InsightsEngine 实例方法,需要 (a) 把 engine 改成 protocol + 注入(侵入式),或 (b) 把 `start()` 内部 switch 抽成 nonisolated static `applyEvent(_:to:&state)` 给 fixture 驱动测,view 侧只验"state→UI"这 30 行。**建议走 (b),零侵入**。

### [P0] `Chronote/Views/Insights/AskPastView.swift:348-393` — `AskPastEventConsumptionTests.{truncatedFlagsBubble, failedSetsErrorText, cancelMidstreamMarksIncomplete, taskIDStaleClearGuard, citationAttaches}` [已记账]
- WHY:同上,复杂度更高(citation 路径 / activeTaskID stale guard / wasCancelled+text+errorText 三态互斥)。activeTaskID stale 守卫(line 388)回归会让二次提问被旧 task 清空 activeTask,UI 卡死。
- Setup:同 NarrativeReader,把 for-await 内 switch 抽 pure helper。

---

# P1 清单(踩过坑 / 边界 nice-to-have)

## AI / SSE / 网络 / 转写

- **[P1] `InstallIdentity.swift:14-21`** — `installID_isStableAcrossAccess` / `_matchesUUIDFormat`。后端 rate limit 用它当 keyGenerator;格式必须是 `/^[A-F0-9-]{36}$/i`。注意:测试会真写 Keychain → 测前 SecItemDelete 测后还原。
- **[P1] `URLRequest+BackendAuth.swift:20-23`** — `applyBackendAuth_setsBothHeaders` / `_overwritesExistingValue`。6 处 callsite 都依赖此 helper,有人后来 `addValue` 而非 `setValue` 会重复 header。
- **[P1] `BackendErrorMapper.swift:11-41`** — `errorForStatus_401and413and429and5xx_returnsLocalizedDescription` / `_includesRetryAfterInUserInfo`。`userInfo["Retry-After"]` 必须真被 `NetworkRetryHelper.retryAfterDelay` 读到 — 两边接口契约只在文字注释里,容易 drift。
- **[P1] `ThemeAliasJudgeService.swift:151-168`** — `judgeAfterWrite_filtersNegativePairsBeforeEnqueue`。`scanAllHistory_respectsNegativePairs` 已覆盖 scan path,**on-write path 没有同款锁**。

## Persistence / Backfill / 导入导出

- **[P1] `DiaryEntry+Extensions.swift:124`** — `decodeEmbeddingVector_misalignedBuffer_doesNotCrash`。CLAUDE.md "CloudKit blob 不 4 字节对齐"是真 crash。构造故意偏移 `Data` 模拟 CK pull。
- **[P1] `DiaryEntry+Extensions.swift:325`** — `loadImageData_iCloudMissing_localPresent_returnsLocal` / `_onlyLegacyFlatPath_stillFinds`。三层回退读取侧无测。
- **[P1] `DiaryEntry+Extensions.swift:80`** — `sanitizeThemes_oversizedTagTruncatedTo50Chars`。现有测覆盖 dedup / CSV 安全 / 大小写 / cap 6,**未覆盖** `maxThemeTagLength = 50` 截断。
- **[P1] `CoreDataImportService.swift:236`** — `importEntries_NFC_NFD_sameDayDifferentSubsecond_dedupsAsOne`。内联文档明示历史 bug:秒级 timestamp + raw text → 重复入库。
- **[P1] `CoreDataImportService.swift:108`** — `importEntries_chunkSaveFailure_fallsBackToPerEntryRetry_partialSucceeds`。失败路径无测。
- **[P1] `WordCountBackfillService.swift:80`** — `gate_concurrentTriggers_onlyOneRuns`。actor 守卫无测。CLAUDE.md "CloudKit 批量 import 一次推 N 个 RemoteChange → race"。
- **[P1] `EmbeddingBackfillService.swift:68`** — `backfillAll_calledTwice_secondCallIgnoredWhileFirstRunning`。`@MainActor runningTask` race 守卫无测。
- **[P1] `EmbeddingBackfillService.swift:175`** — `processOne_textChangedDuringEmbedRequest_doesNotOverwrite`。"防覆盖写"路径无测。
- **[P1] `ThemeBackfillService.swift:184`** — `backfillProblems_picksEmptyThemes_andBannedWords_skipsClean`。
- **[P1] `LegacyDiaryEntry.swift:27`** — 三条向后兼容 decoder 路径(missing moodValue / missing both mood / missing id)无测,JSON 字符串构造,极轻成本。
- **[P1] `DiaryExportService` + `CoreDataImportService` round-trip** — export 走 plain text,import 走 AI 解析 → 测出来会失败,**反而暴露 import/export 不对称的产品 gap**。建议先写 documenting test (`.disabled`)。

## Reminder / Widget / Streak / AppLock

- **[P1] `QuickWriteProvider.swift:38-58`** — `getTimeline_emitsTwoEntries_secondCrossesMidnight_wroteTodayFlips`。midnight rollover contract 零覆盖。
- **[P1] `QuickWriteProvider.swift:20-27`** — `currentSnapshot_olderThanSevenDays_returnsEmpty`。`maxSnapshotAge` 7 天 staleness guard 未测。
- **[P1] `WidgetSnapshotService.swift:247-264`** — `writeSnapshotIfNeeded_sameDigestSkipsWriteAndReload`。content digest dedup 是 ~900ms 高频 backfill 时关键防御。**需要 `forceWriteForTesting` seam**。
- **[P1] `WidgetSnapshotService.swift:135-147`** — `clear_resetsDigestAndFingerprint_nextRefreshDoesNotShortCircuit`。CLAUDE.md 提过 `fingerprint = nil` 要求。
- **[P1] `WidgetSnapshotService.swift:85-86`** — `requestRefresh_inMemoryStore_doesNotWriteSnapshot`。screenshot/test 模式保护。
- **[P1] `WidgetSnapshotService.swift:97`** — `requestRefresh_storeNotLoaded_doesNotWriteEmpty`。冷启动 race 防御。
- **[P1] `InsightsResultCache.swift`** — 三测 `snapshot_missingRangeReturnsNil` / `update_storesAndRetrievesPerRange` / `clear_emptiesAllRanges`。**整个 cache 文件未测**。`@MainActor` 值类型 dict wrapper,trivial。
- **[P1] `AppLockService.swift:101-104`** — `lockOnBackground_whenDisabled_doesNotLock` + `_whenEnabled_setsLocked`。基本生命周期 hook,trivial,不需 LAContext seam。
- **[P1] `ReminderService.swift:344-367`** — `cancelAllPendingReminderNotifications_clearsBothPendingAndDelivered`。CLAUDE.md flag pending+delivered 双清。**UN center mock blocker**,与 backlog 同。
- **[P1] `ReminderService.swift:443-454`** — `disable_2passCancel_capturesInFlightAdd` [已记账]。同 UN-mock blocker。

## Insights / Theme / Prompt / Sync

- ~~**[P1] `ThemeAliasResolver.swift:240`** — `confirm_userOverridesCanonical_chosenIsAliasOfNewTagGroup`~~ ❌ **(2026-05-09 撤销:误判)**。Codex 实际读源码后发现:`chosen == newTag` 在生产代码里是**显式 no-op**(line 254-260)且已被 `confirm_chosenEqualsNewTag_isNoOp`(`ChronoteTests.swift:1442`)覆盖。我误把 CLAUDE.md "用户反选 canonical(把 Abby 改叫'宝贝')"理解成 "newTag 当 canonical",但实际语义是"在 picker 中反向选 canonicalGuess",已属 happy path 覆盖范围。
- ~~**[P1] `ThemeAliasResolver.swift:240`** — `confirm_chosenIsTotallyNewThirdName_createsFreshGroup`~~ ❌ **(2026-05-09 撤销:已覆盖)**。`confirm_withCustomThirdName_onlyMovesNewTag` (`ChronoteTests.swift:1472`) 已锁此场景且严格 `canonicalGuess` 不被卷走。
- **[P1] `ThemeAliasResolver.swift:526`** — `unmerge_thenSnapshotIndex_immediatelySync` / `deleteGroup_thenSnapshotIndex_immediatelySync`。rebuildIndex 必须 save 前跑。
- **[P1] `InsightsEngine.swift:412`** — `computeMoodExtremes_emptyEntries_returnsNilNil` / `allSameMood_returnsNilNil`。`high == low → return (nil, nil)` 让 grounding 知道"无显著差异"。
- **[P1] `InsightsEngine.swift:140`** — `writingStats_singlePassAggregates_matchesNaiveLoop`。如果分子分母漏算 widget 数字静默撒谎。
- **[P1] `PromptSuggestionEngine.swift:298`** — `loadCache_legacyUserDefaults_migratesThenRemoves` / `saveCache_writesProtectedFile`。legacy UserDefaults 兼容路径在没用户验证下静默(用户首次升级时 cache 拿不出 → AskPast 整页骨架)。
- **[P1] `PromptSuggestionEngine.swift:169`** — `runRefresh_secondCallerJoinsInflightTask` / `clearCache_cancelsInflightAndDoesNotResurrectCurrent`。C2 dedup join + clearCache race fix。
- **[P1] `ThemeAliasResolver.swift:73`** — `init_diskRoundTrip_preservesNegativePairs` after `resetForBulkEntryWipe()`。CLAUDE.md backlog 明文"保留 negativePairs"是 contract 关键。
- **[P1] `ContextPromptGenerator.swift:148`** — `moodSwingPrompt_belowThreshold_nil` / `aboveThreshold_returnsCopy`。`range >= 0.5` boundary 漂移用户感知明显。**`moodSwingPrompt` 是 private** — expose `internal static`。

## 后端

- **[P1] SSE 上游 error → `res.destroy(error)` 而非写 `data: [DONE]`** — `upstream_streamError_destroysClientSocket_withoutSendingDone`。CLAUDE.md 反复强调。setup:axios mock upstream PassThrough 写 partial 后 `destroy()`,断言客户端收到的 bytes **不含** `data: [DONE]`。
- **[P1] SSE upstream end without [DONE] → 也 destroy** — `upstream_endsWithoutDone_destroysClientSocket`。
- **[P1] non-UUID install-id 回落 `ip:<req.ip>`** — `installKey_fallsBackToIp_whenInstallIdMalformedOrMissing`。`installKey` 没 export → 黑盒测 quota 桶共享。
- **[P1] pino redact 验证**(authorization / x-app-secret / x-install-id) — `logger_redactsAuthAndInstallHeaders_inRequestLogLines`。**合规问题**(密钥落 PM2 日志)。建议把 `redact` config 单独 export 做单元测。
- **[P1] fail-closed 启动:缺 APP_SHARED_SECRET / OPENAI_API_KEY → process.exit(1)** — 子进程测试。
- **[P1] sanitizeChatBody 输出 → 真实转发到上游的 body 一致** — 跨边界假设没 lock,future `{ ...req.body, ...sanitized }` typo 让 `tools`/`temperature`/`top_p` 泄漏到上游。
- **[P1] chat 上游超时(120s) → 504 + `code: upstream_timeout`** — banner 文案分支(NetworkRetryHelper 看 504 重试 vs 500 直接报错)。
- **[P1] chat 429 + Retry-After 透传** — line 477-479 显式 set Retry-After,客户端用这个决定退避时长。

## UI / Widget / Utils / Components

- **[P1] `LumoryToast.swift:76-117`** — 7 条:`showSetsCurrent` / `durationDismissesAfterSleep` / `dismissActionToastOnlyClearsActionToasts` / `dismissActionToastNoOpsOnPlain` / `repeatedShowResetsTimer` / `performActionRunsClosure` / `showOverwriteCancelsPreviousTokenSoOldTimerNeverStompsNew`。撤销删除命脉。
- **[P1] `AudioPlaybackController.swift:9-22`** — `formattedDuration` 边界 (0 / 负数 / >1h / NaN / Infinity / 分数)。`Int(.nan)` 是 undefined behavior。
- **[P1] `LumoryDateFormatters.swift:96-143`** — 5 个 language-aware accessor + NSLock cache race。zh/en 切换核心。
- **[P1] `QuickWriteProvider.swift`** — DST spring forward 86400s≠1天 + policy +6min + 7d staleness fallback。**需要 `static func makeTimeline(snap:now:cal:)` testable seam**(~15 行)。
- **[P1] `FlowLayout.swift:44-60`** — empty children / single fits / overflow wraps / oversized / zero maxWidth / infinite width。**建议算法剥离**:抽 `computeRows([CGSize]) -> [Row]` nonisolated static。

---

# P2 清单(锦上添花)

## AI / SSE / 网络

- **[P2] `NetworkRetryHelper.swift:120-127`** — `delayBeforeRetry_appliesJitter_within25Percent`。
- **[P2] `OpenAITranscriber.swift:97-104`** — `cancellationViaURLError_doesNotSetLastFailure`。需要 mock URLSession。
- **[P2] `AppSecrets.swift:22-36`** — `appSharedSecret_returnsEmptyStringWhenInfoPlistKeyMissing`。Bundle 行为不易 mock。

## Persistence

- **[P2] `DiaryEntry+Extensions.swift:204`** — `countWords_mixedCJKAndLatin_sumsCorrectly` / `countWords_emojiPureString_returnsZero`。
- **[P2] `DiaryEntryData.swift:37`** — `from_preservesAllPhase0Fields`。防"加新字段忘了 propagate" 的 5 行测。
- **[P2] `DiaryEntry+Extensions.swift:182`** — `v1HeaderValidMagicButZeroDimReturnsNil` / `v1HeaderDimGreaterThanPayloadReturnsNil`。
- **[P2] `EntryDeletionUndoService.commitPendingNow → dismissActionToast`** — Wave-C BUG-P1 修复。
- **[P2] `DiaryExportService.swift:139`** — `cleanupOldExports_removesOldFiles_keepsRecent`。

## Reminder / Widget / Streak / Lifecycle

- **[P2] `StreakMilestoneService.swift:53-61`** — `evaluateAfterSave_zeroStreak_doesNotFire` + `_inferredFromCoreData_overridesCallerHint`。
- **[P2] `ReminderService.swift:206-235`** — `init_anchorDateNotPersistedUntilFirstEnable`。codex P0 fix invariant。
- **[P2] `ReminderService.swift:67-82`** — `willPresent_reminderNotification_passesBannerAndSound`。需要构造 `UNNotification`(无公开 init)。
- **[P2] `LumoryURLRouter.swift:32-38`** — `handle_validURL_callsRequestComposeFocus`。当前 8 个测覆盖 pure `route(for:)`。

## Insights / Theme / Sync

- **[P2] `CloudKitSyncMonitor.swift:190`** — `checkCloudKitStatus_cooldown_skipsWithin30s`。性能 contract,抽 `static shouldSkipCheck(now:lastCheckDate:)` 纯函数。
- **[P2] `CloudKitSyncMonitor.swift:283`** — `handleDatabaseAccessibilityResult_mapsCKErrorCodes`。建议抽 `static mapCKError(_:) -> (SyncStatus, errorKey: String)`。
- **[P2] `PromptSuggestionEngine.swift:346`** — `detectLanguage_emptyEntries_fallsBackToLocale` / `mixedCJK_above30PercentReturnsZh`。
- **[P2] `ThemeAliasResolver.swift:651`** — `bumpDismissCount_threeDismisses_setsCoolUntilAndResetsCounter`。snoozeThreshold = 3。
- **[P2] `ThemeAliasResolver.swift:499`** — `collateralLabels_groupCanonical_returnsAllAliases` / `bareTag_returnsEmpty`。UI long-press 合并预览。
- **[P2] `ThemeAliasResolver.swift:42`** — `coolUntil_didSet_schedulesExpiryTimerThatFiresObjectWillChange`。Timer 单测难。

## 后端

- **[P2] sseFrameHasDone 跨 8KB chunk 边界**(buffer overflow protection) — `sseBuffer_trimsToLast8192Chars_whenNoFrameBoundary`。
- **[P2] graceful shutdown idempotency** — `shutdownReentrancyGuard_ignoresDuplicateSIGTERM`。CLAUDE.md "PM2 unstable_restarts" 历史踩坑。
- **[P2] `/api` 整路径 600/min/IP 全局 IP cap** — `globalIPLimiter_capsTotalApiThroughput_perIP`。
- **[P2] non-streaming chat 客户端 abort** — 同 streaming abort 测试模式但单独实现。
- **[P2] sanitizeUpstreamError IS_PRODUCTION 全 status code 映射表** — parametrized。
- **[P2] embeddings 客户端 abort 取消上游** + **transcription 客户端 abort 取消上游**。

## UI / Components

- **[P2] `MoodLabels.swift:18-27`** — `exactValueMatchesOption` / `midpointTiesToLower` / `outOfRangeBelowZeroAndAboveOne` / `descriptionContainsEmojiAndLocalized`。
- **[P2] `Image+Compression.swift:13-30`** — `transparentPNGBecomesJPEGFlattened` / `oversizedDownscalesUntilUnderLimit` / `corruptDataReturnsNil`。
- **[P2] `ThumbnailImageDecoder.swift:18`** — `validJPEGDecodesToTarget` / `corruptDataNil` / `zeroMaxPixelClampsToOne`。
- **[P2] `HomeInputViewModel.swift:30-51`** + `HomePhotoViewModel.swift:12-48` + `HomeRecordingViewModel.swift:24-49` — VM 初值 / `selectedImages` 双向访问。极简 setup。
- **[P2] `MarkdownText.swift:147-249`** — `parse` 是 nonisolated static,流式 unclosed ``` + `\r\n → \n` normalize 隐式契约。
- **[P2] `ThemeAliasBanner.swift:237-258`** — 5s 折叠 timer,需要 refactor `scheduleCollapse(after:)` 默认参数。
- **[P2] `AnimationConfig.swift:37-43`** — Animation 是 opaque struct,无可断言字段。**skip**。

---

# 不建议做(audit 明确剔除)

- **`WidgetTodayContext.compute` 主路径** — 现有 `WidgetSnapshotTests` 4 用例已覆盖(written-today / yesterday-streak-survives / 2-days-broken / empty)。
- **`LumoryAdaptivePresentation.shouldUseExpandedModal`** — 已 3 用例。
- **`OpenAIService.narrativeTextBlock`** — 已 2 用例(UTF-16 截断 / 单条超长 trim)。
- **`Log.swift`** — 8 个 Category 是 enum case 静态枚举,改一处编译爆,无测必要。
- **`PressableScaleButtonStyle` / `MoodSpectrumBar` view body** — 纯 SwiftUI 视图,无嵌入算法,View snapshot 测试投入产出比低。
- **`LumoryWidgetsBundle` / `QuickWriteWidget` / `LockStreakWidget` body** — `@main` widget bundle 入口不可单测。
- **`QuickWriteEntryView`** — 全部依赖 `QuickWriteEntry` 输入,provider 测好后此处覆盖收敛。
- **production singleton 二次 init `fatalError`** — 测 `processTerminates` 性价比低。

---

# 跨切片洞察

1. **真正的瓶颈不是测试想法不够,而是 seam 缺**:6 个 agent 反复在同一坨地方喊 "需要注入" — `chatThrowing`、`AppLockService.LAContext`、`UN center`、`parseImportedDiaries.chatPerform`、`DataMigrationService` DI、`ContextPromptGenerator` private 函数。先做 1-2 个 seam refactor,后续测试能批量产出。

2. **测试基建空白点是 view-state 观察**(NarrativeReader / AskPastView 的 `.truncated → isIncomplete`),CLAUDE.md backlog 已点名但当时跳过 ViewInspector 决策。**更轻的路径**:把 event handler 抽成纯函数,测纯函数 + 不测 SwiftUI 渲染。

3. **现有 196 测试集中在算法/纯函数层**(cosine、bucketing、streak、cycleBounds),**几乎没碰副作用层**(Backfill race、Undo 重入、widget snapshot dedup、CK status mapping)— 这是后续覆盖增长的金矿。

4. **后端 transcription endpoint 几乎裸奔**(信任边界 + MIME 白名单 + 25MB + 双层限流 + ISO-639-1 校验全无测),5 条 P0 集中在这,加上 `/health` 免鉴权,优先补这一波。

5. **CLAUDE.md 踩过的坑大部分都没回归测**(WidgetSnapshot digest dedup / `date <= now` future guard / fingerprint reset / EntryDeletionUndoService 重入 / EntryWipeOrchestrator 4-vs-5 件 / sentinel migration / multipart boundary)。每条踩过的坑都该有一条防回归测,目前缺口很大。
