---
name: megareview
description: 不计成本对**整个 repo**(不是 uncommitted diff)做最严的 bug + 优化 + **新功能机会**审计 —— 运行前先问用户本次关注点(全面 / 纯 UIUX / 不含 FEAT / 自定义),然后**一次性并行派发**多个 Opus subagent(各写文件、只回摘要)+ 跑 codex 仓库级 read-only audit(首选 `codex:rescue` skill,缺则 `codex` CLI 兜底,都没有才降级跳过),全部回收后主 agent 交叉核对量化事实并产出分级报告;subagent 可发 ESCALATION 信号让主 agent **动态追派** follow-up agent;**报告写完再让 codex 做一遍最终复审(有 codex 就做)**。用户说"megareview / 整库审查 / 全仓审计 / repo audit / 整个仓库找 bug 和优化点 / 找新功能机会"时触发。
---

# Megareview - 不计成本的整仓审计

和 `/superreview` 同源,但 scope 不一样:
- **superreview**:审 uncommitted changes(working tree / branch diff),commit/push/上架前的关。
- **megareview**(本 skill):审**整个 repository 的现状** —— 找已经在 main 里、可能已经跑了几个月、但没人翻过的 bug + 高价值优化机会 + **可加的新功能 / 可以做得更好的体验点**。不依赖 git diff。

## 核心理念

1. **运行前先问关注点**:每次运行第一件事就是 `AskUserQuestion` 问用户本次想看什么(全面 / 纯 UIUX / 不含 FEAT / 自定义)。关注点直接决定派哪些 angle —— 不要默认全套硬跑。详见 Step 1。
2. **整仓不能一锅端**:把 repo 按目录 + 关注点切成 N 个 slice,每个 subagent 只看一个 slice 一个角度。一锅 prompt "review 整仓"必然糊。
3. **多视角并行 + 跨模型**:Opus(找语义 / 项目约定 / 隐藏耦合 / 产品视角的"可以更好") + Codex(找语法层 bug / 库行为 / 大范围 grep 模式)互补。
4. **三档输出**:这个 skill **不只是找 bug**:
   - **BUG**(P0/P1/P2)— 已经错了
   - **OPT**(HIGH/MID/LOW)— 技术债 / 性能 / 死代码 / 测试空白(internal facing)
   - **FEAT**(HIGH/MID/LOW)— **能加的新功能 + 现在 work 但可以 work 更好的产品/UX 点**(user facing)
   FEAT 是一等公民,不是附录 —— 但**只有用户在 Step 1 选了含 FEAT / 纯 UIUX 才派 FEAT angle**。
5. **一次性并行派发 + 文件落盘**:subagent `model: "opus"`,数量按仓库大小给到 8-15 个,Codex 1-2 个 task,**一条消息里全部并行发出去**(不再分波)。为了不让一次性回来的大量 result 撑爆主 agent context,**每个 subagent 把原始 findings 写到 `CodeReview/.megareview-raw/<slice>-<angle>.md`,return 里只给 ≤200 字摘要 + 文件路径 + ESCALATION**。主 agent 在核对阶段按需逐个 Read 这些 raw 文件。详见 Step 4。
6. **动态追派(fresh eye / 工作量溢出)**:subagent 看下来发现 slice 太大没看完、或某条 finding 影响大但自己拿不准,就在 return 里发结构化 **ESCALATION** 信号。主 agent 全部回收后,针对这些 escalation **追派定向 follow-up agent**(同样写文件、只回摘要),再进核对。subagent **不要自己 spawn** 子 agent(嵌套不可靠),只发信号、由主 agent 追派。详见 Step 5。
7. **主 agent 强制核对**:Opus 在量化精度上系统性偏弱(行号 / 计数 / "未被使用" / 库行为),所有 BUG/OPT finding 主 agent **必须 grep + Read + context7 验证**才能进最终报告。FEAT 不要核对存在性(本来就不存在),但要核对"是否已经实现了"(grep 关键词,别提已有的功能)。
8. **报告做完再让 codex 复审一次(有 codex 就做)**:主 agent 写完 `megareview-*.md` 后,**若 codex 可用**(`codex:rescue` skill 或本机 `codex` CLI),起一个 codex task 读这份报告做"二审"—— 找漏掉的 angle / 误判的等级 / 重复条目 / 主 agent 自己也有 Opus 系统性偏弱的可能。codex 完全不可用就降级跳过并在报告注明。详见 Step 7。

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

### Step 1 — 先问关注点 + 要不要扫 dead code(每次运行必做,最先做)

用**一次** `AskUserQuestion` 同时问两件事:本次审计的重心、以及要不要扫 dead code。**这一步在摸底 Bash 之前做**(答案会影响后面切片 × 视角矩阵,先问省得白跑)。

```
AskUserQuestion({
  questions: [
    {
      header: "关注点",
      question: "本次 megareview 想重点看哪方面?",
      multiSelect: false,
      options: [
        { label: "全面(含未来进步,推荐)", description: "BUG + OPT + FEAT 全套。FEAT 含新功能机会 + UI 视觉 + UX 交互。这是默认最全的一档。" },
        { label: "纯 UI/UX", description: "只看 FEAT 的 UI(视觉/布局/暗色/iPad)+ UX(交互/反馈/动效/空态/haptic)。不派 BUG/OPT,也不派'新功能'angle。" },
        { label: "不含 FEAT(不关注未来进步)", description: "只 BUG + OPT(正确性/并发/数据/SSE/性能/抽象/死代码/测试)。完全不派任何 FEAT angle,报告不出 FEAT 档。" }
      ]
    },
    {
      header: "Dead code",
      question: "要不要扫 dead code(未引用的 func/class/file、注释掉的代码)?",
      multiSelect: false,
      options: [
        { label: "扫(推荐)", description: "派一个 code-simplifier 死代码扫描 angle,整仓找未被引用的符号/文件 + 可删的注释代码。" },
        { label: "不扫", description: "跳过死代码 angle,省一个 subagent + 一段报告噪音。" }
      ]
    }
  ]
})
```

> **关注点那题不要自己加"其他/自定义"选项** —— `AskUserQuestion` 会自动给一个 "Other" 自由输入框,用户想限定重心(如"只看后端" / "只看 CoreData/CloudKit" / "只看性能" / "只看 server + 转写链路")就走 Other 打字,主 agent 按那段文字裁剪 angle 矩阵。手动塞一个固定 label 的"其他"反而没法收自由文本,纯属冗余。

> **Dead code 那题的答案只在"本次含 OPT"时生效**(全面 / 不含 FEAT / 含 OPT 的自定义):答"扫"才派死代码 angle,答"不扫"就不派。**纯 UIUX 没 OPT,死代码 angle 本来就不派,这题答什么都忽略**(照样问无妨,省得分支)。

**关注点(× dead code 开关)→ angle 选择映射**(Step 3 据此裁剪矩阵):

| 用户选 | 派哪些 angle | Codex task |
|---|---|---|
| 全面(含未来进步) | BUG + OPT + FEAT(新功能 + UI + UX)全套;强制视角 coredata / sse;**dead code 看 Q2(扫才派)** | bug task + UX task |
| 纯 UI/UX | 只 FEAT-UI + FEAT-UX;**不派** BUG/OPT/新功能,也跳过 coredata/sse/dead code | 只 UX task |
| 不含 FEAT | BUG + OPT 全套 + 强制视角 coredata / sse;**dead code 看 Q2(扫才派)**;**不派任何** FEAT angle | 只 bug task |
| Other 自由输入(自定义重心) | 按用户打的那段文字裁剪(如"只看后端"→ 只派 backend correctness / API contract / server perf 几条);**含 OPT 且 Q2 答"扫"才加 dead code**;拿不准就回问一句再定 | 按裁剪后的重心选(0-2 个) |

把用户两题的选择都记在心里,Step 6 写报告时报告头部要写明"本次关注点:<选项> / dead code:扫|不扫"。

### Step 2 — 摸底:仓库规模 + 切片策略

并行跑(主 agent 用 Bash),顺手建 raw 落盘目录:

```bash
# raw findings 落盘目录(CodeReview/ 已在 .gitignore)
mkdir -p CodeReview/.megareview-raw
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

按规模决定 subagent 数量(**全部一次性派发**,不分波):

| 仓库规模 | Opus subagents | Codex tasks |
|---|---|---|
| 小(< 5k LoC) | 5-6 | 1 |
| 中(5k-30k LoC) | 8-10 | 1-2 |
| 大(> 30k LoC) | 12-15+ | 2 |

> 数量是"全面"档的上限。Step 1 选了纯 UIUX / 不含 FEAT / 自定义时,按裁剪后的 angle 数实际派(可能就 3-5 个)。**Codex task 数也受关注点限制**,不是按规模硬给 2 个:全面 = bug + UX 两个;纯 UIUX = 只 UX 一个;不含 FEAT = 只 bug 一个;自定义按重心 0-2 个。

### Step 3 — 切片(slice)+ 视角(angle)

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

**按 Step 1 关注点裁剪矩阵**:
- **全面**:下面"强制视角"全召唤 + BUG/OPT/FEAT 全套
- **纯 UI/UX**:只派 FEAT-UI + FEAT-UX(可按 view slice 各拆 1-2 个);**不派** coredata/sse/dead code/bug/opt
- **不含 FEAT**:派 BUG + OPT + 强制视角;**一个 FEAT angle 都不派**
- **其他**:按用户描述只留相关 angle

**Lumory 强制视角** —— 分两组,各自的 gating 不同,**别把两组的触发条件混起来**:

*A. BUG/数据强制视角*(**全面** 或 **不含 FEAT** 时召唤;**纯 UIUX** 跳过):
- `coredata-migration-reviewer` 看 Models/Persistence + 任何动 `DiaryEntry` schema 的服务
- `sse-pipeline-reviewer` 看 AI/Network/SSE slice(项目自带 agent)
- 死代码扫(整仓,`code-simplifier:code-simplifier`):**只有 Step 1 Q2 答"扫"才派**;答"不扫"就跳过这一个 angle

*B. FEAT 强制视角*(**全面** 或 **纯 UIUX** 时召唤;**不含 FEAT** 跳过):
- 新功能(**仅全面**;纯 UIUX 不派新功能)+ UI(视觉/布局)+ UX(交互/反馈),各至少 1 个(user 明确要求重点关注 UI 和 UX)

*两组都适用的禁令*:
- **不要召唤"无障碍 / accessibility / VoiceOver / Dynamic Type"专项视角** —— user 明确不关注这块,reviewer 顺便提到也要主 agent 在核对时全部 drop
- **不要把"安全"做成专项 slice** —— Lumory 不需要 OWASP 级审计;只让 `general-purpose` 正确性视角在扫的时候顺手扫一下硬编码 secret 和 SSE 错误关闭就够了(真要深度 OWASP 才换 `code-modernization:security-auditor`)

### Step 4 — **一次性并行派发**(一条消息里全发)

**关键改动**:不再分波。Step 3 裁剪出来的所有 Opus subagent + 所有 Codex task,**在一条消息里同时发出去**。Opus subagent 同步阻塞,会一起回来;Codex task 是 `--background` 不阻塞。

**为什么靠"文件落盘"撑住 context**:一次性回来的 8-15 个 result 如果都把全文塞进 return,主 agent context 会爆。所以**每个 subagent 必须把原始 findings 写文件、return 只回摘要**(见下面 prompt 模板)。主 agent 在 Step 5/6 按需逐个 Read raw 文件,而不是一次性吃 15 份大 result。

**如果个别 subagent 回来 fail / 排队超时**:只**单独重发那一个**(同一条消息只补发失败的),不要回退成分波架构。

**示意结构**(伪代码,一条消息内全部并行):

```
# 单条消息,全部并行(以"全面"档为例)
  Agent { subagent_type: "coredata-migration-reviewer", model: "opus", description: "Models/Persistence data review", ... }
  Agent { subagent_type: "sse-pipeline-reviewer", model: "opus", description: "AI/SSE pipeline review", ... }
  Agent { subagent_type: "code-simplifier:code-simplifier", model: "opus", description: "Dead code scan (整仓)", ... }   # 仅 Step 1 Q2 答"扫"才发
  Agent { subagent_type: "general-purpose", model: "opus", description: "Concurrency review on AI/Network", ... }
  Agent { subagent_type: "general-purpose", model: "opus", description: "Backend correctness (server/index.js)", ... }
  Agent { subagent_type: "general-purpose", model: "opus", description: "Home VM stack correctness", ... }
  Agent { subagent_type: "general-purpose", model: "opus", description: "Perf hot paths", ... }
  Agent { subagent_type: "general-purpose", model: "opus", description: "Test coverage gaps", ... }
  Agent { subagent_type: "general-purpose", model: "opus", description: "FEAT: UI consistency (visual/layout/liquidGlass/暗色/iPad)", ... }
  Agent { subagent_type: "general-purpose", model: "opus", description: "FEAT: UX polish (loading/empty/error/haptic/动效/一致性)", ... }
  Agent { subagent_type: "general-purpose", model: "opus", description: "FEAT: new feature opportunities", ... }
  # codex 紧跟 Opus 批次后台发(见下面"Codex 任务"小节)—— 首选 codex:rescue skill / CLI 兜底,后台跑不阻塞核对:
  Skill({ skill: "codex:rescue", args: "--background --fresh 「<bug audit prompt>」" })    # 首选:read-only(别传 --write),结果回对话
  Skill({ skill: "codex:rescue", args: "--background --fresh 「<UX audit prompt>」" })     # 全面 / 纯 UIUX 才发
  # 兜底(会话没 codex:rescue skill 时,这条可跟上面 Agent 批次同一条消息并行发):
  #   Bash (run_in_background) { codex exec --sandbox read-only "<同一段 prompt>" > CodeReview/.megareview-raw/codex-bug.md 2>&1 }
```

**每个 Opus subagent prompt 必须包含**:
- **本次审计目标 + 关注点**:把 Step 1 用户选的关注点写进去("本次只看 UI/UX,别报 bug/opt" 之类),并说明"找仓库已存在的问题/机会,这不是 diff review"
- **slice 文件清单**(具体路径,别让 agent 自己猜)
- **专项 angle**(只看这个角度,其他 angle 别人会看)
- **写文件 + 回摘要(强制)**:
  > 把你完整的 findings 写到 `CodeReview/.megareview-raw/<slice>-<angle>.md`(用 Write 工具,文件不存在就建)。你的 return **只回**:(1) ≤200 字摘要 — 提了几条、最重的 2-3 条标题;(2) 你写的文件路径;(3) ESCALATION(没有就写"无")。**不要在 return 里贴全文 findings。**
  - ⚠️ **没有 Write 工具的 subagent**(`coredata-migration-reviewer` / `sse-pipeline-reviewer` / 多数 `code-modernization:*` 只有 Read/Grep/Glob/Bash)用不了 Write。给这类 agent 的 prompt 改成:**用 Bash 写文件**(`cat > CodeReview/.megareview-raw/<slice>-<angle>.md <<'EOF' … EOF`)。**派之前先想清楚目标 agent 有没有 Write,没有就别在 prompt 里写"用 Write 工具"。**
  - **唯一允许 inline 回全文的例外**:`coredata-migration-reviewer` / `sse-pipeline-reviewer` 这两个项目 reviewer —— slice 窄、findings 有限,如果连 Bash 写文件都不便,可直接在 return 里贴全文(主 agent 接受)。**其他所有 agent(尤其 `general-purpose` 全仓视角)一律写文件、只回摘要,不准 inline 全文** —— 这是对"return 不贴全文"硬规则的唯一豁免。
- **ESCALATION 信号格式**(强制说明):
  > 如果出现下面任一情况,在 return 末尾加 ESCALATION 块:
  > - `ESCALATION COVERAGE: 本 slice 文件太多/太复杂,我只彻底看了 <files>,建议对 <remaining files/区域> 追派一个 pass`
  > - `ESCALATION FRESH-EYE: finding "<标题>"(<file:line>)影响大但我拿不准/可能误判,建议独立第二只眼复核`
  > 没有就写 `ESCALATION: 无`。**不要自己 spawn 子 agent —— 只发信号,主 agent 会追派。**
- **输出格式**(写进 raw 文件的每条):`[BUG-P0/P1/P2 | OPT-HIGH/MID/LOW | FEAT-HIGH/MID/LOW] file:line — 一句话标题 — 问题/机会描述 — 建议 — 证据(代码片段或调用链;FEAT 类给"为什么用户会受益"的理由)`
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

#### Codex 任务(跨模型交叉校验 —— 紧跟主批次后台发)

⚠️ **codex 走插件优先,`codex exec` CLI 只是兜底**。codex 插件(`codex@openai-codex` marketplace,2026-05-20 装上)提供 `/codex:*` slash command + `codex:codex-rescue` subagent,但其中 **`/codex:review` / `/codex:adversarial-review` / `/codex:status` / `/codex:result` / `/codex:cancel` 全是 `disable-model-invocation: true`,主 agent 用 Skill 工具调不动**(只有用户手敲才触发,不在会话 skill 列表里)。**`codex:rescue` 是 codex 插件里唯一能被主 agent 程序化调用的入口**,megareview 的仓库级 audit 正好走它(自由 prompt,不是 diff review)。调用优先级:
1. **首选:`codex:rescue` skill**(会话起点的可用 skill 列表里有 `codex:rescue` 才用 —— 没 `/reload-plugins` / scope 没启用时它不在列表,盲发会 "skill not found" 硬失败,所以**调用前先看会话 skill 列表**):
   ```
   Skill({ skill: "codex:rescue", args: "--background --fresh 「<audit prompt>」" })
   ```
   底层 `task` 默认 `--sandbox read-only`(**别传 `--write`**)。结果**回到对话、不落文件**;主 agent 在核对阶段直接读它返回的 findings(要留档自己 Write 到 `CodeReview/.megareview-raw/codex-*.md`)。**Skill 调用没法跟 Opus 的 Agent 批次塞进同一个并行 tool-batch**,所以 Opus 批次发完紧接着发 codex:rescue(仍 `--background`,仍在核对前)。
2. **兜底:`codex` CLI**(本机 `/opt/homebrew/bin/codex`,会话没有 `codex:rescue` skill 时):走 **Bash + `run_in_background`**,`--sandbox read-only`,输出重定向到 raw 文件 —— 这条 CLI 命令**可以**跟 Opus Agent 批次同一条消息并行发。
3. **两者都没有 / codex 未登录** → **跳过 codex**,在报告里注明"本次缺跨模型交叉校验"。**codex 是增强,不是出报告的硬依赖**,绝不能因为 codex 调不动就让整个 megareview 卡死。

**不要**用 `/codex:review` / `/codex:adversarial-review` / `codex exec review` 跑整仓 audit —— 它们只看 git diff,megareview 场景 diff 通常是空的,会回 "nothing to review"。要用**自由 prompt**:`codex:rescue` skill(首选)或 `codex exec "<自由 prompt>"`(CLI 兜底,**不是** review 子命令)。

两段 audit prompt 如下(prompt 文本与调用方式无关 —— 首选塞进 `codex:rescue --fresh`,兜底塞进 `codex exec`)。

Bug-focused(选了全面 / 不含 FEAT 时发):
> Audit the entire Lumory repository read-only. Do NOT edit any files. Find: latent bugs (concurrency, error handling, edge cases, data integrity) and high-ROI optimizations (perf hot paths, dead code, repeated logic). Focus on Chronote/Services and server/index.js first. Skip security/OWASP analysis — only flag obvious things like hardcoded secrets or fail-open auth regressions. Output a prioritized list with file:line evidence. Do not run builds or tests.

UX-focused(选了全面 / 纯 UIUX 时发):
> Audit Lumory read-only for UI consistency + UX polish opportunities. UI: visual / spacing / liquidGlass / 暗色模式 / iPad layout / 跨 view 风格漂移. UX: empty states, error toasts, loading states, missing haptic feedback, animation gaps or inconsistencies, i18n string gaps. Skip accessibility entirely — no VoiceOver, no Dynamic Type, no ARIA. Output as FEAT-HIGH/MID/LOW with file:line and a one-sentence user-benefit rationale.

**首选(插件,结果回对话;读它返回的 findings,需要留档就自己 Write 到 raw 文件)**:

```
Skill({ skill: "codex:rescue", args: "--background --fresh 「<上面对应那段 prompt>」" })
```

**兜底(CLI,结果落 raw 文件,完成后 Read 它)**:

```bash
# Bash run_in_background
codex exec --sandbox read-only "<上面对应那段 prompt>" > CodeReview/.megareview-raw/codex-bug.md 2>&1   # UX 那条改成 codex-ux.md
```

### Step 5 — 全部回收 + 动态追派 + 主 agent 核对(最关键 — 不要跳)

所有 Opus subagent 同步回完后,主 agent 拿到的是一堆**摘要 + raw 文件路径 + ESCALATION**。Codex 是后台跑的,按 Step 4 用的路径收结果:
- **codex:rescue skill 路径(首选)**:`--background` 的 codex:rescue 完成时主 agent 收到后台 task 通知,直接读它返回的 findings(结果回对话、不落文件);要留档就自己 Write 一份到 `CodeReview/.megareview-raw/codex-*.md`。`/codex:status` / `/codex:result` 是 `disable-model-invocation`,主 agent **调不动**,别去 poll —— 等通知即可。
- **CLI 兜底路径**:`codex exec` 走 Bash `run_in_background`,完成时你会被通知,然后 Read `CodeReview/.megareview-raw/codex-bug.md` / `codex-ux.md` 拿结果。
- **codex 跳过了**(没 CLI 没 skill / 未登录):直接进核对,报告里注明缺跨模型校验。

**Codex 还在跑就等**(不计成本),但**别为了等 codex 阻塞核对** —— 先把 Opus findings 的核对做了,codex 结果回来再并进去。

#### A. 先处理 ESCALATION(动态追派)

扫所有 subagent return 里的 ESCALATION 块:
- **COVERAGE 型**(slice 没看完):对没覆盖到的文件/区域,**追派一个 `general-purpose` opus follow-up agent**(同样写 `CodeReview/.megareview-raw/<slice>-<angle>-followup.md`、只回摘要),focus 限定在 reviewer 说没看完的那块。
- **FRESH-EYE 型**(某 finding 拿不准):**追派一个独立 `general-purpose` opus agent**,prompt 里**不告诉它原 reviewer 的结论**(避免锚定),只给文件位置 + "独立判断这里有没有 <问题类别>",拿它的独立结论跟原 finding 对照 —— 两边都说有 = 可信度↑,只一边说有 = 进"待确认"。
- **追派也是一次性并行发**(如果有多条 escalation,凑一条消息一起发),回完再继续核对。
- **软上限**:追派一般 ≤ 3-4 个就够;真有大面积没覆盖再多发一轮。不计成本,但别无脑递归。

#### B. 读 raw 文件 + 去重 + 合并

**不能**直接合并 paste。逐个 Read `CodeReview/.megareview-raw/*.md`(一个 slice 一个 slice 读,别一次性全 Read 进来撑 context),然后:
- 同一处问题被多个 reviewer 提到 → 合一条,credit 多个来源(可信度↑)
- finding 之间互相矛盾 → 标"冲突",自己读代码裁决
- BUG / OPT / FEAT 分三堆,**不混着写**

#### C. 量化事实核对(Opus 系统性弱点 — 必查)

> **按关注点对应做**:纯 UIUX 模式没有 BUG/OPT finding,下面这张 BUG/OPT 核对表自然跳过,只做后面"FEAT 的核对";不含 FEAT 模式则反过来,只做 BUG/OPT 表、不做 FEAT 核对。

对每条 BUG/OPT finding 中的:**计数 / 行号 / 文件位置 / "未被使用" / "dead code" / "X 处" / 库行为陈述**,主 agent 必须验证:

| 陈述类型 | 验证手段 |
|---|---|
| "有 N 个 X" | `Grep` 实数一遍 |
| 行号 / 文件位置 | `Read` 那个文件区间确认 |
| "此 helper / class / file 没业务 caller" | `Grep` 函数名 + 类名全仓搜,**包括** 测试目录、xcconfig、storyboard、plist |
| "库 X 不会做 Y" | 用 context7 的 `query-docs`(MCP,名字随安装变,会话起点的工具列表为准)查官方文档,**别**信 subagent 记忆 |
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

#### D. 分级校准

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

### Step 6 — 写第一版报告

写到 `CodeReview/megareview-YYYYMMDD-HHmm.md`(`CodeReview/` 已在 .gitignore;如未在则加上)。**只出本次实际派了 angle 的那些档**(纯 UIUX 就只出 FEAT;不含 FEAT 就不出 FEAT 档;Other 自定义就只出该重心对应的档,比如"只看后端"可能就一个 Bug + 一个 OPT 档,没有的档整段不写)。

```markdown
# Megareview Report — <YYYY-MM-DD HH:mm>

## 仓库概览
- 本次关注点:<Step 1 用户选的选项> / dead code:<扫 | 不扫>
- 总文件 / LoC / 顶层目录分布
- 最近 90 天 churn 热点文件 top N
- TODO/FIXME 总数
- 触发的视角:[列出 subagent 视角 + slice 清单;含动态追派了几个 follow-up + 为什么]

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
| Slice | Angle | subagent | 提了 N 条 | 命中率 | 追派? |
|---|---|---|---|---|---|
| Models/Persistence | data | coredata-migration-reviewer | 5 | 4/5 | — |
| AI/SSE | sse-pipeline | sse-pipeline-reviewer | 3 | 3/3 | — |
| 整仓 | bug audit | codex (rescue) | 12 | 9/12 | — |
| Insights | UX/polish | general-purpose | 8 | 7/8 | followup×1 (COVERAGE) |
```

### Step 7 — codex 复审报告(有 codex 就做,没有就降级)

主 agent **不能信任自己**(Opus 系统性偏弱也适用于自己整合的报告 —— 可能漏 angle、误判等级、重复条目没发现)。报告 `megareview-YYYYMMDD-HHmm.md` 写完后,**若 codex 可用**(优先级同 Step 4:首选 `codex:rescue` skill,兜底 `codex` CLI),起一个 codex 二审。

**首选(插件)**:`Skill({ skill: "codex:rescue", args: "--background --fresh 「<下面 bash 块里那段英文 prompt>」" })`,read-only(别传 `--write`),完成后读它返回的 verdict。

**兜底(CLI)**(Bash `run_in_background`,完成后 Read `CodeReview/.megareview-raw/codex-review.md`):

```bash
codex exec --sandbox read-only "Read the megareview report at CodeReview/megareview-<YYYYMMDD-HHmm>.md. Do NOT edit any files. Critique it: (1) Are any P0/P1/OPT-HIGH/FEAT-HIGH items mis-prioritized (too high or too low) given the actual codebase impact? (2) Are there obvious BUG / OPT / FEAT angles the report missed entirely (do a sanity grep across Chronote/ and server/ for things like force-unwraps, retained-cycle risks, unused public APIs, hardcoded English in zh-Hans paths, UI/UX inconsistencies across views)? (3) Any duplicate findings that should be merged? (4) Any '已否决' items that were actually correct and should be reinstated? Skip accessibility entirely (no VoiceOver / Dynamic Type / ARIA — user explicitly excluded this scope). Skip OWASP-style security analysis — only flag if you see hardcoded secrets or fail-open auth. Output verdict per existing finding (KEEP / DOWNGRADE / UPGRADE / DROP) plus a list of missed findings. Read-only — do not modify the report file." > CodeReview/.megareview-raw/codex-review.md 2>&1
```

> 同一段 prompt 既可塞进上面"首选"的 `codex:rescue`,也可塞进"兜底"的 `codex exec`。

> 二审范围跟着 Step 1 关注点走:纯 UIUX 就让 codex 只复审 FEAT 部分;不含 FEAT 就把上面 prompt 里的 FEAT 字样删掉。
> **codex 完全不可用时**(没 CLI 没 skill / 未登录):**跳过本步**,在报告头部注明"未做 codex 二审(环境无 codex)",自己再扫一遍 Step 5-C 的高风险条目当兜底 —— 但要诚实标注**这不是跨模型校验**,只是 Opus 自查。

拿到 codex 二审结果后:
- **Verdict 表**:跟主 agent 自己的判断逐条对一遍。codex 升降级理由如果合理 → 接受并改 report;不合理 → 在 report 末尾"复审反驳"小节写为什么不接受
- **Missed findings**:逐条核对(同 Step 5-C 的核对手段 —— grep + Read);确认存在的话补进 report 对应分级
- **重复合并**:接受
- 如果 codex 复审产出超过 3 条主 agent 接受的修订 → 在报告头部加一行"经 codex 二审,X 条调整 / Y 条新增"

最后在 report 末尾加一段:

```markdown
## Codex 二审结果(Step 7)
- 复审时间:<timestamp>
- 调整:<keep/upgrade/downgrade/drop 计数>
- 新增 finding:<N> 条(已并入对应分级)
- 主 agent 反驳:<列出不接受 codex 调整的条目 + 理由>
```

### Step 8 — 主对话回报

主对话**只回**:
- 本次关注点(Step 1 选项)
- 报告路径
- BUG-P0 数量 + 标题(全列)— 若本次不含 BUG 档则跳过
- OPT-HIGH 前 3 条标题 — 若不含 OPT 档则跳过
- **FEAT-HIGH 前 3 条标题** — 若含 FEAT,按本次实际跑的 FEAT angle 各列 1 条(全面 = UI / UX / 新功能 各 1;纯 UIUX = UI / UX 各 1,无新功能)
- 动态追派了几个 follow-up + 为什么(1 句)
- Codex 二审带来的关键修订(1-2 句)
- 一句话整体观感(技术债集中在哪 / 哪个模块最值得动 / 哪条 FEAT 最该排上日程)

**不要 paste 全文**,用户去文件看。

## Lumory 项目专属核对清单

主 agent 在 Step 5 的核对阶段,拿这份清单过一遍 finding 是否覆盖了已知踩坑(reviewer 没提就该自己补的)。**这是一份 bug/数据/SSE 清单 —— 选了"纯 UIUX"时整份跳过**(里面没有 UI/UX 项,过了也是空);全面 / 不含 FEAT / 相关自定义重心才用:

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
1. **Step 1**:`AskUserQuestion` 一次问两题 —— 关注点(全面 / 纯 UIUX / 不含 FEAT / 自定义)+ 要不要扫 dead code(扫 / 不扫;只在含 OPT 时生效)
2. 跑摸底 Bash(并行命令)+ `mkdir -p CodeReview/.megareview-raw`
3. 看仓库规模 + 关注点定 slice × angle 矩阵(Lumory 中等 + 全面 → 8-10 Opus + 2 Codex;纯 UIUX → 3-5 Opus + 1 Codex)
4. **一次性并行派发**:一条消息里把所有 Opus subagent + Codex task 全发出去(各写文件、只回摘要、带 ESCALATION 说明)
5. 全部 Opus 同步回完 → **先处理 ESCALATION 动态追派**(COVERAGE / FRESH-EYE)→ 等 Codex 后台结果(codex:rescue 回完读它返回的 findings / CLI 兜底回完读 raw 文件;codex 不可用就跳过并注明)
6. 跑核对(逐个 Read raw 文件 + grep + Read + context7 + Lumory 清单)
7. 写 `CodeReview/megareview-*.md` 第一版(只出选了的档)
8. **Step 7: codex 二审报告**(首选 codex:rescue skill / 兜底 CLI,缺则降级跳过 + 注明),根据 verdict 修订
9. 主对话回:关注点 + 报告路径 + P0 数 + OPT-HIGH top-3 + **FEAT-HIGH top-3(UI / UX / 新功能各 1)** + 追派情况 + codex 二审摘要 + 一句话总结

## 失败模式 / 别这么干

- ❌ **跳过 Step 1 的两题(关注点 + dead code)**:直接默认全套硬跑。用户明确要求每次先问这两题;选了纯 UIUX 还派一堆 bug/opt agent、或答了"不扫"还派死代码 angle = 浪费 + 噪音。
- ❌ **subagent return 里贴全文 findings**:一次性回来 10+ 份全文会撑爆主 agent context。必须写文件、只回摘要 —— 这是"一次性派发"能成立的前提。
- ❌ **subagent 自己 spawn 子 agent**:嵌套不可靠。只发 ESCALATION 信号,由主 agent 追派。
- ❌ **忽略 ESCALATION**:reviewer 说 slice 没看完 / 某 finding 拿不准,主 agent 不追派直接写报告 → 漏覆盖 + 高风险 finding 没二次确认。
- ❌ **codex 可用却跳过 Step 7**:主 agent 自己整合的 report 同样有 Opus 系统性偏弱,有 codex 就一定要做二审。(codex 真的不可用 → 降级跳过 + 报告注明,是允许的,不算违规。)
- ❌ **盲发 `Skill({ skill: "codex:rescue" })` 不先确认它在不在会话 skill 列表**:codex 插件虽已装,但某 scope 没启用 / 没 `/reload-plugins` 时仍会 "skill not found" 硬失败。先看会话起点的可用 skill 列表,不在就走 `codex` CLI。
- ❌ 选了"全面 / 纯 UIUX"却把 UI + UX 只跑一条 → 用户明确要求两边都要看,FEAT 是这个 skill 的核心输出之一。
- ❌ reviewer 把"加 VoiceOver label / 支持 Dynamic Type / 增加色盲对比度"当 finding 写进 report → 必须在核对阶段 drop,user 明确不关注无障碍。
- ❌ 把"安全"做成专项 slice / 派一个独立的 backend security audit subagent → 过度审计;让 `general-purpose` 正确性视角在扫的时候顺手扫硬编码 secret 和 SSE 错误关闭就够。
- ❌ FEAT prompt 模糊("帮我想想还能加什么") → reviewer 会回一堆产品战略层级的空话。必须限定:小到中改动量 + 已存在功能的体验缺口 / 一致性补齐。
- ❌ 用 `/codex:review` / `/codex:adversarial-review` / `codex exec review` 跑整仓 audit:它们只看 git diff(megareview diff 通常是空的,回 "nothing to review"),且 `/codex:*` review 命令是 `disable-model-invocation`、主 agent 根本调不动。要用自由 prompt 走 `codex:rescue` skill(首选)/ `codex exec "<自由 prompt>"`(兜底)。
- ❌ 把所有 subagent 输出原样拼起来当报告 → 量化错误会被原样保留。
- ❌ subagent 数量缩水(为省钱跑 3 个) → 失去多视角互补的意义,这个 skill 就是不计成本(纯 UIUX 等裁剪场景天然就少,不算缩水)。
- ❌ 跳过核对步骤 → 用户读到错的行号 / 错的"dead code"判断,修了反而引入 regression。
- ❌ 给 subagent 模糊 prompt("帮我看看整个仓库") → 视角散,大量重复 + 鸡毛蒜皮 finding。
- ❌ slice 不切就一锅塞:让一个 subagent 看 80 个文件,prompt 装不下,context 爆。
- ❌ Codex 不带 `--sandbox read-only`(CLI)/ 给 `--write`(codex:rescue)→ 这是 read-only audit,CLI 必须 `--sandbox read-only` + prompt 里写 "Do NOT edit any files"。
- ❌ 把"建议大重构"当 BUG/OPT finding → 重构请走 feature-dev / brainstorming 流程,不是 review。
- ❌ FEAT 写成"该做 AI 化 / 大模型 finetune" → 这是产品战略不是 review。
