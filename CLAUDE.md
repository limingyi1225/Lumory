# Lumory

iOS 日记 App。产品名 **Lumory**,Xcode 项目 `Lumory.xcodeproj`,target/scheme/productName 都是 **`Lumory`**(`project.pbxproj:116`),源码目录仍是 `Chronote/`(历史遗留,rename 成本大故不动),bundle id `Mingyi.Lumory`。tests target 仍叫 `ChronoteTests` / `ChronoteUITests`。仓库里同时包含一个 Node.js OpenAI 代理后端(`server/`)。

## 技术栈
- **iOS 客户端**:SwiftUI + CoreData + `NSPersistentCloudKitContainer`(CloudKit 同步)。App 入口 `Chronote/ChronoteApp.swift`;`WindowGroup` 挂一个 `ZStack`,启动先走 `SplashView`(约 1s)再淡出到主内容视图 `HomeView`(见 [ChronoteApp.swift:175-188](Chronote/ChronoteApp.swift:175))。
- **后端**:Node.js + Express 5,部署在 `https://lumory.isaabby.com`(Cloudflare → nginx:443 → node:3000),PM2 进程管理。
- **AI**:走自建后端代理 OpenAI(`/api/openai/chat/completions`、`/api/openai/embeddings`、`/api/openai/audio/transcriptions`)。Chat 走 SSE 流,模型目前是 `gpt-5.5` / `gpt-5.4-mini`(reasoning effort 分档)。
- **语音**:`AVAudio` 本地录音(`AAC m4a / 16kHz mono`,见 [AudioRecorder.swift](Chronote/Services/AudioRecorder.swift)),转写走后端代理 `gpt-4o-mini-transcribe`(见 [OpenAITranscriber.swift](Chronote/Services/OpenAITranscriber.swift) + [Transcriber.swift](Chronote/Services/Transcriber.swift) 协议 + [BackendErrorMapper.swift](Chronote/Services/BackendErrorMapper.swift) 共享错误映射)。失败 UX 用 inline banner + 重试按钮(`recordingVM.transcriptionError`),不再用 alert。**没有** Apple `SFSpeechRecognizer` fallback。
- **本地化**:中(`zh-Hans.lproj`)/ 英(`en.lproj`),由 `@AppStorage("appLanguage")` 切换。

## 目录
- `Chronote/`
  - `ChronoteApp.swift` · `ContentView.swift` · `Views/SplashView.swift`
  - `Model/` — CoreData entity `DiaryEntry`(字段:id/date/text/moodValue/summary/audioFileName/imageFileNames/imagesData/**themes**(CSV,≤6 tag 去重)/**embedding**(Data,V1 格式 `[4B 'EMB1'][4B LE dim][N*Float32 LE]`,legacy 裸 dump 兼容)/**wordCount**(Int32)),`PersistenceController`,`DiaryEntry+Extensions`(业务逻辑入口:themes 清洗、embedding 编解码、图片三层回退、`recomputeWordCount`),`DiaryEntryData`(跨线程 DTO),`LegacyDiaryEntry`(v2 JSON 源模型)。
  - `Services/` — 业务核心。关键文件:
    - [AIService.swift](Chronote/Services/AIService.swift) — `AIServiceProtocol` + `MockAIService`(单测用)。
    - [OpenAIService.swift](Chronote/Services/OpenAIService.swift) — 生产实现,`.shared` singleton,走后端代理。
    - [InsightsEngine.swift](Chronote/Services/InsightsEngine.swift) — Insights / Ask-Your-Past / 写作伙伴 的统一聚合入口,`performBackgroundTask` 读 CoreData,只返值类型。
    - [ContextPromptGenerator.swift](Chronote/Services/ContextPromptGenerator.swift) · [PromptSuggestionEngine.swift](Chronote/Services/PromptSuggestionEngine.swift) — 提示 / 建议生成。
    - [CloudKitSyncMonitor.swift](Chronote/Services/CloudKitSyncMonitor.swift) · [SyncDiagnosticService.swift](Chronote/Services/SyncDiagnosticService.swift) — CloudKit 状态。
    - [DatabaseRecoveryService.swift](Chronote/Services/DatabaseRecoveryService.swift) — 启动时 store 加载失败的恢复(带备份与用户弹窗)。
    - [DataMigrationService.swift](Chronote/Services/DataMigrationService.swift) — v2 JSON → CoreData 一次性迁移(启动时在 `Task.detached` 里跑,见下方坑)。
    - `*BackfillService.swift` — `WordCountBackfillService`(启动 + remote-change 自动跑)、`EmbeddingBackfillService` / `ThemeBackfillService`(**不 auto**,由用户主动触发:Settings 的「一键重建索引」统合按钮(`OneClickRebuildRow`),或单独入口 —— embedding 的「开始」按钮 [SettingsView.swift:728](Chronote/Views/SettingsView.swift:728),theme 的「只修有问题的」[SettingsView.swift:765](Chronote/Views/SettingsView.swift:765) / 「全部重抽」[SettingsView.swift:787](Chronote/Views/SettingsView.swift:787))。
    - [CoreDataImportService.swift](Chronote/Services/CoreDataImportService.swift) · [DiaryImportService.swift](Chronote/Services/DiaryImportService.swift) · [DiaryExportService.swift](Chronote/Services/DiaryExportService.swift) — 导入导出。
    - [NetworkRetryHelper.swift](Chronote/Services/NetworkRetryHelper.swift) — SSE / HTTP 重试。
    - [AppSecrets.swift](Chronote/Services/AppSecrets.swift) — 后端 URL + `X-App-Secret` 共享密钥(⚠️ 目前硬编码,见下方"约定")。
    - [UITestSampleData.swift](Chronote/Services/UITestSampleData.swift) — `#if DEBUG`,启动参数 `-LumoryUITestSampleData YES` 让 `PersistenceController.shared` 自动构造 in-memory store(NSInMemoryStoreType + url=/dev/null,完全旁路 CloudKit),然后 `seedIfNeeded` 种 30 条手写 + ~60 条模板化样例(主角"林子衿"),给 App Store screenshot / demo 用。Guard 强制要求 NSInMemoryStoreType——历史踩过擦真实日记同步到所有设备的坑。
    - [ThemeAliasResolver.swift](Chronote/Services/ThemeAliasResolver.swift) — **主题别名映射的唯一真源**。`@MainActor` 单例,持久化 `canonical → [aliases]` + negativePairs(用户拒绝过的对子)+ pending 待审队列。**不修改 entry.themes CSV**——alias 是纯展示层,raw 数据永不丢。`canonicalize(_:)` 给聚合层 O(1) 查找;`enqueue` / `confirm(canonical:)` / `reject` / `snooze` / `unmerge` / `deleteGroup` 给 UI 用;`snapshotIndex()` 一次性 dict copy 给 nonisolated 调用方。confirm 支持**用户反选 canonical**(把 Abby 改叫"宝贝")或**完全自定义**(合并到第三个名字)。存储 UserDefaults key `lumory.themeAliasStore.v1`。注入点只有两处:[InsightsEngine.aggregateThemes](Chronote/Services/InsightsEngine.swift) 和 [ContextPromptGenerator.fetchEntries](Chronote/Services/ContextPromptGenerator.swift)。
    - [ThemeAliasJudgeService.swift](Chronote/Services/ThemeAliasJudgeService.swift) — 把"AI 判断 → 入待审队列"封起来。两条入口:`judgeAfterWrite(entryID:newTags:)` 写日记后调(每篇都跑,**模型 gpt-5.5 + reasoning=medium**);`scanAllHistory()` Settings 里"扫描已有主题"按钮调,一次性扫存量。两条都不阻塞,失败静默。
    - [ReminderService.swift](Chronote/Services/ReminderService.swift) — **周期型提醒**(完全本地通知,不走推送)。模型:**固定周期 + 锚点对齐**。`frequency`(daily / every3Days / weekly)+ hour:minute,周期从 `anchorDate`(首次 enable 时 startOfDay,持久化)起每 N 天一块。周期内有日记 → 周期 fulfilled 无 reminder;周期末未写 → 当天 hour:minute 提醒 + 挂 8 条未来 cycle-end 兜底(覆盖连续不开 App;`maxFutureFallbacks=8` 远低于 iOS 64 上限)。触发点:scenePhase=active、写完日记、删除日记、Settings 改值。**`requestReschedule()` 在 `!isEnabled` 时只 cancel pending 不跑 CoreData fetch / auth check / schedule**(给冷启动期省一次 backfill 竞争;disable() 也走这条路 cancel 通知,所以入口不能 early-return)。**通知 body 默认走 generic 模板**(`notificationBody(frequency:daysSilent:)`)。Settings 的 "用近期主题作文案" Toggle(`useContextualBody`,UserDefaults `lumory.reminder.useContextualBody`)**新装机默认 off**(privacy-first:contextual placeholder 含真实主题词如"妈妈"/"前任"挂到 lock screen 是隐私风险,改成主动 opt-in)。打开后才走 `PromptSuggestionEngine.shared.randomHomePlaceholder()`(主题词第二人称短句),pool 空时 fallback generic。**legacy 用户保护**:`loadUseContextualBody` 检测到 `enabledKey` 写过(说明用户激活过 reminder)+ `useContextualBodyKey` 缺失 → 一次性写 true 锁住旧体验,不让升级静默吞掉 contextual body 偏好。 Settings 还显示"本周期已记/未记"行(`wroteCurrentCycle`,`.task` 调 `refreshProgress`)。identifier 前缀 `lumory.reminder.`,reschedule 时 prefix-cancel 后重排;UN API 不响应 task cancellation,用 `currentRescheduleGen` 世代号兜底。旧 `weeklyTargetDays` 在 `loadFrequency` 一次性迁移(5-7 → daily,2-4 → every3Days,其他 → weekly)。`cycleBounds(referenceDate:anchor:frequency:calendar:)` 是 `nonisolated static`,给单测显式注入 UTC `Calendar` 锁住 timezone。
    - **`ReminderNotificationRouter`**(同文件顶部)— **全局 `UNUserNotificationCenterDelegate` 单例**,在 [ChronoteApp.swift:45](Chronote/ChronoteApp.swift:45) 设置(`UNUserNotificationCenter.current().delegate = .shared`)。**它接管 App 内所有通知点击和前台展示**,不只是 reminder 的 —— 改之前先想清楚副作用。两个核心 callback:(1) `didReceive`(用户点击)→ `shouldFocusComposer` 判定后 hop `Task { @MainActor in composeFocusRequestID = UUID() }`,HomeView 的 `@ObservedObject` + `.onChange(of: composeFocusRequestID)` 接住,清屏 + 焦点写日记编辑器;(2) `willPresent`(前台收到)→ reminder 类放行 `[.banner, .list, .sound]`,非 reminder 沿用默认压制 `[]`。**没有 `willPresent` = 前台通知完全不显示(无 banner / 无声音)**,这条曾被 superreview 抓出。`shouldFocusComposer` 三条匹配规则任一命中即放行:identifier 以 `lumory.reminder.` 开头 / categoryIdentifier == `lumory.reminder.compose` / userInfo 含 `lumory.intent: compose`。三条都来自 `scheduleOneShot` 设置的 content,故 schedule 端和 router 端一一对齐。
    - `HapticManager.swift` — 触觉反馈统一入口。
  - `Views/`
    - [HomeView.swift](Chronote/Views/HomeView.swift) + `HomeView/`(3 个 `@Observable` VM:`HomeInputViewModel` / `HomeRecordingViewModel` / `HomePhotoViewModel`,+ `Components/` 下的 `DiaryEntryRow` · `DiaryTextEditor` · `PhotosCollectionView`)。**注意:`recorder` / `audioPlaybackController` 故意留 HomeView 作 `@StateObject`,不搬进 @Observable VM —— Observation 宏不 bridge 嵌套 `ObservableObject` 的 `@Published`,搬进去 UI 就不 react 了。** Home 顶部 `safeAreaInset(.top)` 挂 [ThemeAliasBanner](Chronote/Views/Components/ThemeAliasBanner.swift),录音/转写/发送/输入态时不弹。
    - `Insights/` — `InsightsView` · `AskPastView` · `TimeRange`,组件见 `Insights/Components/`(`CalendarMonthModule`、`MoodStoryChart`、`WritingHeatmap`、`ThemeCardList`、`NarrativeReader`、`CitationEntryCard`、`CorrelationChipList`)
    - `Search/SearchView.swift`
    - [DiaryDetailView.swift](Chronote/Views/DiaryDetailView.swift) · [SettingsView.swift](Chronote/Views/SettingsView.swift) · [SyncDiagnosticView.swift](Chronote/Views/SyncDiagnosticView.swift) · [DiaryImportView.swift](Chronote/Views/DiaryImportView.swift) · [DiaryExportView.swift](Chronote/Views/DiaryExportView.swift) · `ImageViewerView.swift` · [ThemeAliasManagementView.swift](Chronote/Views/ThemeAliasManagementView.swift)(主题别名管理:扫描/待审/已合并三段)
    - `Components/` — `MoodSpectrumBar`、`MoodSendAnimation`、`MarkdownText`、[ThemeAliasBanner](Chronote/Views/Components/ThemeAliasBanner.swift)(顶部软提示,liquidGlass + 5s 折叠)
    - `Shared/` — `EmptyStateView`、`Animations/BreathingDots`
  - `Extensions/` — `Color+MoodSpectrum`、`Image+Compression`
  - `Utils/` — `AnimationConfig`、`LiquidGlass`、`LocalizationHelper`、`Log`、`PerformanceOptimization`
- `ChronoteTests/` · `ChronoteUITests/` — 单测 / UI 测试
- `Lumory.xcodeproj` · `Lumory-Info.plist` · `Lumory.entitlements` · `Lumory.icon`
- `server/` — Node 后端。代码主体集中在 [index.js](server/index.js)(约 280 行,Express 5 + pino + pino-http + express-rate-limit + axios + cors + dotenv),目录内还有 `package.json` / `package-lock.json` / `eslint.config.js`。
- `ecosystem.config.js` — PM2 配置(`lumory-server`,fork 模式,`max_memory_restart: 512M`)。
- `Scripts/reset-database.sh`、根目录 `clean-build.sh` / `deep-clean.sh` / `clean-corrupted-db.sh` — 维护脚本。
- `Scripts/generate-screenshots.sh` — 自动跑 `ChronoteUITests/ScreenshotTests` 出 6 张 1320×2868 的 App Store 截图到 `Screenshots/zh-Hans/`。流程:boot iPhone 17 Pro Max → `simctl status_bar override`(9:41 / 满电) → `xcodebuild test -only-testing ... -parallel-testing-enabled NO` → `xcresulttool export attachments`。
- `.claude/` — Claude Code 本地自动化配置。
  - `skills/screenshot/SKILL.md` — 封装截图流水线(iPhone / iPad + 坑位清单)。用户说"截图 / 上架截图"自动触发。
  - `agents/coredata-migration-reviewer.md` — **改任何 CoreData schema / `DiaryEntry+Extensions` / `PersistenceController` 后应主动召唤**,按 CloudKit 兼容性 + `embedding` / `themes` / backfill 清单审查。
  - `hooks/server-lint.sh` + `settings.json` — PostToolUse hook:编辑 `server/*.js` 后静默跑 `eslint --fix` + `prettier --write`。失败不阻塞。
  - `settings.local.json` — 个人权限 allowlist,别把它 check 进 git。
- `CHANGELOG.md` — **内容不可信,不要据此推断版本/日期/功能状态**。

## iOS 架构要点
- **启动序列**(`init()` 在 [ChronoteApp.swift:35-95](Chronote/ChronoteApp.swift:35);remote-change observer 在 [:220](Chronote/ChronoteApp.swift:220)):
  - `PersistenceController.shared` 同步初始化(store 加载失败走 `DatabaseRecoveryService`)。
  - `DataMigrationService.performMigrationIfNeeded()` 放 `Task.detached(.userInitiated)` —— 绝不要挪回 `init()` 同步调用,会触发 watchdog。
  - 权限请求(只剩麦克风,SFSpeech 已移除)、动画预热、图片迁到 iCloud、`WordCountBackfillService.backfillIfNeeded()`。
  - `EmbeddingBackfillService` / `ThemeBackfillService` **不 auto**(历史上自动跑踩过 actor-safety + 弱网失败率坑)。
- **CloudKit**:容器 `iCloud.com.Mingyi.Lumory`,`CloudKit` + `CloudDocuments`,`aps-environment=production`,`UIBackgroundModes=remote-notification`。远端变更通过 `NSPersistentStoreRemoteChange` 驱动 `WordCountBackfill`。
- **场景切换**([ChronoteApp.swift:285-298](Chronote/ChronoteApp.swift:285)):background 时 flush `viewContext` 防止用户输入丢失;active 时 `syncMonitor.checkCloudKitStatus()`(:289)+ `ReminderService.shared.requestReschedule()`(:293,内部已对 `!isEnabled` 早返,只 cancel pending 不跑 CoreData fetch)。

## 后端架构要点
- 入口 [server/index.js](server/index.js)。
- **鉴权**:所有 `/api/*` 要求 header `X-App-Secret`,timing-safe compare。未配 `APP_SHARED_SECRET` 直接 fail-closed(启动即退)。`/health` 不走鉴权,供健康探活。
- **速率限制**:per-install(客户端 `X-Install-Id` = Keychain UUID,`InstallIdentity.current`)+ 全局 IP 兜底双层。chat 120/min per-install,embeddings 300/min per-install,**transcriptions 10/min per-install + 独立 60/min per-IP 兜底**(转写单价高 + 25 MB 上传量,故收紧),`/api` 整路径 600/min per-IP。合法 install-id 用 `/^[A-F0-9-]{36}$/i` 校验,非法 / 缺失回落 `ip:<req.ip>`。
- **请求体限制**:chat messages 总 char `MAX_MESSAGES_CHARS`(默认 32000,十进制非 32768);embedding input `MAX_EMBEDDING_INPUT_CHARS`(默认 8192);transcription 文件 `MAX_TRANSCRIPTION_FILE_BYTES`(默认 25 MB,OpenAI 上限),走 multer memoryStorage + MIME 白名单(`audio/mp4` / `m4a` / `mpeg` / `wav` / `webm` / `ogg` / `flac`)。`REQUEST_TIMEOUT_MS=120_000`(和客户端 `timeoutIntervalForResource=300s` 对齐,给长 SSE 流留余量)。
- **转写路由 model hardcode**:`/api/openai/audio/transcriptions` 服务端固定 `gpt-4o-mini-transcribe`,**不读** client 传的 model 字段(信任边界在服务端,防客户端篡改改更贵模型)。`language` 字段如客户端传需 ISO-639-1 两字母 lowercase,否则丢弃让模型自动检测。
- **SSE 错误处理**:上游 stream 出错时 `res.destroy(error)`,**不能**写 `data: [DONE]`(客户端会把半截当成功)。
- **日志**:pino JSON → PM2 `logs/backend-out.log` / `backend-err.log`,headers 里的 `authorization` / `cookie` / `x-api-key` / `x-app-secret` 在 pino redact 里全部 `[REDACTED]`。
- **网络拓扑**:Cloudflare edge(公共 cert)→ origin nginx:443(self-signed)→ node:3000。`app.set('trust proxy', 'loopback')`。

## 常用命令

iOS:
- 构建 Debug:`xcodebuild -project Lumory.xcodeproj -scheme Lumory -configuration Debug build`
- 跑测试:`xcodebuild test -project Lumory.xcodeproj -scheme Lumory -destination 'platform=iOS Simulator,name=iPhone 17'`
- 清理:`./clean-build.sh`;彻底清(含 DerivedData / ModuleCache / .swiftpm):`./deep-clean.sh`
- 本地 DB 损坏恢复:`./clean-corrupted-db.sh` 或 `Scripts/reset-database.sh`
- 生成 App Store 截图:
  - iPhone(默认,1320×2868):`./Scripts/generate-screenshots.sh` → `Screenshots/zh-Hans/`
  - iPad(2064×2752):`./Scripts/generate-screenshots.sh ipad` → `Screenshots/zh-Hans-iPad/`
  - 任意机型:`LUMORY_SIM="iPhone 13 Pro Max - Lumory" ./Scripts/generate-screenshots.sh`
  - 注意 iPad 上 `.sheet` 是中心 formSheet,Insights / AskPast 截图会显示成浮在 Home 上的小卡 —— 这是 SwiftUI 默认行为,要 full-screen 得改成 `.fullScreenCover` 或加 `.presentationSizing(.fitted/.full)`。

后端(`server/`):
- 启动:`npm start`;开发:`npm run dev`(nodemon)
- Lint:`npm run lint`;Format:`npm run format`
- 生产重启(服务器上):`pm2 restart lumory-server`
- 健康探活(免鉴权):`curl https://lumory.isaabby.com/health`

## 约定 / 踩过的坑

- **⚠️ Secrets**:
  - `appSharedSecret` 现在走 xcconfig 注入链:`Lumory.local.xcconfig`(gitignored 真实值)→ `#include?` 到 `Lumory.xcconfig`(committed)→ pbxproj base config → `Lumory-Info.plist` 里 `$(APP_SHARED_SECRET)` 替换 → `AppSecrets` 运行时 `Bundle.main.infoDictionary` 读。fallback 是空字符串(读不到 → 401),**不**硬编码。新 clone 后 setup:`cp Lumory.local.xcconfig.sample Lumory.local.xcconfig` + 填值 + Cmd+B。
  - 轮换流程:本机改 `Lumory.local.xcconfig` + SSH 改 server `/root/server/.env` + `pm2 restart lumory-server` + 出新 build。
  - 后端 `OPENAI_API_KEY` 和 `APP_SHARED_SECRET` 都必须来自 `server/.env`,缺任一立刻 `process.exit(1)`。
- **Info.plist 的 ATS 例外**已删(历史上为旧明文 origin `64.176.209.155` 留的,现在全 HTTPS 走 `lumory.isaabby.com`,不再需要)。
- **CoreData 迁移**不要同步跑在 `init()`。回填用 `*BackfillService` 模式:`WordCountBackfillService` 走后台 context `fetch(predicate: wordCount == 0)` + 遍历 + save(无 UserDefaults flag,天然幂等 —— 没 pending 就是空数组,代价只是一次 SQL 扫);`Embedding/ThemeBackfillService` 的 `runningTask` 已改 `@MainActor` 隔离,所有 start/cancel 入口都会汇合到 MainActor 排队,多入口 race 被锁死。
- **SSE 在客户端**:`OpenAIService.SSEParser` 负责底层解析(支持多行 data: 累加 + `:` 注释行 + 可选空格 + `[DONE]` 识别);`NetworkRetryHelper` 负责传输层异常重试,每轮 attempt 前会 `try Task.checkCancellation()`。流式事件走 `AIServiceProtocol.streamReportEvents` / `askEvents` 返回 `AsyncStream<StreamEvent>`,UI 消费端(NarrativeReader / AskPastView)在看到 `.truncated` 时 set `isIncomplete` flag 显示警示条,**不再**把中文错误字符串当 chunk 吐出去。后端 SSE 出错仍必须 `res.destroy(error)` 硬断,不能写 `data: [DONE]`。
  - **千万别把 byte→line 切分换回 `URLSession.AsyncBytes.lines`**。Apple 实际 ship 的 `AsyncLineSequence` 在 iOS 26 / 部分版本**不为空行 yield `""`**,SSEParser 依赖空行触发 dispatch —— 一旦空行被吞,所有 `data:` event 粘成一坨,EOF 时 decoder 拿到 `{json1}\n{json2}\n…` 多个 JSON 拼起来的怪物,抛 `invalidEvent(byteCount:)` 且**整流一字未 yield**(byteCount 跟回答长度成正比,典型 100KB+)。自家替换实现是 `SSEParser.byteLineSequence`(按 `\n` 切 + 吞 CRLF 的 `\r` + 空行如实 yield)。诊断:服务端 PM2 日志若 `statusCode 200` 且没 `upstream stream errored` / `upstream ended without [DONE]`,字节就是干净的,bug 在客户端解析。
- **提交信息**:沿用仓库既有中英混合风格,参考 `git log`。
- **CHANGELOG.md 不准确**,实际状态以代码和 git 为准。
- **Xcode 项目用 PBXFileSystemSynchronizedRootGroup**(`Chronote/` / `ChronoteTests/` / `ChronoteUITests/`):新加 .swift 直接放目录里就被 target 自动包含,**不要**手编 `project.pbxproj`。
- **UI tests target 配置**:`TEST_TARGET_NAME = Lumory`(历史是 `Chronote`,Lumory 重命名时漏改导致 `xcodebuild test` 报 "UITargetAppPath should be provided",已修;`-only-testing:ChronoteUITests/...` 仍走 target 名 `ChronoteUITests`)。
- **`xcodebuild test` 默认会 clone 指定的 simulator**(运行时 `RUN_DESTINATION_DEVICE_NAME = "Clone N of iPhone X"`),而 `simctl status_bar override` **只对原始 sim 生效,不继承到 clone**。截图脚本必须加 `-parallel-testing-enabled NO -disable-concurrent-destination-testing` 强制走原始 sim,否则状态栏角上是真实电量 / 真实时间。**纯 unit test 跑全 ChronoteTests 也建议加这俩 flag** —— 不加每次跑 pass/fail 数都不一样(149 / 138 / 109…),失败长 `Crash: Lumory at <external symbol>` + duration `0.000s`,看着像真崩,实际是 simulator clone 不稳;加 flag 后 149/0 稳定。**两次 `xcodebuild test` 不能并发** —— 第二个启动让第一个的 test 过程进入同样的 0.000s 假崩。重跑前 `pkill -f "xcodebuild test"; sleep 2`。
  - **⚠️ 但是真的 SIGABRT 不是 clone flake**:macOS `~/Library/Logs/DiagnosticReports/Lumory-*.ips` 有 EXC_CRASH/SIGABRT + Obj-C 异常栈底是 `executeFetchRequest:error:` / SwiftUI `FetchRequest.update`,**这是 PersistenceController 多 NSManagedObjectModel 实例 ambiguity** —— 测试里 `PersistenceController(inMemory: true)` 出现 N 次,每次都 `NSPersistentCloudKitContainer(name: "Model")` 重新加载 .xcdatamodeld 生成新 model,Core Data `+[DiaryEntry entity]` "Failed to find a unique match"。修法:`PersistenceController.cachedModel` 静态共享 `NSManagedObjectModel`,所有实例传 `managedObjectModel:` 参数复用(2026-04-29 落地)。看到 `.ips` 有 Core Data 栈先怀疑这条,而不是默认归类成 clone flake。
- **从 main thread 调 Core Data `bg.performAndWait` 时,不能在 block 内部 `DispatchQueue.main.sync`**——main 已经在等 bg,立即死锁(SIGTRAP / Abort Cause 9005...)。模式:用 `var` 把 batch delete 的 `objectIDs` 暂存,等 `performAndWait` 返回(回到 main 自然态)再 merge。`UITestSampleData.seedIfNeeded` 是参考实现。
- **Screenshot 模式下 `requestPermissions()` 必须 early return**(`if UITestSampleData.isActive { return }`),否则 SFSpeech / Mic 弹窗盖在 Home 上把首屏截烂。**`ReminderService.enable()` 同样要早返**(防 toggle 被意外触发时通知权限弹窗盖住截图);任何"主动 requestAuthorization"路径都得过这道闸。
- **从 .xcresult 提取截图**用 Xcode 16+ 自带的 `xcrun xcresulttool export attachments --path BUNDLE --output-path DIR`(配合 `manifest.json` 把 UUID 文件名映射回 `suggestedHumanReadableName`),不需要装 `xcparse`,也别用 deprecated 的 `--legacy --format json` 老 API。**只想要 pass/fail 摘要 + 失败列表**:`xcrun xcresulttool get test-results summary --path X.xcresult | python3 -c "import json,sys; d=json.load(sys.stdin); print('passed=',d['passedTests'],'failed=',d['failedTests']); [print(' -',f['testIdentifierString'],':',f['failureText'][:80]) for f in d.get('testFailures',[])]"` —— 比 grep 原始 xcodebuild log 干净 10 倍。
- **iOS 部署目标 26.0**(`IPHONEOS_DEPLOYMENT_TARGET` 在 6 个 config 里均一致)。可用 `@Observable` 宏、`@Entry`、iOS 17+ 的 `@State<AnyObject>` 语义。
- **`@Environment` 只能在 instance scope 访问**。SwiftUI `private static func` / 属性初始化器里用 `@Environment` 会报 "instance member cannot be used on type"。静态辅助方法需要 AIService 时,在调用点 `let ai = aiService` 捕获后作参数传进去(参见 `DiaryDetailView.refreshAIIndex(... ai:)`)。
- **SwiftUI `@FetchRequest(animation:)` 不要用**。和 List 原生 row-removal 动画 + `withAnimation { delete }` 三层叠加会错位。当前用 `@FetchRequest(sortDescriptors:)` 无 animation + `ForEach(Array(entries.enumerated()), id: \.element.objectID)` 组合,动画由 `withAnimation` 单层控制,identity 由 objectID 稳定。
- **SwiftUI `.sheet` 必须挂在比"sheet 触发条件"**更稳定**的视图上**。`Group { if let x = optional, !busy { content().sheet(isPresented: $showing) {...} } }` 这种结构 —— sheet 打开期间 `optional` 变 nil 或 `busy` 翻 true,**整个 content 子树被 SwiftUI 拆掉,sheet 跟着死**,用户搜索/选择被无声打断。修法:把 `.sheet(item: $subject)` 挂到 `Group` 之上(条件渲染外层),`@State var subject: ItemType?` 在 trigger 时 set,picker 自己 `dismiss()` 时 SwiftUI 自动回 nil。`ThemeAliasBanner.body` 是参考实现 —— 之前历史踩过两遍同一坑(从 `expandedCard` 内挪到 `content` 内仍不够,得挪到 `Group` 之上)。
- **bash `cmd1 | cmd2 || true` 会覆盖 `PIPESTATUS`**。`|| true` 之后 `${PIPESTATUS[0]}` 只剩 `true` 的 exit code,原 pipeline 状态丢光。需要真实 exit code 时改用 `set +e` + 直接 pipeline(不加 `|| true`),然后读 `PIPESTATUS[0]`,最后 `set -e`(参见 `Scripts/generate-screenshots.sh`)。
- **xcconfig 注入自定义 Info.plist key 的三个坑**:
  (1) `INFOPLIST_KEY_*` build setting 只对 Apple 已知 plist key(NS*UsageDescription / CFBundle*)有效,自定义 key 必须直接在 `Lumory-Info.plist` 写 `<string>$(VAR_NAME)</string>` 让 Xcode 在 build 时变量替换。
  (2) Run Script PBXShellScriptBuildPhase 默认 `showEnvVarsInLog = 1`,会把所有 build setting `export VAR=value` echo 到 xcodebuild 日志(包括 secret)。涉及 secret 时 pbxproj 里手动加 `showEnvVarsInLog = 0;`。
  (3) `PBXFileSystemSynchronizedRootGroup` 只自动收 `Chronote/` 下的 swift,**根目录的 xcconfig 不会被识别**。需要手动加 `PBXFileReference`(`lastKnownFileType = text.xcconfig`)到 PBXFileReference section + 加到 root PBXGroup children + 在 project-level Debug + Release 的 XCBuildConfiguration 里写 `baseConfigurationReference = <FILE_ID>`。
- **日志 API**:`Log.warning(...)` 不是 `Log.warn`(后者编译报 "type 'Log' has no member 'warn'")。`Log.Category` 仅 8 个:`general / ai / network / persistence / sync / audio / ui / migration`,新分类要先在 `Log.swift` 注册。
- **`URLSession.sslTolerantSession` 命名误导,不要被吓到**:`NetworkRetryHelper.swift:104` 里这个名字暗示 SSL 绕过,实际**只是**共享 session + `timeoutIntervalForResource = 300s` 超时配置。全仓 `URLSessionDelegate` / `didReceiveChallenge` 零命中。安全扫描看到这个名字别紧张,以后有空可以重命名为 `sharedRetrySession`。
- **NSManagedObject Sendable + Swift 6 兼容防御**(项目当前 `SWIFT_VERSION = 5.0`,strict concurrency 没显式开,**为切 Swift 6 提前防御**):`NSManagedObject` 在 iOS 上**不是** `Sendable`(`Conformance of 'NSManagedObject' to 'Sendable' is unavailable in iOS`)。`async` 函数返回 `[DiaryEntry]` / 单个 `DiaryEntry` 必然跨 await boundary,Swift 6 模式编译报错(Swift 5 是 warning)。修法:**函数整体标 `@MainActor`** + 把 `MainActor.run { ... }` wrapper 直接拆掉(本来就是冗余,函数已锁主线程)。后台 fetch 仍走 `performBackgroundTask` 拿 `[NSManagedObjectID]`(Sendable),回 main 后 `viewContext.existingObject(with:)` 物化。参考 [SearchView.keywordHits](Chronote/Views/Search/SearchView.swift) 和 [HomeView.keywordHits](Chronote/Views/HomeView.swift)。
- **`@MainActor` 类的 `static let` / `static func` 也继承 actor 隔离**。从 `Task.detached` 调静态成员会报 `main actor-isolated static method '...' cannot be called from outside of the actor`(Swift 6 直接 error,**当前 Swift 5 模式**是 warning)。修法:静态成员显式 `nonisolated`(端到端例:[OpenAITranscriber.prepareUpload](Chronote/Services/OpenAITranscriber.swift) —— 25 MB 文件读取 + multipart 拼装放后台 Task,主线程只发 URLRequest)。
- **主题别名(ThemeAliasResolver)是展示层,不动 entry.themes**。alias map 在 `aggregateThemes` / `ContextPromptGenerator.fetchEntries` 注入,把 `["宝贝", "Abby"]` 折成同一 canonical bucket;**entry 的 themes CSV 永远保留原文**,用户改主意 unmerge 立即生效。绝对不要写"扫描完成自动 setThemes"这种逻辑——历史上(EmbeddingBackfill)自动改写踩过 actor-safety + 弱网失败率坑,体感是"AI 索引出问题",但 root 是写时无中间态保护。on-write judge 走 `ThemeAliasJudgeService.judgeAfterWrite`,**模型 gpt-5.5 + reasoning=medium**(mini 抓不到跨语言昵称对应,low 抓不全;medium 是 quality/cost 折中),fire-and-forget,失败仅日志。一次性 scan 走 `scanAllHistory`,接受人工 confirm/custom/reject,绝不自动合并。
- **本地通知不要 schedule badge counter**。`ReminderService` 只用 `.alert + .sound`,不写 `content.badge` —— badge 数字一旦设了得自己维护清零(读日记打开 = 0?切到 Insights = ?),状态机一旦设错 App icon 会一直挂着红 1。日记 App 没必要,弃。
- **`UNCalendarNotificationTrigger(repeats: false)` + 同 identifier 重 schedule = 覆盖**。智能 reminder 的"reschedule"模式靠这个:每次 user 进入 active / 写完日记,**先按 prefix `lumory.reminder.` cancel 所有 pending**,再根据当下状态(W vs target)决定要不要挂今天 + 明天的 one-shot。如果用 `repeats: true` 就没法做"达标了今天不发"的智能逻辑(系统不允许 fire 时再决定),所以一定是 one-shot per-day。
- **`Lumory-Info.plist` 里改的 `NS*UsageDescription` 会被本地化覆盖**。`Chronote/zh-Hans.lproj/InfoPlist.strings` 和 `en.lproj/InfoPlist.strings` 里的同名 key 在运行时**完全盖过** root plist 的英文 fallback —— 改隐私文案必须**三个文件一起改**(root + zh + en),否则中文 / 英文用户看到的还是旧文案,合规审核会出事。code review 踩过这一坑。
- **`NSLocalizedString` 必须双语 locale 都加,key 是中文也不能省 zh 那条**。iOS 找不到 key 会沿 fallback 链落到**开发区域 locale**(本项目 en),所以「`zh-Hans` 漏 + `en` 有英文值」→ **中文用户会看到英文**(典型症状:Settings 某行突然蹦出英文)。「en 漏 + key 是中文」→ 英文用户看到原始中文 key。审核改动里新加的 NSLocalizedString 用一行扫:
  ```bash
  git diff HEAD -- Chronote/ | grep -oE '^\+.*NSLocalizedString\("[^"]+"' | grep -oE '"[^"]+"' | sort -u | while read k; do
    grep -qF "$k =" Chronote/en.lproj/Localizable.strings || echo "EN MISSING: $k"
    grep -qF "$k =" Chronote/zh-Hans.lproj/Localizable.strings || echo "ZH MISSING: $k"
  done
  ```
  zh 那条值 = key 也得显式写一行(`"全部清空" = "全部清空";`),否则就是上面说的英文穿透。superreview 反复踩同一坑。
- **Race-prevention 用世代号别用 `var task: Task!` self-reference**。`var newTask: Task<Void, Never>!; newTask = Task { ... 用 newTask ... }` 在 strict concurrency 触发 `'newTask' mutated after capture by sendable closure` warning(Swift 5 警告 / Swift 6 error)。修法:在 class 里加 `var someGen: Int = 0`,每次 `someGen &+= 1` + 闭包捕获 `let myGen = someGen`,完成后 `if self.someGen == myGen { ... }`。两处实例:`ReminderService.currentRescheduleGen`、`ThemeAliasJudgeService.scanGen`。
- **默认 true 的 `Bool` UserDefaults 不能用 `defaults.bool(forKey:)`** —— 缺省返 false,与"显式关"撞。用 `(defaults.object(forKey: key) as? Bool) ?? true`。参考 `ReminderService.useContextualBody`。
- **Bool UserDefaults 默认值翻转有 silent regression 风险,要 sentinel migration**。旧代码靠"读时合成默认值"(没显式写到盘),后续把代码默认值翻转 → 老用户启动时全部静默翻向新默认。修法:用同 feature 的另一个 key(已激活过的存在性标志,如 `enabledKey`)做 sentinel —— 当前 key 缺 + sentinel 已写 → 老用户 → 一次性写**旧默认**锁住体验;两个都缺 → 真新装机 → 走新默认。`ReminderService.loadUseContextualBody` 是参考实现(默认 true→false 翻转时保护老用户)。
- **批量删 entry 三件套**:任何**一次性删 ≥1 篇 entry** 的路径(`SettingsView.deleteAllEntries` / `DatabaseRecoveryService.recreateStore` / 未来新增的 clear-and-restore)`save()` 成功后必须**同时**调三个清理:`ReminderService.shared.requestReschedule()` + `ThemeAliasResolver.shared.resetForBulkEntryWipe()`(清 groups/pending/coolUntil,**保留 negativePairs**)+ `PromptSuggestionEngine.shared.clearCache()`(置 nil + cancel inflight refresh)。漏一个 → banner / 通知 body / 别名管理页引用已不存在的 entry。
- **`Form` `.insetGrouped` 内放 `liquidGlassCard` 的 row 必须 `listRowInsets(leading: 16, trailing: 16)`,不能 0**。iOS 26 Form 给每个 row 包一层系统 rounded inset chrome,liquidGlassCard 顶满(0/0)会跟 chrome 边缘重合产生"突兀阴影 / 双圆角";16/16 给卡留呼吸空间,只显示自己的玻璃边。pendingCard / HomeView 时间线 row / `ThemeAliasManagementView.groupRow` 都是这个 pattern。
- **Fire-and-forget `Task { await foo() }` 调用方不持 handle → `foo` 内部 `Task.isCancelled` guard 永不触发,是死代码**。要真 cancel 必须把 Task 存成 ivar(`var fooTask: Task<Void, Never>?`)+ 调用方主动 `cancel()`。fire-and-forget 路径只留语义级守卫(stale-write 防御:`entryStillExists` / 世代号 gen check)更清晰。`ThemeAliasJudgeService.judgeAfterWrite` 是参考实现(删了一堆 isCancelled guards,只保留 `entryStillExists`)。
- **`Task` 是 struct,identity check 用 `==` 不是 `===`** —— `Task: Hashable` since Swift 5.5。`===` 编不过(Task 不是 class)。世代号模式比 task identity 更稳(见上一条)。
- **`UNUserNotificationCenterDelegate` 必须实现 `willPresent`,否则前台通知静默**。iOS 默认 = "App 在前台时,通知**不**展示 banner / 不响 sound / 不进通知列表"。我们手动放行 reminder 类(`shouldFocusComposer` 命中的 identifier / categoryIdentifier / userInfo)= `[.banner, .list, .sound]`,非 reminder = `[]`。`didReceive`(用户点击)路径要单独实现,管 cold launch 和后台点击;`willPresent` 管前台展示,两条不互通,缺一全前台通知失效。
- **冷启动通知点击的 cold-launch 消费需要 `.task` + `.onChange` 双路**,只挂 `.onAppear` 不够。路径:用户在锁屏点 reminder → 系统给 App 启动 → `userNotificationCenter(_:didReceive:)` 在后台 queue 触发 → hop `Task { @MainActor in composeFocusRequestID = UUID() }`(异步) → SwiftUI 跑 `.onAppear` 时 requestID 可能还 nil → router hop 完成 → `.onChange` fire 救场。如果 future 把 router 改成同步主线程 publish,`composeFocusRequestID` 在 `@ObservedObject` 订阅前已 set,`.onChange` 不会 fire(只对 transition 敏感),`.onAppear` 单独无法消费 cold-launch。**`.task` 在 view 完整 wired-up 后跑,read-and-clear 配合 `.onChange` 双路兜底**,`consumeComposeFocusRequest()` 单次消费保证不重复 focus。HomeView 是参考实现。
- **后端 `/root/server` 不是 git working copy**,手动维护。改 devDep / dep:直接 SSH 跑 `npm uninstall <pkg>` / `npm install <pkg>@x.y.z` —— 同时同步 `package.json` + `node_modules`,不会 touch 其他字段。改 `index.js` 部署流程(凭证存在 `~/.claude/.../memory/reference_lumory_server.md`,不进 git):`sshpass -p $PWD ssh root@$HOST 'cp /root/server/index.js{,.bak.$(date +%Y%m%d-%H%M%S)}'` → `scp server/index.js root@$HOST:/root/server/` → `ssh root@$HOST 'cd /root/server && node --check index.js && pm2 restart lumory-server'` → `curl https://lumory.isaabby.com/health`。

## Follow-up backlog(本人留给本人 / 后人的待办)

下面这些是历次 superreview 抓出来的、**有意识跳过**的活儿。代码本身没坏,但测试覆盖 / 抽象基建 / 隐私 hardening 欠了一笔。下次有空再补,不补也能 ship。

### 测试覆盖缺口

- **`parseImportedDiaries` 错误路径 + `StreamEvent.truncated` 端到端消费侧测试** —— 现在 `MockAIService` / `ThemeAliasAITestDouble` 能注入 throw / `.truncated` 事件,但 `NarrativeReader` / `AskPastView` 消费侧无单测断言 `isIncomplete` flag 翻 true。需要给 view-state 观察建一个测试基础设施(可能引入 ViewInspector 或自己写 binding-tap helper),先把这条测试基建落地再补具体用例。
- **`ReminderService.currentRescheduleGen` race stale 场景测试** —— `ThemeAliasJudgeService.scanGen` 的 race 测试已覆盖(`scanGen_staleCompletionDoesNotClearNewerTaskHandle`,通过 `simulateConcurrentScanStartForTesting` 注入),但 `ReminderService` 没装 race test seam(强耦 UN center,要 mock UN 才能干净测)。下次拆 ReminderService 时一并解决。

### 隐私 hardening

- **不要单独把 ThemeAliasResolver 主题名搬 Keychain**(2026-04-29 评估):看着像 PII 加固但其实**不治本**。日记原文存 CoreData SQLite 的默认 file protection 是 `NSFileProtectionCompleteUntilFirstUserAuthentication`(用户首次解锁后明文可读),跟 UserDefaults plist 一档;主题词单独搬 Keychain 等于"大门敞开却锁了厨房柜子"——日记原文里反复出现这些主题词,加密 alias map 不增加真实威胁面。真正的隐私 hardening 应该是**统一升级 SQLite 文件保护级别**(`NSFileProtectionComplete` 锁屏即不可读,但会让后台同步 / 通知调度失效)或**端到端 user passphrase 加密**(像 Signal,大工程)。这两条是产品决策,不是 backlog 单条能解决,在那之前 Keychain 迁移工作量 ≥ 收益,**不做**。

### 重构 / 待续

- **`ThemeAliasResolver` 拆分** —— 882 行(2026-04-29 状态),class body ~500 行,SRP 三件套(read API / queue 生命周期 / persistence)混一坨。下次大动作前拆 `ThemeAliasStore`(read+disk)+ `ThemeAliasResolver`(queue+throttle)。
- **`OpenAIService.swift:1633` 的 `// TODO: migrate to structured JSON payload`** —— 把 rawText 放进 JSON 字段而不是 raw body。具体 endpoint 看代码上下文,工作量看 schema 改动量。
- **`CloudKitSyncMonitor` 内 8 处 `DispatchQueue.main.async` wrap 是 redundant**(class 已 `@MainActor`)—— 行为等价于 `MainActor.assumeIsolated`,清不清都安全。要清要审 8 处 callback 路径来源(确保是主线程 callback,不是 CK 后台 callback),工作量小但要细心。
- **超长文件**(都是预存技术债,SwiftLint 阈值 600 行):HomeView 2344 / OpenAIService 1772 / SettingsView 1165 / InsightsView 970 / DiaryDetailView 883 / ThemeAliasResolver 882。重构机会但都不算 bug。

## Claude Code 自动化(本地,非生产)
- **MCP servers**(`~/.claude.json` 本项目 scope):
  - `xcodebuildmcp` — 封装 `xcodebuild` / `simctl` / UI 自动化。**优先用它的工具**而不是 Bash 跑 `xcodebuild`,能省 2 分钟默认 timeout 且错误结构化返回。
  - `context7`(插件)— 查 SwiftUI / CoreData / CloudKit / Express 5 等官方文档时用,避免训练截止日之后的 API 漂移。
- **Skills** 在 `.claude/skills/`:`screenshot`(截图流水线 + 坑)。用户说截图 / 上架截图时会自动匹配。
- **Subagent** `coredata-migration-reviewer`(`.claude/agents/`):**改 `.xcdatamodeld` / `DiaryEntry+Extensions.swift` / `PersistenceController.swift` / 任何动 `DiaryEntry` schema 的服务后,主动召唤它跑一遍审查**,别等出事。
- **可用的 `subagent_type` 池**(harness allowlist,**派单前别瞎猜**):`code-reviewer` / `general-purpose` / `Explore` / `Plan` / `coredata-migration-reviewer` / `sse-pipeline-reviewer` / `debugger` / `code-simplifier:code-simplifier` / `feature-dev:*` / `plugin-dev:*` / `agent-sdk-dev:*` / `codex:codex-rescue` / `claude-code-guide` / `statusline-setup`。**`security-auditor` / `test-automator` / `architect-review` / `performance-engineer` / `database-optimizer` 等行业常见名字都不在池里**(直接 hard error)—— security / test-gap / architecture / perf review 这类专项视角统一走 `code-reviewer` 或 `general-purpose`,焦点写在 prompt 里。superreview 流水线踩过这坑(3/8 个 agent 派失败重新发)。
- **Hook** `.claude/hooks/server-lint.sh`(PostToolUse):编辑 `server/*.js` 后自动 `eslint --fix` + `prettier --write`,失败不阻塞对话。改了 hook 脚本记得 `chmod +x`。
