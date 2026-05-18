---
name: megareview
description: 不计成本对**整个 repo**(不是 uncommitted diff)做最严的 bug + 优化 + **新功能机会**审计 —— 按目录 / 关注点切片**分波**召唤多个 Opus subagent(避免一次性 10+ 并发触发服务器限流)+ 跑 codex 仓库级 audit(走 codex:codex-rescue 的 read-only task,不是 /codex:review),最后主 agent 交叉核对量化事实并产出分级报告,**报告写完再让 codex:rescue 做一遍最终复审**。用户说"megareview / 整库审查 / 全仓审计 / repo audit / 整个仓库找 bug 和优化点 / 找新功能机会"时触发。
---

# Megareview - 不计成本的整仓审计

和 `/superreview` 同源,但 scope 不一样:
- **superreview**:审 uncommitted changes(working tree / branch diff),commit/push/上架前的关。
- **megareview**(本 skill):审**整个 repository 的现状** —— 找已经在 main 里、可能已经跑了几个月、但没人翻过的 bug + 高价值优化机会 + **可加的新功能 / 可以做得更好的体验点**。不依赖 git diff。

## 核心理念

1. **整仓不能一锅端**:把 repo 按目录 + 关注点切成 N 个 slice,每个 subagent 只看一个 slice 一个角度。一锅 prompt "review 整仓"必然糊。
2. **多视角并行 + 跨模型**:Opus(找语义 / 项目约定 / 隐藏耦合 / 产品视角的"可以更好") + Codex(找语法层 bug / 库行为 / 大范围 grep 模式)互补。
3. **三档输出**:这个 skill **不只是找 bug**:
   - **BUG**(P0/P1/P2)— 已经错了
   - **OPT**(HIGH/MID/LOW)— 技术债 / 性能 / 死代码 / 测试空白(internal facing)
   - **FEAT**(HIGH/MID/LOW)— **能加的新功能 + 现在 work 但可以 work 更好的产品/UX 点**(user facing)
   FEAT 是一等公民,不是附录。
4. **主 agent 强制核对**:Opus 在量化精度上系统性偏弱(行号 / 计数 / "未被使用" / 库行为),所有 BUG/OPT finding 主 agent **必须 grep + Read + context7 验证**才能进最终报告。FEAT 不要核对存在性(本来就不存在),但要核对"是否已经实现了"(grep 关键词,别提已有的功能)。
5. **不计成本但要分波发**:subagent `model: "opus"`,数量按仓库大小给到 8-15 个,Codex 1-2 个 task —— **但不能一条消息里全发出去**,会触发服务器并发限流(用户实测踩过)。改用**波次调度**:每波 3-4 个,**等当前波 Agent 全部回收后再发下一波**(Agent 是同步阻塞,每波本身就分钟级,自然错开,不需要显式 sleep)。详见 Step 3。
6. **报告做完再让 codex 复审一次**:主 agent 写完 `megareview-*.md` 后,起一个 `codex:rescue` task 读这份报告,做"二审"—— 找漏掉的 angle / 误判的等级 / 重复条目 / 主 agent 自己也有 Opus 系统性偏弱的可能。详见 Step 5。

## 何时触发

- 用户输入 `/megareview` 或说"megareview / 整库审查 / 全仓审计 / repo audit / 把整个仓库扒一遍找 bug / 整个项目找优化点 / 看看还能加什么功能 / 现在哪里可以做得更好"
- 大版本上线前 / 季度技术债盘点 / 接手老代码后想全面摸底 / 想要新一轮 roadmap 候选
- superreview 已经跑过 diff,但用户怀疑老代码里也有问题

## 何时**不**该用

- 只关心最近这次改动 → 用 `/superreview`,megareview 太重
- 只想知道"这个文件有没有 bug" → 起一个 `general-purpose` subagent + 把 review 焦点写进 prompt 直接看
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
# Lumory 专属:CLAUDE.md 里的 "Follow-up backlog" / 项目内 P1/TODO 收集
grep -nE 'P1|backlog|TODO' CLAUDE.md 2>/dev/null | head -30
```

按规模决定 subagent 数量 + 波次:

| 仓库规模 | Opus subagents | Codex tasks | 波次安排 |
|---|---|---|---|
| 小(< 5k LoC) | 6 | 1 | 2 波 × 3 个 |
| 中(5k-30k LoC) | 8-10 | 1-2 | 3 波 × 3-4 个 |
| 大(> 30k LoC) | 12-15+ | 2 | 4 波 × 3-4 个 |

### Step 2 — 切片(slice)+ 视角(angle)

**切片维度**(按目录):每个 slice 是一组语义相关的文件。Lumory 参考切法:
- **Models/Persistence**:`Chronote/Model/*` + `PersistenceController.swift` + `*BackfillService.swift`
- **AI/Network/SSE**:`OpenAIService.swift` + `AIService.swift` + `NetworkRetryHelper.swift` + `InsightsEngine.swift` + `ContextPromptGenerator.swift`
- **Audio/Speech**:`AudioRecorder.swift` + `OpenAITranscriber.swift` + `Transcriber.swift` + 相关 Views
- **Home VM stack**:`Chronote/Views/HomeView.swift` + `Chronote/Views/HomeView/`(三个 @Observable VM)
- **Insights/AskPast**:`Chronote/Views/Insights/*`
- **Search/Detail/Settings**:`SearchView.swift` + `DiaryDetailView.swift` + `SettingsView.swift` + `DiaryImportView.swift` + `DiaryExportView.swift`
- **Reminder/Widget/URL**:`ReminderService.swift` + `WidgetSnapshotService.swift` + `LumoryURLRouter.swift` + `LumoryWidgets/` + `LumoryWidgetShared/`
- **Backend**:`server/*.js` + `ecosystem.config.js`
- **Tests**:`ChronoteTests/*` + `ChronoteUITests/*`
- **Scripts/Build**:`Scripts/*` + 根目录 `*.sh` + `Lumory.xcconfig` + `Lumory-Info.plist`
- **Cross-cutting**:dead code / 未引用 symbol / 重复逻辑 / 命名不一致 / **产品体验**(单独 slice 给 FEAT 视角用)

**视角维度**(按关注点):

⚠️ **subagent_type 必须在当前 harness 池里**,池随插件状态变化 —— 每会话起点 system reminder 列的就是当前全集,**spawn 前先核**。2026-05-17 实测可用、对 review 有用的:`general-purpose` / `Explore` / `Plan` / `coredata-migration-reviewer` / `sse-pipeline-reviewer` / `code-simplifier:code-simplifier` / `code-modernization:security-auditor` / `:architecture-critic` / `:test-engineer` / `:legacy-analyst` / `:business-rules-extractor` / `plugin-dev:*` / `agent-sdk-dev:*` / `claude-code-guide` / `statusline-setup` / `claude`。**今天 spawn 仍 hard error 的**:裸名 `code-reviewer` / `debugger` / `security-auditor` / `architect-review` / `test-automator` / `performance-engineer` / `database-optimizer` / `api-design-principles` / `backend-security-coder`;前缀 `codex:*` / `feature-dev:*` / `superpowers:*`。**不确定走 `general-purpose`** + 把视角焦点写进 prompt,行为等价 + 不冒 hard-error 风险。

| 视角 | subagent_type | 重点 | 类别 |
|---|---|---|---|
| Bug — 正确性 | general-purpose | 逻辑错 / off-by-one / 边界 / null / 异常吞掉 | BUG |
| Bug — 并发 | general-purpose | actor 隔离 / @MainActor 违反 / Sendable 漏标 / 取消语义 / 死锁 | BUG |
| Bug — 安全(轻量) | general-purpose | 仅看明显的:硬编码 secret / fail-open 鉴权倒退 / SSE 错误关闭。**不要**做正式的 OWASP 审计 / 不要展开成专项 slice —— Lumory 是单人 iOS 日记 App + 单 backend,过度安全审计 ROI 低(真要深度 OWASP 才换 `code-modernization:security-auditor`) | BUG |
| Bug — 数据 | **coredata-migration-reviewer** | CoreData schema / CloudKit 限制 / backfill 幂等性 | BUG |
| Bug — SSE 管道 | **sse-pipeline-reviewer** | 服务端 res.destroy vs [DONE] / 客户端 SSEParser / NetworkRetryHelper | BUG |
| Perf | general-purpose | 主线程 IO / N+1 fetch / 缓存缺失 / 内存泄漏 / 不必要重渲染 | OPT |
| 优化 — 抽象 | general-purpose | 抽象泄漏 / 重复逻辑 / SRP / 应该提的 helper | OPT |
| 优化 — 死代码 | code-simplifier:code-simplifier | 未被引用的 func/class/file / 注释掉的代码 / 可简化逻辑 | OPT |
| 优化 — 测试 | general-purpose | 关键路径无单测 / mock 错配 / 边界没覆盖(深度 test gap 可换 `code-modernization:test-engineer`) | OPT |
| 优化 — DX/构建 | general-purpose | 构建脚本脆 / CI 缺失 / 工具链漂移 | OPT |
| API contract | general-purpose | 后端 vs 客户端协议 / 错误码 / SSE 帧格式 | OPT/BUG |
| **FEAT — 新功能** | **general-purpose** | **基于现有 model/service 自然延伸的功能(导出格式 / 新可视化 / 新交互)/ 用户已经在用但缺 affordance 的隐性需求** | **FEAT** |
| **FEAT — UI(视觉/布局)** | **general-purpose** | **liquidGlass / 间距 / 对齐 / 字号层级 / 颜色一致性 / 圆角阴影一致性 / 暗色模式表现 / iPad 布局 / Dynamic Island / 状态栏 / 跨 view 视觉风格漂移** | **FEAT** |
| **FEAT — UX(交互/反馈)** | **general-purpose** | **loading 态缺失 / 错误提示糊 / 空态生硬 / 动效缺失或不统一 / haptic 缺失 / 转场动画 / 长按 / 滑动 / 键盘交互 / 触控热区 / 操作完成的确认感 / i18n 漏字符串 / 跨 view 交互模式不一致** | **FEAT** |
| Style/约定 | general-purpose | CLAUDE.md 约定 / 命名 / 日志 API 用法 | OPT |

**切片 × 视角 = subagent**。一个 subagent 一组(slice, angle)。同一个 slice 可以被多个 angle 各看一次。

**Lumory 强制视角**(一定要召唤):
- `coredata-migration-reviewer` 看 Models/Persistence + 任何动 `DiaryEntry` schema 的服务
- `sse-pipeline-reviewer` 看 AI/Network/SSE slice(项目自带 agent)
- 死代码扫(整仓):反复要扫的场景
- **FEAT — 新功能 + UI(视觉/布局)+ UX(交互/反馈)三条都要召唤,各至少 1 个**(user 明确要求重点关注 UI 和 UX,以后默认带)
- **不要召唤"无障碍 / accessibility / VoiceOver / Dynamic Type"专项视角** —— user 明确不关注这块,reviewer 顺便提到也要主 agent 在 Step 4 核对时全部 drop
- **不要把"安全"做成专项 slice** —— Lumory 不需要 OWASP 级审计;只让 `general-purpose` 正确性视角在扫的时候顺手扫一下硬编码 secret 和 SSE 错误关闭就够了(真要深度 OWASP 才换 `code-modernization:security-auditor`)

### Step 3 — **波次调度**召唤(关键改动:不能一次性全发)

**为什么分波**:用户实测一条消息里 10+ Agent tool call 会触发服务器并发限流(具体表现可能是部分 subagent 直接 fail / 排队超时)。即使没限流,响应回来同步等也容易超 context window。

**波次规则**:
- **每波 3-4 个 Agent + 至多 1 个 codex task**
- 波之间**不需要显式 sleep** —— `Agent` 调用本身是同步阻塞,每波回完都已经分钟级,自然错开。主 agent 一拿到 wave N 全部 result 就发 wave N+1,**别在 result 没回齐前预发下一波**(那等于绕过分波)。
- Codex task 是 `--background`,不阻塞,**第一波就发**(让它边跑边等)
- **Wave 1**:**强制视角 + Codex** —— `coredata-migration-reviewer`(Models/Persistence)、`sse-pipeline-reviewer`(AI/SSE)、整仓 dead code 扫、Codex bug audit。这一波最关键,先发。
- **Wave 2**:bug 类剩余 angle —— 并发 / API contract / Home VM stack 等(**安全不单独占 slot**,让 `general-purpose` 正确性视角在扫的时候顺手扫硬编码 secret 即可)
- **Wave 3**:OPT 类 —— 抽象 / 测试 / 性能 / DX
- **Wave 4**:FEAT 类 + 第二个 Codex task(产品/UI/UX 视角)。**这一波是重点之一,user 明确要看 UI 和 UX 改进**,所以即便仓库不大也要跑;只有在前 3 波 context 严重吃紧时才能砍掉,砍掉时主对话要主动说明"这次没跑 FEAT 视角"

**示意结构**(伪代码,主 agent 实际照这个流程发):

```
# Wave 1 (单条消息内并行)
  Agent { subagent_type: "coredata-migration-reviewer", model: "opus", ... }
  Agent { subagent_type: "sse-pipeline-reviewer", model: "opus", ... }
  Agent { subagent_type: "code-simplifier:code-simplifier", description: "Dead code scan", model: "opus", ... }
  Skill { skill: "codex:rescue", args: "--background --fresh ..." }

# === 等 Wave 1 全部 Agent 同步回收 (Codex 仍后台跑) ===

# Wave 2 (单条消息内并行)
  Agent { subagent_type: "general-purpose", description: "Concurrency review on AI/Network", model: "opus", ... }
  Agent { subagent_type: "general-purpose", description: "Backend correctness (server/index.js)", model: "opus", ... }
  Agent { subagent_type: "general-purpose", description: "Home VM stack correctness", model: "opus", ... }

# === 等 Wave 2 回完 ===

# Wave 3 (单条消息内并行)
  Agent { subagent_type: "general-purpose", description: "Perf hot paths", model: "opus", ... }
  Agent { subagent_type: "general-purpose", description: "Test coverage gaps", model: "opus", ... }
  Agent { subagent_type: "general-purpose", description: "Abstraction / SRP audit", model: "opus", ... }

# === 等 Wave 3 回完 ===

# Wave 4 (单条消息内并行) - FEAT (UI + UX 是重点)
  Agent { subagent_type: "general-purpose", description: "FEAT: new feature opportunities", model: "opus", ... }
  Agent { subagent_type: "general-purpose", description: "FEAT: UI consistency (visual / layout / liquidGlass / 暗色模式 / iPad)", model: "opus", ... }
  Agent { subagent_type: "general-purpose", description: "FEAT: UX polish (loading / empty / error / haptic / 动效 / 一致性)", model: "opus", ... }
  Skill { skill: "codex:rescue", args: "--background --fresh Audit Lumory read-only for UI consistency and UX polish opportunities. NO accessibility/VoiceOver/Dynamic Type — skip those." }
```

**每个 Opus subagent prompt 必须包含**:
- **本次审计目标**:"找仓库已存在的 bug / 高 ROI 优化点 / **新功能机会和体验改进点**;这不是 diff review"
- **slice 文件清单**(具体路径,别让 agent 自己猜)
- **专项 angle**(只看这个角度,其他 angle 别人会看)
- **输出格式**:`[BUG-P0/P1/P2 | OPT-HIGH/MID/LOW | FEAT-HIGH/MID/LOW] file:line — 一句话标题 — 问题/机会描述 — 建议 — 证据(代码片段或调用链;FEAT 类给"为什么用户会受益"的理由)`
- **量化要求**(BUG/OPT):所有"X 处"/"未被使用"/"N 次"陈述必须给 grep 结果或代码片段
- **范围克制**:不要建议大重构;FEAT 标"小到中等改动量"的点,大功能(>1 周工作量)单独标 FEAT-HIGH 但写明"需要拆 epic"
- 显式 `subagent_type` + `model: "opus"`

#### FEAT subagent prompt 特别强调

FEAT 视角的 prompt 要写清楚**不要的东西**:
- ❌ "应该做 AI agent 化 / 大模型 finetune" 这类天上掉下来的方向 → 这是产品战略不是 review
- ❌ 已经在 CLAUDE.md "Follow-up backlog" 里的(可以搜一下避免重复)
- ❌ 模糊建议"加更多动画" → 必须指出**哪个具体场景**的动画缺失

要的:
- ✅ "DiaryDetailView 的图片预览没有 zoom-pinch,但 ImageViewerView 已经实现了 zoom,这两处行为不一致 — 把 ImageViewerView 风格挪到 detail 里"
- ✅ "Insights 的 ThemeCardList 长按缺 haptic feedback,其他 list 都有 — 体验不一致"
- ✅ "Reminder Settings 的 hour:minute picker 没有'下次将于 X 触发'的预览 — 用户拨完没确认感"

#### Codex 任务(Wave 1 + Wave 4 各一)

**不要**用 `/codex:review` 或 `/codex:adversarial-review` —— 它们只看 git state,在 megareview 场景里 diff 通常是空的,会被 codex 直接回"nothing to review"。

**正确做法**:走 `codex:codex-rescue`(=`codex-companion.mjs task`),把 audit 当任务派发,**显式 read-only**(让 rescue agent 不加 `--write`)。

Wave 1 Codex(bug-focused):

```
Skill({
  skill: "codex:rescue",
  args: "--background --fresh Audit the entire Lumory repository read-only. Do NOT edit any files. Find: latent bugs (concurrency, error handling, edge cases, data integrity) and high-ROI optimizations (perf hot paths, dead code, repeated logic). Focus on Chronote/Services and server/index.js first. Skip security/OWASP analysis — only flag obvious things like hardcoded secrets or fail-open auth regressions. Output a prioritized list with file:line evidence. Do not run builds or tests."
})
```

Wave 4 Codex(product/UX-focused,可选):

```
Skill({
  skill: "codex:rescue",
  args: "--background --fresh Audit Lumory read-only for UI consistency + UX polish opportunities. UI: visual / spacing / liquidGlass / 暗色模式 / iPad layout / 跨 view 风格漂移. UX: empty states, error toasts, loading states, missing haptic feedback, animation gaps or inconsistencies, i18n string gaps. **Skip accessibility entirely** — no VoiceOver, no Dynamic Type, no ARIA. Output as FEAT-HIGH/MID/LOW with file:line and a one-sentence user-benefit rationale."
})
```

### Step 4 — 等回收 + 主 agent 核对(最关键 — 不要跳)

各波 Opus 同步回完后,Codex background task 由 `codex:rescue` skill 自己管 lifecycle —— 它返回的内容里包含 task id / 状态。如果 wave 1 codex 还没回结果就再 `Skill({ skill: "codex:rescue", args: "<原 task id 或 follow-up 引用>" })` 询问进度,直到拿到完整 audit。**Codex 还在跑就等**,megareview 是不计成本。

(实际机制以 `codex:rescue` 当前版本为准 —— 不要假设有 `/codex:status` 或 `codex:result` 这类独立 skill,本仓 skill 池里没有。)

**不能**直接合并 paste。必须做:

#### A. 去重 + 合并

- 同一处问题被多个 reviewer 提到 → 合一条,credit 多个来源(可信度↑)
- finding 之间互相矛盾 → 标"冲突",自己读代码裁决
- BUG / OPT / FEAT 分三堆,**不混着写**

#### B. 量化事实核对(Opus 系统性弱点 — 必查)

对每条 BUG/OPT finding 中的:**计数 / 行号 / 文件位置 / "未被使用" / "dead code" / "X 处" / 库行为陈述**,主 agent 必须验证:

| 陈述类型 | 验证手段 |
|---|---|
| "有 N 个 X" | `Grep` 实数一遍 |
| 行号 / 文件位置 | `Read` 那个文件区间确认 |
| "此 helper / class / file 没业务 caller" | `Grep` 函数名 + 类名全仓搜,**包括** 测试目录、xcconfig、storyboard、plist |
| "库 X 不会做 Y" | `mcp__plugin_context7_context7__query-docs` 查官方文档,**别**信 subagent 记忆 |
| "运行时一定崩 / 死锁" | 看实际调用入口和调用顺序,Read 上下文 50 行 |
| "重复逻辑 N 处" | grep 关键 token,确认是真重复还是只是相似命名 |

**FEAT 的核对**:不查"是否真有 bug",查**"是否已经实现"**:
- 提议"加 X 功能" → grep 关键词,确认仓里没有
- 提议"改进 Y 体验" → Read 对应 view,确认 reviewer 描述的现状是真的(不是看错了已经存在的实现)
- CLAUDE.md "Follow-up backlog" 里已经记录的 → 标注"已在 backlog,本次确认仍未做",不当成新发现

**核对不通过的**:
- 数字错了 → 改正后保留
- 完全错了 → 移到"已被否决"区,写否决理由
- 没法验证 → 降级到"待确认",**不放进 P0/P1 或 HIGH**

#### C. 分级校准

**Bug 档**:
- **P0** = 必须修:确定能复现的 crash / 数据丢失 / 鉴权破洞 / fail-closed 失效
- **P1** = 应该修:逻辑错(已被实际调用)/ 性能踩坑 / 关键路径缺测试覆盖
- **P2** = nice to fix:可读性 / 边角 case / 罕见路径

**优化档**:
- **OPT-HIGH** = ROI 高:大段死代码可删 / 热路径 N+1 → batch / 主线程阻塞改 background
- **OPT-MID** = 值得做:抽象更清晰 / 测试覆盖补关键路径 / 日志/可观测性
- **OPT-LOW** = 看心情:命名 / 风格 / 可读性

**新功能/体验档**:
- **FEAT-HIGH** = 高用户价值 + 改动 ≤ 1-3 天:用户每天都会触发 / 一致性补齐 / 关键路径的体验空缺
- **FEAT-MID** = 锦上添花:明确受益但不是高频
- **FEAT-LOW** = 等有空再说:边角 case / 极少数用户的体验

把 P0/P1/OPT-HIGH/FEAT-HIGH 跟"实际 runtime / 用户能感知到"对一遍 —— dead helper 的 bug 应降级、写一次的优化收益小的应降级、用户一辈子触发不到的 FEAT 应降级。

#### D. 写第一版报告

写到 `CodeReview/megareview-YYYYMMDD-HHmm.md`(`CodeReview/` 已在 .gitignore;如未在则加上):

```markdown
# Megareview Report — <YYYY-MM-DD HH:mm>

## 仓库概览
- 总文件 / LoC / 顶层目录分布
- 最近 90 天 churn 热点文件 top N
- TODO/FIXME 总数
- 触发的视角 + 波次:[列出 subagent 视角 + slice 清单 + 每波时间戳]

## Bug — P0(必修)
### 1. <一句话标题>
- **来源**:correctness × codex(2 个 reviewer 都标了)
- **位置**:`Chronote/Foo.swift:123`
- **问题**:...
- **核对**:grep 了 `funcName` 全仓 7 处调用,确认热路径
- **建议修复**:...

## Bug — P1(应修)
...

## Bug — P2(nice to fix)
...

## 优化 — OPT-HIGH(高 ROI)
### 1. <一句话标题>
- **来源**:dead-code × architect
- **位置**:`Chronote/Services/UnusedThing.swift`(整文件)
- **核对**:`grep -r UnusedThing` 全仓 0 caller(测试 / xcconfig / plist 都 0)
- **预估收益**:删 ~120 行
- **建议**:删

## 优化 — OPT-MID / OPT-LOW
...

## 新功能 / 体验改进 — FEAT-HIGH
### 1. <一句话标题>
- **来源**:UX-polish reviewer
- **位置**:`Chronote/Views/DiaryDetailView.swift:430-460`
- **现状**:用户在 detail 看图,只能 tap 进 ImageViewerView 才能 zoom;detail inline 预览本身不支持 pinch。
- **机会**:把 ImageViewerView 的 zoom gesture 复用到 inline 预览;一致性 + 减一次 navigation。
- **核对**:grep `MagnificationGesture` 在 DiaryDetailView 0 命中,ImageViewerView 1 命中;现状描述属实。
- **改动量**:小(~30 行 + gesture 提取成 modifier)
- **用户受益**:每个有图日记的用户都会触发(高频)

## FEAT-MID / FEAT-LOW
...

## 待确认(reviewer 提到但主 agent 没法验证)
- ...

## 已否决(reviewer 提到但核对不通过)
- <原 finding>:否决理由

## Reviewer 矩阵
| 波次 | Slice | Angle | subagent | 提了 N 条 | 命中率 |
|---|---|---|---|---|---|
| W1 | Models/Persistence | data | coredata-migration-reviewer | 5 | 4/5 |
| W1 | AI/SSE | sse-pipeline | sse-pipeline-reviewer | 3 | 3/3 |
| W1 | 整仓 | bug audit | codex-rescue | 12 | 9/12 |
| W2 | ... | ... | ... | ... | ... |
| W4 | 整仓 | UX/polish | general-purpose | 8 | 7/8 |
```

### Step 5 — 让 codex:rescue 复审报告(新增)

主 agent **不能信任自己**(Opus 系统性偏弱也适用于自己整合的报告 —— 可能漏 angle、误判等级、重复条目没发现)。报告 `megareview-YYYYMMDD-HHmm.md` 写完后,起一个 codex task 做二审:

```
Skill({
  skill: "codex:rescue",
  args: "--background --fresh Read the megareview report at CodeReview/megareview-<YYYYMMDD-HHmm>.md. Do NOT edit any files. Critique it: (1) Are any P0/P1/OPT-HIGH/FEAT-HIGH items mis-prioritized (too high or too low) given the actual codebase impact? (2) Are there obvious BUG / OPT / FEAT angles the report missed entirely (do a sanity grep across Chronote/ and server/ for things like force-unwraps, retained-cycle risks, unused public APIs, hardcoded English in zh-Hans paths, UI/UX inconsistencies across views)? (3) Any duplicate findings that should be merged? (4) Any '已否决' items that were actually correct and should be reinstated? **Skip accessibility entirely** (no VoiceOver / Dynamic Type / ARIA — user explicitly excluded this scope). **Skip OWASP-style security analysis** — only flag if you see hardcoded secrets or fail-open auth. Output verdict per existing finding (KEEP / DOWNGRADE / UPGRADE / DROP) plus a list of missed findings. Read-only — do not modify the report file."
})
```

`--background` + `--fresh`,完成后由 `codex:rescue` 自身机制返回结果(同 Step 4 备注 —— 没有独立的 `/codex:status` / `codex:result` skill)。

拿到 codex 二审结果后:
- **Verdict 表**:跟主 agent 自己的判断逐条对一遍。codex 升降级理由如果合理 → 接受并改 report;不合理 → 在 report 末尾"复审反驳"小节写为什么不接受
- **Missed findings**:逐条核对(同 Step 4-B 的核对手段 —— grep + Read);确认存在的话补进 report 对应分级
- **重复合并**:接受
- 如果 codex 复审产出超过 3 条主 agent 接受的修订 → 在报告头部加一行"经 codex 二审,X 条调整 / Y 条新增"

最后在 report 末尾加一段:

```markdown
## Codex 二审结果(Step 5)
- 复审时间:<timestamp>
- 调整:<keep/upgrade/downgrade/drop 计数>
- 新增 finding:<N> 条(已并入对应分级)
- 主 agent 反驳:<列出不接受 codex 调整的条目 + 理由>
```

### Step 6 — 主对话回报

主对话**只回**:
- 报告路径
- BUG-P0 数量 + 标题(全列)
- OPT-HIGH 前 3 条标题
- **FEAT-HIGH 前 3 条标题**
- Codex 二审带来的关键修订(1-2 句)
- 一句话整体观感(技术债集中在哪 / 哪个模块最值得动 / 哪条 FEAT 最该排上日程)

**不要 paste 全文**,用户去文件看。

## Lumory 项目专属核对清单

主 agent 在 Step 4 的核对阶段,拿这份清单过一遍 finding 是否覆盖了已知踩坑(reviewer 没提就该自己补的):

- [ ] 有没有 main thread 调 `bg.performAndWait` block 内 `DispatchQueue.main.sync`(SIGTRAP 9005...)
- [ ] SSE 上游错误是不是 `res.destroy(error)` 而不是 `data: [DONE]`
- [ ] CoreData 字段加了非 optional 没默认值(CloudKit 不兼容)
- [ ] `EmbeddingBackfillService` / `ThemeBackfillService` 是不是仍然非 auto(只走用户主动触发)
- [ ] `@Observable` VM 里有没有嵌套 `ObservableObject` 的 `@Published`(UI 不 react)
- [ ] `@FetchRequest(animation:)` 有没有重新出现(动画错位)
- [ ] bash 脚本 `cmd | cmd || true` 有没有覆盖 `PIPESTATUS`
- [ ] 后端 `APP_SHARED_SECRET` 缺失是不是仍然 fail-closed
- [ ] `AppSecrets.swift` 有没有新硬编码 secret(应该走 xcconfig 注入链)
- [ ] `URLSession.sslTolerantSession` 有没有人误以为是绕证书的实现
- [ ] `NSManagedObject` 跨 await 有没有漏 `@MainActor`(Swift 6 Sendable)
- [ ] UITestSampleData guard(`NSInMemoryStoreType` + url=/dev/null)有没有被破坏
- [ ] xcconfig / pbxproj 里 `showEnvVarsInLog = 0` 有没有被改回 1
- [ ] `Log.warn`(错的)vs `Log.warning`(对的);`Log.Category` 有没有用了未注册的分类
- [ ] **批量删 entry "五件套"清理**(Reminder + ThemeAlias + PromptSuggestion + InsightsResultCache + WidgetSnapshot)有没有漏
- [ ] **Widget snapshot V2 schema** 有没有新加正文/snippet 字段(不该加)
- [ ] **`useContextualBody` / 未来 `useContextualPrompt`** 默认值翻转有没有漏 sentinel migration

## 调用示例

用户:`/megareview`

主 agent 该做:
1. 跑摸底 Bash(并行命令)
2. 看仓库规模选 slice × angle 矩阵 + 波次数(Lumory 中等 → 3 波 + Wave 4 FEAT,共 8-10 Opus + 2 Codex)
3. **波次发送**:Wave 1 → 等同步 Agent 回完 → Wave 2 → 等回完 → Wave 3 → 等回完 → Wave 4(每波本身就分钟级,自然错开,不需要显式 sleep)
4. 等 Codex background task 由 codex:rescue 自身机制返回
5. 跑核对(grep + Read + context7 + Lumory 清单)
6. 写 `CodeReview/megareview-*.md` 第一版
7. **Step 5: codex:rescue 二审报告**,根据 verdict 修订
8. 主对话回:报告路径 + P0 数 + OPT-HIGH top-3 + **FEAT-HIGH top-3(分别列出 UI 类 / UX 类 / 新功能类各 1 条)** + codex 二审摘要 + 一句话总结

## 失败模式 / 别这么干

- ❌ **一条消息发 10+ Agent call**:服务器并发限流,部分 subagent 直接挂或排队超时。必须分波。
- ❌ 波次间不等当前波 result 回完就直接发下一波:等于没分波。同步 Agent 必须先全部回收,再发下一波。
- ❌ **跳过 Step 5(codex 复审报告)**:主 agent 自己整合的 report 同样有 Opus 系统性偏弱,二审是质量保证,不是可选。
- ❌ FEAT 视角省略 / UI + UX 只跑一条 → 用户明确要求两边都要看,FEAT 是这个 skill 的核心输出之一,不能省
- ❌ reviewer 把"加 VoiceOver label / 支持 Dynamic Type / 增加色盲对比度"当 finding 写进 report → 必须在核对阶段 drop,user 明确不关注无障碍
- ❌ 把"安全"做成专项 slice / 派一个独立的 backend security audit subagent → 过度审计;让 `general-purpose` 正确性视角在扫的时候顺手扫硬编码 secret 和 SSE 错误关闭就够
- ❌ FEAT prompt 模糊("帮我想想还能加什么") → reviewer 会回一堆产品战略层级的空话。必须限定:小到中改动量 + 已存在功能的体验缺口 / 一致性补齐
- ❌ 用 `/codex:review` 而不是 `codex:rescue`:diff 通常是空的,codex 会直接说"nothing to review"
- ❌ 把所有 subagent 输出原样拼起来当报告 → 量化错误会被原样保留
- ❌ subagent 数量缩水(为省钱跑 3 个) → 失去多视角互补的意义,这个 skill 就是不计成本
- ❌ 跳过核对步骤 → 用户读到错的行号 / 错的"dead code"判断,修了反而引入 regression
- ❌ 给 subagent 模糊 prompt("帮我看看整个仓库") → 视角散,大量重复 + 鸡毛蒜皮 finding
- ❌ slice 不切就一锅塞:让一个 subagent 看 80 个文件,prompt 装不下,context 爆
- ❌ Codex 给 `--write`(默认会加)→ 这是 read-only audit,显式在 prompt 写 "Do NOT edit any files"
- ❌ 把"建议大重构"当 BUG/OPT finding → 重构请走 feature-dev / brainstorming 流程,不是 review
- ❌ FEAT 写成"该做 AI 化 / 大模型 finetune" → 这是产品战略不是 review
