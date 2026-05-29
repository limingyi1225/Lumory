const path = require('path');
const crypto = require('crypto');
const net = require('net');
require('dotenv').config({ path: path.resolve(__dirname, '.env') });

const express = require('express');
const axios = require('axios');
const rateLimit = require('express-rate-limit');
const pino = require('pino');
const pinoHttp = require('pino-http');
const multer = require('multer');

const log = pino({
  level: process.env.LOG_LEVEL || (process.env.NODE_ENV === 'production' ? 'warn' : 'info'),
  base: { service: 'lumory-backend' },
  timestamp: pino.stdTimeFunctions.isoTime,
  // pino-http 默认 info 级打 req.headers 快照，
  // Authorization / Cookie / 自定义 shared-secret 头一落盘立即泄漏。全部 redact。
  // req.body.* 路径：express.json middleware 把解析后的 body 挂到 req.body，pino-http 默认
  // 不 log body，但 err-path 里 `req.log.error({ err }, …)` 可能把 req 快照带上——把
  // 用户 prompt / 日记正文 / embedding input / 上游 OpenAI 错误 body 全挡在日志之外。
  // 注意:req.body.* / err.* 路径在 default serializer 下永远不会触发(default 只 log
  // method/url/headers/remoteAddress/remotePort)。这些 redact path 是 future-proof
  // 兜底 — 如果 future 改了 serializer 或显式 `log.info({ req }, ...)` 路径加上 body,
  // redact 自动生效防泄漏。同 path 的 err.* 兜底 axios 错误 body 落盘。
  redact: {
    paths: [
      'req.headers.authorization',
      'req.headers.cookie',
      'req.headers["x-api-key"]',
      'req.headers["x-app-secret"]',
      'req.headers["x-install-id"]',
      'req.body.messages[*].content',
      'req.body.input',
      'req.body.prompt',
      'err.response.data',
      'err.config.data',
      'err.config.headers.authorization',
      'err.config.headers.Authorization',
      'err.config.headers["x-app-secret"]',
      'err.config.headers["X-App-Secret"]',
      'err.request._header',
    ],
    censor: '[REDACTED]',
  },
});

const OPENAI_API_KEY = process.env.OPENAI_API_KEY;
if (!OPENAI_API_KEY) {
  log.fatal('Missing OPENAI_API_KEY. Set it in server/.env');
  process.exit(1);
}
log.info({ keyLength: OPENAI_API_KEY.length }, 'Loaded OPENAI_API_KEY');

// 客户端在每个请求里要带 `X-App-Secret: <APP_SHARED_SECRET>` 才放行。
// 没配就让 server 在启动时直接拒绝跑（fail-closed），避免无意识把不鉴权的代理暴露出去。
const APP_SHARED_SECRET = process.env.APP_SHARED_SECRET;
if (!APP_SHARED_SECRET) {
  log.fatal(
    'Missing APP_SHARED_SECRET. Set it in server/.env — client must send X-App-Secret header.'
  );
  process.exit(1);
}

const OPENAI_BASE_URL = 'https://api.openai.com/v1';
function positiveNumberEnv(name, defaultValue) {
  const value = Number(process.env[name]);
  return Number.isSafeInteger(value) && value > 0 ? value : defaultValue;
}

function modelAllowlistEnv(name, defaults) {
  const raw = process.env[name];
  if (!raw) return defaults;
  const models = raw
    .split(',')
    .map((model) => model.trim())
    .filter(Boolean);
  return models.length > 0 ? models : defaults;
}

// 长 SSE 流（Ask-Your-Past / NarrativeReader 拼全文回答）在高 reasoning_effort 下能跑 60–90s，
// 30s 上游 timeout 会在 token 还没流完时把连接 abort，客户端 NetworkRetryHelper 重试又从头
// 烧一遍 prompt cost。抬到 120s：留余量给 reasoning + 工具调用，同时和客户端
// URLSessionConfiguration.timeoutIntervalForResource = 300s 对齐（客户端传输层兜底更长，
// 保证上游超时在服务器侧先触发、客户端能看到干净的 504 而不是 "网络断了"）。
const REQUEST_TIMEOUT_MS = positiveNumberEnv('OPENAI_TIMEOUT_MS', 120_000);
// (megareview P2)流式 SSE 的 mid-stream idle 上限。axios 的 `timeout` 对 responseType:'stream'
// 只管到响应头(TTFB)—— settle 后 isDone=true,socket 级 req.setTimeout 的 handler 直接 no-op,
// **管不了 chunk 之间的空闲**。一个连上了、吐了头、然后卡死的上游,axios 不会主动掐,只能等
// 客户端 timeoutIntervalForResource=300s 兜底,期间白占一条连接 + upstream socket。这里给流式
// 自己挂 idle 计时器:每收到 chunk 重置,超过本值没新数据就 destroy upstream(走 'error' cleanup
// 链让客户端拿到断流并由 NetworkRetryHelper 重试)。取 120s = REQUEST_TIMEOUT_MS:既给 reasoning
// 模型首 token 前的思考留足余量(narrative reasoning=low/medium,首 token 一般 <30s),又远小于
// 客户端 300s 故能在客户端放弃前先回收。调小要权衡:别小于上游最慢的 chunk 间隔。
const STREAM_IDLE_TIMEOUT_MS = positiveNumberEnv('OPENAI_STREAM_IDLE_TIMEOUT_MS', 120_000);
const MAX_MESSAGES_CHARS = positiveNumberEnv('MAX_MESSAGES_CHARS', 32_000);
const MAX_EMBEDDING_INPUT_CHARS = positiveNumberEnv('MAX_EMBEDDING_INPUT_CHARS', 8_192);
const MAX_CHAT_COMPLETION_TOKENS = positiveNumberEnv('MAX_CHAT_COMPLETION_TOKENS', 16_384);
const DEFAULT_CHAT_COMPLETION_TOKENS = positiveNumberEnv('DEFAULT_CHAT_COMPLETION_TOKENS', 4_096);
const MAX_OPENAI_RESPONSE_BYTES = positiveNumberEnv('MAX_OPENAI_RESPONSE_BYTES', 8 * 1024 * 1024);
const GLOBAL_IP_LIMIT_MAX = positiveNumberEnv('GLOBAL_IP_LIMIT_MAX', 600);
const CHAT_MODEL_ALLOWLIST = new Set(
  modelAllowlistEnv('CHAT_MODEL_ALLOWLIST', ['gpt-5.5', 'gpt-5.4-mini'])
);
// Fallback 必须在当前 allowlist 内 —— 否则 cost-rollback 配置(把 allowlist 限制到只有 mini 时)
// 还会被 fallback 默默升回 gpt-5.5,绕过 incident-mitigation 意图。allowlist 总有至少一个值
// (modelAllowlistEnv 在 split 后空数组会回退到 defaults),first() 取确定项。
const CHAT_DEFAULT_MODEL = CHAT_MODEL_ALLOWLIST.has('gpt-5.5')
  ? 'gpt-5.5'
  : CHAT_MODEL_ALLOWLIST.values().next().value;
const EMBEDDING_MODEL = 'text-embedding-3-small';
// 转写模型 hardcode,不读 client `model` 字段——客户端可篡改 header,信任边界在服务端。
// 未来要 A/B 不同模型,在这里加 allowlist。
const TRANSCRIPTION_MODEL = 'gpt-4o-mini-transcribe';
// OpenAI `/audio/transcriptions` 上限 25 MB。multer 用 fileSize 触发 LIMIT_FILE_SIZE,
// 我们 catch 后回 413 给客户端,让客户端 banner 区分"分段录制"提示。
const MAX_TRANSCRIPTION_FILE_BYTES = positiveNumberEnv(
  'MAX_TRANSCRIPTION_FILE_BYTES',
  25 * 1024 * 1024
);
const MAX_TRANSCRIPTION_PROMPT_CHARS = positiveNumberEnv('MAX_TRANSCRIPTION_PROMPT_CHARS', 1_000);
// 客户端录音是 audio/mp4(AAC m4a),其他常见格式留余量。Content-Type 白名单挡掉
// 任意上传(被加 X-App-Secret 后,白名单是另一道防线)。
const TRANSCRIPTION_MIME_ALLOWLIST = new Set([
  'audio/mp4',
  'audio/m4a',
  'audio/x-m4a',
  'audio/mpeg',
  'audio/wav',
  'audio/x-wav',
  'audio/webm',
  'audio/ogg',
  'audio/flac',
]);
const IS_PRODUCTION = process.env.NODE_ENV === 'production';

const app = express();
app.disable('x-powered-by');
// 后端永远在 nginx:443 (loopback) 后面——信任 loopback 的 X-Forwarded-For 让
// `req.ip` 反映真实客户端 IP，而不是 127.0.0.1。不这样的话 express-rate-limit 的
// per-IP 桶会退化成"全 app 共享一个桶"。只 trust loopback，避免被非 nginx 来源伪造。
app.set('trust proxy', 'loopback');

// pino-http 必须挂在 requireAppSecret 之前,因为 auth 失败路径用 req.log.warn(line 179)。
// express.json 不在这里全局挂——见下方 `/api` middleware 链。
app.use(
  pinoHttp({
    logger: log,
    genReqId: (req, res) => {
      const existing = req.get('x-request-id');
      const id = existing || crypto.randomUUID();
      res.setHeader('x-request-id', id);
      return id;
    },
  })
);

// Tracker for in-flight SSE upstream streams so graceful shutdown can abort them.
const activeStreams = new Set();

// (2026-05-15 superreview P1)`unhandledRejection` 改 log-only(见 line 758)是有意识的
// trade-off,但缺监控阈值 → 真出现持续 promise 链 bug 时 PM2 健康检查照样过,silent failure。
// 暴露到 `/health` 供运维抓阈值告警。计数器存进程内,重启清零(对齐 PM2 重启语义)。

let unhandledRejectionCount = 0;

// (round-5 D11)抽出 handler 让 test 能直接调验"counter ++ + /health 透出"契约。
// 老 inline `process.on('unhandledRejection', (reason) => { ... })` 只在 `if (require.main === module)`
// 内挂,test 走 `require('./index')` 不会触发 → 完全无覆盖。导出 named function 后 test 直接调。
function recordUnhandledRejection(reason) {
  unhandledRejectionCount += 1;
  // (2026-05-15 superreview-4 P2)log 原始 `reason` 而不是 `safeUpstreamError(reason)`。
  // `safeUpstreamError` 抽 name/message/code/status,**丢 stack**;给 client 的 SSE 响应
  // 走那个抽取无可厚非(防 upstream 信息泄漏),但 unhandledRejection 是给自己 debug 看的,
  // 而且我们改 log-only 后不重启进程,stack 是唯一能定位野 promise 来源的线索。pino 用
  // `err` serializer 接到 Error 实例时会自动序列化 stack;非 Error reason(rare)就原样塞。
  log.error(
    { err: reason, count: unhandledRejectionCount },
    'unhandledRejection (continuing — not fatal)'
  );
}

// Shared-secret 鉴权中间件：time-safe compare 避免 timing attack 逐字节泄漏。
// 不挂在 /health 上，方便负载均衡 / PM2 健康检查。
function requireAppSecret(req, res, next) {
  const provided = req.get('x-app-secret') || '';
  const expected = APP_SHARED_SECRET;
  const providedBuffer = Buffer.from(provided);
  const expectedBuffer = Buffer.from(expected);
  if (
    providedBuffer.length !== expectedBuffer.length ||
    !crypto.timingSafeEqual(providedBuffer, expectedBuffer)
  ) {
    req.log.warn('rejected: invalid or missing X-App-Secret');
    res.status(401).json({ error: 'unauthorized' });
    return;
  }
  next();
}

// Per-install keyGenerator：客户端 `X-Install-Id` 带一个 keychain 里存的 UUID，
// 让 limiter 按"单个 App 安装"而非 IP 分桶。CGNAT / 公司 NAT / 校园网下多个用户共用
// 一个出口 IP，per-IP 会让第二个打开 App 的人直接撞 limit；per-install 单用户归单用户。
// 格式校验挡掉伪造 / 空 / 不合规字符串，fallback 回 IP（开发环境 simulator 也能跑通）。
const installKey = (req) => {
  const id = req.get('x-install-id');
  const normalized = normalizeInstallId(id);
  if (normalized) return 'install:' + normalized;
  return 'ip:' + clientIPKey(req);
};

function normalizeInstallId(id) {
  if (typeof id === 'string' && /^[A-F0-9-]{36}$/i.test(id)) return id.toLowerCase();
  return null;
}

function upstreamStatusForError(err) {
  if (err.response?.status) return err.response.status;
  if (['ECONNABORTED', 'ECONNRESET', 'ETIMEDOUT', 'ENOTFOUND', 'EAI_AGAIN'].includes(err.code)) {
    return 504;
  }
  return 500;
}

function ipv6Bytes(ip) {
  let normalized = ip.toLowerCase();
  if (normalized.includes('%')) {
    normalized = normalized.split('%')[0];
  }

  const parts = normalized.split('::');
  if (parts.length > 2) return null;

  const parseSide = (side) => {
    if (!side) return [];
    const groups = [];
    for (const raw of side.split(':')) {
      if (!raw) return null;
      if (raw.includes('.')) {
        if (net.isIP(raw) !== 4) return null;
        const octets = raw.split('.').map(Number);
        groups.push((octets[0] << 8) | octets[1], (octets[2] << 8) | octets[3]);
      } else {
        const value = Number.parseInt(raw, 16);
        if (!Number.isInteger(value) || value < 0 || value > 0xffff) return null;
        groups.push(value);
      }
    }
    return groups;
  };

  const left = parseSide(parts[0]);
  const right = parts.length === 2 ? parseSide(parts[1]) : [];
  if (!left || !right) return null;
  const missing = 8 - left.length - right.length;
  if (missing < 0 || (parts.length === 1 && missing !== 0)) return null;
  const groups = [...left, ...Array(missing).fill(0), ...right];
  if (groups.length !== 8) return null;

  const bytes = [];
  for (const group of groups) {
    bytes.push((group >> 8) & 0xff, group & 0xff);
  }
  return bytes;
}

function clientIPKey(req) {
  const ip = req.ip || req.socket?.remoteAddress || 'unknown';
  if (net.isIP(ip) !== 6) return ip;
  const bytes = ipv6Bytes(ip);
  if (!bytes) return ip;
  const isIPv4Mapped =
    bytes.slice(0, 10).every((byte) => byte === 0) && bytes[10] === 0xff && bytes[11] === 0xff;
  if (isIPv4Mapped) {
    return bytes.slice(12, 16).join('.');
  }
  const isLoopbackOrUnspecified =
    bytes.slice(0, 15).every((byte) => byte === 0) && (bytes[15] === 0 || bytes[15] === 1);
  if (isLoopbackOrUnspecified) {
    return ip;
  }
  // express-rate-limit 7.4.x does not expose ipKeyGenerator. Collapse IPv6 to
  // /56 so host-bit rotation inside the same client allocation shares one bucket.
  return `ipv6:${bytes
    .slice(0, 7)
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('')}/56`;
}

// 速率限制。分端点 + per-install (`X-Install-Id`) 按"单用户"计额。
//
// 额度要高于客户端 backfill 的理论 peak，否则"一键重建"会打半拉：
//   - ThemeBackfillService:    batchSize=2, throttleMs=1400 → peak ~85 req/min (走 chat)
//   - EmbeddingBackfillService: batchSize=3, throttleMs=900  → peak ~200 req/min
// 下面的数字和老 per-IP-共享值一致（chat 120 / embeddings 300），但语义变成
// "per-install 独占" —— 单用户拿到的配额实际比 per-IP 共享年代还宽松。
// 正常对话、Insights、主题回填都安全落在阈值下；恶意单 install 打满后还有
// globalIPLimiter (600/IP) 兜底。两层都不至于把服务器打爆。
const chatLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 120,
  standardHeaders: 'draft-7',
  legacyHeaders: false,
  keyGenerator: installKey,
  message: { error: 'rate_limited' },
});

const embeddingsLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 300,
  standardHeaders: 'draft-7',
  legacyHeaders: false,
  keyGenerator: installKey,
  message: { error: 'rate_limited' },
});

// 转写每个请求都是 25 MB 量级 + 上游单价比 chat 高,正常用户连续录音不会超过 10/min,
// 给 install 紧一点。X-Install-Id 是客户端头不是强安全边界,所以再加一道 per-IP 兜底。
const transcriptionsLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 10,
  standardHeaders: 'draft-7',
  legacyHeaders: false,
  keyGenerator: installKey,
  message: { error: 'rate_limited' },
});

// 转写专用 per-IP 兜底:全局 600/IP 对音频上传太宽,这条单独按 60/IP/min。
const transcriptionsIPLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 60,
  standardHeaders: 'draft-7',
  legacyHeaders: false,
  keyGenerator: clientIPKey,
  message: { error: 'rate_limited_global' },
});

// 全局 per-IP 兜底：per-install limiter 按 `X-Install-Id` 分桶，一个恶意客户端每次随机换
// install-id 就能绕过（每个新 id 拿新配额）。这一层按 IP 限流，挡住"单 IP 海量刷
// install-id"的放大攻击。阈值放得比 chat+embeddings 加起来还宽松——正常用户、甚至
// 一家人共用 NAT 也不会撞到；只有单 IP > 10/s 才会被挡。
const globalIPLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: GLOBAL_IP_LIMIT_MAX,
  standardHeaders: 'draft-7',
  legacyHeaders: false,
  keyGenerator: clientIPKey,
  message: { error: 'rate_limited_global' },
});

// Health check. 不走鉴权，方便 PM2 / 负载均衡健康探活。
app.get('/health', (_req, res) => {
  // (2026-05-15 superreview-2 P1)response body 含 `unhandledRejectionCount` /
  // `activeStreams.size` 实时计数,任何上游 cache(Cloudflare Page Rule /
  // nginx proxy_cache)缓存了运维拿到的就是冻结值,告警基线失真 → 强制不缓存。
  res.setHeader('Cache-Control', 'no-store');
  res.json({
    status: 'ok',
    message: 'Backend is running',
    unhandledRejectionCount,
    activeStreams: activeStreams.size,
  });
});

// 鉴权挂到整个 /api;通过鉴权后再计入 globalIPLimiter,避免未授权流量耗尽正常用户配额。
// globalIPLimiter 在 per-path limiter 前面:per-install 配额 + per-IP 上限两层保险。
// (megareview P1 #2)express.json 在 requireAppSecret 之后挂,**未鉴权请求不会消耗
// body parse 内存/CPU**(对 1MB cap 仍可放大),防 unauthenticated body amplification。
// globalIPLimiter 在 express.json 前面,让已鉴权但超全局配额的 JSON 请求不用先 parse 1MB body。
// 顺序固定:pino-http(已挂) → /api requireAppSecret → globalIPLimiter → express.json → endpoint limiters → handlers。
// transcriptions 路由用 multer multipart,不受 express.json 影响(json parser 只在
// Content-Type: application/json 时激活)。
function jsonBodyErrorHandler(err, req, res, next) {
  if (!err) {
    next();
    return;
  }
  if (err.type === 'entity.too.large') {
    res.status(413).json({ error: 'request_body_too_large' });
    return;
  }
  if (err instanceof SyntaxError && 'body' in err) {
    res.status(400).json({ error: 'invalid_json' });
    return;
  }
  next(err);
}

app.use(
  '/api',
  requireAppSecret,
  globalIPLimiter,
  express.json({ limit: '1mb' }),
  jsonBodyErrorHandler
);
app.use('/api/openai/chat/completions', chatLimiter);
app.use('/api/openai/embeddings', embeddingsLimiter);
// 转写挂双层:per-install 紧 + per-IP 独立兜底。注意挂的顺序在 multer 之前,
// 限流先于读取 multipart body —— 被限流时不浪费 25 MB 上传带宽。
app.use('/api/openai/audio/transcriptions', transcriptionsLimiter, transcriptionsIPLimiter);

function countContentChars(content) {
  if (typeof content === 'string') return content.length;
  if (Array.isArray(content)) {
    return content.reduce((total, part) => {
      if (part && part.type === 'text' && typeof part.text === 'string') {
        return total + part.text.length;
      }
      return total;
    }, 0);
  }
  return 0;
}

function countMessageContentChars(messages) {
  if (!Array.isArray(messages)) return 0;
  return messages.reduce((total, message) => total + countContentChars(message?.content), 0);
}

function sanitizeMessageContent(content) {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content
    .filter((part) => part && part.type === 'text' && typeof part.text === 'string')
    .map((part) => ({ type: 'text', text: part.text }));
}

function sanitizeReasoningEffort(model, effort) {
  if (model === 'gpt-5.4-mini') {
    return effort === 'low' ? 'low' : 'none';
  }
  if (effort === 'medium' || effort === 'high') return effort;
  return 'low';
}

function clampCompletionTokens(value) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric) || numeric <= 0) {
    return Math.min(DEFAULT_CHAT_COMPLETION_TOKENS, MAX_CHAT_COMPLETION_TOKENS);
  }
  return Math.min(Math.floor(numeric), MAX_CHAT_COMPLETION_TOKENS);
}

// 单次 chat 请求 messages 数组上限 — 防绕 char cap 用大量短 messages 撑大上游 token 计费
// (每条 message 有 ~7 token role/format overhead;1000 条 content="A" 通过 char cap 但
// 上游算 7000+ token。Lumory 客户端只发单 user message,64 上限对真实使用 0 影响)。
const MAX_MESSAGES_COUNT = 64;

function sanitizeChatBody(body) {
  const requestedModel = typeof body?.model === 'string' ? body.model : CHAT_DEFAULT_MODEL;
  const model = CHAT_MODEL_ALLOWLIST.has(requestedModel) ? requestedModel : CHAT_DEFAULT_MODEL;
  const messages = (Array.isArray(body?.messages) ? body.messages : []).map((message) => ({
    role: ['system', 'user', 'assistant'].includes(message?.role) ? message.role : 'user',
    content: sanitizeMessageContent(message?.content),
  }));

  const sanitized = {
    model,
    messages,
    stream: body?.stream === true ? true : undefined,
    reasoning_effort: sanitizeReasoningEffort(model, body?.reasoning_effort),
    max_completion_tokens: clampCompletionTokens(body?.max_completion_tokens),
  };

  if (body?.response_format?.type === 'json_object') {
    sanitized.response_format = { type: 'json_object' };
  }

  return sanitized;
}

function sseFrameHasDone(frame) {
  return frame.split(/\r?\n/).some((line) => {
    if (!line.startsWith('data:')) return false;
    return line.slice(5).trim() === '[DONE]';
  });
}

function safeUpstreamError(err) {
  return {
    name: err?.name,
    message: err?.message,
    code: err?.code,
    status: err?.response?.status,
  };
}

// OpenAI proxy. Streaming vs buffered decided by `req.body.stream`.
app.post('/api/openai/chat/completions', async (req, res) => {
  const isStreaming = req.body?.stream === true;

  // Minimal shape validation — reject malformed bodies early so OpenAI doesn't.
  if (!Array.isArray(req.body?.messages) || req.body.messages.length === 0) {
    res.status(400).json({ error: 'Request body must include a non-empty `messages` array.' });
    return;
  }
  if (req.body.messages.length > MAX_MESSAGES_COUNT) {
    res.status(400).json({ error: 'too many messages' });
    return;
  }
  const upstreamBody = sanitizeChatBody(req.body);
  // 防止恶意超长 prompt（也挡了意外拼错 prompt 模板浪费 tokens 的失误）
  const totalChars = countMessageContentChars(upstreamBody.messages);
  if (totalChars > MAX_MESSAGES_CHARS) {
    res.status(413).json({ error: 'messages too large' });
    return;
  }

  // abortUpstream lifted out of try so the catch block can `res.off('close', ...)` it —
  // axios() at line ~415 can throw (timeout / network / 401) **after** the listener is
  // registered, leaving the listener attached when control falls into the catch path.
  // Node Writable cleanup auto-removes listeners on destroy, but explicit `res.off` is
  // less fragile to refactor (lint flags "registered but never removed" for `on(...)` calls).
  let abortUpstream;
  try {
    if (isStreaming) {
      req.log.info('streaming request started');

      res.setHeader('Content-Type', 'text/event-stream');
      res.setHeader('Cache-Control', 'no-cache');
      res.setHeader('Connection', 'keep-alive');
      res.setHeader('X-Accel-Buffering', 'no');

      const abortController = new AbortController();
      abortUpstream = () => {
        abortController.abort();
      };
      // `req.on('aborted')` 在 Node 17+ deprecated,'close' 覆盖更全面(含 TCP RST、
      // Cloudflare 边缘超时切断)且对 HTTP/1.1 abort 是 superset。AbortController 自身
      // idempotent,理论上挂两个 listener 无副作用,但只挂 'close' 减一组 EventEmitter 记账。
      res.on('close', abortUpstream);

      const upstream = await axios({
        method: 'post',
        url: `${OPENAI_BASE_URL}/chat/completions`,
        data: upstreamBody,
        headers: {
          Authorization: `Bearer ${OPENAI_API_KEY}`,
          'Content-Type': 'application/json',
          Accept: 'text/event-stream',
        },
        responseType: 'stream',
        timeout: REQUEST_TIMEOUT_MS,
        signal: abortController.signal,
        // (megareview P3)对齐其余 3 处 axios(non-stream chat / embeddings / transcription)——
        // 上游地址硬编码到可信 OPENAI_BASE_URL,不应跟随任何 3xx 跳转(defense-in-depth:
        // 避免被重定向到别处时携带 Authorization bearer)。此前唯独流式漏设。
        maxRedirects: 0,
      });

      // (megareview P2)mid-stream idle 计时器(见 STREAM_IDLE_TIMEOUT_MS 处长注释)。
      // axios timeout 对流式只管 TTFB,管不了 chunk 间空闲,这里自己兜。每收到 chunk 重置;
      // 超时则带 sentinel destroy upstream → 落到下面的 'error' handler(非 CLIENT_DISCONNECT
      // 分支)log.error + res.destroy → 客户端断流重试。clearIdleTimer 幂等,end/error 都清。
      let idleTimer = null;
      const clearIdleTimer = () => {
        if (idleTimer) {
          clearTimeout(idleTimer);
          idleTimer = null;
        }
      };
      const armIdleTimer = () => {
        clearIdleTimer();
        idleTimer = setTimeout(() => {
          const idleError = new Error('upstream idle timeout');
          idleError.code = 'UPSTREAM_IDLE_TIMEOUT';
          upstream.data.destroy(idleError);
        }, STREAM_IDLE_TIMEOUT_MS);
      };

      // (2026-05-15 superreview-4 P1)`'error'` listener 必须**在 activeStreams.add 之前**挂。
      // Node Readable 在无 'error' listener 时 emit 'error' → `process.emit('uncaughtException')`
      // → line 799+ `shutdown('uncaughtException')` 杀进程,所有在飞 SSE 流陪葬。axios resolve 后
      // 到挂 'error' listener 之间的任何同步代码都是 race 窗口(尤其 client 紧跟 axios resolve
      // 同 microtick 内 abort,upstream 立即 emit error)。这里先把 listener 挂上再做 add /
      // 'data' / 'end',保证 race 窗口为 0。
      upstream.data.on('error', (error) => {
        clearIdleTimer();
        activeStreams.delete(upstream.data);
        res.off('close', abortUpstream);
        // (2026-05-15 superreview-2 P1)区分 client mid-stream 中断和真上游错误。
        // 前者每次用户切后台都会触发,不该灌 ERROR log 导致 PagerDuty 阈值告警麻木。
        // 不能写 `data: [DONE]`—— 那是 SSE 的**成功**终止帧，iOS 端的
        // `streamChat` 看到 `[DONE]` 会 `break` 并 `return result`，把半截
        // 流当完整响应回调给用户。硬破连接让客户端 `bytes.lines` 抛错，
        // 被 NetworkRetryHelper 接住重试；重试到头会把错误冒到 UI。
        if (error?.code === 'CLIENT_DISCONNECT') {
          // sentinel 是从 'data' 分支的 `if (res.destroyed)` 制造的,
          // 此时 res 必已 destroyed,不需要再 destroy。只 cleanup + log。
          req.log.info('client disconnect mid-stream — cleanup ran');
        } else {
          req.log.error({ err: safeUpstreamError(error) }, 'upstream stream errored');
          // 真上游错误:client 可能还活着,需要 destroy res 让客户端 SSEParser
          // 抛错被 NetworkRetryHelper 接住。`!res.destroyed` guard 防 race。
          if (!res.destroyed) {
            res.destroy(error);
          }
        }
      });

      activeStreams.add(upstream.data);
      armIdleTimer();

      let sawDone = false;
      let sseBuffer = '';
      upstream.data.on('data', (chunk) => {
        // (2026-05-15 megareview P2-22)res 已被 client-disconnect 销毁,abortUpstream 已发但
        // upstream 还可能 flush 一个 in-flight chunk;此时 res.write() 在已销毁 socket 上
        // emit 'ERR_STREAM_DESTROYED'。早期 return + 主动 destroy upstream 关 race。
        //
        // (2026-05-15 superreview P1)`destroy()` 无 arg 只 emit 'close',不触发 'end' / 'error'
        // → `activeStreams.delete()` 永不跑。传 Error 让 line 'error' handler 跑 cleanup。
        // (2026-05-15 superreview-2 P1)用 sentinel `code: CLIENT_DISCONNECT` 而非 message 字符串
        // 让 'error' handler 区分"客户端中断"(降级 log.info)和"真上游错误"(log.error)。
        if (res.destroyed) {
          const clientDisconnect = new Error('client disconnected');
          clientDisconnect.code = 'CLIENT_DISCONNECT';
          upstream.data.destroy(clientDisconnect);
          return;
        }
        armIdleTimer(); // 收到有效 chunk,重置 idle 计时器
        const text = chunk.toString('utf8');
        const combined = sseBuffer + text;
        const frames = combined.split(/\r?\n\r?\n/);
        sseBuffer = frames.pop() || '';
        if (!sawDone && (frames.some(sseFrameHasDone) || sseFrameHasDone(sseBuffer))) {
          sawDone = true;
        }
        if (sseBuffer.length > 8192) {
          sseBuffer = sseBuffer.slice(-8192);
        }
        if (!res.write(chunk)) {
          upstream.data.pause();
          // 已注册的 'drain' once-listener 还没 fire,不要再加 — 否则 sustained backpressure
          // 下每个 chunk 都注册新 once,drain fire 时同 tick 触发 N 个 resume()。`once` 自动 unbind,
          // 但 listener 短暂膨胀(N 个 once 监听)。
          if (res.listenerCount('drain') === 0) {
            res.once('drain', () => upstream.data.resume());
          }
        }
      });
      upstream.data.on('end', () => {
        clearIdleTimer();
        activeStreams.delete(upstream.data);
        res.off('close', abortUpstream);
        if (res.destroyed) {
          return;
        }
        if (!sawDone && sseFrameHasDone(sseBuffer)) {
          sawDone = true;
        }
        if (!sawDone) {
          res.destroy(new Error('upstream ended without [DONE]'));
          return;
        }
        res.end();
      });
      // 'error' listener 已在 activeStreams.add **之前**注册(见上)。
    } else {
      req.log.info('non-streaming request started');

      // 客户端断开时取消上游 OpenAI 请求,避免烧 token / 算 reasoning。
      // 跟流式分支(line 363-404)同 abortController 模式。
      const nonStreamAbort = new AbortController();
      const cancelOnClose = () => nonStreamAbort.abort();
      res.on('close', cancelOnClose);
      try {
        const upstream = await axios.post(`${OPENAI_BASE_URL}/chat/completions`, upstreamBody, {
          headers: {
            Authorization: `Bearer ${OPENAI_API_KEY}`,
            'Content-Type': 'application/json',
          },
          timeout: REQUEST_TIMEOUT_MS,
          signal: nonStreamAbort.signal,
          maxContentLength: MAX_OPENAI_RESPONSE_BYTES,
          maxRedirects: 0,
        });
        res.json(upstream.data);
      } finally {
        res.off('close', cancelOnClose);
      }
    }
  } catch (err) {
    // Cleanup listener on the streaming early-throw path — axios() reject before 'end' / 'error'
    // listeners attach leaves res.on('close', abortUpstream) dangling. Node Writable destroy will
    // sweep it eventually, but explicit off here keeps the EventEmitter accounting honest.
    if (isStreaming && abortUpstream) {
      res.off('close', abortUpstream);
    }
    if (isStreaming && err.code === 'ERR_CANCELED') {
      req.log.info('streaming request cancelled');
      if (!res.destroyed) {
        res.destroy(err);
      }
      return;
    }
    if (err.code === 'ERR_CANCELED') {
      // 非流式 chat 客户端断开 — 不再回 status 码(socket 已关)。
      req.log.info('non-streaming chat request cancelled');
      return;
    }
    const status = upstreamStatusForError(err);
    req.log.error({ err: safeUpstreamError(err), status }, 'OpenAI request failed');
    if (!res.headersSent) {
      const retryAfter = err.response?.headers?.['retry-after'];
      if (status === 429 && retryAfter) {
        res.setHeader('Retry-After', retryAfter);
      }
      res.status(status).json({ error: sanitizeUpstreamError(err, status) });
    } else if (isStreaming) {
      res.destroy(err);
    } else {
      res.end();
    }
  }
});

// Embeddings proxy — used by Lumory's semantic search & RAG ("Ask Your Past").
app.post('/api/openai/embeddings', async (req, res) => {
  if (typeof req.body?.input !== 'string' || req.body.input.length === 0) {
    res.status(400).json({ error: 'Request body must include a non-empty `input` string.' });
    return;
  }
  if (req.body.input.length > MAX_EMBEDDING_INPUT_CHARS) {
    res.status(413).json({ error: 'input too large' });
    return;
  }

  // 客户端断开时取消上游,避免烧无效 token。
  const embeddingAbort = new AbortController();
  const cancelOnClose = () => embeddingAbort.abort();
  res.on('close', cancelOnClose);

  try {
    const upstream = await axios.post(
      `${OPENAI_BASE_URL}/embeddings`,
      {
        model: EMBEDDING_MODEL,
        input: req.body.input,
      },
      {
        headers: {
          Authorization: `Bearer ${OPENAI_API_KEY}`,
          'Content-Type': 'application/json',
        },
        timeout: REQUEST_TIMEOUT_MS,
        signal: embeddingAbort.signal,
        maxContentLength: MAX_OPENAI_RESPONSE_BYTES,
        maxRedirects: 0,
      }
    );
    res.json(upstream.data);
  } catch (err) {
    if (err.code === 'ERR_CANCELED') {
      req.log.info('embeddings request cancelled');
      return;
    }
    const status = upstreamStatusForError(err);
    req.log.error({ err: safeUpstreamError(err), status }, 'OpenAI embeddings request failed');
    if (!res.headersSent) {
      const retryAfter = err.response?.headers?.['retry-after'];
      if (status === 429 && retryAfter) {
        res.setHeader('Retry-After', retryAfter);
      }
      res.status(status).json({ error: sanitizeUpstreamError(err, status) });
    } else {
      res.end();
    }
  } finally {
    res.off('close', cancelOnClose);
  }
});

// Transcriptions proxy. 客户端上传 m4a → 后端转发到 OpenAI /v1/audio/transcriptions。
//
// 设计要点:
//   - multer 内存模式 + 严格 limits(单文件 25 MB、最多 1 个 file 字段、最多 4 个 text 字段)
//   - Content-Type 白名单 (TRANSCRIPTION_MIME_ALLOWLIST) — 防任意文件冒充音频
//   - model 在服务端 hardcode TRANSCRIPTION_MODEL — **不读** client 字段,避免被改成更贵模型
//   - language 字段从 client 透传,但只接受 ISO-639-1 两字母 lowercase(否则丢弃,让模型自动检测)
//   - prompt 字段可透传,但服务端 trim + cap,防篡改客户端塞超长提示
//   - 失败用 res.json({ error: { code } }) 一致风格,前端 banner 据此分类
const transcriptionUpload = multer({
  storage: multer.memoryStorage(),
  limits: {
    fileSize: MAX_TRANSCRIPTION_FILE_BYTES,
    files: 1,
    fields: 4,
  },
  fileFilter: (_req, file, cb) => {
    if (TRANSCRIPTION_MIME_ALLOWLIST.has(file.mimetype)) {
      cb(null, true);
    } else {
      // multer 推荐用 cb(null, false) + 业务侧返回错误,而不是 cb(error) —— error 路径
      // 会让其他字段也丢。这里直接拒掉,handler 里检测 req.file 缺失回 415。
      cb(null, false);
    }
  },
});

app.post('/api/openai/audio/transcriptions', (req, res) => {
  transcriptionUpload.single('file')(req, res, async (uploadErr) => {
    if (uploadErr) {
      // multer 自己抛的错误最常见就是 LIMIT_FILE_SIZE / LIMIT_PART_COUNT 等。
      const code = uploadErr.code;
      if (code === 'LIMIT_FILE_SIZE') {
        req.log.warn({ code }, 'transcription file too large');
        res.status(413).json({ error: { code: 'file_too_large' } });
        return;
      }
      req.log.warn(
        { err: safeUpstreamError(uploadErr), code },
        'multer rejected transcription upload'
      );
      res.status(400).json({ error: { code: 'bad_request' } });
      return;
    }
    if (!req.file) {
      req.log.warn('transcription upload missing or rejected by mime filter');
      res.status(415).json({ error: { code: 'unsupported_media_type' } });
      return;
    }

    // language: 只接受 ISO-639-1 两字母 lowercase。客户端目前不传,留这道挡位为了之后
    // 想传时不踩规则不一致的坑(OpenAI 严格按 ISO-639-1 校验)。
    const rawLang = typeof req.body?.language === 'string' ? req.body.language : '';
    const language = /^[a-z]{2}$/.test(rawLang) ? rawLang : undefined;
    // prompt 允许客户端提供受控提示(例如限制中英自动检测),但仍按信任边界裁剪,
    // 防止被篡改客户端拿 shared secret 后塞超长 prompt 烧 token。
    const rawPrompt = typeof req.body?.prompt === 'string' ? req.body.prompt.trim() : '';
    const prompt =
      rawPrompt.length > 0 ? rawPrompt.slice(0, MAX_TRANSCRIPTION_PROMPT_CHARS) : undefined;

    // OpenAI 的 SDK 接受 multipart/form-data。我们手工拼,避免引第三方 form-data lib —— 一个
    // boundary + 几行 Content-Disposition 没必要装包。Node 18+ 自带 FormData/Blob。
    const form = new FormData();
    form.append('model', TRANSCRIPTION_MODEL);
    form.append('response_format', 'json');
    if (language) form.append('language', language);
    if (prompt) form.append('prompt', prompt);
    // 客户端可控字符串 sanitize — 即使 Node 18 FormData 自身会 escape `\r\n`(防 multipart header
    // injection),trust boundary 上仍不该让任意客户端字符串原样出现在传给 OpenAI 的 filename。
    // 收紧到 `[A-Za-z0-9._-]` 100 字节内,iOS native 客户端发的 `recording.m4a` 类正常文件名不受影响。
    const safeFilename =
      (req.file.originalname || 'audio.m4a').replace(/[^A-Za-z0-9._-]/g, '_').slice(0, 100) ||
      'audio.m4a';
    form.append('file', new Blob([req.file.buffer], { type: req.file.mimetype }), safeFilename);

    // 客户端断开时取消上游 — transcription 25 MB upload + 30-90s 上游耗时,
    // 不取消会让客户端关 sheet 后服务器仍跑完整套,烧无效 token。
    const transcriptionAbort = new AbortController();
    const cancelOnClose = () => transcriptionAbort.abort();
    res.on('close', cancelOnClose);

    try {
      const upstream = await axios.post(`${OPENAI_BASE_URL}/audio/transcriptions`, form, {
        headers: {
          Authorization: `Bearer ${OPENAI_API_KEY}`,
        },
        timeout: REQUEST_TIMEOUT_MS,
        // axios 默认会把 FormData 自动序列化并加 Content-Type: multipart/form-data; boundary=...
        // 不要手动设 Content-Type,会丢 boundary。
        maxBodyLength: MAX_TRANSCRIPTION_FILE_BYTES + 1024 * 1024, // 留 1 MB 余量给 multipart 头
        maxContentLength: MAX_OPENAI_RESPONSE_BYTES,
        maxRedirects: 0,
        signal: transcriptionAbort.signal,
      });

      // OpenAI 返回 { text: "..." }(其他元字段如 duration / language 不透出给客户端,只回 text)
      const text = typeof upstream.data?.text === 'string' ? upstream.data.text : '';
      res.json({ text });
    } catch (err) {
      if (err.code === 'ERR_CANCELED') {
        req.log.info('transcription request cancelled');
        return;
      }
      const status = upstreamStatusForError(err);
      req.log.error({ err: safeUpstreamError(err), status }, 'OpenAI transcription request failed');
      if (!res.headersSent) {
        const retryAfter = err.response?.headers?.['retry-after'];
        if (status === 429 && retryAfter) {
          res.setHeader('Retry-After', retryAfter);
        }
        res.status(status).json({ error: sanitizeUpstreamError(err, status) });
      } else {
        res.end();
      }
    } finally {
      res.off('close', cancelOnClose);
    }
  });
});

// 把 OpenAI 上游 error payload 按 status 归类成粗粒度错误返给客户端，
// 不再原样转发 `err.response.data`——上游 body 里常含 `error.type`/`error.param`/
// 模型内部标识等信息，不需要给客户端看到。
function sanitizeUpstreamError(err, status) {
  if (IS_PRODUCTION) {
    switch (status) {
      case 400:
        return { code: 'bad_request' };
      case 401:
      case 403:
        return { code: 'upstream_auth_error' };
      case 404:
        return { code: 'upstream_not_found' };
      case 408:
      case 504:
        return { code: 'upstream_timeout' };
      case 429:
        return { code: 'rate_limited' };
      case 502:
      case 503:
        return { code: 'upstream_unavailable' };
      default:
        return { code: 'upstream_error' };
    }
  }
  // 非 prod：仍然不回传上游原始 body，只回 HTTP status + axios 侧的 err.code
  // （ECONNABORTED / ENOTFOUND 等），避免 OpenAI error.type/error.param 等内部
  // 标识泄漏给客户端调试控制台。
  return { code: err.code || 'upstream_error', status };
}

function startServer() {
  const port = process.env.PORT || 3000;
  return app.listen(port, () => {
    log.info(
      { port, upstream: OPENAI_BASE_URL, timeoutMs: REQUEST_TIMEOUT_MS },
      'server listening'
    );
  });
}

// Graceful shutdown — give in-flight requests up to 10s to finish before exit.
//
// **Reentrancy guard**:`unhandledRejection` / `uncaughtException` 重新导向走这条路径时,
// 多个信号同 tick 触发会让 `activeServer.close()` 在第二次 call 时同步抛 ERR_SERVER_NOT_RUNNING
// → `process.exit(1)`(应该是 0)。PM2 看到 exit 1 计入 unstable_restarts。守 1 行 flag 拦掉。
let shuttingDownGate = false;
const shutdown = (signal) => {
  if (shuttingDownGate) {
    log.warn({ signal }, 'shutdown already in progress, ignoring duplicate signal');
    return;
  }
  shuttingDownGate = true;
  log.info({ signal, activeStreams: activeStreams.size }, 'shutting down');
  // Abort in-flight upstream SSE streams so they don't dangle past server.close().
  // Their 'error' handler will fire and `res.destroy(error)` the client connection,
  // letting NetworkRetryHelper on iOS retry against the next process.
  //
  // ⚠️ Must pass an Error to `destroy()` — calling `s.destroy()` with no arg emits
  // `close` only, NOT `error`, so the `upstream.data.on('error', ...)` handler that
  // ends `res` never fires. Without that, `server.close()` blocks on the open
  // keep-alive connection, the 10s safety timeout fires, and PM2 force-kills us
  // (client sees an abrupt cut instead of a clean disconnect).
  const shutdownErr = new Error('server shutting down');
  shutdownErr.code = 'SHUTDOWN';
  for (const s of activeStreams) {
    try {
      s.destroy(shutdownErr);
    } catch (e) {
      log.warn({ err: safeUpstreamError(e) }, 'error destroying active stream during shutdown');
    }
  }
  activeStreams.clear();
  activeServer.close((err) => {
    if (err) {
      log.error({ err: safeUpstreamError(err) }, 'error during server.close');
      process.exit(1);
    }
    process.exit(0);
  });
  // Safety net — kill the process if something hangs.
  setTimeout(() => {
    log.warn('forced shutdown after timeout');
    process.exit(1);
  }, 10_000).unref();
};

let activeServer;
if (require.main === module) {
  activeServer = startServer();

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGHUP', () => shutdown('SIGHUP'));

  // (2026-05-15 megareview OPT-MID-6)`unhandledRejection` 改 log-only,不再触发 shutdown。
  // 老路径:任何 await 路径上的野 promise 拒绝 → 整个 server 重启 → 所有在飞 SSE 流被打断。
  // 代理场景下 unhandledRejection 几乎都是非致命的(下游 OpenAI 抛错没 catch 等),不应等同
  // `uncaughtException`。`uncaughtException` 仍 fatal — 那个真的可能让进程处于 corrupt 状态。
  process.on('unhandledRejection', recordUnhandledRejection);
  process.on('uncaughtException', (err) => {
    log.fatal({ err: safeUpstreamError(err) }, 'uncaughtException');
    shutdown('uncaughtException');
  });
}

module.exports = {
  app,
  recordUnhandledRejection,
  countMessageContentChars,
  positiveNumberEnv,
  modelAllowlistEnv,
  sanitizeChatBody,
  sanitizeUpstreamError,
  sseFrameHasDone,
  normalizeInstallId,
  clientIPKey,
  upstreamStatusForError,
  startServer,
};
