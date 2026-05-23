---
name: superreview
description: 不计成本对 uncommitted changes(或指定 diff range)做最严的代码审查 —— 并行召唤多个 Opus subagent(不同视角)+ 跑 codex review,最后主 agent 交叉核对量化事实并产出统一 review 报告(同时落 MD + 给非程序员看的 HTML 双产物)。用户说"superreview / 超级审查 / 最严 review / 不计成本审查 / 上线前 review"时触发。
---

# Superreview - 不计成本的最严代码审查

把"多视角 Opus 并行 review" + "codex review"(可跳过) + "主 agent 交叉核对量化事实"串成一条流水线。目的是在 commit / push / 上架前把 P0-P2 都翻出来。

## 输入开关(用户自然语言里识别)

| 用户说法 | 含义 |
|---|---|
| 默认(不指定) | 审 working tree:`git diff HEAD` + `git status` 的 uncommitted changes |
| "只看没 push 到 main 的"/"未推送到 main 的"/"unpushed" | 审 `origin/main..HEAD` 这段已 commit 但未 push 的范围 |
| "审 PR" / "审这条 branch" / "vs main" | 审 `main..HEAD`(本地 branch vs 本地 main) |
| "跳过 codex" / "不跑 codex" / "skip codex" | 跳过 Step 3 codex review + Step 5 codex 终审,Reviewer 矩阵里标记 codex 行为 skipped |
| "只跑 N 个 agent" | 强制 subagent 数量 |

主 agent **在 Step 1 收集改动时就要锁定 diff range**,后续所有 subagent prompt 里都要明确告诉它们 review 哪个 range(不是无脑 `git diff HEAD`)。

## 核心理念

1. **多视角并行**:不同 Opus subagent 用不同焦点(correctness / security / perf / concurrency / arch / test-gap / API-contract / data-migration)各扫一遍。每个 subagent 只做一件事,别贪。
2. **跨模型互补**:Opus 找一类盲点,Codex(GPT 系)找另一类。模型差异 = 盲点互补。
3. **主 agent 不止"汇总"还"核对"**:Opus reviewer 在量化精度上有系统性弱点(计数错 / 行号偏 / dead code 误判 / 库行为靠记忆),主 agent **必须 grep + Read + context7 验证后**再纳入最终报告(参见 user memory `feedback_review_quality.md`)。
4. **不计成本**:subagent 全部 `model: "opus"`,数量按改动规模选,不为省 token 砍人头。

## 何时触发

- 用户输入 `/superreview` 或说"superreview / 超级审查 / 最严 review / 不计成本审查 / 上线前最后一审"
- 准备 commit / push 大块改动前(uncommitted ≥5 文件 或 ≥200 行)
- release / 上架前最后一道关

## 何时**不**该用

- 只动了 1-2 个文件 / 几十行 → 直接 `/codex:review` 或起一个 `general-purpose` agent 就够,起 6 个 Opus 是浪费
- 用户只要"扫一眼"而非"严审"
- 改动还没保存(git diff 看不到 buffer 内容)→ 先提醒用户保存

## 流程

### Step 1 — 锁定 diff range + 估规模

按用户语义先确定 **review range**(下面 prompt 都要带这个 range,不要再无脑 `git diff HEAD`):

| 用户语义 | range 参数 | git 命令 |
|---|---|---|
| 默认 / "uncommitted" | working tree | `git status --short -uall` + `git diff HEAD --stat` |
| "未 push 到 main" | `origin/main..HEAD` | `git log origin/main..HEAD --oneline` + `git diff origin/main..HEAD --stat` |
| "vs main" / "审 branch" | `main..HEAD` | `git log main..HEAD --oneline` + `git diff main..HEAD --stat` |

主 agent 把锁定的 range 字符串(例如 `origin/main..HEAD`)记下来,**写进所有 subagent prompt** + 报告头部"改动概览"区。

并行跑(按选定 range 替换):
```bash
git status --short --untracked-files=all            # working tree
git diff <RANGE> --stat
git log <RANGE> --oneline                            # 仅 commit range 模式
```

按改动规模选 subagent 数量:
- **小**(≤5 文件 / ≤200 行):4 Opus + Codex
- **中**(6-15 文件 / 200-1000 行):6-8 Opus + Codex
- **大**(>15 文件 / >1000 行):10+ Opus + Codex,按文件分片(每个 subagent 看一组相关文件)

### Step 2 — 并行召唤 Opus subagents(单条消息内 N 个 Agent tool call)

每个 subagent 一个**专项视角**。Prompt 必须包含:
- 要 review 的文件清单 + 当前 git diff 范围(说明这是 working tree 状态)
- **专项焦点**(只看这个角度,其他视角别人会看)
- 要求输出格式:`P0/P1/P2 + file:line + 一句话问题 + 一句话修复`
- 明确说明:**所有数字 / 行号 / "X 处 Y"类陈述都要给出 grep 结果或截取的代码块,主 agent 会逐条核对**
- 显式 `subagent_type: "general-purpose"`(或更专项的 namespaced agent,见下表)+ `model: "opus"`

视角池(按改动类型挑,不必全用)。⚠️ **subagent_type 池随插件状态变化 —— 每会话起点 system reminder 列的就是当前全集,spawn 前先核**;不在池里 hard error。下表是 2026-05-17 实测有效的映射,裸名 `code-reviewer` / `security-auditor` / `architect-review` / `test-automator` / `performance-engineer` / `database-optimizer` 等**都不在池里**,改走 `general-purpose` + prompt 写焦点。

| 视角 | 推荐 subagent_type | 重点 |
|---|---|---|
| Correctness | general-purpose | 逻辑错 / off-by-one / 边界 / null / 异常吞掉 / 错误返回值 |
| Architecture | general-purpose(深度可换 code-modernization:architecture-critic) | 抽象泄漏 / 耦合 / SRP 违反 / 未来扩展 |
| Security | general-purpose(深度 OWASP 可换 code-modernization:security-auditor) | 注入 / 鉴权 / 密钥泄漏 / SSE 错误处理 |
| Performance | general-purpose | 主线程阻塞 / N+1 / 缓存 / 内存泄漏 / O(n²) |
| Concurrency | general-purpose(Lumory: Swift Concurrency 重点) | actor / race / deadlock / cancellation / @MainActor 违反 |
| Test gap | general-purpose(深度可换 code-modernization:test-engineer) | 关键路径缺单测 / 边界没测 / mock 是否合理 |
| API contract | general-purpose | breaking change / 向后兼容 / 错误码 / SSE 协议 |
| Data migration / CoreData | **coredata-migration-reviewer**(Lumory 项目自定义) | CoreData schema / CloudKit 兼容 / backfill |
| SSE pipeline | **sse-pipeline-reviewer**(Lumory 项目自定义) | server `res.destroy` / 客户端 SSEParser / NetworkRetryHelper / `activeStreams` invariant |
| Simplify / 死代码 | code-simplifier:code-simplifier | 可简化逻辑 / 未引用 symbol / 注释掉的代码 |
| Style / convention | general-purpose | 项目既有约定(CLAUDE.md)/ 命名 / 风格 |

**Lumory 强制视角**:
- 任何 `Chronote/Model/` / `PersistenceController.swift` / `DiaryEntry+Extensions.swift` 被改 → **必须**召唤 `coredata-migration-reviewer`
- 任何 `server/*.js` 被改 → **必须**召唤一个 backend-security 视角(SSE / rate-limit / X-App-Secret / fail-closed)
- 改了 `AppSecrets.swift` / xcconfig → 扫"硬编码 secret"

### Step 3 — 同时跑 codex review(并行,不等)

**如果用户说"跳过 codex / skip codex":跳过本 Step + Step 5,并在 Reviewer 矩阵记 `codex | skipped (user request)`。**

否则紧接 Step 2 trigger。**codex 走插件优先,`codex exec` CLI 只是兜底**:

1. **首选:codex 插件的 `codex:rescue` skill**(会话起点的可用 skill 列表里有 `codex:rescue` 才用)。它是 codex 插件里**唯一能被主 agent 程序化调用**的入口;喂它 diff range + review 焦点,read-only(底层 `task` 默认就是 `--sandbox read-only`,**别传 `--write`**),后台跑:
   ```
   Skill({ skill: "codex:rescue", args: "--background --fresh 「Read-only review of the <RANGE> diff in this repo. Do NOT edit any files. Find correctness / concurrency / security / data / API-contract bugs. Output P0/P1/P2 + file:line + 一句话问题 + 一句话修复.」" })
   ```
   `--background` → 它起一个后台 task,完成时主 agent 收到通知,届时读它返回的 findings(`codex:rescue` 结果**回到对话、不落文件**;要留档自己 Write 到 `CodeReview/.superreview-codex-review.md`)。
   > ⚠️ **不要用 `/codex:review` / `/codex:adversarial-review`,也别去 poll `/codex:status` / `/codex:result`**:这些命令 frontmatter 全是 `disable-model-invocation: true` —— **只有用户手敲 slash command 才触发,主 agent 用 Skill 工具调不动**(它们不在会话 skill 列表里,硬调会 fail)。原生 reviewer 虽然结构化输出更好,但只能用户自己跑;自动化流水线里 codex 的唯一程序化入口就是 `codex:rescue`。
2. **兜底:`codex:rescue` skill 当前会话不可用**(codex 插件没 `/reload-plugins` / scope 没启用,会话 skill 列表里没有 `codex:rescue`)→ 用 standalone `codex` CLI(`/opt/homebrew/bin/codex`),Bash `run_in_background`:
   ```bash
   codex exec review --base <base-ref> > CodeReview/.superreview-codex-review.md 2>&1   # working tree 审就去掉 --base
   ```
3. **两者都没有 / codex 未登录** → 跳过本 Step + Step 5,Reviewer 矩阵记 `codex | skipped (codex unavailable)`。codex 是增强不是硬依赖。

### Step 4 — 主 agent 核对(最关键 — 不要跳)

收齐所有 Opus + Codex finding 后,**不能直接合并 paste**。必须做:

#### A. 去重 + 合并
- 同一处问题被多个 reviewer 提到 → 合一条,credit 多个来源(可信度↑)
- finding 之间互相矛盾 → 标"冲突",自己读代码裁决

#### B. 量化事实核对(Opus 系统性弱点 — 必查)

对每条 finding 中的:**计数 / 行号 / 文件位置 / "未被使用" / "dead code" / "X 处" / 库行为陈述**,主 agent 必须验证:

| 陈述类型 | 验证手段 |
|---|---|
| "有 N 个 X" | `Grep` 实数一遍 |
| 行号 / 文件位置 | `Read` 那个文件区间确认 |
| "此 helper 没业务 caller" | `Grep` 函数名全仓搜 |
| "库 X 不会做 Y" | `mcp__context7__query-docs` 查官方文档,**别**信 subagent 记忆 |
| "运行时一定崩 / 死锁" | 看实际调用入口和调用顺序,Read 上下文 50 行 |

**核对不通过的**:
- 数字错了 → 改正后保留 finding
- 完全错了(dead code 其实活的)→ 移到"已被否决"区,写否决理由
- 没法验证 → 降级到"待确认"区,**不放进 P0/P1**

#### C. Severity 校准

- **P0** = 必须修才能 commit/push:crash / 数据丢失 / 鉴权破洞 / fail-closed 失效 / 用户可见崩溃
- **P1** = 应该修:逻辑错(已被实际调用)/ 性能踩坑 / 关键路径缺测试
- **P2** = nice to fix:可读性 / 重构机会 / 边角 case

把每条 P0/P1 的 severity 跟"实际 runtime 是否触发"对一遍 —— dead helper 的 bug 应降级。

#### D. 写最终报告

写到 `CodeReview/superreview-YYYYMMDD-HHmm.md`(`CodeReview/` 已在 .gitignore 里,如未在则加上):

```markdown
# Superreview Report — <YYYY-MM-DD HH:mm>

## 改动概览
- N 文件 / +A / -B 行
- diff range: working tree vs HEAD(或 staged / branch)
- 触发的视角:[列出 subagent 视角清单]

## P0 — 必修(commit/push 前)
### 1. <一句话标题>
- **来源**:correctness × codex(2 个 reviewer 都标了)
- **位置**:`Chronote/Foo.swift:123`
- **问题**:...
- **核对**:grep 了 `funcName` 全仓 7 处调用,确认是热路径
- **建议修复**:...

## P1 — 应修
...

## P2 — Nice to fix
...

## 待确认(reviewer 提到但主 agent 没法验证 — 让用户决定)
- ...

## 已否决(reviewer 提到但核对不通过)
- <原 finding>:否决理由(grep 结果 / 文档链接)

## Reviewer 矩阵
| 视角 | subagent | 提了 N 条 | 命中率(被纳入最终) |
|---|---|---|---|
| correctness | general-purpose (Opus) | 8 | 6/8 |
| security | general-purpose (Opus, security focus in prompt) | 4 | 3/4 |
| codex | codex:rescue (review-framed) | 5 | 4/5 |
| ...
```

报告草稿写完后**不要**立刻告诉用户,先进入 Step 5 做 Codex 终审(如未跳过)再进入 Step 6 出 HTML。

### Step 5 — Codex 对最终报告做完整终审(用户跳过 codex 则整步省掉)

**用户要"跳过 codex"时:直接跳到 Step 6,在 Reviewer 矩阵补一行 `codex-final | skipped (user request)`。**

Step 4 报告草稿落盘后，跑一次 Codex 的 **read-only 终审**，完整读取报告文件 + 所有被改动的源文件，做最后一轮独立扫描。codex 调用优先级同 Step 3:**①有 `codex:rescue` skill 就用 skill;②否则 standalone `codex` CLI 兜底**(`codex exec --sandbox read-only "<读报告 + 被改文件并复审>" > CodeReview/.superreview-codex-final.md 2>&1`,Bash `run_in_background`);**③都没有就跳过本步 + 注明**。

> **别把 codex 当 `Agent` 的 `subagent_type` 直接派** —— 即使 `/reload-plugins` 后 `codex:codex-rescue` 进了 subagent_type 池,正确用法仍是走 `/codex:rescue` slash command(它内部自己调度 codex),直接 Agent 派不符合插件设计。

**Prompt 要点**（主 agent 在召唤时必须包含）：
- 给出报告文件路径（`CodeReview/superreview-*.md`）和所有被改动文件的绝对路径
- 说明前序 Opus 视角清单（让 Codex 知道哪些角度已经覆盖）
- 要求 Codex：①指出报告中明显遗漏的 finding；②纠正报告里量化有误的断言；③提出 Opus 系视角集体漏掉的盲点
- 输出格式同 Opus：`P0/P1/P2 + file:line + 一句话问题 + 一句话修复`，并标注是"新增"还是"纠正已有"

**主 agent 收到 Codex 终审结果后**：
- 新增 finding → 按 severity 并入对应的 P0/P1/P2 区（标注来源 `codex-final`）
- 纠正已有 finding → 直接修改原条目，在"核对"字段追加 `[Codex 终审修正: ...]`
- 无新发现 → 在报告末尾 Reviewer 矩阵里加一行 `codex-final | 0 新增 | 0 纠正`，记录已过终审

最终报告 MD 更新完后,**不要**告诉用户结束 —— 还有 Step 6 要出 HTML。

### Step 6 — 生成 HTML 报告(给非程序员看的版本,强制每次都出)

最终 MD 落盘 + 必要 Codex 终审更新完之后,**强制**为这次 review 生成一份配套的 HTML 报告。文件名沿用 MD 的 timestamp 后缀:`CodeReview/superreview-YYYYMMDD-HHmm.html`。

#### HTML 报告写作准则(关键 —— 偏离这条就废了)

**目标读者**:产品负责人本人 —— 不太懂代码,但有很强的理科思维和逻辑。所以:
- ❌ **不要**直接 paste MD 原文(那是给程序员的)
- ❌ **不要**只翻译术语就交差("race condition" → "竞争条件")—— 这等于没解释
- ✅ 每条 finding 都要补一段"**这是什么 / 为什么会出问题 / 用户能感受到什么 / 不修会怎样**"的人话解释
- ✅ 用**类比 + 因果链 + 量化后果**讲清楚,例如:
  - "这就像两个人同时往同一个本子上写字,谁的字先落笔不确定 → 偶尔笔记会被对方覆盖"
  - "用户看到的现象:打开 App → 转圈 → 卡 0.5 秒 → 内容弹出来。修了之后没有 0.5 秒卡顿。"
- ✅ 行号 / 文件路径**保留**(读者可能要让 Claude 帮他改),但放在折叠区/小字里,不挡阅读
- ✅ 给每条 finding 一个**"严重程度直观比喻"**:
  - P0 = 🚨 "炸弹"—— 必须先拆,否则会真的炸用户
  - P1 = ⚠️ "漏水的水管"—— 当下能用,但拖久了一定坏
  - P2 = 💡 "优化空间"—— 不修也没事,修了更好
- ✅ 顶部放**整体结论 dashboard**:总 finding 数 / P0 数 / P1 数 / P2 数 / "现在能不能 push?"的一句话裁决

#### HTML 模板要求

- 单文件 self-contained:**内联 CSS**(不依赖外部 CDN,离线也能开),不依赖 JS 框架。一点点 vanilla JS 做折叠/筛选可以,没有也行。
- 设计风格:干净中文阅读体验,Pretendard / 系统中文字体 fallback。配色用语义色(红=P0,橙=P1,蓝=P2,绿=已过)。
- 结构(对应到 DOM 区块):
  1. **顶部 Dashboard**:大标题 + 时间 + range + 4 个数字卡(总数 / P0 / P1 / P2)+ 一句"能不能 push"裁决
  2. **如何阅读这份报告**:2-3 句话告诉读者卡片含义 / 严重程度图标 / 点击展开看技术细节
  3. **P0 / P1 / P2 三段**:每条 finding 一张卡,卡片正面是"人话解释 + 严重程度比喻 + 用户能感受到的现象",折叠区是"原始 finding(给 Claude 看) + 文件路径 + 行号 + 建议修复"
  4. **待确认 / 已否决**:折叠,默认收起
  5. **底部 Reviewer 矩阵**:简化成"哪些视角看过 / 哪些被跳过"
- 颜色无障碍:对比度 AA 级,P0 红别选纯 #FF0000(会闪眼睛),用 `#c0392b` 之类

#### 生成方式

主 agent 自己用 Write 工具写 HTML 文件,**不要**召唤 subagent 翻译 —— subagent 给非程序员讲技术问题往往讲不到位,主 agent 才有完整 finding 上下文。

写完后告诉用户:**MD 路径 + HTML 路径 + P0 数 + 一句话总结**(中文)。**不要**在对话里 paste HTML 或 MD 全文。

## Lumory 项目专属核对清单

主 agent 在 Step 4 的核对阶段,拿这份清单过一遍 finding 是否覆盖了已知踩坑:

- [ ] 有没有 main thread 调 `bg.performAndWait` block 内 `DispatchQueue.main.sync`(SIGTRAP 9005...)
- [ ] SSE 上游错误是不是 `res.destroy(error)` 而不是 `data: [DONE]`
- [ ] CoreData 字段加了非 optional 没默认值(CloudKit 不兼容)
- [ ] `EmbeddingBackfillService` / `ThemeBackfillService` 是不是仍然非 auto(只走用户主动触发)
- [ ] `@Observable` VM 里有没有嵌套 `ObservableObject` 的 `@Published`(UI 不 react)
- [ ] `@FetchRequest(animation:)` 有没有重新出现(动画错位)
- [ ] bash 脚本 `cmd | cmd || true` 有没有覆盖 `PIPESTATUS`
- [ ] 后端 `APP_SHARED_SECRET` 缺失是不是仍然 fail-closed
- [ ] AppSecrets 有没有新硬编码 secret

## 调用示例

用户:`/superreview`

主 agent 该做:
1. **锁定 range**(默认 working tree / "未 push 到 main" → `origin/main..HEAD` / "vs main" → `main..HEAD`)+ 检测"跳过 codex"开关
2. 跑 git status/diff/log(并行,按选定 range)
3. 看规模选视角
4. 单条消息内 N 个 Agent tool call(每个 `model: "opus"`,prompt 里带 range);Opus 批次发完紧接着发 codex review(首选 `codex:rescue` skill / 兜底 `codex exec review` CLI,用户没跳过才有 —— Skill 调用没法跟 Agent 批次塞进同一个并行 tool-batch,所以单独紧跟着发)
5. 收齐结果
6. 跑核对(grep + Read + context7)
7. 写报告草稿到 `CodeReview/superreview-*.md`
8. 跑 Codex rescue read-only task 终审(用户没跳过才有;Skill / Bash 路径,**非** Agent subagent_type)
9. 按 Codex 终审结果更新报告(新增 / 纠正 finding)
10. **强制**生成配套 HTML 到 `CodeReview/superreview-*.html`(给非程序员的版本,人话+类比+严重程度直观比喻)
11. 主对话只回:MD 路径 + HTML 路径 + P0 数量 + 一句话总结

## 失败模式 / 别这么干

- ❌ 把所有 subagent 输出原样拼起来当报告 → 量化错误会被原样保留
- ❌ subagent 数量缩水(为省钱跑 2 个) → 失去多视角互补的意义,这个 skill 就是不计成本
- ❌ 跳过核对步骤 → 用户读到错的行号 / 错的计数,这个 skill 就废了
- ❌ 给 subagent 模糊 prompt("帮我 review 一下") → 视角散,大量重复 finding
- ❌ 全部串行 → 没必要,subagent 之间无依赖
- ❌ 跳过 Step 5 Codex 终审(用户没说要跳过却自作主张跳)→ 失去跨模型盲点互补,等于把 Opus 系集体盲点遗漏带进报告
- ❌ Step 6 HTML 只是把 MD 套个 `<pre>` → 这不是给非程序员看的,等于没做
- ❌ Step 6 HTML 把行号 / 文件名删掉 → 用户要二次让 Claude 修代码时无从下手,行号 / 路径必须保留(放折叠区)
- ❌ Step 6 召唤 subagent 翻译 finding → subagent 没完整 finding 上下文,主 agent 自己写
