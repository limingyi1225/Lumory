export const meta = {
  name: 'superreview',
  description: '不计成本对一段 diff(working tree / origin/main..HEAD / main..HEAD)做最严代码审查的编排引擎:薄壳层选好视角传进来 → pipeline 边审边核(无 barrier)→ escalation 动态追派 → 返回结构化已核对 findings',
  whenToUse: '由 superreview skill 薄壳层在锁定 diff range + 选好视角后调用,args 传 {range, gitRange, perspectives, changedFiles, ...}',
  phases: [
    { title: 'Review', detail: 'pipeline:每个视角一个 opus reviewer 审 diff → findings 出来立刻进 verify(无 barrier)' },
    { title: 'Escalation', detail: 'COVERAGE/FRESH_EYE 追派 follow-up(全局 cap 3),同样 review→verify' },
  ],
}

// ───────────────────────── args ─────────────────────────
// {
//   range: "working tree" | "origin/main..HEAD" | "main..HEAD",   // 人话标签,写进报告
//   gitRange: "HEAD" | "origin/main..HEAD" | "main..HEAD",          // git diff 的实际参数
//   diffStat?: string,                                              // git diff --stat 摘要
//   changedFiles?: string[],
//   perspectives: [ { key, label, agentType, focus, files?: string[] } ]  // 薄壳层按改动文件选好
// }
// args 可能以对象或 JSON 字符串到达(Workflow 的 args 参数无类型,scriptPath 模式下常以字符串注入)—— 两种都兜住
let A = args || {}
if (typeof A === 'string') {
  try { A = JSON.parse(A) } catch (e) { A = {} }
}
const RANGE = A.range || 'working tree'
const GIT_RANGE = A.gitRange || 'HEAD'
const DIFF_STAT = A.diffStat || ''
const CHANGED = Array.isArray(A.changedFiles) ? A.changedFiles : []
const PERSPECTIVES = Array.isArray(A.perspectives) ? A.perspectives.filter((p) => p && p.key && p.agentType) : []

if (!PERSPECTIVES.length) {
  // 薄壳层没传视角:兜底一个 correctness 全 diff 视角,别让 workflow 空跑
  PERSPECTIVES.push({ key: 'correctness', label: 'correctness', agentType: 'general-purpose', focus: '逻辑错 / off-by-one / 边界 / null / 异常吞掉 / 错误返回值' })
}

// ───────────────────────── Lumory 专属核对清单(注入相关视角)─────────────────────────
const LUMORY_CHECKLIST = [
  '主线程在 bg.performAndWait block 内调 DispatchQueue.main.sync(SIGTRAP 9005)',
  'SSE 上游错误用 res.destroy(error) 而不是 data: [DONE]',
  'CoreData 字段加了非 optional 没默认值(CloudKit 不兼容)',
  'EmbeddingBackfillService / ThemeBackfillService 是否仍非 auto(只走用户主动触发)',
  '@Observable VM 里嵌套 ObservableObject 的 @Published(UI 不 react)',
  '@FetchRequest(animation:) 重新出现(动画错位)',
  'bash 脚本 cmd | cmd || true 覆盖了 PIPESTATUS',
  '后端 APP_SHARED_SECRET 缺失是否仍 fail-closed',
  'AppSecrets.swift 新硬编码 secret(应走 xcconfig 注入链)',
]

// ───────────────────────── schemas(与 megareview 同形)─────────────────────────
const FINDING = {
  type: 'object',
  properties: {
    severity: { type: 'string', enum: ['P0', 'P1', 'P2'] },
    file: { type: 'string' },
    line: { type: 'string', description: '行号或区间;拿不准写 "?"' },
    title: { type: 'string', description: '一句话问题' },
    description: { type: 'string' },
    suggestion: { type: 'string', description: '一句话修复' },
    evidence: { type: 'string', description: '代码片段或调用链(量化陈述必须给证据)' },
  },
  required: ['severity', 'file', 'line', 'title', 'description', 'suggestion', 'evidence'],
}
const FINDINGS_SCHEMA = {
  type: 'object',
  properties: {
    findings: { type: 'array', items: FINDING },
    escalation: {
      type: 'object',
      properties: {
        type: { type: 'string', enum: ['NONE', 'COVERAGE', 'FRESH_EYE'] },
        detail: { type: 'string', description: 'COVERAGE:没看完的文件/区域;FRESH_EYE:拿不准的 finding 标题+位置;NONE 写 "无"' },
      },
      required: ['type', 'detail'],
    },
  },
  required: ['findings', 'escalation'],
}
const VERDICT_SCHEMA = {
  type: 'object',
  properties: {
    verdict: { type: 'string', enum: ['CONFIRMED', 'CORRECTED', 'REJECTED', 'UNVERIFIABLE'] },
    correctedFile: { type: 'string' },
    correctedLine: { type: 'string' },
    correctedSeverity: { type: 'string' },
    note: { type: 'string', description: '核对依据(grep 结果/读到的上下文);REJECTED 写否决理由' },
  },
  required: ['verdict', 'correctedFile', 'correctedLine', 'correctedSeverity', 'note'],
}

// ───────────────────────── prompt builders ─────────────────────────
const DROP_RULES = [
  '❌ 不要报无障碍 / accessibility / VoiceOver / Dynamic Type —— Lumory 不关注。',
  '❌ 不要做 OWASP 级安全审计展开 —— 只顺手扫明显的硬编码 secret / fail-open 鉴权 / SSE 错误关闭。',
  '❌ 不要建议大重构 —— 这是 diff review,只看这段改动引入/触及的问题。',
].join('\n')

function diffContext() {
  let s = `本次 review range:【${RANGE}】(git diff 参数:${GIT_RANGE})。这是【diff review】—— 只报这段改动引入或直接触及的问题,不要泛审整库。`
  if (DIFF_STAT) s += `\n\ndiff --stat:\n${DIFF_STAT}`
  if (CHANGED.length) s += `\n\n改动文件(${CHANGED.length}):\n  ${CHANGED.slice(0, 60).join('\n  ')}`
  return s
}

function reviewPrompt(p) {
  const fileScope = p.files && p.files.length
    ? `\n【你负责的文件】(只看这些,别人看其他):\n  ${p.files.join('\n  ')}`
    : `\n【范围】所有改动文件(见上)`
  const isChecklist = p.key === 'lumory-checklist'
  const checklistBlock = isChecklist
    ? `\n\n【逐条核对清单】对下面每条,看这段 diff 有没有违反(违反才写 finding,给 file:line + grep 证据):\n${LUMORY_CHECKLIST.map((c, i) => `  ${i + 1}. ${c}`).join('\n')}`
    : ''

  return `你是 Lumory superreview 的 ${p.label} reviewer(专项视角,只看这一个角度,其他角度有别人看)。

${diffContext()}${fileScope}

【你的专项 angle】${p.focus}${checklistBlock}

【怎么看】先跑 \`git diff ${GIT_RANGE}${p.files && p.files.length ? ' -- ' + p.files.join(' ') : ''}\` 看改动,需要上下文就 Read 周围 50 行 / Grep 调用方。

${DROP_RULES}

【量化要求】所有 "X 处"/"未被使用"/"N 次" 必须给 grep 结果或代码片段。行号尽量准,拿不准写 "?"。
【输出】通过结构化工具返回 findings 数组,每条:severity(P0/P1/P2)/file/line/title/description/suggestion/evidence。
- P0 = 必须修才能 commit/push(crash / 数据丢失 / 鉴权破洞 / fail-closed 失效 / 用户可见崩溃)
- P1 = 应该修(已被实际调用的逻辑错 / 性能踩坑 / 关键路径缺测试)
- P2 = nice to fix(可读性 / 重构机会 / 边角 case)
【ESCALATION】文件太多没看完 → escalation.type=COVERAGE + detail;某 finding 影响大但拿不准 → FRESH_EYE + detail(标题+位置);都没有 → NONE detail="无"。不要自己 spawn 子 agent。`
}

function followupPrompt(e) {
  if (e.type === 'COVERAGE') {
    return `你是 Lumory superreview 的 follow-up reviewer。上一个 reviewer(${e.srcLabel})这块没看完:
「${e.detail}」
${diffContext()}
请彻底审这块未覆盖区域(跑 git diff ${GIT_RANGE} 看改动 + Read 上下文)。
${DROP_RULES}
通过结构化工具返回 findings(severity/file/line/title/description/suggestion/evidence)。escalation 一般 NONE。`
  }
  return `你是 Lumory superreview 的独立第二只眼。请【独立判断】下面这个位置有没有问题(别假设结论,自己 git diff ${GIT_RANGE} + Read 上下文 50 行下结论):
${e.detail}
${DROP_RULES}
通过结构化工具返回 findings;独立看下来认为有问题就写 finding(给证据),不认为有就返回空 findings + escalation NONE。`
}

function verifyPrompt(f) {
  return `核对一条 Lumory superreview finding 的量化事实(Opus 在行号/计数/"未被使用"/库行为上系统性偏弱,必须实查)。本次 diff range:${RANGE}(${GIT_RANGE})。
Finding:[${f.severity}] ${f.file}:${f.line} — ${f.title}
描述:${f.description}
证据(reviewer 给的):${f.evidence}
请按需:(1) Read ${f.file} 对应行区间确认 file:line 准确(不准 → CORRECTED 给正确行号);(2) "有 N 处"/"未被使用"/"dead code" → Grep 实数(含测试/xcconfig/plist);(3) "库 X 不会做 Y" → 用 context7 query-docs 查官方文档(别信记忆);(4) "一定崩/死锁" → 看实际调用入口顺序 Read 上下文 50 行;(5) 校准 severity:dead helper 里的 bug 降级、用户触发不到的降级、改动没实际引入的降级或否决。
通过结构化工具返回 verdict(CONFIRMED/CORRECTED/REJECTED/UNVERIFIABLE)+ corrected*(没改回原值)+ note(核对依据;REJECTED 写理由)。`
}

function verifyFindings(findings, phaseName) {
  if (!findings || !findings.length) return Promise.resolve([])
  return parallel(
    findings.map((f) => () =>
      agent(verifyPrompt(f), { schema: VERDICT_SCHEMA, agentType: 'general-purpose', model: 'opus', phase: phaseName, label: `verify:${(f.file || '?').split('/').pop()}` })
        .then((v) => ({ ...f, verdict: v || { verdict: 'UNVERIFIABLE', correctedFile: f.file, correctedLine: f.line, correctedSeverity: f.severity, note: 'verify 返回空' } }))
        .catch((err) => ({ ...f, verdict: { verdict: 'UNVERIFIABLE', correctedFile: f.file, correctedLine: f.line, correctedSeverity: f.severity, note: 'verify 异常: ' + String((err && err.message) || err) } }))
    )
  )
}

// ───────────────────────── 主流程 ─────────────────────────
log(`superreview 编排:range=${RANGE} → ${PERSPECTIVES.length} 个视角(${PERSPECTIVES.map((p) => p.label).join(', ')})`)

phase('Review')
const reviewed = await pipeline(
  PERSPECTIVES,
  (p) => agent(reviewPrompt(p), { schema: FINDINGS_SCHEMA, agentType: p.agentType, model: 'opus', phase: 'Review', label: p.label }),
  (review, p) => {
    const r = review || { findings: [], escalation: { type: 'NONE', detail: '无' } }
    return verifyFindings(r.findings, 'Verify').then((vf) => ({ label: p.label, findings: vf, escalation: r.escalation }))
  }
)

// escalation 全局 cap 3(barrier 正确:cap 是跨 item 的全局决策)
const escalations = reviewed
  .filter(Boolean)
  .filter((m) => m.escalation && m.escalation.type && m.escalation.type !== 'NONE')
  .map((m) => ({ type: m.escalation.type, detail: m.escalation.detail, srcLabel: m.label }))
  .slice(0, 3)

let followFindings = []
if (escalations.length) {
  log(`动态追派 ${escalations.length} 个 follow-up:${escalations.map((e) => `${e.type}@${e.srcLabel}`).join(', ')}`)
  phase('Escalation')
  const fups = await pipeline(
    escalations,
    (e) => agent(followupPrompt(e), { schema: FINDINGS_SCHEMA, agentType: 'general-purpose', model: 'opus', phase: 'Escalation', label: `followup:${e.srcLabel}` }),
    (review) => verifyFindings((review && review.findings) || [], 'Escalation')
  )
  followFindings = fups.filter(Boolean).flat()
}

// verdict=CORRECTED 时把校准后的 file/line/severity 回写到 finding,主 agent 写报告直接读到已校准值
function applyVerdict(f) {
  const v = f.verdict
  if (v && v.verdict === 'CORRECTED') {
    return { ...f, file: v.correctedFile || f.file, line: v.correctedLine || f.line, severity: v.correctedSeverity || f.severity }
  }
  return f
}

const allFindings = [...reviewed.filter(Boolean).flatMap((m) => m.findings), ...followFindings]
const rejected = allFindings.filter((f) => f.verdict && f.verdict.verdict === 'REJECTED')
const kept = allFindings.filter((f) => !f.verdict || f.verdict.verdict !== 'REJECTED').map(applyVerdict)

return {
  range: RANGE,
  gitRange: GIT_RANGE,
  perspectivesRun: PERSPECTIVES.map((p) => p.label),
  escalations,
  counts: {
    total: allFindings.length,
    kept: kept.length,
    rejected: rejected.length,
    p0: kept.filter((f) => f.severity === 'P0').length,
    p1: kept.filter((f) => f.severity === 'P1').length,
    p2: kept.filter((f) => f.severity === 'P2').length,
  },
  kept,
  rejected,
}
