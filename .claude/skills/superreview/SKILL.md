---
name: superreview
description: 不计成本对 uncommitted changes 做最严的代码审查 —— 并行召唤多个 Opus subagent(不同视角)+ 跑 codex review,最后主 agent 交叉核对量化事实并产出统一 review 报告。用户说"superreview / 超级审查 / 最严 review / 不计成本审查 / 上线前 review"时触发。
---

# Superreview - 不计成本的最严代码审查

把"多视角 Opus 并行 review" + "codex review" + "主 agent 交叉核对量化事实"串成一条流水线。目的是在 commit / push / 上架前把 P0-P2 都翻出来。

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

- 只动了 1-2 个文件 / 几十行 → 直接 `/codex:review` 或起一个 `code-reviewer` agent 就够,起 6 个 Opus 是浪费
- 用户只要"扫一眼"而非"严审"
- 改动还没保存(git diff 看不到 buffer 内容)→ 先提醒用户保存

## 流程

### Step 1 — 收集改动 + 估规模

并行跑:
```bash
git status --short --untracked-files=all
git diff --stat
git diff --cached --stat
git diff HEAD --stat
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
- 显式 `subagent_type: "code-reviewer"`(或更专项的)+ `model: "opus"`

视角池(按改动类型挑,不必全用):

| 视角 | 推荐 subagent_type | 重点 |
|---|---|---|
| Correctness | code-reviewer | 逻辑错 / off-by-one / 边界 / null / 异常吞掉 / 错误返回值 |
| Architecture | architect-review / general-purpose | 抽象泄漏 / 耦合 / SRP 违反 / 未来扩展 |
| Security | security-auditor / backend-security-coder | 注入 / 鉴权 / 密钥泄漏 / OWASP / SSE 错误处理 |
| Performance | performance-engineer / database-optimizer | 主线程阻塞 / N+1 / 缓存 / 内存泄漏 / O(n²) |
| Concurrency | general-purpose(Lumory: Swift Concurrency 重点) | actor / race / deadlock / cancellation / @MainActor 违反 |
| Test gap | test-automator | 关键路径缺单测 / 边界没测 / mock 是否合理 |
| API contract | api-design-principles / general-purpose | breaking change / 向后兼容 / 错误码 / SSE 协议 |
| Data migration | **coredata-migration-reviewer**(Lumory 项目专用 agent) | CoreData schema / CloudKit 兼容 / backfill |
| Style / convention | code-reviewer | 项目既有约定(CLAUDE.md)/ 命名 / 风格 |

**Lumory 强制视角**:
- 任何 `Chronote/Model/` / `PersistenceController.swift` / `DiaryEntry+Extensions.swift` 被改 → **必须**召唤 `coredata-migration-reviewer`
- 任何 `server/*.js` 被改 → **必须**召唤一个 backend-security 视角(SSE / rate-limit / X-App-Secret / fail-closed)
- 改了 `AppSecrets.swift` / xcconfig → 扫"硬编码 secret"

### Step 3 — 同时跑 codex review(并行,不等)

和 Step 2 同一条消息里 trigger:

```
Skill({ skill: "codex:review", args: "--background" })
```

或直接 Bash run_in_background:
```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/codex-companion.mjs" review --background
```

之后用 `/codex:status` / `/codex:result` 取结果。

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
| correctness | code-reviewer (Opus) | 8 | 6/8 |
| security | security-auditor (Opus) | 4 | 3/4 |
| codex | codex:review | 5 | 4/5 |
| ...
```

报告写完后告诉用户路径,**不要**在主对话里 paste 全文(太长,用户去文件看)。可以摘 P0 一两条 + 总数概览。

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
1. 跑 git status/diff(并行)
2. 看规模选视角
3. 单条消息内 N 个 Agent tool call(每个 `model: "opus"`)+ 1 个 codex review skill 调用
4. 收齐结果
5. 跑核对(grep + Read + context7)
6. 写 `CodeReview/superreview-*.md`
7. 主对话只回:报告路径 + P0 数量 + 一句话总结

## 失败模式 / 别这么干

- ❌ 把所有 subagent 输出原样拼起来当报告 → 量化错误会被原样保留
- ❌ subagent 数量缩水(为省钱跑 2 个) → 失去多视角互补的意义,这个 skill 就是不计成本
- ❌ 跳过核对步骤 → 用户读到错的行号 / 错的计数,这个 skill 就废了
- ❌ 给 subagent 模糊 prompt("帮我 review 一下") → 视角散,大量重复 finding
- ❌ 全部串行 → 没必要,subagent 之间无依赖
