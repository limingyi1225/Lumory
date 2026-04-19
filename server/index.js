const path = require('path');
const crypto = require('crypto');
require('dotenv').config({ path: path.resolve(__dirname, '.env') });

const express = require('express');
const axios = require('axios');
const cors = require('cors');
const rateLimit = require('express-rate-limit');
const pino = require('pino');
const pinoHttp = require('pino-http');

const log = pino({
  level: process.env.LOG_LEVEL || 'info',
  base: { service: 'lumory-backend' },
  timestamp: pino.stdTimeFunctions.isoTime,
  // pino-http 默认 info 级打 req.headers 快照，
  // Authorization / Cookie / 自定义 shared-secret 头一落盘立即泄漏。全部 redact。
  redact: {
    paths: [
      'req.headers.authorization',
      'req.headers.cookie',
      'req.headers["x-api-key"]',
      'req.headers["x-app-secret"]',
    ],
    censor: '[REDACTED]',
  },
});

const OPENAI_API_KEY = process.env.OPENAI_API_KEY;
if (!OPENAI_API_KEY) {
  log.fatal('Missing OPENAI_API_KEY. Set it in server/.env');
  process.exit(1);
}
log.info(
  { maskedKey: `${OPENAI_API_KEY.substring(0, 7)}…` },
  'Loaded OPENAI_API_KEY'
);

// 客户端在每个请求里要带 `X-App-Secret: <APP_SHARED_SECRET>` 才放行。
// 没配就让 server 在启动时直接拒绝跑（fail-closed），避免无意识把不鉴权的代理暴露出去。
const APP_SHARED_SECRET = process.env.APP_SHARED_SECRET;
if (!APP_SHARED_SECRET) {
  log.fatal('Missing APP_SHARED_SECRET. Set it in server/.env — client must send X-App-Secret header.');
  process.exit(1);
}

const OPENAI_BASE_URL = 'https://api.openai.com/v1';
const REQUEST_TIMEOUT_MS = Number(process.env.OPENAI_TIMEOUT_MS) || 30_000;
const MAX_MESSAGES_CHARS = Number(process.env.MAX_MESSAGES_CHARS) || 32_000;
const MAX_EMBEDDING_INPUT_CHARS = Number(process.env.MAX_EMBEDDING_INPUT_CHARS) || 8_192;
const IS_PRODUCTION = process.env.NODE_ENV === 'production';

const app = express();
// 后端永远在 nginx:443 (loopback) 后面——信任 loopback 的 X-Forwarded-For 让
// `req.ip` 反映真实客户端 IP，而不是 127.0.0.1。不这样的话 express-rate-limit 的
// per-IP 桶会退化成"全 app 共享一个桶"。只 trust loopback，避免被非 nginx 来源伪造。
app.set('trust proxy', 'loopback');

// Express 5 不带 CORS。native client 并不会触发 preflight，但如果以后挂 web 面板 / 调试页，
// 默认 deny 比默认 open 安全——明确允许域名时再改。
app.use(cors({ origin: false }));
app.use(express.json({ limit: '1mb' }));
app.use(pinoHttp({ logger: log }));

// Shared-secret 鉴权中间件：time-safe compare 避免 timing attack 逐字节泄漏。
// 不挂在 /health 上，方便负载均衡 / PM2 健康检查。
function requireAppSecret(req, res, next) {
  const provided = req.get('x-app-secret') || '';
  const expected = APP_SHARED_SECRET;
  if (
    provided.length !== expected.length ||
    !crypto.timingSafeEqual(Buffer.from(provided), Buffer.from(expected))
  ) {
    req.log.warn('rejected: invalid or missing X-App-Secret');
    res.status(401).json({ error: 'unauthorized' });
    return;
  }
  next();
}

// 速率限制。分端点设阈值，单一 `/api` 上限太死会把"一键重建索引"打趴：
//   - Theme/Embedding 回填按条发请求（Theme batchSize=5 throttle=800ms → peak ~375/min；
//     Embedding batchSize=10 throttle=500ms → peak ~1200/min）
//   - 先前 30/min 的统一限在 30 条未缓存日记之后就连续 429，UI 以为成功其实半拉
// 分端点的好处：chat completions 是"贵"路径（完整 prompt + 长响应）收紧，embeddings 便宜一个
// 数量级放宽。客户端 backfill 的节流在下面 Swift 侧同步调整，保证 peak 永远低于此处 limit。
const chatLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 120,               // 2/s 平均 — 正常使用 + 主题回填不会打满
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'rate_limited' },
});

const embeddingsLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 300,               // 5/s 平均 — 给 embedding 回填 2.5-3/s peak 留一倍 headroom
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'rate_limited' },
});

// Health check. 不走鉴权，方便 PM2 / 负载均衡健康探活。
app.get('/health', (_req, res) => {
  res.json({ status: 'ok', message: 'Backend is running' });
});

// 鉴权挂到整个 /api；rate limit 按路径分别挂，避免 chat 和 embeddings 互相干扰。
app.use('/api', requireAppSecret);
app.use('/api/openai/chat/completions', chatLimiter);
app.use('/api/openai/embeddings', embeddingsLimiter);

// OpenAI proxy. Streaming vs buffered decided by `req.body.stream`.
app.post('/api/openai/chat/completions', async (req, res) => {
  const isStreaming = req.body?.stream === true;

  // Minimal shape validation — reject malformed bodies early so OpenAI doesn't.
  if (!Array.isArray(req.body?.messages) || req.body.messages.length === 0) {
    res.status(400).json({ error: 'Request body must include a non-empty `messages` array.' });
    return;
  }
  // 防止恶意超长 prompt（也挡了意外拼错 prompt 模板浪费 tokens 的失误）
  const totalChars = req.body.messages.reduce((acc, m) => acc + (typeof m?.content === 'string' ? m.content.length : 0), 0);
  if (totalChars > MAX_MESSAGES_CHARS) {
    res.status(413).json({ error: 'messages too large' });
    return;
  }

  try {
    if (isStreaming) {
      req.log.info('streaming request started');

      res.setHeader('Content-Type', 'text/event-stream');
      res.setHeader('Cache-Control', 'no-cache');
      res.setHeader('Connection', 'keep-alive');
      res.setHeader('X-Accel-Buffering', 'no');

      const upstream = await axios({
        method: 'post',
        url: `${OPENAI_BASE_URL}/chat/completions`,
        data: req.body,
        headers: {
          Authorization: `Bearer ${OPENAI_API_KEY}`,
          'Content-Type': 'application/json',
          Accept: 'text/event-stream',
        },
        responseType: 'stream',
        timeout: REQUEST_TIMEOUT_MS,
      });

      upstream.data.on('data', (chunk) => res.write(chunk));
      upstream.data.on('end', () => res.end());
      upstream.data.on('error', (error) => {
        req.log.error({ err: error }, 'upstream stream errored');
        // 不能写 `data: [DONE]`—— 那是 SSE 的**成功**终止帧，iOS 端的
        // `streamChat` 看到 `[DONE]` 会 `break` 并 `return result`，把半截
        // 流当完整响应回调给用户。硬破连接让客户端 `bytes.lines` 抛错，
        // 被 NetworkRetryHelper 接住重试；重试到头会把错误冒到 UI。
        res.destroy(error);
      });

      // Client disconnected — cancel upstream so we stop paying for the tokens.
      req.on('close', () => {
        if (!upstream.data.destroyed) {
          upstream.data.destroy();
        }
      });
    } else {
      req.log.info('non-streaming request started');

      const upstream = await axios.post(
        `${OPENAI_BASE_URL}/chat/completions`,
        req.body,
        {
          headers: {
            Authorization: `Bearer ${OPENAI_API_KEY}`,
            'Content-Type': 'application/json',
          },
          timeout: REQUEST_TIMEOUT_MS,
        }
      );
      res.json(upstream.data);
    }
  } catch (err) {
    const status = err.response?.status || (err.code === 'ECONNABORTED' ? 504 : 500);
    req.log.error({ err, status }, 'OpenAI request failed');
    if (!res.headersSent) {
      res.status(status).json({ error: sanitizeUpstreamError(err, status) });
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

  try {
    const upstream = await axios.post(
      `${OPENAI_BASE_URL}/embeddings`,
      {
        model: req.body.model || 'text-embedding-3-small',
        input: req.body.input,
      },
      {
        headers: {
          Authorization: `Bearer ${OPENAI_API_KEY}`,
          'Content-Type': 'application/json',
        },
        timeout: REQUEST_TIMEOUT_MS,
      }
    );
    res.json(upstream.data);
  } catch (err) {
    const status = err.response?.status || (err.code === 'ECONNABORTED' ? 504 : 500);
    req.log.error({ err, status }, 'OpenAI embeddings request failed');
    res.status(status).json({ error: sanitizeUpstreamError(err, status) });
  }
});

// 把 OpenAI 上游 error payload 按 status 归类成粗粒度错误返给客户端，
// 不再原样转发 `err.response.data`——上游 body 里常含 `error.type`/`error.param`/
// 模型内部标识等信息，不需要给客户端看到。
function sanitizeUpstreamError(err, status) {
  if (IS_PRODUCTION) {
    switch (status) {
      case 400: return { code: 'bad_request' };
      case 401:
      case 403: return { code: 'upstream_auth_error' };
      case 404: return { code: 'upstream_not_found' };
      case 408:
      case 504: return { code: 'upstream_timeout' };
      case 429: return { code: 'rate_limited' };
      case 502:
      case 503: return { code: 'upstream_unavailable' };
      default:  return { code: 'upstream_error' };
    }
  }
  // 非 prod：保留上游原始信息方便调试
  return err.response?.data || { message: err.message, code: err.code };
}

const port = process.env.PORT || 3000;
const server = app.listen(port, () => {
  log.info({ port, upstream: OPENAI_BASE_URL, timeoutMs: REQUEST_TIMEOUT_MS }, 'server listening');
});

// Graceful shutdown — give in-flight requests up to 10s to finish before exit.
const shutdown = (signal) => {
  log.info({ signal }, 'shutting down');
  server.close((err) => {
    if (err) {
      log.error({ err }, 'error during server.close');
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

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

process.on('unhandledRejection', (reason) => {
  log.error({ err: reason }, 'unhandledRejection');
});
process.on('uncaughtException', (err) => {
  log.fatal({ err }, 'uncaughtException');
  process.exit(1);
});
