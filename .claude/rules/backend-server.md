---
paths:
  - "server/**"
  - "ecosystem.config.js"
---

# Lumory 后端 — Node.js + Express 5 代理

部署在 `https://lumory.isaabby.com`(Cloudflare → nginx:443 → node:3000),PM2 进程管理。代码主体集中在 [index.js](server/index.js)(约 970 行量级,会随功能增长漂;Express 5 + pino + pino-http + express-rate-limit + axios + cors + dotenv)。其余:`package.json` / `package-lock.json` / `eslint.config.js`。`ecosystem.config.js`(PM2 配置:`lumory-server`,fork 模式,`max_memory_restart: 512M`)。

## 鉴权

- 所有 `/api/*` 要求 header `X-App-Secret`,**timing-safe compare**。未配 `APP_SHARED_SECRET` 直接 fail-closed(启动即退)。
- `/health` 不走鉴权,供健康探活。
- 后端 `OPENAI_API_KEY` 和 `APP_SHARED_SECRET` 都必须来自 `server/.env`,缺任一立刻 `process.exit(1)`。

## 速率限制

per-install(客户端 `X-Install-Id` = Keychain UUID,`InstallIdentity.current`)+ 全局 IP 兜底双层。
- `chat` 120/min per-install
- `embeddings` 300/min per-install
- **`transcriptions` 10/min per-install + 独立 60/min per-IP 兜底**(转写单价高 + 25 MB 上传量,故收紧)
- `/api` 整路径 600/min per-IP

合法 install-id 用 `/^[A-F0-9-]{36}$/i` 校验,非法 / 缺失回落 `ip:<req.ip>`。

## 请求体限制

- `chat` messages 总 char `MAX_MESSAGES_CHARS`(默认 32000,**十进制非 32768**)。
- `embedding` input `MAX_EMBEDDING_INPUT_CHARS`(默认 8192)。
- `transcription` 文件 `MAX_TRANSCRIPTION_FILE_BYTES`(默认 25 MB,OpenAI 上限),走 multer memoryStorage + MIME 白名单(`audio/mp4` / `m4a` / `mpeg` / `wav` / `webm` / `ogg` / `flac`)。
- `REQUEST_TIMEOUT_MS=120_000`(和客户端 `timeoutIntervalForResource=300s` 对齐,给长 SSE 流留余量)。

## 转写路由 model hardcode

`/api/openai/audio/transcriptions` 服务端固定 `gpt-4o-mini-transcribe`,**不读** client 传的 model 字段(信任边界在服务端,防客户端篡改改更贵模型)。`language` 字段如客户端传需 ISO-639-1 两字母 lowercase,否则丢弃让模型自动检测。

## SSE 错误处理

上游 stream 出错时 `res.destroy(error)`,**不能写 `data: [DONE]`**(客户端会把半截当成功)。

**`upstream.data.on('error', ...)` 必须在 `activeStreams.add(upstream.data)` 之前注册**(2026-05-15 superreview-4 P1):Node Readable 在无 `'error'` listener 时 emit `'error'` → `process.emit('uncaughtException')` → 走 `shutdown('uncaughtException')` 杀进程,所有在飞 SSE 流陪葬。`await axios()` resolve 到挂 listener 之间的任何同步代码都是 race 窗口(尤其客户端在同 microtick 内 abort,upstream 立即 emit error)。顺序固定:**`on('error', ...)` → `activeStreams.add` → `on('data', ...)` → `on('end', ...)`**。

**`activeStreams` 计数 invariant**:`add` 与 `delete` 严格成对,只在 `'end'` / `'error'` listener 体内 delete(不要在 `'data'` 分支 destroy upstream 然后忘记 delete —— 见 P1 round superreview)。`destroy()` 必须**带 Error 参数**,无 arg `destroy()` 只 emit `'close'` 不触发 `'error'` → `delete` 永不跑 → 泄漏。客户端中断走 sentinel `error.code === 'CLIENT_DISCONNECT'` 让 `'error'` handler 降级 log.info 而非 log.error。

## 日志

pino JSON → PM2 `logs/backend-out.log` / `backend-err.log`。headers 里的 `authorization` / `cookie` / `x-api-key` / `x-app-secret` 在 pino redact 里全部 `[REDACTED]`。

## 网络拓扑

Cloudflare edge(公共 cert)→ origin nginx:443(self-signed)→ node:3000。`app.set('trust proxy', 'loopback')`。

## 部署 / 运维

**`/root/server` 不是 git working copy**,手动维护。

改 devDep / dep:直接 SSH 跑 `npm uninstall <pkg>` / `npm install <pkg>@x.y.z` —— 同时同步 `package.json` + `node_modules`,不会 touch 其他字段。

改 `index.js` 部署流程(凭证存在 `~/.claude/.../memory/reference_lumory_server.md`,**不进 git**):

```bash
sshpass -p $PWD ssh root@$HOST 'cp /root/server/index.js{,.bak.$(date +%Y%m%d-%H%M%S)}'
scp server/index.js root@$HOST:/root/server/
ssh root@$HOST 'cd /root/server && node --check index.js && pm2 restart lumory-server'
curl https://lumory.isaabby.com/health
```

## 常用本地命令

- 启动:`npm start`
- 开发:`npm run dev`(nodemon)
- Lint:`npm run lint`
- Format:`npm run format`
- 生产重启(服务器上):`pm2 restart lumory-server`
- 健康探活(免鉴权):`curl https://lumory.isaabby.com/health`
