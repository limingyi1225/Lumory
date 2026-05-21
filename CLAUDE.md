# Lumory

iOS 日记 App。产品名 **Lumory**,Xcode 项目 `Lumory.xcodeproj`,主 target/scheme/productName 都是 **`Lumory`**(`project.pbxproj:171`),**源码目录仍是 `Chronote/`**(历史遗留,rename 成本大故不动),bundle id `Mingyi.Lumory`。**Widget extension 单列 target `LumoryWidgets`**(.appex,bundle id `Mingyi.Lumory.Widgets`,源码 `LumoryWidgets/` + 双 target 共享 `LumoryWidgetShared/`)。tests target 仍叫 `ChronoteTests` / `ChronoteUITests`。仓库里同时包含一个 Node.js OpenAI 代理后端(`server/`)。

## 路径范围 rule files(详细规则按需自动加载)

仓库太大,把"`>200 行 always-loaded` 一坨"的 CLAUDE.md 拆成 path-scoped 规则,Claude Code 工作在对应路径才加载:

- [`.claude/rules/ios-codebase.md`](.claude/rules/ios-codebase.md) — 改 `Chronote/**` / `LumoryWidgets/**` / `LumoryWidgetShared/**` 时加载。包含**iOS 启动序列、Service catalog、Model 字段、Views 树、Swift/SwiftUI/CoreData/Concurrency 踩坑、通知/转写/SSE 客户端约定**。
- [`.claude/rules/views-design-tokens.md`](.claude/rules/views-design-tokens.md) — 改 `Chronote/Views/**` 时加载。包含**字号 / 圆角 / 动画 / Haptic / PressableScaleButtonStyle / Sheet 文案 / DateFormatter / 删除 toast / Toast 入口 / Form-insetGrouped-liquidGlassCard / Sheet Color / NavigationStack gradient**。
- [`.claude/rules/backend-server.md`](.claude/rules/backend-server.md) — 改 `server/**` / `ecosystem.config.js` 时加载。包含**鉴权 / 速率限制 / 请求体限制 / 转写 model hardcode / SSE 错误处理 / 部署流程**。
- [`.claude/rules/testing.md`](.claude/rules/testing.md) — 改 `ChronoteTests/**` / `ChronoteUITests/**` / `Scripts/**` 时加载。包含**xcodebuild 串行 flag / SIGABRT 诊断 / xcresulttool 提取 / Screenshot 模式 early-return / bash PIPESTATUS**。

新加规则放对应 rule 文件,不要塞回主 CLAUDE.md。本文件只放**所有任务都需要的 cross-cutting 信息**。

## 技术栈

- **iOS 客户端**:SwiftUI + CoreData + `NSPersistentCloudKitContainer`(CloudKit 同步)。App 入口 [Chronote/ChronoteApp.swift:265](Chronote/ChronoteApp.swift:265) `var body: some Scene`,启动先走 `SplashView`(约 1s)再淡出到 `HomeView`(`SplashView()` 在 [:275](Chronote/ChronoteApp.swift:275))。iOS 部署目标 26.0。
- **后端**:Node.js + Express 5,部署在 `https://lumory.isaabby.com`(Cloudflare → nginx:443 → node:3000),PM2 进程管理。
- **AI**:走自建后端代理 OpenAI(`/api/openai/chat/completions` / `/api/openai/embeddings` / `/api/openai/audio/transcriptions`)。Chat 走 SSE 流,模型 `gpt-5.5` / `gpt-5.4-mini`(reasoning effort 分档);转写 `gpt-4o-mini-transcribe`。
- **本地化**:中(`zh-Hans.lproj`)/ 英(`en.lproj`),由 `@AppStorage("appLanguage", store: AppGroup.userDefaults)` 切换 —— 主 App + widget extension 共用 App Group `group.Mingyi.Lumory` 这个 UserDefaults suite。

## 目录(顶级)

- `Chronote/` — iOS 主 App 源码(`ChronoteApp.swift` / `Model/` / `Services/` / `Views/` / `Extensions/` / `Utils/`)。详细 catalog 见 [`ios-codebase.md`](.claude/rules/ios-codebase.md)。
- `ChronoteTests/` · `ChronoteUITests/` — 单测 / UI 测试。详见 [`testing.md`](.claude/rules/testing.md)。
- `LumoryWidgetShared/` — **双 target 共享 sources**(主 App + LumoryWidgets extension 同时编),**只 import Foundation**。
- `LumoryWidgets/` — Widget extension target(QuickWriteWidget + LockStreakWidget)。
- `server/` — Node 后端,代码主体集中在 [server/index.js](server/index.js)(约 840 行,2026-05-17 verified)。详见 [`backend-server.md`](.claude/rules/backend-server.md)。
- `Lumory.xcodeproj` · `Lumory-Info.plist` · `Lumory.entitlements` · `Lumory.icon` · `LumoryWidgets-Info.plist` · `LumoryWidgets.entitlements`(widget plist / entitlement **放项目根目录**,不放 `LumoryWidgets/` —— 那是 PBXFileSystemSynchronizedRootGroup,扔进去会被自动塞进 Resources copy phase)。
- `ecosystem.config.js` — PM2 配置(`lumory-server`,fork 模式,`max_memory_restart: 512M`)。
- `Scripts/` — `generate-screenshots.sh`、`reset-database.sh`;根目录 `clean-build.sh` / `deep-clean.sh` / `clean-corrupted-db.sh` 维护脚本。
- `.claude/` — Claude Code 本地自动化(`rules/` / `skills/` / `agents/` / `hooks/` / `settings.json`)。
- `CHANGELOG.md` — **内容不可信,不要据此推断版本/日期/功能状态**。实际状态以代码和 git 为准。

## 常用命令

iOS:
- 构建 Debug:`xcodebuild -project Lumory.xcodeproj -scheme Lumory -configuration Debug build`
- 跑测试(必带串行 flag,见 `testing.md`):`xcodebuild test -project Lumory.xcodeproj -scheme Lumory -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -disable-concurrent-destination-testing`
- 清理:`./clean-build.sh`;彻底清(含 DerivedData / ModuleCache / .swiftpm):`./deep-clean.sh`
- 本地 DB 损坏恢复:`./clean-corrupted-db.sh` 或 `Scripts/reset-database.sh`
- 生成 App Store 截图:`./Scripts/generate-screenshots.sh`(iPhone 1320×2868)/ `./Scripts/generate-screenshots.sh ipad`(2064×2752)

后端(`server/`):见 [`backend-server.md`](.claude/rules/backend-server.md) 完整列表。常用:`npm start` / `npm run dev` / `npm run lint` / `pm2 restart lumory-server` / `curl https://lumory.isaabby.com/health`。

## ⚠️ Secrets

`appSharedSecret` 走 xcconfig 注入链:`Lumory.local.xcconfig`(gitignored 真实值)→ `#include?` 到 `Lumory.xcconfig`(committed)→ pbxproj base config → `Lumory-Info.plist` 里 `$(APP_SHARED_SECRET)` 替换 → `AppSecrets` 运行时 `Bundle.main.infoDictionary` 读。fallback 是空字符串(读不到 → 401),**不**硬编码。新 clone 后 setup:`cp Lumory.local.xcconfig.sample Lumory.local.xcconfig` + 填值 + Cmd+B。

轮换流程:本机改 `Lumory.local.xcconfig` + SSH 改 server `/root/server/.env` + `pm2 restart lumory-server` + 出新 build。

后端 `OPENAI_API_KEY` 和 `APP_SHARED_SECRET` 都必须来自 `server/.env`,缺任一立刻 `process.exit(1)`。

## 提交信息

沿用仓库既有中英混合风格,参考 `git log`(典型:`refactor(wave12): HomeView 1980→1260 抽 4 子 view + EntryCreationService`)。

## Follow-up backlog(留给本人 / 后人的待办)

历次 superreview / megareview 抓出的、**有意识跳过**的活儿。代码本身没坏,但测试覆盖 / 抽象基建 / 隐私 hardening 欠了一笔。下次有空再补,不补也能 ship。

### 测试覆盖缺口

- **`StreamEvent.truncated` view-side 端到端测试** — Service-side(`NarrativePrecomputeService` 消费 .truncated 写 `payload.isIncomplete=true / truncatedReason`)已补完单测(2026-05-13 superreview round 1);view-side(`NarrativeSummaryCard` / `AskPastView` 消费侧让 isIncomplete flag 翻 true + 渲染 incompleteFooter)仍需 ViewInspector 或自写 binding-tap helper 才能断言。`parseImportedDiaries` 错误路径已在 2026-05-16 通过 MockURLProtocol 基建 + `OpenAIServiceImportTests` 补完。
- **`ReminderService.currentRescheduleGen` race stale 场景测试** — `ThemeAliasJudgeService.scanGen` 已覆盖(`scanGen_staleCompletionDoesNotClearNewerTaskHandle`,通过 `simulateConcurrentScanStartForTesting` 注入),但 `ReminderService` 没装 race test seam(强耦 UN center,要 mock UN 才能干净测)。下次拆 ReminderService 时一并解决。

### 隐私 hardening

- **不要单独把 ThemeAliasResolver 主题名搬 Keychain**(2026-04-29 评估):**不治本**。日记原文存 SQLite `NSFileProtectionCompleteUntilFirstUserAuthentication`(首次解锁后明文)跟 UserDefaults plist 一档,日记里反复出现的主题词单独搬 Keychain 不增加真实威胁面。真隐私 hardening 是升级 SQLite 文件保护级别(`NSFileProtectionComplete` 锁屏即不可读,会让后台同步/通知失效)或端到端 passphrase 加密(Signal 量级大工程)— 都是产品决策,在那之前 Keychain 迁移 ROI 倒挂,**不做**。

### 重构 / 待续

- **超长文件**(SwiftLint 阈值 600 行,2026-05-17 重测):ThemeAliasResolver 805(已拆 Store + 加 round 1-3 注释)/ AskPastView 783 / ReminderService 767 / ThemeAliasManagementView 709 / InsightsView 640。near-threshold(已挨阈值,留意但不算超长):SettingsView 590。重构机会但都不算 bug。**已拆完的**:OpenAIService 在 wave11 拆 7 文件;HomeView 在 wave12 抽 4 个 SwiftUI 子 view + EntryCreationService;2026-05-16 把 method logic 按功能区拆 6 个 HomeView+*.swift extension 文件(Search / Recording / Audio / Send / Entry / Helpers),1433 → 519 行;2026-05-16 `ThemeAliasResolver` 拆 `ThemeAliasStore`(read+disk+pure reads+persistence)+ `ThemeAliasResolver`(facade ObservableObject + mutation + queue/throttle/cool-down timer),883 → 788 + 293(callsite 零改动,Resolver 后续因 mutation 业务逻辑沉淀又长回 ~805,真要再降需把 mutation 切 `+Confirm.swift` / `+Merge.swift` extension);2026-05-16 `DiaryDetailView` 拆 3 个 `+Display.swift` / `+Edit.swift` / `+Audio.swift` extension + 抽 `AsyncPhotoThumbnail` 独立 Component,861 → 229 行;**2026-05-16 round 3** `InsightsEngine` 拆 facade + `InsightsSearchEngine`(Search/RAG 子系统),771 → 470 + 368(2026-05-17 重测 508 + 387,业务自然增长),Phase 3.1 完成(Phase 3.2 aggregator 拆 + 嵌套类型抽顶层留 backlog,见 `.claude/rules/ios-codebase.md` `InsightsSearchEngine.swift` 行的注释)。**

## Claude Code 自动化(本地,非生产)

- **MCP servers**(`~/.claude.json` 本项目 scope):
  - `xcodebuildmcp` — 封装 `xcodebuild` / `simctl` / UI 自动化。**优先用它的工具**而不是 Bash 跑 `xcodebuild`。坑:(1) `build_run_sim({extraArgs: [...]})` 的 extraArgs 是**编译 flag**,不是 app 启动参数 —— 塞 `-LumoryUITestSampleData YES` 会被 xcodebuild 拒。要传 app 启动参数走三步:`build_sim` → `install_app_sim({appPath: ".../Debug-iphonesimulator/Lumory.app"})` → `launch_app_sim({args: ["-LumoryUITestSampleData", "YES"]})`。`session_set_defaults({bundleId: "Mingyi.Lumory"})` 一次,后续不用再传。(2) 默认配置不暴露 tap/gesture,`snapshot_ui` 只读但可用;真要驱动 UI 走 computer-use 或 ChronoteUITests。(3) Sim 窗口可能投到"External Display"虚拟屏,computer-use 看不到但 `xcodebuildmcp.snapshot_ui` 走 simctl 是 headless 的不受影响。
  - `context7`(插件)— 查 SwiftUI / CoreData / CloudKit / Express 5 等官方文档时用,避免训练截止日之后的 API 漂移。
- **Skills** 在 `.claude/skills/`(共 4 个):`screenshot`(截图流水线 + 坑,"截图/上架截图"自动触发)/ `megareview`(整库 bug+优化+功能机会审计;运行前先 `AskUserQuestion` 问两题〔关注点:全面 / 纯 UIUX / 不含 FEAT / 自定义;+ 要不要扫 dead code〕→ **一次性并行派发** Opus subagent + codex〔不再分波〕,各写文件只回摘要,subagent 可发 ESCALATION 让主 agent 动态追派)/ `superreview`(默认审 working tree;自然语言开关支持"未 push 到 main" → `origin/main..HEAD`、"vs main" → `main..HEAD`、"跳过 codex" 等;每次强制出 MD + 给非程序员看的 HTML 双报告到 `CodeReview/`)/ `sync-to-mac`(双 Mac 协作 git 同步,push/pull/ship)。
- **Subagents** 项目级定义在 `.claude/agents/`(`coredata-migration-reviewer.md` / `sse-pipeline-reviewer.md`)。**2026-05-17 verified**:harness **会**把这两个注册成有效 `subagent_type`(早期版本不会,本节历史曾写"不在池里" —— 已纠正)。
- **`Agent` 工具的 `subagent_type` 池随插件安装 / 升级状态变化**,每个会话起点的 system reminder 列的就是当前全集。spawn 前**先看那份列表**确认目标在池里;不在池里 hard error,无静默回退。
- **2026-05-17 实测在池里、对 Lumory review 工作有用的**:
  - 项目自定义:`coredata-migration-reviewer` / `sse-pipeline-reviewer`
  - Namespaced(命名带 "modernization" 但角度通用,可做安全 / 架构 / 测试缺口审计):`code-modernization:security-auditor` / `:architecture-critic` / `:test-engineer` / `:legacy-analyst` / `:business-rules-extractor`
  - 其他:`code-simplifier:code-simplifier`(代码简化)/ `plugin-dev:*`(改 `.claude/skills` / plugin 时用)/ `agent-sdk-dev:*`
  - 兜底通用:`general-purpose`(把 focus 写进 prompt)/ `Explore`(只读搜索)/ `Plan`(设计实现)/ `claude-code-guide` / `statusline-setup` / `claude`
- **历史上常被瞎猜、但今天 spawn 仍会 hard error 的**:裸名 `code-reviewer` / `debugger` / `security-auditor` / `architect-review` / `test-automator` / `performance-engineer` / `database-optimizer` / `api-design-principles` / `backend-security-coder`;前缀 `feature-dev:*` / `superpowers:*`。
- **codex 插件**(`codex@openai-codex` marketplace,2026-05-20 装上,user scope):提供 `/codex:review` `/codex:adversarial-review` `/codex:rescue` `/codex:status` `/codex:result` `/codex:cancel` 等 **slash command(skill)**,以及 `codex:codex-rescue` **subagent**(`/reload-plugins` + 新会话后才进 subagent_type 池)。**用法:codex 的 review/rescue 一律当 `/codex:*` slash command(Skill)调,不要当 `Agent` 的 subagent_type 直接派** —— slash command 内部会自己 spawn `codex:codex-rescue`,直接 Agent 派不符合插件设计。codex CLI 在 `/opt/homebrew/bin/codex`(ChatGPT 登录);skill 当前会话不可用(没 reload / scope 没启用)时,用 `codex exec`(audit 加 `--sandbox read-only`;diff review 用 `codex exec review`)兜底,都没有就跳过 codex 步并在报告注明。`megareview` / `superreview` 都靠它做跨模型终审。
- **怎么办**:不确定走 `general-purpose` + 把 focus 写进 prompt。`.claude/agents/*.md` 的内容也可以**抄进 prompt** 给 `general-purpose` 用,等同手贴 system prompt。读 / 搜代码走 `Explore`,设计 plan 走 `Plan`。
- **Hooks**:`.claude/hooks/server-lint.sh`(PostToolUse)— 编辑 `server/*.js` 后静默跑 `eslint --fix` + `prettier --write`,失败不阻塞对话。改 hook 脚本记得 `chmod +x`。
