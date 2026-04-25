# Lumory 代码审查总结报告
**日期**: 2026-04-24  
**基线提交**: `e9e7a19` — review: P0/P1/P2 18 条代码审查修复 + HomeView VM 拆分 + per-install 限流  
**构建基线**: ✅ BUILD SUCCEEDED (iOS Simulator, iPhone 17, scheme Lumory)  
**方法论**: 两轮审查 — Layer 1: 9 个专项 Opus agent 并行审查各主题；Layer 2: 9 个 Opus verify agent 独立交叉核对，标注 CONFIRM / PARTIAL / REJECT，并补充遗漏发现  

---

## 验证统计概览

| Track | 主题 | Layer 1 发现 | CONFIRM | PARTIAL | REJECT | 新增 |
|-------|------|------------|---------|---------|--------|------|
| 1 | 安全 / 威胁模型 | 13 | 13 | 0 | 0 | 6 |
| 2 | CoreData + CloudKit | 18 | 16 | 2 | 0 | 6 |
| 3 | 并发 / 内存 | 13 | 10 | 3 | 0 | 3 |
| 4 | UI/UX + Accessibility | 21 | 18 | 2 | 1 | 10 |
| 5 | 错误处理 + 边界 | 20 | 16 | 3 | 0 | 6 |
| 6 | 性能 | 14 | 12 | 2 | 0 | 7 |
| 7 | 测试 / 维护性 | 14 | 13 | 1 | 0 | 5 |
| 8 | 后端 / 基础设施 | 17 | 15 | 2 | 0 | 6 |
| 9 | 文档 / Onboarding | 10 | 8 | 2 | 0 | 5 |

---

## P0 — 立即修复（数据丢失 / 在线安全威胁）

### P0-1 ⚠️ OpenRouter API 密钥泄漏至公开 GitHub 仓库
- **位置**: git commit `5424111`（仓库初始提交）；仓库 `github.com/limingyi1225/Lumory.git` 已公开
- **详情**: 提交里含 `sk-or-v1-821542693f…a03e`（OpenRouter 密钥，非 OpenAI）。verify-1 进一步确认仓库已公开，Track 1 原报告高估"如果将来公开"的假设——当前已是**在线真实泄漏**。
- **行动**: 立即在 OpenRouter Dashboard 撤销并重生成密钥；检查 git history 中其他密钥片段。
- **来源**: Track 1 P0 → Verify-1 CONFIRM + 严重度升级

### P0-2 ⚠️ `AppSecrets.swift` 硬编码 `appSharedSecret` 在公开 git 历史中
- **位置**: `Chronote/Services/AppSecrets.swift`；在 `refs/pull/1/head` 引用中可见
- **详情**: 后端共享密钥硬编码在客户端源文件中且已推送公开仓库，任何人可读取并直接调用后端 API，绕过速率限制。
- **行动**: 轮换 `APP_SHARED_SECRET`；将密钥迁移到 xcconfig / CI secret injection，不得 check in 源码。
- **来源**: Track 1 P0 → Verify-1 CONFIRM

### P0-3 CloudKitSyncMonitor block observer 永久泄漏
- **位置**: `Chronote/Services/CloudKitSyncMonitor.swift:50–113`
- **详情**: `setupNotifications` 用 `NotificationCenter.addObserver(forName:object:queue:using:)` 注册 4 个 block-form observer，返回的 `NSObjectProtocol` token 全部被丢弃。`deinit` 调用 `removeObserver(self)`，只能清除 target-selector 形式的注册，block-form observer 永远不会被移除 → 每次 `CloudKitSyncMonitor` 重建时堆叠一层内存泄漏并收到重复通知。
- **行动**: 用 `var observers: [NSObjectProtocol] = []` 存储 tokens，`deinit` 里逐个 `removeObserver`。
- **来源**: Track 2 P0 + Track 3 P0 → Verify-2 CONFIRM + Verify-3 CONFIRM（双重独立验证）

### P0-4 `SyncDiagnosticService.checkCoreDataStoreStatus()` 主线程外访问 viewContext
- **位置**: `Chronote/Services/SyncDiagnosticService.swift`（静态函数内 `container.viewContext.fetch`）
- **详情**: `checkCoreDataStoreStatus` 是 struct 静态函数，无 `@MainActor` 约束，在诊断流程任意线程调用时直接操作 `viewContext`（主线程绑定上下文），CoreData 并发规则违反，可导致 SIGTRAP / 数据一致性问题。
- **行动**: 标注 `@MainActor` 或改用 `performBackgroundTask` + 私有 context。
- **来源**: Track 3 P0 → Verify-3 CONFIRM

### P0-5 `server/index.js: sanitizeUpstreamError` 非生产环境直接返回上游原始错误
- **位置**: `server/index.js:290–292`
- **详情**: `IS_PRODUCTION` 为 false（`NODE_ENV !== 'production'`）时，`sanitizeUpstreamError` 返回 `err.response?.data`——即 OpenAI API 完整错误 body（含 model 内部标识、error.type、error.param 等），直接 JSON 序列化发回客户端。pino redact 只覆盖日志，不过滤 HTTP 响应体。
- **行动**: staging/dev 也应至少按 status 分类返回，不得原样转发上游 body；或仅允许 `localhost` origin 看到 raw 错误。
- **来源**: Track 8 P0 → Verify-8 CONFIRM

---

## P1 — 高优先级（下次发布前修复）

### P1-1 `PersistenceController.performEmergencyRecovery` — 危险 dead code 未删
- **位置**: `Chronote/Model/PersistenceController.swift:192–248`
- **详情**: `handlePreLoadCorruption` / `performEmergencyRecovery` / `reloadAfterRecovery` 三个方法从未被任何路径调用（全仓 grep 零调用点，Track 7 + Track 2 + Track 9 三路交叉确认），但包含静默删除 sqlite 四件套 + 清空 UserDefaults CloudKit 相关 key 的逻辑，与代码注释"永远不要在未经用户同意时删本地数据"直接冲突。
- **行动**: 直接删除这 62 行；正式恢复路径已由 `DatabaseRecoveryService.performRecovery` 承担（有用户确认弹窗）。
- **来源**: Track 2 P1 + Track 7 P1 + Track 9 P1 → Verify-2/7/9 CONFIRM

### P1-2 `PersistenceController.clearCloudKitTokens` 过度激进
- **位置**: `Chronote/Model/PersistenceController.swift:287`
- **详情**: 遍历全部 UserDefaults key，删除任何 `key.contains("CloudKit")` 的项，可能误删第三方 SDK（如 Firebase、AppCheck）存储的含 "CloudKit" 字符串的 key。
- **行动**: 改为显式枚举只删 CoreData 已知 token key，或使用专属 Suite。
- **来源**: Track 2 P1 → Verify-2 CONFIRM；Verify-5 NEW P2 也独立发现

### P1-3 `DiaryImportService` 绕过 `AIServiceProtocol` DI，手写 HTTP
- **位置**: `Chronote/Services/DiaryImportService.swift:77–134`
- **详情**: `CoreDataImportService` 通过 `aiService: AIServiceProtocol` 注入 Mock，但 `DiaryImportService.parse` 直接 `URLSession.shared`（`sslTolerantSession`）打 OpenAI，无视 DI，Mock 对解析路径完全无效，单测无法覆盖。同时该 session 命名 `sslTolerantSession` 具有误导性（实际无 SSL 绕过，仅为超时配置）。
- **行动**: 让 `DiaryImportService` 通过 `AIServiceProtocol` 注入 AI 调用；重命名 `sslTolerantSession` 为 `importURLSession` 或类似中性名称。
- **来源**: Track 1 P1 + Track 9 P1 → Verify-1/9 CONFIRM

### P1-4 `DiaryImportService` prompt injection 防护薄弱
- **位置**: `Chronote/Services/DiaryImportService.swift`（`<<<\(rawText)>>>` 分隔符）
- **详情**: 用户日记正文可包含 `>>>` 字符，截断 prompt 边界，使 AI 解析日记中的任意指令。
- **行动**: 对 `rawText` 中的 `>>>` 进行转义或替换；或改用 JSON 结构化传输而非纯文本分隔。
- **来源**: Track 1 P1 → Verify-1 CONFIRM

### P1-5 `CloudKitSyncMonitor` / `SyncDiagnosticService` 错误文本全英文，无 i18n
- **位置**: `CloudKitSyncMonitor.swift`（17 处英文字符串，含 `:128/140/152/169/179/182/185/188/191/235/238/241/250/278/294/302/358`）；`SyncDiagnosticService.swift:229–296`（`generateDiagnosticReport`、`SyncIssue.description`）
- **详情**: 全仓 grep 确认两文件零 `NSLocalizedString` 调用。中文语言环境下用户看到英文错误消息，与 App 整体本地化承诺不一致。Verify-4 还发现 `errorMessage` 会拼接 `error.localizedDescription`（系统本地化字符串）产生混合语言字符串。
- **行动**: 将展示用字符串迁移到 `Localizable.strings`，保留内部诊断用英文 log key。
- **来源**: Track 4 P0 + Track 9 P1 → Verify-4/9 CONFIRM

### P1-6 `ImageViewerView` 零 VoiceOver accessibility 标注
- **位置**: `Chronote/Views/ImageViewerView.swift`
- **详情**: 图片、关闭按钮均无 `accessibilityLabel`；关闭按钮点击区域约 28pt，远低于 HIG 推荐 44pt；图片加载失败（`UIImage(data:)` 返回 nil）时显示空白，无 fallback UI。全仓搜索确认零 `accessibilityReduceMotion` / `accessibilityDifferentiateWithoutColor` / `dynamicTypeSize` 适配。
- **行动**: 补充 `accessibilityLabel`；关闭按钮用 `.frame(minWidth: 44, minHeight: 44)` + `.contentShape(Rectangle())`；nil 图片时显示占位符。
- **来源**: Track 4 P1 → Verify-4 CONFIRM；Verify-4 NEW 补充 44pt 要求

### P1-7 `AudioRecorder` 错误路径状态机损坏
- **位置**: `Chronote/Services/AudioRecorder.swift`
- **详情**: `startRecording()` 在 `AVAudioRecorder` 初始化失败时未将 `isRecording` 重置为 false，后续 UI 仍显示录音中状态。另 Verify-3 NEW 发现无 `guard !isRecording` — 双次调用会创建两个 `meterTimer`，前一个未被 invalidate。
- **行动**: 在所有错误出口重置状态；`startRecording` 添加 `guard !isRecording else { return }` 保护。
- **来源**: Track 5 P0 → Verify-5 CONFIRM；Verify-3 NEW

### P1-8 `PersistenceController.save()` 静默吞错
- **位置**: `Chronote/Model/PersistenceController.swift`
- **详情**: `save()` 调用 `viewContext.save()` 失败时只 log，不向调用方抛出错误，日记写入失败对用户不可见。
- **行动**: 改为 `throws`，或至少向 UI 发出可观察的错误状态。
- **来源**: Track 5 P0 → Verify-5 CONFIRM

### P1-9 `DiaryImportService` 导入失败静默返回空结果
- **位置**: `Chronote/Services/DiaryImportService.swift`
- **详情**: 导入失败时返回空数组，UI 层将其当作成功（0 条记录导入），用户不知道发生了错误。
- **行动**: 区分"导入成功 0 条"和"导入失败"，失败时抛出错误并在 UI 展示。
- **来源**: Track 5 P1 → Verify-5 CONFIRM

### P1-10 `ImageViewerView` 一次性将所有图片 Data 加载入内存
- **位置**: `Chronote/Views/ImageViewerView.swift:11, 30–34`
- **详情**: `TabView` + `ForEach` 直接迭代 `[Data]` 并同步解码为 `UIImage`，6 张原图展开后可达 200+ MB，大相册场景下易触发 jetsam 被系统强杀。
- **行动**: 改为懒加载（`LazyHStack` 或 `@State` 按需解码），当前页 ±1 页缓存。
- **来源**: Track 6 P0 → Verify-6 CONFIRM

### P1-11 `SearchView` 全文三字段 OR 查询无索引
- **位置**: `Chronote/Views/Search/SearchView.swift:101–119`
- **详情**: `text CONTAINS[cd] %@ OR summary CONTAINS[cd] %@ OR themes CONTAINS[cd] %@` 三字段 CONTAINS[cd] 在 CoreData 中无法利用索引，1000 条日记全表扫描，`propertiesToFetch` 在 `.managedObjectResultType`（默认）下是 prefetch 提示而非 projection，仍 fault-in 完整对象。
- **行动**: 改 `resultType = .managedObjectIDResultType` 后映射；或为 text/summary/themes 字段在 `.xcdatamodeld` 中开启全文索引（CoreSpotlight integration 或 NSIndex）。
- **来源**: Track 6 P0 → Verify-6 CONFIRM；Verify-6 NEW P1 补充 resultType 细节

### P1-12 后端缺 Retry-After header
- **位置**: `server/index.js:113, 122, 135`（rate limiter message）
- **详情**: 限速响应只有 `{ error: 'rate_limited' }`，客户端 `NetworkRetryHelper` 没有等待依据，只能指数退避盲重试；upstream 429 也不转发 OpenAI 的 `retry-after`。
- **行动**: rate limiter 改 `standardHeaders: 'draft-7'`（自动加 `RateLimit-Reset`）；catch 块转发 upstream `retry-after` header 给客户端。
- **来源**: Track 8 P1 → Verify-8 CONFIRM

### P1-13 后端无 Correlation ID，请求无法端到端追踪
- **位置**: `server/index.js:73`（`pinoHttp({ logger: log })`）
- **详情**: 每个请求无唯一 ID，客户端日志和服务器日志无法关联，线上问题排查依赖时间戳碰运气。
- **行动**: `pinoHttp({ logger: log, genReqId: () => crypto.randomUUID() })`，同时在响应头 `X-Request-Id` 回传给客户端。
- **来源**: Track 8 P1 → Verify-8 CONFIRM

### P1-14 后端优雅关闭时不等待 SSE 流完成
- **位置**: `server/index.js:301–315`
- **详情**: `server.close()` 只停止接受新连接，不追踪 in-flight SSE stream；SIGTERM 时正在流式回答的请求被硬切，客户端收到截断 SSE 然后重试，重复消耗 token。
- **行动**: 维护活跃 stream Set，`shutdown` 时 `stream.destroy()` 每个 + 等待 `server.close()`。
- **来源**: Track 8 P1 → Verify-8 CONFIRM

### P1-15 `CloudKitSyncMonitor.checkCloudKitStatus()` 无防抖，每次 app active 都打 CloudKit
- **位置**: `Chronote/Services/CloudKitSyncMonitor.swift:160–195`；调用点 `Chronote/ChronoteApp.swift:265–267`
- **详情**: `.active` 场景每次前台都触发 `accountStatus` + `CKQuery`，用户频繁 app switch 下每次约 300–500ms 网络延迟 + CloudKit 配额消耗。
- **行动**: 添加 30s 冷却（`lastCheckDate` + `timeIntervalSinceNow < 30`），或改为 `NSPersistentCloudKitContainer` 的 event notification 驱动。
- **来源**: Track 6 P1 → Verify-6 CONFIRM

---

## P2 — 中优先级

### P2-1 `PersistenceController.storeURL()` 启动路径 force unwrap
- **位置**: `Chronote/Model/PersistenceController.swift:327, 362`
- **详情**: `.applicationSupportDirectory` / `.documentDirectory` 解析用 `.first!`；沙盒受损时 crash。
- **行动**: 用 `guard let` + fallback 或明确的 `fatalError` 信息。
- **来源**: Track 7 P1（force unwrap 列表）→ Verify-2 NEW P2

### P2-2 `InsightsEngine.retrieve()` 全量 fetch embedding 后内存排序
- **位置**: `Chronote/Services/InsightsEngine.swift:411–490`
- **详情**: 每次语义搜索把全部条目 text + embedding（1000 条 ≈ 15–30 MB transient）载入内存，完整 `sort O(N log N)` 后 `prefix K`；应改为两阶段（只 fetch embedding + id，内存 top-K heap）。
- **来源**: Track 6 P1 → Verify-6 CONFIRM

### P2-3 `WritingHeatmap` / `CalendarMonthModule` hash 策略漏重建（兼正确性 bug）
- **位置**: `Chronote/Views/Insights/Components/WritingHeatmap.swift:154–166`；`CalendarMonthModule.swift:234–242`
- **详情**: 两者只 hash 首末 cell，中间日期数据变化（编辑 wordCount / mood）不触发重建，热图 / 月历显示陈旧。Verify-6 指出这是**正确性 bug**，优先级高于报告标注。
- **行动**: hash 改为 `cells.map(\.hashValue).reduce(0, ^)` 或 hash 总数 + 首末 + 中间采样。
- **来源**: Track 6 P2 → Verify-6 CONFIRM + 严重度升级

### P2-4 `CalendarMonthModule.fetchDailyCells` 硬编码 140 天 + 错误 Core Data resultType
- **位置**: `Chronote/Views/Insights/Components/CalendarMonthModule.swift`
- **详情**: 固定 140 天不随 range 自适应，翻 6 个月前显示全空；`returnsObjectsAsFaults = false` + `propertiesToFetch` 在 `.managedObjectResultType` 下不做 projection（仍全字段 fault），应改 `.dictionaryResultType`。
- **来源**: Track 6 P2 → Verify-6 CONFIRM；Verify-6 NEW P1 补充 resultType

### P2-5 `InsightsView` range 快速切换堆叠并发 fetch
- **位置**: `Chronote/Views/Insights/InsightsView.swift:106, 199–230`
- **详情**: `loadToken` 只 guard UI 写入，不 cancel `performBackgroundTask`；range 快速切换 4 次 → 4 个并发 fetch 抢 store coordinator lock。
- **行动**: 在发起新 fetch 前取消已有 Task。
- **来源**: Track 6 P1 → Verify-6 CONFIRM（PARTIAL，细节修正）

### P2-6 第二个 `asyncAfter(2.0s)` 乐观定时器语义相同
- **位置**: `Chronote/Services/CloudKitSyncMonitor.swift:307–312`
- **详情**: Track 2/3 指出 1.5s 定时器，Verify-2 NEW 发现还有一个 2.0s `verifySync` 定时器有相同的假乐观状态问题，修只修一个不完整。
- **来源**: Verify-2 NEW P2

### P2-7 `CoreDataImportService.init` 默认用新实例而非 `.shared`
- **位置**: `Chronote/Services/CoreDataImportService.swift`
- **详情**: 默认 `aiService = OpenAIService(apiKey: "")` 实例化新对象而非 `OpenAIService.shared`，导致 session 配置不共享，连接池分散。
- **来源**: Verify-2 NEW P2

### P2-8 `DataMigrationService` 迁移后不回填 wordCount
- **位置**: `Chronote/Services/DataMigrationService.swift`
- **详情**: v2 JSON → CoreData 迁移后未调用 `recomputeWordCount()`，迁移条目 wordCount = 0，影响统计准确性（WritingHeatmap / 字数统计）。
- **来源**: Verify-2 NEW P3（升级，影响面较广）

### P2-9 `WordCountBackfillService` 在 remote change 无防抖触发
- **位置**: `Chronote/ChronoteApp.swift`（remote-change observer）
- **详情**: CloudKit 批量导入触发多个 `NSPersistentStoreRemoteChange` 通知，每次都起 `Task.detached { await WordCountBackfillService.backfillIfNeeded() }`，无 in-flight guard，多个 backfill 并行抢 store lock。
- **来源**: Verify-3 NEW

### P2-10 Embeddings 错误处理缺 `!res.headersSent` 检查
- **位置**: `server/index.js:262`（embeddings catch）vs `:224`（chat catch）
- **详情**: chat 路径在发送错误前检查 `!res.headersSent`，embeddings 路径直接写 `res.status().json()`，若 headers 已发出会抛 `Cannot set headers after they are sent`。
- **行动**: 对齐 chat 路径的 `if (!res.headersSent)` 模式。
- **来源**: Track 8 P2 → Verify-8 CONFIRM

### P2-11 `ecosystem.config.js` 无日志轮转，无 Node 版本约束
- **位置**: `ecosystem.config.js`
- **详情**: 无 `log_date_format`/`log_type: 'json'` + logrotate 配置，日志无限增长；无 `node_version`/`engines` 约束，版本漂移静默。
- **行动**: 配置 PM2 logrotate module；在 `package.json` 添加 `engines.node`。
- **来源**: Track 8 P1 → Verify-8 CONFIRM

### P2-12 `DiaryExportService` 写入 temp 目录无存储空间警告
- **位置**: `Chronote/Services/DiaryExportService.swift:81`
- **详情**: 导出文件写 `temporaryDirectory`，iOS 低存储时系统可能在用户分享前清理文件；写失败时错误不区分类型，UI 一律提示"检查存储空间"。
- **来源**: Track 5 P1 + Verify-5 NEW P1

### P2-13 `DatabaseRecoveryService.restoreFromBackup` 只恢复主 sqlite，不恢复 wal/shm
- **位置**: `Chronote/Services/DatabaseRecoveryService.swift:150–157`
- **详情**: 备份时 copy 了三件套（main + wal + shm），恢复时只 copy main sqlite，导致恢复后 WAL 不一致。
- **来源**: Verify-5 NEW P2

### P2-14 服务器日志暴露 OpenAI 密钥前 7 字符
- **位置**: `server/index.js:40`
- **详情**: `log.info({ maskedKey: \`${OPENAI_API_KEY.substring(0, 7)}…\` }, 'Loaded OPENAI_API_KEY')` 在日志中暴露 key 前缀，对于已知前缀模式的密钥（如 `sk-proj-`）泄漏了类型信息，无识别价值却有泄漏风险。
- **行动**: 改为只 log key 长度或固定 `[REDACTED]`。
- **来源**: Verify-1 NEW P2

### P2-15 `.gitignore` 未覆盖 `.claude/settings.local.json`
- **位置**: `.gitignore`
- **详情**: CLAUDE.md 注明 `settings.local.json` 不应 check in，但 `.gitignore` 实际未包含此规则，下次修改后可能意外提交个人权限配置（含 allowlist 路径）。
- **行动**: 在 `.gitignore` 添加 `.claude/settings.local.json`。
- **来源**: Verify-9 NEW

### P2-16 混合语言 frankenstrings（CloudKitSyncMonitor.errorMessage）
- **位置**: `Chronote/Services/CloudKitSyncMonitor.swift`（`errorMessage` 属性）
- **详情**: 英文固定前缀 + `error.localizedDescription`（系统本地化，中文环境返中文）拼接，产生"Network Error: 网络连接已断开"式混合语言字符串，UX 割裂。
- **来源**: Verify-4 NEW P2

---

## P3 — 低优先级 / 技术债

### P3-1 `ContextPromptGenerator` 使用不稳定的 `String.hashValue`
- **位置**: `Chronote/Services/ContextPromptGenerator.swift`
- **详情**: `abs(theme.hashValue) % templates.count` — Swift 5.7+ 哈希随机化，同字符串跨进程 hashValue 不同，每次启动可能选不同模板。功能上无害（随机选模板），但语义是"按主题稳定映射"时会令人迷惑。
- **来源**: Track 7 P2 → Verify-7 CONFIRM（PARTIAL，影响轻微）

### P3-2 `ChronoteUITests` 仅为 Xcode 模板残留
- **位置**: `ChronoteUITests/ScreenshotTests.swift`；`ChronoteUITestsLaunchTests.swift`（Verify-7 NEW 发现第二个文件）
- **详情**: 两个 UI 测试文件均为 Xcode 模板 `testExample` + `testLaunchPerformance`，零业务覆盖。
- **来源**: Track 7 P2 → Verify-7 CONFIRM + NEW

### P3-3 `ChronoteTests` 零 Service 层覆盖
- **位置**: `ChronoteTests/ChronoteTests.swift`（919 行，15 个 test struct）
- **详情**: 全部为纯函数（InsightsEngine 聚合、PromptSuggestion、主题清洗）测试，无 DiaryImportService / CoreDataImportService / AudioRecorder / CloudKitSyncMonitor / DatabaseRecoveryService 覆盖。
- **来源**: Track 7 P2 → Verify-7 CONFIRM

### P3-4 `AudioRecorder.handleMeter(_:)` @objc selector 为 dead code
- **位置**: `Chronote/Services/AudioRecorder.swift:239`
- **详情**: `@objc func handleMeter(_ timer: Timer)` — Timer 已改为闭包注册，selector 零调用点，混淆代码意图。
- **来源**: Track 7 P1 → Verify-7 CONFIRM

### P3-5 `AppleSpeechRecognizer` 不必要的二次权限查询
- **位置**: `Chronote/Services/AppleSpeechRecognizer.swift`
- **详情**: `requestAuthorization` 忽略回调中的 auth status 结果，立即再调 `SFSpeechRecognizer.authorizationStatus()` 二次查询，逻辑冗余。
- **来源**: Track 7 P3 → Verify-7 CONFIRM

### P3-6 大文件维护性问题
- **位置**: `HomeView.swift` (2117 行)，`OpenAIService.swift` (1501 行)，`DiaryEntry+Extensions.swift` (758 行)，`SettingsView.swift` (915 行)，`DiaryDetailView.swift` (979 行)，`AskPastView.swift` (619 行)
- **详情**: SwiftLint file_length / type_body_length 警告；`OpenAIService.firstValidScore` 是静态方法，可提取到纯函数命名空间。
- **来源**: Track 7 P2 → Verify-7 CONFIRM

### P3-7 `isICloudAvailable()` / `checkiCloudContainerAccess()` 写测试文件到 iCloud 容器
- **位置**: `Chronote/Model/PersistenceController.swift`；`Chronote/Services/SyncDiagnosticService.swift`
- **详情**: 两处都向 iCloud ubiquity container 写临时文件来探测可达性，产生无意义 iCloud 同步流量，`PersistenceController.swift:319–322` 注释本身说"不要用 ubiquity"——前后矛盾。
- **来源**: Track 2 P2 + Verify-2 NEW

### P3-8 服务器 `SIGHUP` 未处理
- **位置**: `server/index.js:317–326`
- **详情**: 处理了 SIGTERM + SIGINT，但 SIGHUP（nginx reload / terminal hangup）未 handle，PM2 某些模式下以 SIGHUP 发出重载信号。
- **来源**: Verify-8 NEW

### P3-9 服务器 chat 端点转发未过滤的 `req.body` 字段
- **位置**: `server/index.js:179–191`
- **详情**: `data: req.body` 将整个客户端 body（含 `n`、`tools`、`max_tokens` 等）透传 OpenAI，compromised secret 可指定 `n=10` 放大成本或附加 tools 做不预期的调用。
- **来源**: Verify-8 NEW P3

---

## 已确认无问题项（可从 TODO 移除）

| 项目 | 结论 |
|------|------|
| `sslTolerantSession` SSL 安全性 | ✅ 安全 — 无 URLSessionDelegate，无证书跳过，仅超时配置 |
| `AppleSpeechRecognizer` safeResume 二次进入 | ✅ once-guard 正确防止重复 resume |
| `DiaryExportView` force_unwrap | ✅ SwiftLint 警告存在但为 optional-chaining 场景，非崩溃路径 |
| `DatabaseRecoveryService` showRecoveryAlert nil 时 complete(true) | ✅ 已修为 complete(false)，代码注释明确 |

---

## 报告文件索引

| 文件 | 内容 |
|------|------|
| `CodeReview/baseline-build-warnings.txt` | SwiftLint 基线警告（约 150 条） |
| `CodeReview/CodeDefense.md` | 给 reviewer 看的精简版，含 v2 reviewer 修订 |
| `CodeReview/SECRET_ROTATION.md` | `appSharedSecret` 轮换手册 + 今次已执行步骤 |

**历史审查脚手架**（preliminary.md + 9 × track-*.md + 9 × verify-*.md，共 19 个文件、~5800 行）已于 2026-04-24 删除。
18 个 Opus agent 的原始报告已合并到本 SUMMARY；如需回溯，在 git 里查 commit `e9e7a19` 之后的历史。
