# Lumory Code Defense — 代码审查发现
**项目**: Lumory iOS 日记 App + Node.js 后端代理  
**基线提交**: `e9e7a19`  
**审查日期**: 2026-04-24  
**审查方法**: 18 个独立 Claude Opus 4.6 agent（9 个专项审查 × 9 个交叉验证），双盲两轮；经人工 reviewer 抽检修订（v2）

---

## ⚡ 修复状态（2026-04-24 截止）

**已完成**: P0 两项（密钥撤销 + 共享密钥轮换上线）+ P1 全部 16 项 + P2 全部 15 项 + P3 四项（#34 #35 #37 #38 #40）。  
**未动**: P3 的 #36（Service 层测试覆盖）和 #39（大文件拆分） —— 均为大重构，延后。  
**构建**: ✅ 最终 build 通过，服务器侧新密钥验证 401/401/400/200 全通过。

下方条目保留作 audit trail，描述的是**原始问题**，不代表当前状态。

---

## ⚠️ P0 — 需立即处理

### 1. OpenRouter API 密钥曾泄漏至公开 GitHub 仓库（✅ **已撤销**）
- **状态**: 用户确认已在 OpenRouter Dashboard 撤销；保留为 audit trail
- **位置**: commit `5424111` 的 `AppSecrets.swift`；**另**，后续多个历史提交的 `server/.env` 也含 `sk-or-v1-*`（reviewer 补充）
- **仓库**: `github.com/limingyi1225/Lumory.git`（公开）
- **教训**: 删除 git 历史 ≠ 撤销 key，必须在 provider 端撤销才有效（已完成）

### 2. 后端共享密钥（appSharedSecret）当前仍硬编码，且与历史哈希一致（**从未轮换**）
- **文件**: `Chronote/Services/AppSecrets.swift:13`
- **历史可见**: `refs/pull/1/head`；reviewer 确认 **PR1 中的哈希值与当前值完全一致** — 即从项目公开至今从未更换
- **影响**: 任何人可从公开 PR 历史读取 `X-App-Secret`，绕过 per-install 速率限制直接调用后端 OpenAI 代理
- **修复**: 轮换 `APP_SHARED_SECRET`（服务器 `.env` + 客户端 `AppSecrets.swift` 必须同时改，否则客户端 fail-closed）；后续迁移到 xcconfig / CI secret injection

---

## 🔴 P1 — 高优先级（下次发布前修复）

### 3. CloudKitSyncMonitor block observer 永久泄漏
- **文件**: `Chronote/Services/CloudKitSyncMonitor.swift:52`（reviewer 精确定位）
- **问题**: `setupNotifications` 用 block-form `NotificationCenter.addObserver` 注册 **3 个** block observer（原报告误写 4 个），返回的 `NSObjectProtocol` token 全部丢弃。`deinit` 的 `removeObserver(self)` 只能清除 target-selector 形式的注册，block-form 的永远不会被移除。
- **修复**: `var observers: [NSObjectProtocol] = []` 存储 tokens，`deinit` 逐个 `removeObserver`

### 4. SyncDiagnosticService 在非主线程访问 viewContext
- **文件**: `Chronote/Services/SyncDiagnosticService.swift`
- **问题**: `checkCoreDataStoreStatus()` 是 struct 静态函数，无 `@MainActor` 约束，直接调用 `container.viewContext.fetch`。CoreData `viewContext` 必须在主线程访问，在任意线程调用此函数会触发线程违规，轻则数据错误，重则 SIGTRAP 崩溃。
- **修复**: 标注 `@MainActor` 或改用 `performBackgroundTask` + 私有 context

### 5. 后端 sanitizeUpstreamError 在非生产环境泄漏上游原始错误
- **文件**: `server/index.js:290–292`
- **问题**: `NODE_ENV !== 'production'` 时，函数返回完整 `err.response?.data`（OpenAI API 原始错误，含 error.type / error.param / 模型内部标识），直接 JSON 序列化发回客户端。pino 的 redact 只过滤日志，不过滤 HTTP 响应体。
- **影响**: staging / dev 环境客户端可读取 OpenAI 内部错误信息
- **修复**: staging/dev 同样按 HTTP status 分类返回错误码，不转发上游原始 body

### 6. PersistenceController 含危险 dead code（从未被调用）
- **文件**: `Chronote/Model/PersistenceController.swift:192–248`
- **问题**: `handlePreLoadCorruption` / `performEmergencyRecovery` / `reloadAfterRecovery` 三个方法全仓 grep 零调用点（Track 2 + Track 7 + Track 9 三路独立确认），但包含无 user consent 的静默删除 sqlite 四件套逻辑——与同文件注释"永远不要在未经用户同意时删本地数据"直接冲突。
- **风险**: 若将来被意外调用，用户数据将在无任何确认弹窗的情况下被删除
- **修复**: 直接删除这 62 行；正式恢复路径已由 `DatabaseRecoveryService.performRecovery`（有用户弹窗确认）承担

### 7. DiaryImportService 绕过依赖注入，手写 HTTP
- **文件**: `Chronote/Services/DiaryImportService.swift:77–134`
- **问题**: `CoreDataImportService` 通过 `aiService: AIServiceProtocol` 支持 Mock 注入，但 `DiaryImportService.parse` 直接用 `URLSession` 打后端，完全绕过 DI。测试时注入 MockAIService 对解析路径无效——单测无法覆盖此路径。另，session 命名 `sslTolerantSession` 具有误导性（实际无 SSL 绕过，仅为超时配置）。
- **修复**: 让 `DiaryImportService` 通过 `AIServiceProtocol` 注入；重命名 session

### 8. DiaryImportService prompt injection 防护薄弱
- **文件**: `Chronote/Services/DiaryImportService.swift`
- **问题**: AI 解析使用 `<<<\(rawText)>>>` 作为 prompt 边界标记。用户日记正文若包含 `>>>` 字符，可截断 prompt 边界，使 AI 执行日记内容中的任意指令（prompt injection）。
- **修复**: 对 `rawText` 中的 `>>>` 进行转义或替换；或改用 JSON 结构化传输

### 9. 全部 CloudKit 同步 UI 文字英文，零本地化
- **文件**: `CloudKitSyncMonitor.swift`（17 处）、`SyncDiagnosticService.swift`（`generateDiagnosticReport`、`SyncIssue.description` 等）
- **问题**: 全仓 grep 确认两文件零 `NSLocalizedString` 调用。中文语言环境用户在同步出错时看到全英文错误信息。`errorMessage` 还拼接 `error.localizedDescription`（系统中文）产生混合语言字符串，如"Network Error: 网络连接已断开"。
- **修复**: 将展示用字符串迁移至 `Localizable.strings`

### 10. ImageViewerView 无障碍支持缺失 + 内存问题
- **文件**: `Chronote/Views/ImageViewerView.swift`
- **问题 A**: 图片和关闭按钮均无 `accessibilityLabel`；关闭按钮约 28pt，低于 HIG 44pt 要求；nil 图片（加载失败）显示空白无 fallback
- **问题 B**: `TabView` + `ForEach` 直接迭代 `[Data]` 同步解码所有图片，6 张原图展开后可达 200+ MB，大相册场景易触发 jetsam 被系统强杀
- **修复 A**: 补 `accessibilityLabel`；关闭按钮用 `.frame(minWidth: 44, minHeight: 44)` + `.contentShape`；nil 图片显示占位符
- **修复 B**: 改为懒加载，仅解码当前页 ±1 页

### 11. AudioRecorder 错误路径状态机损坏
- **文件**: `Chronote/Services/AudioRecorder.swift`
- **问题 A**: `startRecording()` 在 `AVAudioRecorder` 初始化失败时未重置 `isRecording`，UI 持续显示录音中
- **问题 B**: 无 `guard !isRecording` 保护，双次调用创建两个 `meterTimer`，前一个未被 invalidate
- **修复**: 所有错误出口重置状态；添加 `guard !isRecording else { return }` 保护

### 12. PersistenceController.save() 静默吞错
- **文件**: `Chronote/Model/PersistenceController.swift`
- **问题**: `viewContext.save()` 失败时只 log，不向调用方抛出错误。日记写入失败对用户完全不可见。
- **修复**: 改为 `throws`，或至少向 UI 发出可观察的错误状态

### 13. DiaryImportService 失败静默返回空结果
- **文件**: `Chronote/Services/DiaryImportService.swift`
- **问题**: 导入失败时返回空数组，UI 将其当作"成功导入 0 条"，用户不知道发生了错误
- **修复**: 区分"成功 0 条"和"失败"，失败时抛出错误并在 UI 展示

### 14. SearchView 全文查询无索引，全表扫描
- **文件**: `Chronote/Views/Search/SearchView.swift:101–119`
- **问题**: `text CONTAINS[cd] %@ OR summary CONTAINS[cd] %@ OR themes CONTAINS[cd] %@` 三字段 OR + case/diacritic insensitive，CoreData 无法走索引，1000 条日记全表扫描。`propertiesToFetch` 在默认 `.managedObjectResultType` 下是 prefetch 提示而非 projection，仍 fault-in 完整对象（含 text/embedding/imagesData）。
- **修复**: 改 `resultType = .managedObjectIDResultType`；或为搜索字段建全文索引

### 15. 后端缺 Retry-After header
- **文件**: `server/index.js:113, 122, 135`
- **问题**: 限速响应仅返回 `{ error: 'rate_limited' }`，客户端 `NetworkRetryHelper` 无等待依据，只能盲目指数退避；upstream OpenAI 429 的 `retry-after` 也不转发
- **修复**: rate limiter 改 `standardHeaders: 'draft-7'`（自动加 `RateLimit-Reset`）；catch 块转发 upstream `retry-after`

### 16. 后端无 Correlation ID
- **文件**: `server/index.js:73`
- **问题**: 每个请求无唯一 ID，客户端日志和服务器日志无法关联，线上问题排查依赖时间戳碰运气
- **修复**: `pinoHttp({ logger: log, genReqId: () => crypto.randomUUID() })`，响应头 `X-Request-Id` 回传客户端

### 17. 后端优雅关闭不等待 in-flight SSE 流
- **文件**: `server/index.js:301–315`
- **问题**: `server.close()` 仅停止接受新连接，不追踪活跃 SSE stream；SIGTERM 时正在回答的流式请求被硬切，客户端重试重复消耗 token
- **修复**: 维护活跃 stream Set，shutdown 时逐个 destroy + 等待 server.close()

### 18. CloudKitSyncMonitor 每次 app active 无防抖打 CloudKit
- **文件**: `CloudKitSyncMonitor.swift:160–195`，调用点 `ChronoteApp.swift:265–267`
- **问题**: `.active` 场景每次前台都触发 `accountStatus + CKQuery`，用户频繁 app switch 下每次约 300–500ms 网络延迟 + CloudKit 配额消耗
- **修复**: 添加 30s 冷却，或改为 `NSPersistentCloudKitContainer` event notification 驱动

---

## 🟡 P2 — 中优先级

| # | 问题 | 文件 |
|---|------|------|
| 19 | 启动路径 `storeURL()` force unwrap `.first!`，沙盒受损时 crash | `PersistenceController.swift:327,362` |
| 20 | `InsightsEngine.retrieve()` 全量 fetch embedding 内存排序（1000 条 ≈ 15–30 MB transient） | `InsightsEngine.swift:411–490` |
| 21 | `WritingHeatmap`/`CalendarMonthModule` hash 只取首末 cell，中间日期变化不触发重建（**正确性 bug**，热图显示陈旧数据） | `WritingHeatmap.swift`、`CalendarMonthModule.swift` |
| 22 | `CalendarMonthModule.fetchDailyCells` 硬编 140 天不随 range 自适应；`propertiesToFetch` 在错误 resultType 下不做 projection | `CalendarMonthModule.swift` |
| 23 | InsightsView range 快速切换堆叠并发 fetch，多个 `performBackgroundTask` 抢 store lock | `InsightsView.swift:199–230` |
| 24 | 第二个 `asyncAfter(2.0s)` verifySync 定时器与 1.5s 定时器有相同假乐观状态 bug | `CloudKitSyncMonitor.swift:307–312` |
| 25 | `CoreDataImportService.init` 默认 `OpenAIService(apiKey:"")` 新建实例而非 `.shared` | `CoreDataImportService.swift` |
| 26 | `DataMigrationService` v2→CoreData 迁移后未调 `recomputeWordCount()`，迁移条目 wordCount 全零 | `DataMigrationService.swift` |
| 27 | `WordCountBackfill` 在 remote-change 无防抖，CloudKit 批量导入触发多个并行 backfill | `ChronoteApp.swift` |
| 28 | Embeddings catch 缺 `!res.headersSent` 检查（chat 路径有，embeddings 路径没有，headers 已发出时会抛异常） | `server/index.js:262` |
| 29 | `ecosystem.config.js` 无日志轮转配置，无 Node 版本约束 | `ecosystem.config.js` |
| 30 | `DiaryExportService` 写入 temp 目录，iOS 低存储时可能在用户分享前被清理，无警告 | `DiaryExportService.swift:81` |
| 31 | `DatabaseRecoveryService.restoreFromBackup` 只恢复主 sqlite，不恢复 wal/shm（备份三件套，恢复一件） | `DatabaseRecoveryService.swift:150–157` |
| 32 | 服务器日志打印 OpenAI key 前 7 字符，无识别价值却泄露 key 类型信息 | `server/index.js:40` |
| 33 | `.gitignore` 未覆盖 `.claude/settings.local.json` | `.gitignore` |

---

## ⚪ P3 — 低优先级 / 技术债

| # | 问题 |
|---|------|
| 34 | `ContextPromptGenerator` 用 `String.hashValue`（Swift 5.7+ 跨进程不稳定）做模板选择 |
| 35 | `ChronoteUITests` 两个文件均为 Xcode 模板残留，零业务覆盖 |
| 36 | 测试零 Service 层覆盖（DiaryImportService / AudioRecorder / CloudKitSyncMonitor 等） |
| 37 | `AudioRecorder.handleMeter(_:)` @objc selector dead code（Timer 已改闭包注册，selector 从未被调用） |
| 38 | `isICloudAvailable()` / `checkiCloudContainerAccess()` 写测试文件到 iCloud ubiquity container，与"不用 ubiquity"原则矛盾 |
| 39 | 6 个超大文件（HomeView 2117 行、OpenAIService 1501 行、SettingsView 915 行等）维护困难 |
| 40 | 服务器 `SIGHUP` 未处理；chat 端点透传未过滤的 `req.body` 字段（n / tools / max_tokens 等） |

---

## ✅ 已确认无问题（可从 concern 列表移除）

| 项目 | 结论 |
|------|------|
| `sslTolerantSession` SSL 安全性 | **安全**：全仓 grep 零 URLSessionDelegate，无证书跳过，仅为超时配置，可放心重命名 |
| `AppleSpeechRecognizer` safeResume | **正确**：once-guard 防止 continuation 重复 resume |
| `DatabaseRecoveryService` showRecoveryAlert nil 路径 | **已修**：nil window 时 `completion(false)`，不再静默删数据 |
| `PersistenceController.batchDelete` async merge | **已知**：async dispatch 语义明确，设计意图清晰 |

---

## 附：关键修复顺序建议

```
立即（今天）:  P0-1 轮换 OpenRouter 密钥 → P0-2 轮换 appSharedSecret
本周:          P1-3 observer leak → P1-4 SyncDiagnosticService 线程 → P1-11 save() 吞错 → P1-12 AudioRecorder 状态机
下个版本前:    P1-6 SearchView 索引 → P1-7 ImageViewerView 内存/a11y → P1-9 CloudKit 防抖 → P1-5 i18n
后续迭代:      P2 系列（性能 / 正确性 bug 优先：#21 hash bug → #20 embedding 全量 fetch）
```
