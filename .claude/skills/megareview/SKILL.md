---
name: megareview
description: 不计成本对**整个 repo**(不是 uncommitted diff)做最严的 bug + 优化 + **新功能机会**审计 —— 运行前先问用户本次关注点(全面 / 纯 UIUX / 不含 FEAT / 自定义)+ 要不要扫 dead code,然后**调用 `.claude/workflows/megareview.mjs` Workflow**(确定性编排:pipeline 边审边核 + escalation 动态追派 + 结构化 schema),拿回已核对的分级 findings 后主 agent 写报告;**报告写完再让 codex 做一遍最终复审(有 codex 就做)**。用户说"megareview / 整库审查 / 全仓审计 / repo audit / 整个仓库找 bug 和优化点 / 找新功能机会"时触发。
---

# Megareview — 不计成本的整仓审计(Workflow 驱动)

和 `/superreview` 同源,scope 不一样:
- **superreview**:审 uncommitted changes(working tree / branch diff),commit/push/上架前的关。
- **megareview**(本 skill):审**整个 repository 的现状** —— 找已经在 main 里、可能跑了几个月没人翻过的 bug + 高价值优化机会 + **可加的新功能 / 可以做得更好的体验点**。不依赖 git diff。

## 架构(2026-05-28 重构:Workflow 驱动)

**编排机制全部下沉到确定性 JS 脚本** [`.claude/workflows/megareview.mjs`](../../workflows/megareview.mjs),skill 只是薄壳:
- **薄壳层(主 agent,本文件)**:问关注点 → 摸底 Bash → 启动 Workflow → 收结构化结果写报告 → codex 二审 → 回报。这些是必须在主 agent 层做的(AskUserQuestion 脚本内弹不了、codex:rescue 脚本内调不动)。
- **引擎层(Workflow 脚本)**:Lumory slice 图 + 16 条核对清单 + angle 矩阵 + 三档 schema 都内置在脚本里。`pipeline(review→verify)` 无 barrier 边审边核,`escalation` 全局 cap 动态追派,结构化 schema 把 findings 回到**脚本运行时**而不是主 agent context。

**为什么这样比旧版稳**:旧版"写文件落盘 + return 只回摘要 + 没 Write 工具用 Bash 写"那套防 context 爆的 hack —— Workflow 用 schema 从结构上消灭了(reviewer 结构化输出回脚本,不灌主 context;tool-limited 的 coredata/sse reviewer 也能靠 StructuredOutput 返回,不需要 Write)。"一次性并行不分波""先 find 后 verify""ESCALATION 手动追派"全变成脚本里的 `pipeline`/`parallel`/控制流,确定性执行不靠主 agent 自觉。

## 何时触发

- 用户输入 `/megareview` 或说"megareview / 整库审查 / 全仓审计 / repo audit / 把整个仓库扒一遍找 bug / 找优化点 / 看看还能加什么功能 / 现在哪里可以做得更好"
- 大版本上线前 / 季度技术债盘点 / 接手老代码摸底 / 想要新一轮 roadmap 候选
- superreview 跑过 diff 但怀疑老代码也有问题

## 何时**不**该用

- 只关心最近这次改动 → 用 `/superreview`
- 只想知道"这个文件有没有 bug" → 起一个 `general-purpose` subagent 直接看
- 仓库刚 init,代码量 < 500 行 → 一个 reviewer 就够
- 用户想的是"重构这块" → feature-dev / brainstorming 流程,不是 review

## 流程

### Step 1 — 先问关注点 + 要不要扫 dead code(每次必做,最先做)

用**一次** `AskUserQuestion` 同时问两件事。**在摸底 Bash 之前做**(答案决定 workflow 的 focus 参数)。

```
AskUserQuestion({
  questions: [
    {
      header: "关注点",
      question: "本次 megareview 想重点看哪方面?",
      multiSelect: false,
      options: [
        { label: "全面(含未来进步,推荐)", description: "BUG + OPT + FEAT 全套。FEAT 含新功能机会 + UI 视觉 + UX 交互。最全的一档。" },
        { label: "纯 UI/UX", description: "只看 FEAT 的 UI(视觉/布局/暗色/iPad)+ UX(交互/反馈/动效/空态/haptic)。不派 BUG/OPT,也不派'新功能'angle。" },
        { label: "不含 FEAT(不关注未来进步)", description: "只 BUG + OPT(正确性/并发/数据/SSE/性能/抽象/死代码/测试)。完全不派 FEAT angle。" }
      ]
    },
    {
      header: "Dead code",
      question: "要不要扫 dead code(未引用的 func/class/file、注释掉的代码)?",
      multiSelect: false,
      options: [
        { label: "扫(推荐)", description: "加一个 code-simplifier 死代码扫描 angle,整仓找未被引用的符号/文件 + 可删的注释代码。" },
        { label: "不扫", description: "跳过死代码 angle,省一个 reviewer + 一段报告噪音。" }
      ]
    }
  ]
})
```

> **关注点那题不要自己加"其他/自定义"选项** —— `AskUserQuestion` 自动给 "Other" 自由输入框。用户想限定重心(如"只看后端" / "只看 CoreData/CloudKit" / "只看性能")就走 Other 打字。
>
> **Dead code 那题只在"本次含 OPT"时生效**(全面 / 不含 FEAT / 含 OPT 的自定义):答"扫"才加死代码 angle。纯 UIUX 没 OPT,这题答什么都忽略(workflow 内部已 gate)。

**两题答案 → workflow `focus` 参数映射**:

| 用户选 | focus | deadCode |
|---|---|---|
| 全面(含未来进步) | `"full"` | Q2 的布尔 |
| 纯 UI/UX | `"uiux"` | (忽略,传 false) |
| 不含 FEAT | `"nobug"` | Q2 的布尔 |
| Other 自由输入 | `"custom"` + `customFocusText`(原文)+ `customAssignmentKeys`(你按描述从下面 key 表里挑) | Q2 的布尔 |

`customAssignmentKeys` 可选 key(见 workflow 脚本 `ALL_ASSIGNMENTS`):`data` `sse` `concurrency` `backend` `home_correctness` `detail_correctness` `reminder_correctness` `perf` `abstraction` `tests` `checklist` `feat_ui` `feat_ux` `feat_new`(`deadcode` 由 deadCode 布尔自动加,别手列)。例:用户说"只看后端" → `customAssignmentKeys: ["backend"]`;"只看 CoreData/CloudKit" → `["data"]`;"只看性能" → `["perf"]`。拿不准就回问一句再定。不传 `customAssignmentKeys` 则 workflow 默认跑 full 全套。

### Step 2 — 摸底:仓库规模(并行 Bash)

```bash
mkdir -p CodeReview
# 总体规模
git ls-files | wc -l
git ls-files | xargs -I {} wc -l {} 2>/dev/null | tail -1
# 最近 90 天 churn 热点(风险高)
git log --since=90.days --name-only --pretty=format: | sort | uniq -c | sort -rn | head -12
# 大文件(>500 行,重构候选)
git ls-files | xargs wc -l 2>/dev/null | awk '$1>500 && $2!="total"' | sort -rn | head -15
# TODO/FIXME 总数
git grep -nE 'TODO|FIXME|HACK|XXX|@deprecated' -- '*.swift' '*.js' '*.ts' | wc -l
```

把结果整理成 `repo` 对象传给 workflow:`{ totalFiles, totalLoc, churnHot: [文件名数组], todoCount, bigFiles: [文件名数组] }`。

### Step 3 — 启动 Workflow(编排全在脚本里)

> ⚠️ 本 skill 是 Workflow 的合法 opt-in 入口(skill 指令明确要求调 Workflow)。

```
Workflow({
  scriptPath: ".claude/workflows/megareview.mjs",
  args: {
    focus: "full" | "uiux" | "nobug" | "custom",
    deadCode: <bool>,
    customFocusText: "<仅 custom:用户 Other 原文>",
    customAssignmentKeys: ["<仅 custom:挑的 key>"],
    repo: { totalFiles, totalLoc, churnHot: [...], todoCount, bigFiles: [...] }
  }
})
```

Workflow 是后台跑的,返回 task ID,完成时你会被通知。它内部:
1. 按 focus 裁 assignment(full ≈ 13-14 个 reviewer + dead code;uiux ≈ 2;nobug ≈ 11)
2. `pipeline`:每个 (slice,angle) 一个 opus reviewer 出结构化 findings → **立刻**并行送 verify agent grep/Read/context7 核对量化事实(无 barrier,边审边核)
3. 收 escalation(COVERAGE/FRESH_EYE)全局 cap 4 → 动态追派 follow-up(同样 review→verify)
4. 返回 `{ focus, deadCode, repo, assignmentsRun, escalations, counts, kept, rejected }`

`kept` = 已核对未否决的 findings(每条带 `verdict` 的 `correctedFile/correctedLine/correctedSeverity` 校准);`rejected` = 核对不通过的(写进报告"已否决"区)。

**别在主 agent 里重复 workflow 已做的 grep 核对** —— verify stage 已经做了。主 agent 只做 workflow 没覆盖的事(见 Step 4)。

### Step 4 — 收结果 + 主 agent 补位 + 写报告

Workflow 回来后,findings 已结构化、已核对。主 agent 做三件 workflow 没做的:

1. **分级校准复核**:用每条 finding 的 `verdict`:`CORRECTED` → 用 `corrected*` 覆盖原 file/line/severity;`REJECTED` → 进"已否决"区;`UNVERIFIABLE` → 降级到"待确认",**不进 P0/P1/HIGH**。
2. **去重合并**:同一处被多个 reviewer 提到 → 合一条 credit 多来源(可信度↑);矛盾的 → 标"冲突",Read 代码自己裁决。
3. **写报告** `CodeReview/megareview-YYYYMMDD-HHmm.md`(`CodeReview/` 已在 .gitignore;如未在则加上)。**只出本次实际派了 angle 的档**(uiux 只出 FEAT;nobug 不出 FEAT;custom 按所跑 assignment 的 category 出)。

报告结构:

```markdown
# Megareview Report — <YYYY-MM-DD HH:mm>

## 仓库概览
- 本次关注点:<full|uiux|nobug|custom 原文> / dead code:<扫|不扫>
- 总文件 / LoC / 顶层目录分布 / churn 热点 top N / TODO 总数
- 触发的 reviewer:<workflow assignmentsRun 列表 + 动态追派了几个 escalation + 类型>

## Bug — P0(必修) / P1(应修) / P2(nice to fix)
### 1. <一句话标题>
- **来源**:<reviewer label>(多个来源就都列,可信度↑)
- **位置**:`file:line`(用 verdict 校准后的)
- **问题** / **核对**(verdict note)/ **建议修复**

## 优化 — OPT-HIGH / OPT-MID / OPT-LOW
(同结构,OPT-HIGH 写预估收益,如"删 ~120 行")

## 新功能 / 体验改进 — FEAT-HIGH / FEAT-MID / FEAT-LOW
(每条:现状 / 机会 / 核对"是否已实现" / 改动量 / 用户受益)

## 待确认(verdict=UNVERIFIABLE)
## 已否决(verdict=REJECTED,写否决理由)

## Reviewer 矩阵
| Slice·Angle | category | 提了 N 条 | 核对后保留 | 追派? |
```

**分级口径**(workflow verify 已初校,主 agent 终校一遍):
- BUG:**P0** 确定复现的 crash/数据丢失/鉴权破洞 · **P1** 已被实际调用的逻辑错/性能踩坑/关键路径缺测试 · **P2** 边角/罕见路径
- OPT:**HIGH** 大段死代码可删/热路径 N+1→batch/主线程阻塞改 bg · **MID** 抽象更清晰/补关键测试 · **LOW** 命名/风格
- FEAT:**HIGH** 高用户价值 + 改动 ≤1-3 天/一致性补齐 · **MID** 锦上添花 · **LOW** 边角

### Step 5 — codex 二审报告(有 codex 就做,没有降级)

主 agent 不能信任自己整合的报告(Opus 系统性偏弱也适用于主 agent)。报告写完后**若 codex 可用**起一个 codex 二审。codex **不在 workflow 脚本里**(脚本调不动 codex:rescue Skill),只能在这一步薄壳层做。优先级:

1. **首选:`codex:rescue` skill**(**先看会话起点的可用 skill 列表里有没有 `codex:rescue`**,没有就别盲发):
   ```
   Skill({ skill: "codex:rescue", args: "--background --fresh 「<下面那段 prompt>」" })
   ```
   read-only(**别传 `--write`**),完成后读它返回的 verdict。
2. **兜底:`codex` CLI**(`/opt/homebrew/bin/codex`,会话没 `codex:rescue` skill 时),Bash `run_in_background`:
   ```bash
   codex exec --sandbox read-only "<下面那段 prompt>" > CodeReview/.megareview-codex-review.md 2>&1
   ```
3. **都没有 / 未登录** → 跳过,报告头部注明"未做 codex 二审(环境无 codex),非跨模型校验"。

二审 prompt(范围跟 Step 1 关注点走 —— uiux 只复审 FEAT,nobug 删掉 FEAT 字样):

> Read the megareview report at `CodeReview/megareview-<YYYYMMDD-HHmm>.md`. Do NOT edit any files. Critique it: (1) Are any P0/P1/OPT-HIGH/FEAT-HIGH items mis-prioritized given actual codebase impact? (2) Are there obvious BUG/OPT/FEAT angles the report missed entirely (sanity-grep across Chronote/ and server/ for force-unwraps, retain-cycle risks, unused public APIs, hardcoded English in zh-Hans paths, UI/UX inconsistencies across views)? (3) Any duplicate findings to merge? (4) Any '已否决' items that were actually correct and should be reinstated? Skip accessibility entirely (no VoiceOver/Dynamic Type/ARIA — explicitly out of scope). Skip OWASP-style security — only flag hardcoded secrets or fail-open auth. Output verdict per finding (KEEP/DOWNGRADE/UPGRADE/DROP) plus a list of missed findings. Read-only.

拿到二审结果:升降级理由合理 → 接受改报告,不合理 → 报告末尾"复审反驳"小节写理由;missed findings 逐条 grep+Read 核对,确认的补进对应分级。报告末尾加:

```markdown
## Codex 二审结果(Step 5)
- 复审时间:<ts> / 调整:<keep/upgrade/downgrade/drop 计数> / 新增:<N> 条
- 主 agent 反驳:<不接受的条目 + 理由>
```

### Step 6 — 主对话回报

主对话**只回**(不 paste 全文):
- 本次关注点(Step 1 选项)+ 报告路径
- BUG-P0 数量 + 标题(全列)— 不含 BUG 档则跳过
- OPT-HIGH 前 3 条标题 — 不含 OPT 档则跳过
- **FEAT-HIGH 前 3 条**(全面 = UI/UX/新功能各 1;纯 UIUX = UI/UX 各 1)— 不含 FEAT 则跳过
- 动态追派了几个 follow-up + 为什么(1 句)
- codex 二审关键修订(1-2 句)
- 一句话整体观感(技术债集中在哪 / 哪个模块最值得动 / 哪条 FEAT 最该排日程)

## 失败模式 / 别这么干

- ❌ **跳过 Step 1 两题**:直接默认全套硬跑。用户明确要求每次先问关注点 + dead code。
- ❌ **主 agent 重复 workflow 已做的 grep 核对**:verify stage 已做完。主 agent 只做去重/终校/写报告/codex,别把整库再 grep 一遍浪费 context。
- ❌ **codex 可用却跳过 Step 5**:主 agent 整合的报告同样有 Opus 系统性偏弱,有 codex 就做二审。(真不可用 → 降级 + 注明,不违规。)
- ❌ **盲发 `Skill({ skill: "codex:rescue" })` 不先确认它在会话 skill 列表**:某 scope 没启用 / 没 reload 时硬失败。先看列表,不在就走 CLI。
- ❌ 选"全面/纯 UIUX"却只跑一条 FEAT:workflow 已 gate(uiux 跑 feat_ui+feat_ux 两个),别在报告里只写一类。
- ❌ reviewer 把"加 VoiceOver / Dynamic Type / 色盲对比度"写进 finding → workflow prompt 已禁,漏网的主 agent drop。
- ❌ 把"建议大重构 / AI 化"当 finding → 这是 roadmap 不是 review,workflow prompt 已禁。
- ❌ **改 angle 矩阵 / slice 图 / 16 条清单时去改 SKILL.md**:这些已下沉到 `.claude/workflows/megareview.mjs`,改那里。SKILL.md 只管薄壳流程。
- ❌ 把 workflow 的 `kept` 原样 paste 当报告:量化已核对但仍要主 agent 去重/分组/分级,paste 会丢结构。

## 调用示例

用户:`/megareview`

主 agent:
1. **Step 1**:`AskUserQuestion` 一次问两题(关注点 + dead code)
2. **Step 2**:摸底 Bash + `mkdir -p CodeReview`,整理 `repo` 对象
3. **Step 3**:`Workflow({ scriptPath: ".claude/workflows/megareview.mjs", args: {...} })`,等后台完成通知
4. **Step 4**:收 `{kept, rejected, ...}` → 去重/终校 → 写 `CodeReview/megareview-*.md`(只出选了的档)
5. **Step 5**:codex 二审(首选 codex:rescue / 兜底 CLI / 缺则降级注明)→ 按 verdict 修订
6. **Step 6**:主对话回:关注点 + 路径 + P0 数 + OPT-HIGH top3 + FEAT-HIGH top3 + 追派情况 + codex 摘要 + 一句话总结
