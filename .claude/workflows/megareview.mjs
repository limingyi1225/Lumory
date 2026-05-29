export const meta = {
  name: 'megareview',
  description: 'Lumory 整仓 BUG+OPT+FEAT 审计编排引擎:按关注点裁 slice×angle 矩阵 → pipeline 边审边核(无 barrier)→ escalation 动态追派 → 返回结构化已核对 findings',
  whenToUse: '由 megareview skill 薄壳层在跑完 AskUserQuestion(关注点+dead code)+ 摸底 Bash 后调用,args 传 {focus, deadCode, repo, ...}',
  phases: [
    { title: 'Review', detail: 'pipeline:每个 (slice,angle) 一个 opus reviewer,findings 出来立刻进 verify(无 barrier)' },
    { title: 'Escalation', detail: 'COVERAGE/FRESH_EYE 追派 follow-up(全局 cap 4),同样 review→verify' },
  ],
}

// ───────────────────────── args ─────────────────────────
// {
//   focus: "full" | "uiux" | "nobug" | "custom",
//   deadCode: boolean,                       // 只在含 OPT 的档生效
//   customAssignmentKeys?: string[],         // focus==="custom" 时:从 ALL_ASSIGNMENTS 选哪些 key
//   customFocusText?: string,                // focus==="custom" 时:用户自由输入(注入 reviewer prompt)
//   repo: { totalFiles, totalLoc, churnHot: string[], todoCount, bigFiles: string[] }
// }
// args 可能以对象或 JSON 字符串到达(Workflow 的 args 参数无类型,scriptPath 模式下常以字符串注入)—— 两种都兜住
let A = args || {}
if (typeof A === 'string') {
  try { A = JSON.parse(A) } catch (e) { A = {} }
}
const FOCUS = A.focus || 'full'
const DEAD_CODE = A.deadCode === true
const REPO = A.repo || {}
const CHURN = Array.isArray(REPO.churnHot) ? REPO.churnHot.slice(0, 12) : []
const BIG = Array.isArray(REPO.bigFiles) ? REPO.bigFiles.slice(0, 15) : []

// ───────────────────────── Lumory slice 图 ─────────────────────────
const SLICE_FILES = {
  models: [
    'Chronote/Model/*.swift',
    'Chronote/Model/PersistenceController.swift',
    'Chronote/Services/*BackfillService.swift',
    'Chronote/*.xcdatamodeld',
  ],
  ai_sse: [
    'Chronote/Services/OpenAI/*.swift',
    'Chronote/Services/AIService.swift',
    'Chronote/Services/NetworkRetryHelper.swift',
    'Chronote/Services/InsightsEngine.swift',
    'Chronote/Services/InsightsSearchEngine.swift',
    'Chronote/Services/ContextPromptGenerator.swift',
    'Chronote/Services/NarrativePrecomputeService.swift',
  ],
  audio: [
    'Chronote/Services/AudioRecorder.swift',
    'Chronote/Services/OpenAITranscriber.swift',
    'Chronote/Services/Transcriber.swift',
  ],
  home_vm: ['Chronote/Views/HomeView.swift', 'Chronote/Views/HomeView/*.swift'],
  insights: ['Chronote/Views/Insights/*.swift', 'Chronote/Views/Insights/**/*.swift'],
  search_detail_settings: [
    'Chronote/Views/SearchView.swift',
    'Chronote/Views/DiaryDetailView*.swift',
    'Chronote/Views/DiaryDetailView/*.swift',
    'Chronote/Views/SettingsView.swift',
    'Chronote/Views/DiaryImportView.swift',
    'Chronote/Views/DiaryExportView.swift',
  ],
  reminder_widget_url: [
    'Chronote/Services/ReminderService.swift',
    'Chronote/Services/WidgetSnapshotService.swift',
    'Chronote/Utils/LumoryURLRouter.swift',
    'LumoryWidgets/**/*.swift',
    'LumoryWidgetShared/**/*.swift',
  ],
  backend: ['server/*.js', 'ecosystem.config.js'],
  tests: ['ChronoteTests/**/*.swift', 'ChronoteUITests/**/*.swift'],
  scripts_build: ['Scripts/*', '*.sh', 'Lumory.xcconfig', 'Lumory-Info.plist', 'LumoryWidgets-Info.plist'],
  product_experience: ['Chronote/Views/**/*.swift'], // FEAT 视角:扫所有 view 找体验缺口
  whole_repo: ['Chronote/**/*.swift', 'LumoryWidgets/**/*.swift', 'server/*.js'],
}

// ───────────────────────── Lumory 16 条专属核对清单 ─────────────────────────
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
  'URLSession.sslTolerantSession 被误以为是绕证书的实现',
  'NSManagedObject 跨 await 漏 @MainActor(Swift 6 Sendable)',
  'UITestSampleData guard(NSInMemoryStoreType + url=/dev/null)被破坏',
  'xcconfig / pbxproj 里 showEnvVarsInLog 被改回 1',
  'Log.warn(错)vs Log.warning(对);Log.Category 用了未注册分类',
  '批量删 entry 五件套清理(Reminder + ThemeAlias + PromptSuggestion + InsightsResultCache + WidgetSnapshot)有漏',
  'Widget snapshot V2 schema 新加正文/snippet 字段(不该加);useContextualBody/useContextualPrompt 默认翻转漏 sentinel migration',
]

// ───────────────────────── 全部可派 assignment(keyed)─────────────────────────
// category: BUG | OPT | FEAT ;agentType 必须在 harness 池里(见 CLAUDE.md)
const ALL_ASSIGNMENTS = {
  data: { label: 'models·data', agentType: 'coredata-migration-reviewer', category: 'BUG', slices: ['models'],
    focus: 'CoreData schema / CloudKit 限制 / backfill 幂等性 / NSManagedObject 跨 await Sendable' },
  sse: { label: 'ai_sse·sse-pipeline', agentType: 'sse-pipeline-reviewer', category: 'BUG', slices: ['ai_sse'],
    focus: '服务端 res.destroy vs [DONE] / 客户端 SSEParser / NetworkRetryHelper / StreamEvent.truncated 消费' },
  concurrency: { label: 'ai_sse·concurrency', agentType: 'general-purpose', category: 'BUG', slices: ['ai_sse', 'audio'],
    focus: 'actor 隔离 / @MainActor 违反 / Sendable 漏标 / 取消语义 / 死锁 / 主线程 sync' },
  backend: { label: 'backend·correctness', agentType: 'general-purpose', category: 'BUG', slices: ['backend'],
    focus: '逻辑错 / 错误处理 / 鉴权 fail-open 倒退 / 速率限制 / 请求体限制;顺手扫硬编码 secret(别做 OWASP)' },
  home_correctness: { label: 'home_vm·correctness', agentType: 'general-purpose', category: 'BUG', slices: ['home_vm'],
    focus: '逻辑错 / off-by-one / 边界 / null / 异常吞掉 / @Observable VM 嵌套 @Published' },
  detail_correctness: { label: 'search_detail_settings·correctness', agentType: 'general-purpose', category: 'BUG', slices: ['search_detail_settings'],
    focus: '逻辑错 / 边界 / 状态管理 / 批量删 entry 五件套清理是否漏' },
  reminder_correctness: { label: 'reminder_widget_url·correctness', agentType: 'general-purpose', category: 'BUG', slices: ['reminder_widget_url'],
    focus: '逻辑错 / reschedule generation race / widget snapshot schema / URL 路由 / App Group 共享' },
  perf: { label: 'perf·hot-paths', agentType: 'general-purpose', category: 'OPT', slices: ['ai_sse', 'models', 'home_vm'],
    focus: '主线程 IO / N+1 fetch / 缓存缺失 / 内存泄漏 / 不必要重渲染 / fetch batch' },
  abstraction: { label: 'cross·abstraction', agentType: 'general-purpose', category: 'OPT', slices: ['whole_repo'],
    focus: '抽象泄漏 / 重复逻辑 / SRP / 应该提的 helper / 超长文件(>600 行)' },
  tests: { label: 'tests·coverage', agentType: 'general-purpose', category: 'OPT', slices: ['tests'],
    focus: '关键路径无单测 / mock 错配 / 边界没覆盖 / view-side StreamEvent.truncated 端到端测试缺口' },
  deadcode: { label: 'whole·dead-code', agentType: 'code-simplifier:code-simplifier', category: 'OPT', slices: ['whole_repo'],
    focus: '未被引用的 func/class/file / 注释掉的代码 / 可简化逻辑(全仓搜 caller 含测试/xcconfig/plist)' },
  checklist: { label: 'lumory·checklist', agentType: 'general-purpose', category: 'BUG', slices: ['whole_repo'],
    focus: '逐条核对 Lumory 16 条已知踩坑清单(见 prompt),grep 验证每条是否被违反' },
  feat_ui: { label: 'product·FEAT-UI', agentType: 'general-purpose', category: 'FEAT', slices: ['product_experience'],
    focus: 'liquidGlass / 间距 / 对齐 / 字号层级 / 颜色一致性 / 圆角阴影一致 / 暗色模式 / iPad 布局 / Dynamic Island / 状态栏 / 跨 view 视觉风格漂移' },
  feat_ux: { label: 'product·FEAT-UX', agentType: 'general-purpose', category: 'FEAT', slices: ['product_experience'],
    focus: 'loading 态缺失 / 错误提示糊 / 空态生硬 / 动效缺失或不统一 / haptic 缺失 / 转场 / 长按 / 滑动 / 键盘交互 / 触控热区 / 操作完成确认感 / i18n 漏字符串 / 跨 view 交互不一致' },
  feat_new: { label: 'product·FEAT-new', agentType: 'general-purpose', category: 'FEAT', slices: ['product_experience'],
    focus: '基于现有 model/service 自然延伸的功能(导出格式/新可视化/新交互)/ 用户已在用但缺 affordance 的隐性需求。小到中改动量,大功能标 epic' },
}

// ───────────────────────── 关注点 → assignment 选择 ─────────────────────────
const FOCUS_KEYS = {
  full: ['data', 'sse', 'concurrency', 'backend', 'home_correctness', 'detail_correctness',
    'reminder_correctness', 'perf', 'abstraction', 'tests', 'checklist', 'feat_ui', 'feat_ux', 'feat_new'],
  nobug: ['data', 'sse', 'concurrency', 'backend', 'home_correctness', 'detail_correctness',
    'reminder_correctness', 'perf', 'abstraction', 'tests', 'checklist'],
  uiux: ['feat_ui', 'feat_ux'],
}

function selectedKeys() {
  if (FOCUS === 'custom') {
    const k = Array.isArray(A.customAssignmentKeys) && A.customAssignmentKeys.length
      ? A.customAssignmentKeys.filter((x) => ALL_ASSIGNMENTS[x])
      : FOCUS_KEYS.full
    return k.filter((x) => x !== 'deadcode')
  }
  return (FOCUS_KEYS[FOCUS] || FOCUS_KEYS.full).filter((x) => x !== 'deadcode')
}

// dead code 只在含 OPT 的档(full / nobug / custom-含-OPT)且用户答"扫"才加
function deadCodeApplies() {
  if (!DEAD_CODE) return false
  if (FOCUS === 'uiux') return false
  const ks = selectedKeys()
  const hasOpt = ks.some((k) => ALL_ASSIGNMENTS[k] && ALL_ASSIGNMENTS[k].category === 'OPT')
  return FOCUS === 'full' || FOCUS === 'nobug' || hasOpt
}

const assignmentKeys = selectedKeys()
if (deadCodeApplies()) assignmentKeys.push('deadcode')
const assignments = assignmentKeys.map((k) => ALL_ASSIGNMENTS[k]).filter(Boolean)

// ───────────────────────── schemas ─────────────────────────
const FINDING = {
  type: 'object',
  properties: {
    category: { type: 'string', enum: ['BUG', 'OPT', 'FEAT'] },
    severity: { type: 'string', description: 'BUG: P0|P1|P2 ;OPT/FEAT: HIGH|MID|LOW' },
    file: { type: 'string' },
    line: { type: 'string', description: '行号或区间,如 "123" 或 "430-460";拿不准写 "?"' },
    title: { type: 'string', description: '一句话标题' },
    description: { type: 'string', description: '问题/机会描述' },
    suggestion: { type: 'string', description: '建议修复/改进' },
    evidence: { type: 'string', description: '代码片段或调用链;FEAT 给"为什么用户受益"' },
  },
  required: ['category', 'severity', 'file', 'line', 'title', 'description', 'suggestion', 'evidence'],
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
    correctedFile: { type: 'string', description: '若 CORRECTED:修正后的文件;否则原值' },
    correctedLine: { type: 'string', description: '若 CORRECTED:修正后的行号;否则原值' },
    correctedSeverity: { type: 'string', description: '若 CORRECTED:校准后的等级;否则原值' },
    note: { type: 'string', description: '核对依据(grep 结果/读到的上下文);REJECTED 写否决理由' },
  },
  required: ['verdict', 'correctedFile', 'correctedLine', 'correctedSeverity', 'note'],
}

// ───────────────────────── prompt builders ─────────────────────────
const DROP_RULES = [
  '❌ 不要报无障碍 / accessibility / VoiceOver / Dynamic Type / 色盲对比度 —— 用户明确不关注,提到也 drop。',
  '❌ 不要做 OWASP 级安全审计 / 不要展开成专项 —— Lumory 是单人 iOS 日记 App,只顺手扫明显的硬编码 secret / fail-open 鉴权。',
  '❌ 不要建议大重构 / "该做 AI agent 化" 这类产品战略 —— 这是 review 不是 roadmap。',
].join('\n')

function repoContext() {
  let s = `仓库规模:${REPO.totalFiles || '?'} 文件 / ${REPO.totalLoc || '?'} LoC。`
  if (CHURN.length) s += `\n最近 90 天 churn 热点(风险高,重点看):\n  ${CHURN.join('\n  ')}`
  if (BIG.length) s += `\n大文件(>500 行,抽象/重构候选):\n  ${BIG.join('\n  ')}`
  return s
}

function reviewPrompt(a) {
  const globs = a.slices.flatMap((s) => SLICE_FILES[s] || []).join('  ')
  const isFeat = a.category === 'FEAT'
  const customNote = FOCUS === 'custom' && A.customFocusText ? `\n本次用户自定义重心:「${A.customFocusText}」—— 优先服务这个重心。` : ''
  let checklistBlock = ''
  if (a.label === 'lumory·checklist') {
    checklistBlock = `\n\n【逐条核对清单】对下面每条 grep + Read 验证仓里是否真违反,违反的写成 BUG finding(给 file:line + grep 证据),没违反的不用报:\n${LUMORY_CHECKLIST.map((c, i) => `  ${i + 1}. ${c}`).join('\n')}`
  }
  const featGuide = isFeat
    ? `\n\n【FEAT 视角要求】\n要的:具体场景的体验缺口/一致性补齐(如 "DiaryDetailView 图片预览缺 pinch-zoom 但 ImageViewerView 已实现,行为不一致")。\n不要的:模糊建议("加更多动画")、产品战略("AI 化")、CLAUDE.md Follow-up backlog 里已记的(可 grep 避重)。\n每条标改动量(小/中/大;大功能写 "需拆 epic")+ 用户受益理由(谁会触发、多高频)。`
    : `\n\n【BUG/OPT 量化要求】所有 "X 处"/"未被使用"/"N 次" 必须给 grep 结果或代码片段。行号尽量准,拿不准 line 写 "?"。`

  return `你是 Lumory 整仓审计的 ${a.label} reviewer(专项视角,只看这一个角度,其他角度有别人看)。
这是【对仓库现状的审计】,不是 diff review —— 找已经在 main 里、可能跑了几个月没人翻过的问题/机会。

${repoContext()}${customNote}

【你的 slice 文件范围】(用 Glob/Grep/Read 看这些,别自己猜路径):
  ${globs}

【你的专项 angle】${a.focus}${checklistBlock}${featGuide}

${DROP_RULES}

【输出】通过结构化工具返回 findings 数组,每条:category(${a.category})/severity/file/line/title/description/suggestion/evidence。
【ESCALATION】slice 太大没看完 → escalation.type=COVERAGE + detail 写没看完的区域;某 finding 影响大但你拿不准/可能误判 → type=FRESH_EYE + detail 写标题+位置;都没有 → type=NONE detail="无"。不要自己 spawn 子 agent,只发信号。`
}

function followupPrompt(e) {
  if (e.type === 'COVERAGE') {
    return `你是 Lumory 整仓审计的 follow-up reviewer。上一个 reviewer(${e.srcLabel})报告这块没看完:
「${e.detail}」
请彻底审这块未覆盖区域,用 Glob/Grep/Read 看代码。这是仓库现状审计不是 diff review。
${DROP_RULES}
通过结构化工具返回 findings 数组(category/severity/file/line/title/description/suggestion/evidence)。escalation 一般写 NONE。`
  }
  // FRESH_EYE —— 不告诉它原结论,避免锚定
  return `你是 Lumory 整仓审计的独立第二只眼。请【独立判断】下面这个位置有没有问题(别假设结论,自己 grep + Read 上下文 50 行下结论):
${e.detail}
${DROP_RULES}
通过结构化工具返回 findings 数组;如果你独立看下来也认为有问题就写成 finding(给证据),不认为有就返回空 findings + escalation NONE。`
}

function verifyPrompt(f) {
  if (f.category === 'FEAT') {
    return `核对一条 Lumory FEAT 提议(查"是否已实现"而非"是否真 bug")。
提议:[FEAT-${f.severity}] ${f.file}:${f.line} — ${f.title}
现状描述:${f.description}
请:(1) grep 关键词确认仓里是否已经实现了这个功能/体验(已实现 → REJECTED,写"已存在 at ...");(2) Read ${f.file} 对应区间确认 reviewer 描述的现状属实(描述错了 → REJECTED 或 CORRECTED);(3) grep CLAUDE.md "Follow-up backlog" 看是否已记录(已记 → note 标注"已在 backlog");(4) 校准等级。
通过结构化工具返回 verdict(CONFIRMED/CORRECTED/REJECTED/UNVERIFIABLE)+ corrected* + note。`
  }
  return `核对一条 Lumory BUG/OPT finding 的量化事实(Opus 在行号/计数/"未被使用"/库行为上系统性偏弱,必须实查)。
Finding:[${f.category}-${f.severity}] ${f.file}:${f.line} — ${f.title}
描述:${f.description}
证据(reviewer 给的):${f.evidence}
请按需:(1) Read ${f.file} 对应行区间确认 file:line 准确(不准 → CORRECTED 给正确行号);(2) "有 N 处"/"未被使用"/"dead code" → Grep 全仓实数一遍(含测试/xcconfig/plist);(3) "库 X 不会做 Y" → 用 context7 query-docs 查官方文档(别信记忆);(4) "一定崩/死锁" → 看实际调用入口顺序。(5) 校准等级:dead helper 里的 bug 降级、用户触发不到的降级。
通过结构化工具返回 verdict(CONFIRMED/CORRECTED/REJECTED/UNVERIFIABLE)+ corrected*(没改就回原值)+ note(核对依据;REJECTED 写理由)。`
}

// 把一批 findings 并行送 verify(在 pipeline stage 内调用,phase 显式传以防 race)
function verifyFindings(findings, phaseName) {
  if (!findings || !findings.length) return Promise.resolve([])
  return parallel(
    findings.map((f) => () =>
      agent(verifyPrompt(f), { schema: VERDICT_SCHEMA, agentType: 'general-purpose', model: 'opus', phase: phaseName, label: `verify:${(f.file || '?').split('/').pop()}` })
        .then((v) => ({ ...f, verdict: v || { verdict: 'UNVERIFIABLE', correctedFile: f.file, correctedLine: f.line, correctedSeverity: f.severity, note: 'verify 返回空' } }))
        .catch((err) => ({ ...f, verdict: { verdict: 'UNVERIFIABLE', correctedFile: f.file, correctedLine: f.line, correctedSeverity: f.severity, note: 'verify 异常: ' + String(err && err.message || err) } }))
    )
  )
}

// ───────────────────────── 主流程 ─────────────────────────
log(`megareview 编排:focus=${FOCUS} deadCode=${DEAD_CODE} → ${assignments.length} 个 reviewer(${assignments.map((a) => a.label).join(', ')})`)

// Phase Review:pipeline —— 每个 reviewer 的 findings 一出来立刻进 verify(无 barrier,边审边核)
phase('Review')
const reviewed = await pipeline(
  assignments,
  (a) => agent(reviewPrompt(a), { schema: FINDINGS_SCHEMA, agentType: a.agentType, model: 'opus', phase: 'Review', label: a.label }),
  (review, a) => {
    const r = review || { findings: [], escalation: { type: 'NONE', detail: '无' } }
    return verifyFindings(r.findings, 'Verify').then((vf) => ({ label: a.label, findings: vf, escalation: r.escalation }))
  }
)

// 收 escalation —— 全局 cap 4(barrier 在此是正确的:cap 是跨 item 的全局决策)
const escalations = reviewed
  .filter(Boolean)
  .filter((m) => m.escalation && m.escalation.type && m.escalation.type !== 'NONE')
  .map((m) => ({ type: m.escalation.type, detail: m.escalation.detail, srcLabel: m.label }))
  .slice(0, 4)

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

// 汇总:展平所有已核对 findings(保留 verdict,主 agent 据此分档/否决)
const mainFindings = reviewed.filter(Boolean).flatMap((m) => m.findings)
const allFindings = [...mainFindings, ...followFindings]

const rejected = allFindings.filter((f) => f.verdict && f.verdict.verdict === 'REJECTED')
const kept = allFindings.filter((f) => !f.verdict || f.verdict.verdict !== 'REJECTED').map(applyVerdict)

return {
  focus: FOCUS,
  deadCode: DEAD_CODE,
  repo: REPO,
  assignmentsRun: assignments.map((a) => a.label),
  escalations,
  counts: {
    total: allFindings.length,
    kept: kept.length,
    rejected: rejected.length,
    bug: kept.filter((f) => f.category === 'BUG').length,
    opt: kept.filter((f) => f.category === 'OPT').length,
    feat: kept.filter((f) => f.category === 'FEAT').length,
  },
  kept,       // 已核对、未否决的 findings(含 verdict 的 corrected* 校准)
  rejected,   // 核对不通过 → 报告写进 "已否决" 区
}
