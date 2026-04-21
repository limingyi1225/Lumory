# Lumory

iOS 日记 App。产品名 **Lumory**,Xcode 项目 `Lumory.xcodeproj`,target/scheme 叫 **`Lumory`**(`project.pbxproj:116`),`productName = Chronote`(遗留,`project.pbxproj:119`),源码目录 `Chronote/`,bundle id `Mingyi.Lumory`(`project.pbxproj:462`)。仓库里同时包含一个 Node.js OpenAI 代理后端(`server/`)。

## 技术栈
- **iOS 客户端**:SwiftUI + CoreData + `NSPersistentCloudKitContainer`(CloudKit 同步)。App 入口 `Chronote/ChronoteApp.swift`;`WindowGroup` 挂一个 `ZStack`,启动先走 `SplashView`(约 1s)再淡出到主内容视图 `HomeView`(见 [ChronoteApp.swift:173-186](Chronote/ChronoteApp.swift:173))。
- **后端**:Node.js + Express 5,部署在 `https://lumory.isaabby.com`(Cloudflare → nginx:443 → node:3000),PM2 进程管理。
- **AI**:走自建后端代理 OpenAI(`/api/openai/chat/completions`、`/api/openai/embeddings`)。Chat 走 SSE 流,模型目前是 `gpt-5.4` / `gpt-5.4-mini`(reasoning effort 分档)。
- **语音**:Apple `SFSpeechRecognizer` + `AVAudio` 录音,转写本地做(见 [AppleSpeechRecognizer.swift](Chronote/Services/AppleSpeechRecognizer.swift) / [AudioRecorder.swift](Chronote/Services/AudioRecorder.swift));不走 OpenAI 转录。
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
    - `HapticManager.swift` — 触觉反馈统一入口。
  - `Views/`
    - [HomeView.swift](Chronote/Views/HomeView.swift) + `HomeView/Components/`(`DiaryEntryRow` · `DiaryTextEditor` · `PhotosCollectionView`)
    - `Insights/` — `InsightsView` · `AskPastView` · `TimeRange`,组件见 `Insights/Components/`(`CalendarMonthModule`、`MoodStoryChart`、`WritingHeatmap`、`ThemeCardList`、`NarrativeReader`、`CitationEntryCard`、`CorrelationChipList`)
    - `Search/SearchView.swift`
    - [DiaryDetailView.swift](Chronote/Views/DiaryDetailView.swift) · [SettingsView.swift](Chronote/Views/SettingsView.swift) · [SyncDiagnosticView.swift](Chronote/Views/SyncDiagnosticView.swift) · [DiaryImportView.swift](Chronote/Views/DiaryImportView.swift) · [DiaryExportView.swift](Chronote/Views/DiaryExportView.swift) · `ImageViewerView.swift`
    - `Components/` — `MoodSpectrumBar`、`MoodSendAnimation`、`MarkdownText`
    - `Shared/` — `EmptyStateView`、`Animations/BreathingDots`
  - `Extensions/` — `Color+MoodSpectrum`、`Image+Compression`
  - `Utils/` — `AnimationConfig`、`LiquidGlass`、`LocalizationHelper`、`Log`、`PerformanceOptimization`
- `ChronoteTests/` · `ChronoteUITests/` — 单测 / UI 测试
- `Lumory.xcodeproj` · `Lumory-Info.plist` · `Lumory.entitlements` · `Lumory.icon`
- `server/` — Node 后端。代码主体集中在 [index.js](server/index.js)(约 280 行,Express 5 + pino + pino-http + express-rate-limit + axios + cors + dotenv),目录内还有 `package.json` / `package-lock.json` / `eslint.config.js`。
- `ecosystem.config.js` — PM2 配置(`lumory-server`,fork 模式,`max_memory_restart: 512M`)。
- `Scripts/reset-database.sh`、根目录 `clean-build.sh` / `deep-clean.sh` / `clean-corrupted-db.sh` — 维护脚本。
- `CHANGELOG.md` — **内容不可信,不要据此推断版本/日期/功能状态**。

## iOS 架构要点
- **启动序列**(`init()` 在 [ChronoteApp.swift:35-95](Chronote/ChronoteApp.swift:35);remote-change observer 在 [:197-207](Chronote/ChronoteApp.swift:197)):
  - `PersistenceController.shared` 同步初始化(store 加载失败走 `DatabaseRecoveryService`)。
  - `DataMigrationService.performMigrationIfNeeded()` 放 `Task.detached(.userInitiated)` —— 绝不要挪回 `init()` 同步调用,会触发 watchdog。
  - 权限请求(麦克风 + 语音识别)、动画预热、图片迁到 iCloud、`WordCountBackfillService.backfillIfNeeded()`。
  - `EmbeddingBackfillService` / `ThemeBackfillService` **不 auto**(历史上自动跑踩过 actor-safety + 弱网失败率坑)。
- **CloudKit**:容器 `iCloud.com.Mingyi.Lumory`,`CloudKit` + `CloudDocuments`,`aps-environment=production`,`UIBackgroundModes=remote-notification`。远端变更通过 `NSPersistentStoreRemoteChange` 驱动 `WordCountBackfill`。
- **场景切换**([ChronoteApp.swift:220](Chronote/ChronoteApp.swift:220)):background 时 flush `viewContext` 防止用户输入丢失;active 时 `syncMonitor.checkCloudKitStatus()`。

## 后端架构要点
- 入口 [server/index.js](server/index.js)。
- **鉴权**:所有 `/api/*` 要求 header `X-App-Secret`,timing-safe compare。未配 `APP_SHARED_SECRET` 直接 fail-closed(启动即退)。`/health` 不走鉴权,供健康探活。
- **速率限制**:`/api/openai/chat/completions` 120/min;`/api/openai/embeddings` 300/min(给客户端批量回填留 headroom,客户端侧节流参数在 `EmbeddingBackfillService`/`ThemeBackfillService` 里和这里对齐)。
- **请求体限制**:chat messages 总 char `MAX_MESSAGES_CHARS`(默认 32000,十进制非 32768);embedding input `MAX_EMBEDDING_INPUT_CHARS`(默认 8192)。
- **SSE 错误处理**:上游 stream 出错时 `res.destroy(error)`,**不能**写 `data: [DONE]`(客户端会把半截当成功)。
- **日志**:pino JSON → PM2 `logs/backend-out.log` / `backend-err.log`,headers 里的 `authorization` / `cookie` / `x-api-key` / `x-app-secret` 在 pino redact 里全部 `[REDACTED]`。
- **网络拓扑**:Cloudflare edge(公共 cert)→ origin nginx:443(self-signed)→ node:3000。`app.set('trust proxy', 'loopback')`。

## 常用命令

iOS:
- 构建 Debug:`xcodebuild -project Lumory.xcodeproj -scheme Lumory -configuration Debug build`
- 跑测试:`xcodebuild test -project Lumory.xcodeproj -scheme Lumory -destination 'platform=iOS Simulator,name=iPhone 17'`
- 清理:`./clean-build.sh`;彻底清(含 DerivedData / ModuleCache / .swiftpm):`./deep-clean.sh`
- 本地 DB 损坏恢复:`./clean-corrupted-db.sh` 或 `Scripts/reset-database.sh`

后端(`server/`):
- 启动:`npm start`;开发:`npm run dev`(nodemon)
- Lint:`npm run lint`;Format:`npm run format`
- 生产重启(服务器上):`pm2 restart lumory-server`
- 健康探活(免鉴权):`curl https://lumory.isaabby.com/health`

## 约定 / 踩过的坑

- **⚠️ Secrets**:
  - `Chronote/Services/AppSecrets.swift` 里硬编码 `appSharedSecret`,已知问题,TODO 迁到 xcconfig / CI secret injection。修改时注意不要再引入真正的 OpenAI key(曾泄露过一次)。
  - 后端 `OPENAI_API_KEY` 和 `APP_SHARED_SECRET` 都必须来自 `server/.env`,缺任一立刻 `process.exit(1)`。
- **Info.plist 里的 ATS 例外**(`64.176.209.155`)是旧明文 origin 的遗留,现在已走 HTTPS,可考虑清掉;动前先确认没有老版本客户端在用。
- **CoreData 迁移**不要同步跑在 `init()`。回填用 `*BackfillService` 模式:`WordCountBackfillService` 走后台 context `fetch(predicate: wordCount == 0)` + 遍历 + save(无 UserDefaults flag,天然幂等 —— 没 pending 就是空数组,代价只是一次 SQL 扫);`Embedding/ThemeBackfillService` 靠 in-memory `runningTask` 做互斥(也没 flag,进程重启后不会"跳过已做完")。不要让 auto-path 和 Settings 里的"一键重建"共用 `.shared` 的 `runningTask` guard(非 actor-safe)。
- **SSE 在客户端**:`OpenAIService` 解析 SSE(见 `data: [DONE]` 才算正常结束),`NetworkRetryHelper` 负责传输层异常重试。两者合起来要求后端出错必须"硬断"(`res.destroy(error)`),**不能**写 `data: [DONE]`——否则会被当作成功回执。
- **提交信息**:沿用仓库既有中英混合风格,参考 `git log`。
- **CHANGELOG.md 不准确**,实际状态以代码和 git 为准。
