---
name: superreview
description: 不计成本对 uncommitted changes(或指定 diff range)做最严的代码审查 —— 薄壳层锁定 range + 按改动文件选视角,然后**调用 `.claude/workflows/superreview.mjs` Workflow**(确定性编排:pipeline 边审边核 + escalation 动态追派 + 结构化 schema),主 agent 拿回已核对 findings 后写 MD 报告 + 跑 codex 复审 + 出给非程序员看的 HTML 双产物。用户说"superreview / 超级审查 / 最严 review / 不计成本审查 / 上线前 review"时触发。
---

# Superreview — 不计成本的最严代码审查(Workflow 驱动)

在 commit / push / 上架前把 diff 里的 P0-P2 都翻出来。和 `/megareview` 同源,scope 不同:**superreview 审一段 diff**(working tree / branch range),megareview 审整个 repo 现状。

## 架构(2026-05-28 重构:Workflow 驱动)

**编排机制下沉到** [`.claude/workflows/superreview.mjs`](../../workflows/superreview.mjs),skill 是薄壳:
- **薄壳层(主 agent,本文件)**:锁 range + 识别开关 → git 摸底 → **按改动文件选视角** → 启动 Workflow → 收结构化结果写 MD → codex 复审 → 写 HTML → 回报。视角选择是 diff 相关的判断活(改了什么才派什么),留主 agent;`AskUserQuestion`(无)/ codex:rescue 调用 / HTML 写作也必须在薄壳层。
- **引擎层(Workflow 脚本)**:`pipeline(review→verify)` 无 barrier 边审边核(verify 用 grep/Read/context7 核对量化事实),`escalation` 全局 cap 动态追派,结构化 schema 把 findings 回脚本运行时(不灌主 context;tool-limited 的 coredata/sse reviewer 也靠 StructuredOutput 返回,不需要 Write)。

> 和 megareview 的区别:megareview 的 slice 图固定写死在脚本里;superreview 的视角随 diff 变,所以**视角选择留薄壳层**(主 agent 看 changedFiles 判断),workflow 只对传进来的视角做编排。

## 输入开关(用户自然语言里识别)

| 用户说法 | range 标签 | gitRange(传 workflow) |
|---|---|---|
| 默认(不指定) | `working tree` | `HEAD`(审 `git diff HEAD` + 未跟踪) |
| "只看没 push 到 main 的"/"unpushed" | `origin/main..HEAD` | `origin/main..HEAD` |
| "审 PR"/"审这条 branch"/"vs main" | `main..HEAD` | `main..HEAD` |
| "跳过 codex"/"skip codex" | — | 跳过 Step 4 codex 复审 + Step 5 codex 终审,报告矩阵标 skipped |
| "只跑 N 个 agent" | — | 薄壳层把视角数砍到 N |

## 何时触发

- `/superreview` 或"超级审查 / 最严 review / 不计成本审查 / 上线前最后一审"
- commit / push 大块改动前(uncommitted ≥5 文件 或 ≥200 行)/ release 前最后一关

## 何时**不**该用

- 只动 1-2 文件 / 几十行 → `/codex:review` 或一个 `general-purpose` agent 就够
- 用户只要"扫一眼"而非"严审"
- 改动没保存(git diff 看不到 buffer)→ 先提醒保存

## 流程

### Step 1 — 锁定 range + 估规模 + 识别开关

按用户语义定 range(见上表),记下 `range` 标签 + `gitRange`。识别"跳过 codex""只跑 N 个"开关。并行跑(按选定 range 替换 `<GR>`):

```bash
mkdir -p CodeReview
git status --short --untracked-files=all          # working tree
git diff <GR> --stat                              # <GR> = HEAD | origin/main..HEAD | main..HEAD
git log <GR> --oneline                            # 仅 commit range 模式
```

按规模定视角数(不计成本,opus):
- **小**(≤5 文件 / ≤200 行):4-5 视角
- **中**(6-15 文件 / 200-1000 行):6-8 视角
- **大**(>15 文件 / >1000 行):10+ 视角,按文件分组分给视角

### Step 2 — 按改动文件选视角(薄壳层判断,组装 `perspectives` 数组)

每个视角一个对象:`{ key, label, agentType, focus, files?: [...] }`(`files` 省略 = 看全部改动文件)。

**视角池**(按改动类型挑,不必全用)。⚠️ **subagent_type 池随插件状态变化,spawn 前先核会话起点 reminder**;不在池里 hard error。2026-05-17 实测有效映射:

| 视角 key | agentType | focus 重点 |
|---|---|---|
| correctness | general-purpose | 逻辑错 / off-by-one / 边界 / null / 异常吞掉 / 错误返回值 |
| architecture | general-purpose(深度可换 code-modernization:architecture-critic) | 抽象泄漏 / 耦合 / SRP / 未来扩展 |
| security | general-purpose(深度 OWASP 才换 code-modernization:security-auditor) | 硬编码 secret / 鉴权 fail-open / SSE 错误关闭(别展开 OWASP) |
| performance | general-purpose | 主线程阻塞 / N+1 / 缓存 / 内存泄漏 / O(n²) |
| concurrency | general-purpose | actor / race / deadlock / cancellation / @MainActor 违反 |
| test-gap | general-purpose(深度可换 code-modernization:test-engineer) | 关键路径缺单测 / 边界没测 / mock 是否合理 |
| api-contract | general-purpose | breaking change / 向后兼容 / 错误码 / SSE 协议 |
| coredata | **coredata-migration-reviewer** | CoreData schema / CloudKit 兼容 / backfill |
| sse | **sse-pipeline-reviewer** | server res.destroy / SSEParser / NetworkRetryHelper / activeStreams invariant |
| simplify | code-simplifier:code-simplifier | 可简化逻辑 / 未引用 symbol / 注释掉的代码 |
| lumory-checklist | general-purpose | 逐条核对 Lumory 9 条已知踩坑(脚本内置清单) |

**Lumory 强制视角**(改了对应文件就**必加**):
- 改了 `Chronote/Model/` / `PersistenceController.swift` / `DiaryEntry+Extensions.swift` → 加 `coredata`
- 改了 `server/*.js` → 加 `security`(focus 写 SSE / rate-limit / X-App-Secret / fail-closed)
- 改了 SSE 链路(`OpenAIService` / `AIService` / `NetworkRetryHelper` / server SSE)→ 加 `sse`
- 改了 `AppSecrets.swift` / xcconfig → 加 `security`(focus 写"扫硬编码 secret")
- 任何 review 都建议带一个 `lumory-checklist` 视角(diff 小可省)

"只跑 N 个"时按重要性砍到 N(correctness + 强制视角优先保留)。

### Step 3 — 启动 Workflow(编排全在脚本里)

> ⚠️ 本 skill 是 Workflow 的合法 opt-in 入口。

```
Workflow({
  scriptPath: ".claude/workflows/superreview.mjs",
  args: {
    range: "working tree" | "origin/main..HEAD" | "main..HEAD",
    gitRange: "HEAD" | "origin/main..HEAD" | "main..HEAD",
    diffStat: "<git diff --stat 输出>",
    changedFiles: ["<改动文件路径>"],
    perspectives: [ { key, label, agentType, focus, files } ]
  }
})
```

Workflow 后台跑,完成时通知。内部:`pipeline` 每个视角一个 opus reviewer 审 diff 出结构化 findings → **立刻**并行送 verify(grep/Read/context7 核对,无 barrier)→ escalation cap 3 动态追派 → 返回 `{ range, perspectivesRun, escalations, counts, kept, rejected }`。`kept` 每条带 `verdict`(CORRECTED 的用 `corrected*` 覆盖)。

**别在主 agent 重复 workflow 已做的 grep 核对** —— verify stage 已做。

### Step 4 — 收结果 + 写 MD + codex diff 复审

Workflow 回来后:

1. **应用 verdict**:`CORRECTED` → 用 `corrected*` 覆盖 file/line/severity;`REJECTED` → "已否决"区;`UNVERIFIABLE` → "待确认",不进 P0/P1。
2. **去重合并**:同一处多 reviewer 提 → 合一条 credit 多来源;矛盾 → 标"冲突"自己读代码裁决。
3. **codex 对 diff 复审**(用户没跳过 + codex 可用才做,跨模型互补盲点)。优先级:
   - 首选 `codex:rescue` skill(**先看会话 skill 列表有没有**):`Skill({ skill: "codex:rescue", args: "--background --fresh 「Read-only review of the <RANGE> diff. Do NOT edit. Find correctness/concurrency/security/data/API-contract bugs. Output P0/P1/P2 + file:line + 一句话问题 + 一句话修复.」" })`,read-only(别传 `--write`),回对话读 findings。
   - 兜底 `codex` CLI:`codex exec review --base <base-ref> > CodeReview/.superreview-codex-review.md 2>&1`(working tree 去掉 `--base`),Bash `run_in_background`。
   - 都没有 → 跳过,矩阵标 `codex | skipped`。
   - ⚠️ **不要**用 `/codex:review` / `/codex:adversarial-review`(`disable-model-invocation`,主 agent 调不动);**别**当 Agent 的 subagent_type 直接派。
4. **写 MD** `CodeReview/superreview-YYYYMMDD-HHmm.md`(`CodeReview/` 已 gitignore):

```markdown
# Superreview Report — <YYYY-MM-DD HH:mm>
## 改动概览
- range: <range 标签> / N 文件 / +A -B 行 / 触发视角:<perspectivesRun + 追派情况>
## P0 — 必修(commit/push 前)
### 1. <标题>
- **来源**:<reviewer label>(多来源都列)/ **位置**:`file:line`(verdict 校准后)
- **问题** / **核对**(verdict note)/ **建议修复**
## P1 — 应修 / ## P2 — Nice to fix
## 待确认(verdict=UNVERIFIABLE)/ ## 已否决(verdict=REJECTED + 理由)
## Reviewer 矩阵
| 视角 | agentType | 提了 N 条 | 核对后保留 | 追派? |
```

severity 口径:**P0** crash/数据丢失/鉴权破洞/fail-closed 失效 · **P1** 已被实际调用的逻辑错/性能踩坑/关键路径缺测试 · **P2** 可读性/重构机会/边角。

### Step 5 — codex 对最终报告做终审(用户跳过 codex 则整步省掉)

报告草稿落盘后,codex read-only 终审(完整读报告 + 被改文件,独立扫一轮)。优先级同 Step 4(`codex:rescue` skill 首选 / `codex exec --sandbox read-only` CLI 兜底 / 都没有跳过 + 注明)。

Prompt 要点:给报告路径 + 被改文件绝对路径 + 前序视角清单;要 codex ①指报告遗漏的 finding ②纠正量化有误的断言 ③提 Opus 系集体盲点;输出 `P0/P1/P2 + file:line + 问题 + 修复` 并标"新增/纠正"。

收到终审:新增 → 按 severity 并入(来源标 `codex-final`);纠正 → 改原条目"核对"字段追加 `[Codex 终审修正: ...]`;无新发现 → 矩阵加 `codex-final | 0 新增 | 0 纠正`。

### Step 6 — 生成 HTML 报告(给非程序员看,强制每次出)

最终 MD 落盘后**强制**出配套 HTML:`CodeReview/superreview-YYYYMMDD-HHmm.html`(沿用 MD timestamp)。**主 agent 自己用 Write 写,别召唤 subagent 翻译**(subagent 没完整 finding 上下文,讲不到位)。

**目标读者**:产品负责人本人 —— 不太懂代码,强理科思维。所以:
- ❌ 不要 paste MD 原文 / 不要只翻译术语
- ✅ 每条 finding 补"**这是什么 / 为什么出问题 / 用户能感受到什么 / 不修会怎样**",用类比 + 因果链 + 量化后果讲(如"两个人同时往一个本子写字,谁先落笔不定 → 偶尔笔记被覆盖")
- ✅ 严重程度直观比喻:P0 = 🚨 炸弹(必须先拆)· P1 = ⚠️ 漏水水管(拖久必坏)· P2 = 💡 优化空间
- ✅ 行号/路径保留但放折叠区/小字;顶部放 dashboard(总数/P0/P1/P2 + "现在能不能 push?"一句裁决)

HTML 模板:单文件 self-contained,**内联 CSS**(无 CDN,离线能开),vanilla JS 折叠可选。语义色(红=P0 用 `#c0392b` 别纯红 / 橙=P1 / 蓝=P2 / 绿=已过),对比度 AA。结构:Dashboard → 如何阅读 → P0/P1/P2 三段(卡片正面人话+比喻+用户现象,折叠区原始 finding+路径+行号+修复)→ 待确认/已否决(默认收起)→ Reviewer 矩阵。

### Step 7 — 主对话回报

只回(不 paste 全文):**MD 路径 + HTML 路径 + P0 数 + 一句话总结(中文)**+ 追派/codex 关键修订各 1 句。

## 失败模式 / 别这么干

- ❌ **主 agent 重复 workflow 已做的 grep 核对**:verify stage 已做完,主 agent 只做去重/写报告/codex/HTML。
- ❌ 视角数缩水(为省钱跑 2 个):失去多视角互补,这个 skill 就是不计成本。
- ❌ 改了 `Chronote/Model/` 不加 coredata / 改了 `server/*.js` 不加 security:Lumory 强制视角漏了。
- ❌ 跳过 Step 5 codex 终审(用户没说跳却自作主张):失去跨模型盲点互补。(codex 真不可用 → 降级 + 注明,不违规。)
- ❌ 盲发 `Skill({ skill: "codex:rescue" })` 不先确认它在会话 skill 列表:没启用/没 reload 时硬失败,先看列表,不在走 CLI。
- ❌ Step 6 HTML 只把 MD 套 `<pre>` / 删行号路径 / 召唤 subagent 翻译:都等于没做。
- ❌ **改视角池 / schema / 核对清单时去改 SKILL.md**:这些已下沉到 `.claude/workflows/superreview.mjs`(schema + 9 条清单 + 编排),改那里。SKILL.md 只管薄壳流程 + 视角选择 + HTML。
- ❌ 把 workflow 的 `kept` 原样 paste 当报告:量化已核对但仍要主 agent 去重/分组。

## 调用示例

用户:`/superreview`

主 agent:
1. **Step 1**:锁 range(默认 working tree)+ 识别开关 + git 摸底 Bash
2. **Step 2**:看 changedFiles 选视角(correctness + 强制视角 + 按规模补)组 `perspectives` 数组
3. **Step 3**:`Workflow({ scriptPath: ".claude/workflows/superreview.mjs", args: {...} })`,等通知
4. **Step 4**:收 `{kept, rejected, ...}` → 应用 verdict / 去重 → codex diff 复审 → 写 `CodeReview/superreview-*.md`
5. **Step 5**:codex 终审报告(没跳过 + 可用才做)→ 按结果更新
6. **Step 6**:强制写 `CodeReview/superreview-*.html`(人话+类比+比喻)
7. **Step 7**:回 MD 路径 + HTML 路径 + P0 数 + 一句话总结
