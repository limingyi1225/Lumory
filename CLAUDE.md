# Lumory

iOS 日记 App。产品名 **Lumory**,Xcode 项目 `Lumory.xcodeproj`,target/scheme/productName 都是 **`Lumory`**(`project.pbxproj:116`),源码目录仍是 `Chronote/`(历史遗留,rename 成本大故不动),bundle id `Mingyi.Lumory`。tests target 仍叫 `ChronoteTests` / `ChronoteUITests`。仓库里同时包含一个 Node.js OpenAI 代理后端(`server/`)。

## 技术栈
- **iOS 客户端**:SwiftUI + CoreData + `NSPersistentCloudKitContainer`(CloudKit 同步)。App 入口 `Chronote/ChronoteApp.swift`;`WindowGroup` 挂一个 `ZStack`,启动先走 `SplashView`(约 1s)再淡出到主内容视图 `HomeView`(见 [ChronoteApp.swift:173-186](Chronote/ChronoteApp.swift:173))。
- **后端**:Node.js + Express 5,部署在 `https://lumory.isaabby.com`(Cloudflare → nginx:443 → node:3000),PM2 进程管理。
- **AI**:走自建后端代理 OpenAI(`/api/openai/chat/completions`、`/api/openai/embeddings`)。Chat 走 SSE 流,模型目前是 `gpt-5.5` / `gpt-5.4-mini`(reasoning effort 分档)。
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
    - [UITestSampleData.swift](Chronote/Services/UITestSampleData.swift) — `#if DEBUG`,启动参数 `-LumoryUITestSampleData YES` 触发同步擦库 + 种入 30 条手写 + ~60 条模板化样例日记(主角"林子衿"),给 App Store screenshot / demo 用。`ChronoteApp.init()` 里调 `seedIfNeeded(into:)`。
    - `HapticManager.swift` — 触觉反馈统一入口。
  - `Views/`
    - [HomeView.swift](Chronote/Views/HomeView.swift) + `HomeView/`(3 个 `@Observable` VM:`HomeInputViewModel` / `HomeRecordingViewModel` / `HomePhotoViewModel`,+ `Components/` 下的 `DiaryEntryRow` · `DiaryTextEditor` · `PhotosCollectionView`)。**注意:`recorder` / `audioPlaybackController` 故意留 HomeView 作 `@StateObject`,不搬进 @Observable VM —— Observation 宏不 bridge 嵌套 `ObservableObject` 的 `@Published`,搬进去 UI 就不 react 了。**
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
- `Scripts/generate-screenshots.sh` — 自动跑 `ChronoteUITests/ScreenshotTests` 出 6 张 1320×2868 的 App Store 截图到 `Screenshots/zh-Hans/`。流程:boot iPhone 17 Pro Max → `simctl status_bar override`(9:41 / 满电) → `xcodebuild test -only-testing ... -parallel-testing-enabled NO` → `xcresulttool export attachments`。
- `.claude/` — Claude Code 本地自动化配置。
  - `skills/screenshot/SKILL.md` — 封装截图流水线(iPhone / iPad + 坑位清单)。用户说"截图 / 上架截图"自动触发。
  - `skills/swift-verify/SKILL.md` — `xcodebuild build/test` + Lumory 特有陷阱读法。改完 Swift 想快速确认时触发。
  - `agents/coredata-migration-reviewer.md` — **改任何 CoreData schema / `DiaryEntry+Extensions` / `PersistenceController` 后应主动召唤**,按 CloudKit 兼容性 + `embedding` / `themes` / backfill 清单审查。
  - `hooks/server-lint.sh` + `settings.json` — PostToolUse hook:编辑 `server/*.js` 后静默跑 `eslint --fix` + `prettier --write`。失败不阻塞。
  - `settings.local.json` — 个人权限 allowlist,别把它 check 进 git。
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
- **速率限制**:per-install(客户端 `X-Install-Id` = Keychain UUID,`InstallIdentity.current`)+ 全局 IP 兜底双层。chat 120/min per-install,embeddings 300/min per-install(和客户端 Theme peak ~85/min、Embedding peak ~200/min 对齐留 headroom),`/api` 整路径 600/min per-IP 防滥用。合法 install-id 用 `/^[A-F0-9-]{36}$/i` 校验,非法 / 缺失回落 `ip:<req.ip>`。
- **请求体限制**:chat messages 总 char `MAX_MESSAGES_CHARS`(默认 32000,十进制非 32768);embedding input `MAX_EMBEDDING_INPUT_CHARS`(默认 8192)。`REQUEST_TIMEOUT_MS=120_000`(和客户端 `timeoutIntervalForResource=300s` 对齐,给长 SSE 流留余量)。
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
  - `Chronote/Services/AppSecrets.swift` 里硬编码 `appSharedSecret`,已知问题,TODO 迁到 xcconfig / CI secret injection。
  - 后端 `OPENAI_API_KEY` 和 `APP_SHARED_SECRET` 都必须来自 `server/.env`,缺任一立刻 `process.exit(1)`。
- **Info.plist 的 ATS 例外**已删(历史上为旧明文 origin `64.176.209.155` 留的,现在全 HTTPS 走 `lumory.isaabby.com`,不再需要)。
- **CoreData 迁移**不要同步跑在 `init()`。回填用 `*BackfillService` 模式:`WordCountBackfillService` 走后台 context `fetch(predicate: wordCount == 0)` + 遍历 + save(无 UserDefaults flag,天然幂等 —— 没 pending 就是空数组,代价只是一次 SQL 扫);`Embedding/ThemeBackfillService` 的 `runningTask` 已改 `@MainActor` 隔离,所有 start/cancel 入口都会汇合到 MainActor 排队,多入口 race 被锁死。
- **SSE 在客户端**:`OpenAIService.SSEParser` 负责底层解析(支持多行 data: 累加 + `:` 注释行 + 可选空格 + `[DONE]` 识别);`NetworkRetryHelper` 负责传输层异常重试,每轮 attempt 前会 `try Task.checkCancellation()`。流式事件走 `AIServiceProtocol.streamReportEvents` / `askEvents` 返回 `AsyncStream<StreamEvent>`,UI 消费端(NarrativeReader / AskPastView)在看到 `.truncated` 时 set `isIncomplete` flag 显示警示条,**不再**把中文错误字符串当 chunk 吐出去。后端 SSE 出错仍必须 `res.destroy(error)` 硬断,不能写 `data: [DONE]`。
- **提交信息**:沿用仓库既有中英混合风格,参考 `git log`。
- **CHANGELOG.md 不准确**,实际状态以代码和 git 为准。
- **Xcode 项目用 PBXFileSystemSynchronizedRootGroup**(`Chronote/` / `ChronoteTests/` / `ChronoteUITests/`):新加 .swift 直接放目录里就被 target 自动包含,**不要**手编 `project.pbxproj`。
- **UI tests target 配置**:`TEST_TARGET_NAME = Lumory`(历史是 `Chronote`,Lumory 重命名时漏改导致 `xcodebuild test` 报 "UITargetAppPath should be provided",已修;`-only-testing:ChronoteUITests/...` 仍走 target 名 `ChronoteUITests`)。
- **`xcodebuild test` 默认会 clone 指定的 simulator**(运行时 `RUN_DESTINATION_DEVICE_NAME = "Clone N of iPhone X"`),而 `simctl status_bar override` **只对原始 sim 生效,不继承到 clone**。截图脚本必须加 `-parallel-testing-enabled NO -disable-concurrent-destination-testing` 强制走原始 sim,否则状态栏角上是真实电量 / 真实时间。
- **从 main thread 调 Core Data `bg.performAndWait` 时,不能在 block 内部 `DispatchQueue.main.sync`**——main 已经在等 bg,立即死锁(SIGTRAP / Abort Cause 9005...)。模式:用 `var` 把 batch delete 的 `objectIDs` 暂存,等 `performAndWait` 返回(回到 main 自然态)再 merge。`UITestSampleData.seedIfNeeded` 是参考实现。
- **Screenshot 模式下 `requestPermissions()` 必须 early return**(`if UITestSampleData.isActive { return }`),否则 SFSpeech / Mic 弹窗盖在 Home 上把首屏截烂。
- **从 .xcresult 提取截图**用 Xcode 16+ 自带的 `xcrun xcresulttool export attachments --path BUNDLE --output-path DIR`(配合 `manifest.json` 把 UUID 文件名映射回 `suggestedHumanReadableName`),不需要装 `xcparse`,也别用 deprecated 的 `--legacy --format json` 老 API。
- **iOS 部署目标 26.0**(`IPHONEOS_DEPLOYMENT_TARGET` 在 6 个 config 里均一致)。可用 `@Observable` 宏、`@Entry`、iOS 17+ 的 `@State<AnyObject>` 语义。
- **`@Environment` 只能在 instance scope 访问**。SwiftUI `private static func` / 属性初始化器里用 `@Environment` 会报 "instance member cannot be used on type"。静态辅助方法需要 AIService 时,在调用点 `let ai = aiService` 捕获后作参数传进去(参见 `DiaryDetailView.refreshAIIndex(... ai:)`)。
- **SwiftUI `@FetchRequest(animation:)` 不要用**。和 List 原生 row-removal 动画 + `withAnimation { delete }` 三层叠加会错位。当前用 `@FetchRequest(sortDescriptors:)` 无 animation + `ForEach(Array(entries.enumerated()), id: \.element.objectID)` 组合,动画由 `withAnimation` 单层控制,identity 由 objectID 稳定。
- **bash `cmd1 | cmd2 || true` 会覆盖 `PIPESTATUS`**。`|| true` 之后 `${PIPESTATUS[0]}` 只剩 `true` 的 exit code,原 pipeline 状态丢光。需要真实 exit code 时改用 `set +e` + 直接 pipeline(不加 `|| true`),然后读 `PIPESTATUS[0]`,最后 `set -e`(参见 `Scripts/generate-screenshots.sh`)。

## Claude Code 自动化(本地,非生产)
- **MCP servers**(`~/.claude.json` 本项目 scope):
  - `xcodebuildmcp` — 封装 `xcodebuild` / `simctl` / UI 自动化。**优先用它的工具**而不是 Bash 跑 `xcodebuild`,能省 2 分钟默认 timeout 且错误结构化返回。
  - `context7`(插件)— 查 SwiftUI / CoreData / CloudKit / Express 5 等官方文档时用,避免训练截止日之后的 API 漂移。
- **Skills** 在 `.claude/skills/`:`screenshot`(截图流水线 + 坑)、`swift-verify`(build/test + 陷阱)。用户说截图 / build / 测试时会自动匹配。
- **Subagent** `coredata-migration-reviewer`(`.claude/agents/`):**改 `.xcdatamodeld` / `DiaryEntry+Extensions.swift` / `PersistenceController.swift` / 任何动 `DiaryEntry` schema 的服务后,主动召唤它跑一遍审查**,别等出事。
- **Hook** `.claude/hooks/server-lint.sh`(PostToolUse):编辑 `server/*.js` 后自动 `eslint --fix` + `prettier --write`,失败不阻塞对话。改了 hook 脚本记得 `chmod +x`。
