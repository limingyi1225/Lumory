---
name: megareview
description: 不计成本对**整个 repo**(不是 uncommitted diff)做最严的 bug + 优化机会审计 —— 按目录 / 关注点切片并行召唤多个 Opus subagent + 跑 codex 仓库级 audit(走 codex:codex-rescue 的 read-only task,不是 /codex:review),最后主 agent 交叉核对量化事实并产出分级报告。用户说"megareview / 整库审查 / 全仓审计 / repo audit / 整个仓库找 bug 和优化点"时触发。
---

# Megareview - 不计成本的整仓审计

和 `/superreview` 同源,但 scope 不一样:
- **superreview**:审 uncommitted changes(working tree / branch diff),commit/push/上架前的关。
- **megareview**(本 skill):审**整个 repository 的现状** —— 找已经在 main 里、可能已经跑了几个月、但没人翻过的 bug + 高价值优化机会。不依赖 git diff。

## 核心理念

1. **整仓不能一锅端**:把 repo 按目录 + 关注点切成 N 个 slice,每个 subagent 只看一个 slice 一个角度。一锅 prompt "review 整仓"必然糊。
2. **多视角并行 + 跨模型**:Opus(找语义 / 项目约定 / 隐藏耦合) + Codex(找语法层 bug / 库行为 / 大范围 grep 模式)互补。
3. **Bug 与优化分两档**:这个 skill 不是只找 P0,**优化机会(性能 / 抽象 / 死代码 / 测试空白)是一等公民**。最终报告里要有"高 ROI 优化"区。
4. **主 agent 强制核对**:Opus 在量化精度上系统性偏弱(行号 / 计数 / "未被使用" / 库行为),所有 finding 主 agent **必须 grep + Read + context7 验证**才能进最终报告(见 user memory `feedback_review_quality.md`)。
5. **不计成本**:subagent `model: "opus"`,数量按仓库大小给到 8-15 个,Codex 也是 1-2 个 task 同时跑,**不为省 token 砍人头**。

## 何时触发

- 用户输入 `/megareview` 或说"megareview / 整库审查 / 全仓审计 / repo audit / 把整个仓库扒一遍找 bug / 整个项目找优化点"
- 大版本上线前 / 季度技术债盘点 / 接手老代码后想全面摸底
- superreview 已经跑过 diff,但用户怀疑老代码里也有问题

## 何时**不**该用

- 只关心最近这次改动 → 用 `/superreview`,megareview 太重
- 只想知道"这个文件有没有 bug" → 起一个 `code-reviewer` subagent 直接看
- 仓库刚 init,代码量 < 500 行 → 一个 reviewer 就够,megareview 是浪费
- 用户实际想的是"重构这块" → 那是 feature-dev / refactor 流程,不是 review

## 流程

### Step 1 — 摸底:仓库规模 + 切片策略

并行跑(主 agent 用 Bash):

```bash
# 总体规模
git ls-files | wc -l
git ls-files | xargs -I {} wc -l {} 2>/dev/null | tail -1
# 各顶层目录的文件数 + 行数(只看代码语言扩展)
git ls-files '*.swift' '*.js' '*.ts' '*.py' '*.go' '*.rb' '*.rs' '*.java' '*.kt' '*.m' '*.mm' \
  | awk -F'/' '{print $1}' | sort | uniq -c | sort -rn
# 最近 90 天热点文件(churn 高 = 风险高)
git log --since=90.days --name-only --pretty=format: | sort | uniq -c | sort -rn | head -30
# 看有没有 TODO/FIXME/HACK/XXX 集中区
git grep -nE 'TODO|FIXME|HACK|XXX|@deprecated' -- '*.swift' '*.js' '*.ts' | wc -l
# 大文件(>500 行通常是重构候选)
git ls-files | xargs wc -l 2>/dev/null | awk '$1>500 && $2!="total"' | sort -rn | head -20
```

按规模决定 subagent 数量:

| 仓库规模 | Opus subagents | Codex tasks |
|---|---|---|
| 小(< 5k LoC) | 6 | 1 |
| 中(5k-30k LoC) | 8-10 | 1-2 |
| 大(> 30k LoC) | 12-15+,按目录分片 | 2 |

### Step 2 — 切片(slice)+ 视角(angle)

**切片维度**(按目录):每个 slice 是一组语义相关的文件。Lumory 参考切法:
- **Models/Persistence**:`Chronote/Model/*` + `PersistenceController.swift` + `*BackfillService.swift`
- **AI/Network/SSE**:`OpenAIService.swift` + `AIService.swift` + `NetworkRetryHelper.swift` + `InsightsEngine.swift` + `ContextPromptGenerator.swift`
- **Audio/Speech**:`AppleSpeechRecognizer.swift` + `AudioRecorder.swift` + 相关 Views
- **Home VM stack**:`Chronote/Views/HomeView.swift` + `Chronote/Views/HomeView/`(三个 @Observable VM)
- **Insights/AskPast**:`Chronote/Views/Insights/*`
- **Search/Detail/Settings**:`SearchView.swift` + `DiaryDetailView.swift` + `SettingsView.swift` + `DiaryImportView.swift` + `DiaryExportView.swift`
- **Backend**:`server/*.js` + `ecosystem.config.js`
- **Tests**:`ChronoteTests/*` + `ChronoteUITests/*`
- **Scripts/Build**:`Scripts/*` + 根目录 `*.sh` + `Lumory.xcconfig` + `Lumory-Info.plist`
- **Cross-cutting**(给单独的 subagent):dead code / 未引用 symbol / 重复逻辑 / 命名不一致

**视角维度**(按关注点):

| 视角 | 推荐 subagent_type | 重点 |
|---|---|---|
| Bug — 正确性 | code-reviewer | 逻辑错 / off-by-one / 边界 / null / 异常吞掉 / 错误返回值 / 数据竞争 |
| Bug — 并发 | general-purpose(Lumory: Swift Concurrency 重点) | actor 隔离 / @MainActor 违反 / Sendable 漏标 / 取消语义 / `performAndWait` 内 main.sync 死锁 |
| Bug — 安全 | security-auditor / backend-security-coder | 注入 / 鉴权 / fail-open / 密钥泄漏 / SSE 错误处理 / OWASP |
| Bug — 数据 | **coredata-migration-reviewer**(项目 agent) | CoreData schema 不兼容 / CloudKit 限制 / backfill 幂等性 / DTO Sendable |
| Perf | performance-engineer / database-optimizer | 主线程 IO / N+1 fetch / 缓存缺失 / 内存泄漏 / O(n²) 在热路径 / 不必要的 reactive 重渲染 |
| 优化 — 抽象 | architect-review | 抽象泄漏 / 重复逻辑 / SRP 违反 / 应该提的 helper / 应该砍的中间层 |
| 优化 — 死代码 | code-reviewer / general-purpose | 未被任何 caller 引用的 func/class/file / 已废弃 flag / 注释掉的代码 / 未跑的测试 |
| 优化 — 测试 | test-automator | 关键路径无单测 / mock 错配 / 边界没覆盖 / UI 测试脆弱 |
| 优化 — DX/构建 | devops-troubleshooter / general-purpose | 构建脚本脆 / CI 缺失 / 工具链漂移 / 重复 lint 规则 |
| API contract | api-design-principles | 后端 vs 客户端协议匹配 / 错误码 / 版本化 / SSE 帧格式 |
| Style/约定 | code-reviewer | 项目既有约定(CLAUDE.md)/ 命名 / 文件组织 / 日志 API 用法 |

**切片 × 视角 = subagent**。一个 subagent 一组(slice, angle)。同一个 slice 可以被多个 angle 各看一次,同一个 angle 可以扫多个 slice(看哪种更贴这次审计目标)。

**Lumory 强制视角**(一定要召唤):
- `coredata-migration-reviewer` 看 Models/Persistence + 任何动 `DiaryEntry` schema 的服务
- backend-security 看 `server/*.js`(SSE 错误关闭 / rate-limit / X-App-Secret fail-closed / `res.destroy(error)` vs `data: [DONE]`)
- 死代码扫(整仓):上次 `e01fd29 refactor: drop dead code (28 iOS symbols + 1 backend devDep)` 砍掉 28 个,这是反复要扫的场景

### Step 3 — 并行召唤(单条消息内 N 个 Agent tool call + Codex)

每个 Opus subagent prompt **必须**包含:
- **本次审计目标**:"找仓库已存在的 bug 和高 ROI 优化点;这不是 diff review"
- **slice 文件清单**(具体路径,别让 agent 自己猜)
- **专项 angle**(只看这个角度,其他 angle 别人会看)
- **输出格式**:`[BUG-P0/P1/P2 | OPT-HIGH/MID/LOW] file:line — 一句话问题 — 一句话修复 — 一段证据(代码片段或调用链)`
- **量化要求**:所有"X 处"/"未被使用"/"N 次"陈述必须给 grep 结果或代码片段,主 agent 会逐条核对
- **范围克制**:不要建议大重构,只标"应该被处理的点"
- 显式 `subagent_type` + `model: "opus"`

#### Codex 任务(关键,和 Opus 同时发)

**不要**用 `/codex:review` 或 `/codex:adversarial-review` —— 它们只看 git state,在 megareview 场景里 diff 通常是空的,会被 codex 直接回"nothing to review"。

**正确做法**:走 `codex:codex-rescue`(=`codex-companion.mjs task`),把 audit 当任务派发,**显式 read-only**(让 rescue agent 不加 `--write`)。

最简调用,在主消息里和 Opus 并行触发:

```
Skill({
  skill: "codex:rescue",
  args: "--background --fresh Audit the entire Lumory repository read-only. Do NOT edit any files. Find: (1) latent bugs in production code (concurrency, error handling, edge cases, security, data integrity), (2) high-ROI optimizations (perf hot paths, dead code, repeated logic, missing tests). Focus on Chronote/Services and server/index.js first. Output a prioritized list with file:line evidence. Do not run builds or tests."
})
```

(`--fresh` 防 resume 上次,`--background` 让 codex 后台跑;主对话继续推进 Opus 这条线。)

**仓库特别大 / 想要双视角**:开两个 codex task,一个聚焦 iOS / Swift Concurrency,一个聚焦 server + SSE + 鉴权。两个独立 background task,prompt 写清楚分工。

#### Step 3 调用模板(单条消息内,N 个 Agent + 1-2 个 codex skill)

主 agent 一条 message 里同时发:
- N 个 `Agent` 调用(每个 `model: "opus"`,见上面 angle × slice 矩阵)
- 1-2 个 `Skill({ skill: "codex:rescue", ... })`

**不要**串行发,subagent 之间无依赖。

### Step 4 — 等回收 + 主 agent 核对(最关键 — 不要跳)

Opus subagents 回完之后,Codex background task 用 `/codex:status` 看进度,完成后 `/codex:result` 取结果(skill 形式:`Skill({ skill: "codex:result" })`)。如果 Codex 还在跑且 Opus 已经齐了,**等**,megareview 就是不计成本,不要为了快漏掉 Codex 那一份。

**不能**直接合并 paste。必须做:

#### A. 去重 + 合并

- 同一处问题被多个 reviewer 提到 → 合一条,credit 多个来源(可信度↑)
- finding 之间互相矛盾 → 标"冲突",自己读代码裁决
- "Bug" 和 "优化"分两堆,不混着写

#### B. 量化事实核对(Opus 系统性弱点 — 必查)

对每条 finding 中的:**计数 / 行号 / 文件位置 / "未被使用" / "dead code" / "X 处" / 库行为陈述**,主 agent 必须验证:

| 陈述类型 | 验证手段 |
|---|---|
| "有 N 个 X" | `Grep` 实数一遍 |
| 行号 / 文件位置 | `Read` 那个文件区间确认 |
| "此 helper / class / file 没业务 caller" | `Grep` 函数名 + 类名全仓搜,**包括** 测试目录、xcconfig、storyboard、plist |
| "库 X 不会做 Y" | `mcp__plugin_context7_context7__query-docs` 查官方文档,**别**信 subagent 记忆 |
| "运行时一定崩 / 死锁" | 看实际调用入口和调用顺序,Read 上下文 50 行 |
| "重复逻辑 N 处" | grep 关键 token,确认是真重复还是只是相似命名 |

**核对不通过的**:
- 数字错了 → 改正后保留 finding
- 完全错了(dead code 其实活的 / "崩"实际不会跑到)→ 移到"已被否决"区,写否决理由
- 没法验证 → 降级到"待确认"区,**不放进 P0/P1 或 OPT-HIGH**

#### C. 分级校准

**Bug 档**:
- **P0** = 必须修:已观察到 / 确定能复现的 crash / 数据丢失 / 鉴权破洞 / fail-closed 失效
- **P1** = 应该修:逻辑错(已被实际调用)/ 性能踩坑 / 关键路径缺测试覆盖
- **P2** = nice to fix:可读性 / 边角 case / 罕见路径

**优化档**:
- **OPT-HIGH** = ROI 高:大段死代码可以删 / 热路径 N+1 → batch / 主线程阻塞改 background / 重复逻辑提取一次性收益大
- **OPT-MID** = 值得做:抽象更清晰 / 测试覆盖补关键路径 / 日志/可观测性补
- **OPT-LOW** = 看心情:命名 / 风格 / 可读性

把每条 P0/P1/OPT-HIGH 的等级跟"实际 runtime / 用户能感知到"对一遍 —— dead helper 的 bug 应降级、写一次的优化收益小的应降级。

#### D. 写最终报告

写到 `CodeReview/megareview-YYYYMMDD-HHmm.md`(`CodeReview/` 已在 .gitignore;如未在则加上):

```markdown
# Megareview Report — <YYYY-MM-DD HH:mm>

## 仓库概览
- 总文件 / LoC / 顶层目录分布
- 最近 90 天 churn 热点文件 top N
- TODO/FIXME 总数
- 触发的视角:[列出 subagent 视角 + slice 清单]

## Bug — P0(必修)
### 1. <一句话标题>
- **来源**:correctness × codex(2 个 reviewer 都标了)
- **位置**:`Chronote/Foo.swift:123`
- **问题**:...
- **核对**:grep 了 `funcName` 全仓 7 处调用,确认是热路径(`Bar.swift:45`、`Baz.swift:200` ...)
- **建议修复**:...

## Bug — P1(应修)
...

## Bug — P2(nice to fix)
...

## 优化 — OPT-HIGH(高 ROI)
### 1. <一句话标题>
- **来源**:dead-code × architect
- **位置**:`Chronote/Services/UnusedThing.swift`(整文件)
- **问题**:...
- **核对**:`grep -r UnusedThing` 全仓 0 caller(包含测试 / xcconfig / plist 都 0)
- **预估收益**:删 ~120 行 / 减一个并发盲点
- **建议**:删

## 优化 — OPT-MID
...

## 优化 — OPT-LOW
...

## 待确认(reviewer 提到但主 agent 没法验证 — 让用户决定)
- ...

## 已否决(reviewer 提到但核对不通过)
- <原 finding>:否决理由(grep 结果 / 文档链接)

## Reviewer 矩阵
| Slice | Angle | subagent | 提了 N 条 | 命中率 |
|---|---|---|---|---|
| Models/Persistence | data | coredata-migration-reviewer (Opus) | 5 | 4/5 |
| Services/AI | concurrency | general-purpose (Opus) | 8 | 6/8 |
| server/ | security | backend-security-coder (Opus) | 4 | 3/4 |
| 整仓 | dead code | code-reviewer (Opus) | 6 | 5/6 |
| 整仓 | codex audit | codex-rescue | 12 | 9/12 |
| ...
```

报告写完后告诉用户路径,**不要**在主对话里 paste 全文(太长,用户去文件看)。可以摘:
- P0 数量 + 标题(全列)
- OPT-HIGH 前 3 条标题
- 一句话整体观感(技术债集中在哪 / 哪个模块最值得动)

## Lumory 项目专属核对清单

主 agent 在 Step 4 的核对阶段,拿这份清单过一遍 finding 是否覆盖了已知踩坑(也是 reviewer 没提就该自己补的):

- [ ] 有没有 main thread 调 `bg.performAndWait` block 内 `DispatchQueue.main.sync`(SIGTRAP 9005...)
- [ ] SSE 上游错误是不是 `res.destroy(error)` 而不是 `data: [DONE]`
- [ ] CoreData 字段加了非 optional 没默认值(CloudKit 不兼容)
- [ ] `EmbeddingBackfillService` / `ThemeBackfillService` 是不是仍然非 auto(只走用户主动触发)
- [ ] `@Observable` VM 里有没有嵌套 `ObservableObject` 的 `@Published`(UI 不 react)
- [ ] `@FetchRequest(animation:)` 有没有重新出现(动画错位)
- [ ] bash 脚本 `cmd | cmd || true` 有没有覆盖 `PIPESTATUS`
- [ ] 后端 `APP_SHARED_SECRET` 缺失是不是仍然 fail-closed
- [ ] `AppSecrets.swift` 有没有新硬编码 secret(应该走 xcconfig 注入链)
- [ ] `URLSession.sslTolerantSession` 有没有人误以为是绕证书的实现(其实只是 timeout 配置,有没有引入新的 URLSessionDelegate didReceiveChallenge)
- [ ] `NSManagedObject` 跨 await 有没有漏 `@MainActor`(Swift 6 Sendable 报错)
- [ ] UITestSampleData guard(`NSInMemoryStoreType` + url=/dev/null)有没有被破坏
- [ ] xcconfig / pbxproj 里 `showEnvVarsInLog = 0` 有没有被改回 1(secret 进 build log)
- [ ] `Log.warn`(错的)vs `Log.warning`(对的);`Log.Category` 有没有用了未注册的分类

## 调用示例

用户:`/megareview`

主 agent 该做:
1. 跑摸底命令(并行 Bash:`git ls-files | wc -l` / 各目录文件数 / churn / TODO 统计 / 大文件)
2. 看仓库规模选 slice × angle 矩阵(Lumory 中等规模 → 8-10 Opus + 1-2 Codex)
3. 单条消息内:
   - N 个 Agent tool call(每个 `model: "opus"`,prompt 自包含 slice + angle + 输出格式 + 量化要求)
   - 1-2 个 `Skill({ skill: "codex:rescue", args: "--background --fresh ..." })`
4. 等回收(Opus 同步,Codex 用 `/codex:status` 轮询;Codex 还在跑就等)
5. 跑核对(grep + Read + context7 + Lumory 清单)
6. 写 `CodeReview/megareview-*.md`
7. 主对话只回:报告路径 + P0 数量 + OPT-HIGH top-3 标题 + 一句话总结

## 失败模式 / 别这么干

- ❌ 用 `/codex:review` 而不是 `codex:rescue`:diff 通常是空的,codex 会直接说"nothing to review",这个 skill 就废了
- ❌ 把所有 subagent 输出原样拼起来当报告 → 量化错误会被原样保留
- ❌ subagent 数量缩水(为省钱跑 3 个) → 失去多视角互补的意义,这个 skill 就是不计成本
- ❌ 跳过核对步骤 → 用户读到错的行号 / 错的"dead code"判断,修了反而引入 regression
- ❌ 给 subagent 模糊 prompt("帮我看看整个仓库") → 视角散,大量重复 + 鸡毛蒜皮 finding
- ❌ slice 不切就一锅塞:让一个 subagent 看 80 个文件,prompt 装不下,context 爆,输出糊
- ❌ 全部串行 → 没必要,subagent 之间无依赖
- ❌ Codex 给 `--write`(默认会加)→ 这是 read-only audit,显式在 prompt 写 "Do NOT edit any files",让 rescue agent 把 `--write` 关掉
- ❌ 把"建议大重构"当 finding → 这个 skill 只标点,不画蓝图;重构请走 feature-dev / architect-review 流程
