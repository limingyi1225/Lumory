// Health endpoint contract + SSE upstream-error invariant tests.
//
// Two groups:
//   1. /health is auth-free and limiter-free — required for PM2 / Cloudflare /
//      nginx liveness probes. If anyone ever moves `requireAppSecret` from
//      `app.use('/api', ...)` to a global `app.use(...)`, /health will start
//      401-ing and the box will silently drop out of rotation. These tests
//      lock that contract.
//   2. SSE upstream errors must NOT emit `data: [DONE]`. The iOS SSEParser
//      treats `[DONE]` as the success terminator (break + return collected
//      content), so writing it after a partial stream would surface a
//      truncated answer as "complete" with no retry. server/index.js:436
//      destroys the socket; server/index.js:423 also destroys on
//      "ended-without-DONE". These tests prove neither path leaks `[DONE]`.

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { PassThrough } = require('node:stream');
const axios = require('axios');

process.env.OPENAI_API_KEY = process.env.OPENAI_API_KEY || 'test-openai-key';
process.env.ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY || 'test-anthropic-key';
process.env.APP_SHARED_SECRET = process.env.APP_SHARED_SECRET || 'test-app-secret';
process.env.GLOBAL_IP_LIMIT_MAX = process.env.GLOBAL_IP_LIMIT_MAX || '3';
process.env.NODE_ENV = 'test';

const {
  app,
  recordUnhandledRejection,
  sanitizeAnthropicBody,
  sseFrameHasMessageStop,
} = require('./index');

function listen(app) {
  return new Promise((resolve, reject) => {
    const server = app.listen(0, '127.0.0.1', () => resolve(server));
    server.on('error', reject);
  });
}

function close(server) {
  return new Promise((resolve, reject) => {
    server.close((err) => (err ? reject(err) : resolve()));
  });
}

// Poll /health until predicate(body) is true or timeout. Replaces brittle
// `setTimeout(150)` waits — those depend on CI scheduler luck; this one
// loops fast and only spends the wall-clock time it actually needs.
async function pollHealth(
  server,
  predicate,
  { timeoutMs = 1000, intervalMs = 25, label = 'pollHealth' } = {}
) {
  const deadline = Date.now() + timeoutMs;
  let lastBody = null;
  while (Date.now() < deadline) {
    const { body } = await getJSON(server, '/health');
    lastBody = body;
    if (predicate(body)) return body;
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  throw new Error(
    `${label} — predicate never satisfied within ${timeoutMs}ms; last /health body: ${JSON.stringify(lastBody)}`
  );
}

// GET helper — collects status + body, no rejection on non-2xx.
function getJSON(server, path, headers = {}) {
  return new Promise((resolve, reject) => {
    const { port } = server.address();
    const req = http.request(
      {
        method: 'GET',
        host: '127.0.0.1',
        port,
        path,
        headers,
      },
      (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => {
          const body = Buffer.concat(chunks).toString('utf8');
          let parsed = null;
          try {
            parsed = JSON.parse(body);
          } catch {
            // leave as null; caller can inspect raw if needed
          }
          resolve({ status: res.statusCode, body: parsed, raw: body });
        });
      }
    );
    req.on('error', reject);
    req.end();
  });
}

// ---------------------------------------------------------------------------
// Group 1 — /health is unauthenticated and unmetered
// ---------------------------------------------------------------------------

test('health_responds200WithoutAppSecret', async (t) => {
  // Most important contract: PM2 / nginx / Cloudflare probe `/health` with no
  // auth header. If `requireAppSecret` ever leaks onto this path, the probe
  // 401s and the host gets pulled from rotation.
  const server = await listen(app);
  t.after(() => close(server));

  const { status, body } = await getJSON(server, '/health');
  assert.equal(status, 200);
  assert.equal(body?.status, 'ok');
});

test('health_responds200EvenWithBogusAppSecret', async (t) => {
  // Defensive: a wrong secret must NOT break /health either. This catches a
  // future refactor that mounts `requireAppSecret` globally — in that world a
  // probe sending a stale secret would fail-closed instead of bypassing auth.
  const server = await listen(app);
  t.after(() => close(server));

  const { status, body } = await getJSON(server, '/health', {
    'X-App-Secret': 'not-the-real-secret',
  });
  assert.equal(status, 200);
  assert.equal(body?.status, 'ok');
});

test('health_responds200WithoutInstallId', async (t) => {
  // Defensive: /health must not be subject to per-install or global IP rate
  // limiters either. Probes hammer this endpoint and must never 429. This
  // catches a future refactor that hangs `globalIPLimiter` outside `/api`.
  const server = await listen(app);
  t.after(() => close(server));

  // Hit it 5x rapidly with no install-id. GLOBAL_IP_LIMIT_MAX=3 in test env,
  // so if a limiter were attached we'd see a 429 by the 4th call.
  for (let i = 0; i < 5; i += 1) {
    const { status, body } = await getJSON(server, '/health');
    assert.equal(status, 200, `iteration ${i} expected 200, got ${status}`);
    assert.equal(body?.status, 'ok');
  }
});

// ---------------------------------------------------------------------------
// Group 2 — SSE upstream errors must destroy the socket without writing [DONE]
// ---------------------------------------------------------------------------

// Drives a streaming chat request through a mocked axios adapter. Returns a
// Promise that resolves with { body, closed } when the client response ends or
// the socket closes. Mirrors the pattern in server/index.test.js:239.
function runStreamingChat({ port, xff, install, secret, payload }) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(payload);
    const req = http.request(
      {
        method: 'POST',
        host: '127.0.0.1',
        port,
        path: '/api/openai/chat/completions',
        headers: {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(data),
          'X-App-Secret': secret,
          'X-Install-Id': install,
          'X-Forwarded-For': xff,
        },
      },
      (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('close', () => {
          const body = Buffer.concat(chunks).toString('utf8');
          resolve({ body, complete: res.complete, statusCode: res.statusCode });
        });
        res.on('error', () => {
          // socket-level error is the expected destroy path; resolve with what
          // we collected so the assertions can run on partial content.
          const body = Buffer.concat(chunks).toString('utf8');
          resolve({ body, complete: false, statusCode: res.statusCode });
        });
      }
    );
    // Server destroys the socket on upstream error/end-without-DONE; node may
    // surface that as a request-side ECONNRESET. Don't reject — the response
    // handler above will resolve with whatever bytes made it through.
    req.on('error', () => {});
    req.end(data);
    // Safety: never let the test hang if neither side fires.
    setTimeout(() => reject(new Error('runStreamingChat timeout')), 3000).unref();
  });
}

test('chat_streamingUpstreamError_destroysClientSocketWithoutSendingDone', async (t) => {
  // Upstream OpenAI mid-stream blowup. Server must:
  //   (a) NOT inject `data: [DONE]` (would lie to client about completeness)
  //   (b) destroy the socket so the iOS SSEParser surfaces the error and
  //       NetworkRetryHelper retries.
  // The first partial frame must reach the client to prove the stream was
  // actually live before the destroy fired (i.e. we're testing the error
  // branch, not the "auth failed before any bytes" branch).
  const originalAdapter = axios.defaults.adapter;
  let upstream;

  axios.defaults.adapter = async (config) => {
    upstream = new PassThrough();
    // Schedule the upstream behavior on next tick so axios returns the
    // response object first and the server wires up its 'data'/'error'
    // listeners before we push frames.
    setImmediate(() => {
      upstream.write('data: {"choices":[{"delta":{"content":"hel"}}]}\n\n');
      setImmediate(() => {
        upstream.destroy(new Error('upstream blew up'));
      });
    });
    return {
      status: 200,
      statusText: 'OK',
      headers: { 'content-type': 'text/event-stream' },
      config,
      data: upstream,
      request: {},
    };
  };

  t.after(() => {
    axios.defaults.adapter = originalAdapter;
    upstream?.destroy();
  });

  const server = await listen(app);
  t.after(() => close(server));

  const { port } = server.address();
  const { body, complete } = await runStreamingChat({
    port,
    xff: '10.60.10.4',
    install: 'a7d9673d-eba6-4cf8-a209-cc87f4f7cbba',
    secret: process.env.APP_SHARED_SECRET,
    payload: {
      model: 'gpt-5.5',
      stream: true,
      messages: [{ role: 'user', content: 'hello' }],
    },
  });

  // Critical invariant: NEVER `data: [DONE]` on the error path.
  assert.equal(
    body.includes('data: [DONE]'),
    false,
    'server must not write SSE [DONE] terminator on upstream error'
  );
  // Partial content was relayed before the destroy — proves the stream was
  // genuinely interrupted, not aborted before any bytes flowed.
  assert.equal(
    body.includes('"hel"'),
    true,
    'expected partial frame "hel" to reach client before destroy'
  );
  // (2026-05-15 superreview-4 P2)Symmetry with the "ended without DONE"
  // test below — the upstream-error path must also destroy the socket
  // (`complete=false`), not cleanly end. Otherwise the client treats a
  // truncated stream as a clean close.
  assert.equal(
    complete,
    false,
    'upstream error must leave response incomplete (socket destroyed, not res.end)'
  );

  // (2026-05-15 superreview-4 P1#4)Regression test for round-2 P1
  // `activeStreams` leak fix. The `.on('error')` handler must call
  // `activeStreams.delete(upstream.data)` on the **upstream error** path,
  // not just the client-disconnect path. Without this assertion a future
  // refactor that drops the delete (or reorders 'error' listener after
  // add) would silently regress.
  await pollHealth(server, (b) => b?.activeStreams === 0, {
    timeoutMs: 1000,
    label: 'upstream error path must release activeStreams',
  });
});

test('chat_clientDisconnectMidStream_releasesActiveStreamsReference', async (t) => {
  // (2026-05-15 superreview P1#1)Regression test for the leak where
  // `if (res.destroyed) { upstream.data.destroy(); return; }` used a no-arg
  // `destroy()` that only emitted 'close', not 'end' or 'error'. That left
  // the stream reference in `activeStreams` until process restart.
  //
  // Fix: pass an Error to destroy() so the 'error' handler runs the
  // `activeStreams.delete()` cleanup. This test drives the path:
  //   1. Upstream emits a frame.
  //   2. Client receives it and destroys the request (mid-stream abort).
  //   3. Server's `abortUpstream` fires, then next upstream chunk triggers
  //      the `if (res.destroyed)` branch.
  //   4. After the dust settles, /health should report activeStreams: 0.
  const originalAdapter = axios.defaults.adapter;
  let upstream;
  let pushInterval;

  axios.defaults.adapter = async (config) => {
    upstream = new PassThrough();
    // Keep pushing frames slowly so a chunk arrives AFTER the client aborts.
    // First frame fires soon enough that the client receives it.
    setImmediate(() => {
      upstream.write('data: {"choices":[{"delta":{"content":"a"}}]}\n\n');
    });
    pushInterval = setInterval(() => {
      if (upstream.destroyed) return;
      upstream.write('data: {"choices":[{"delta":{"content":"x"}}]}\n\n');
    }, 30);
    return {
      status: 200,
      statusText: 'OK',
      headers: { 'content-type': 'text/event-stream' },
      config,
      data: upstream,
      request: {},
    };
  };

  t.after(() => {
    axios.defaults.adapter = originalAdapter;
    if (pushInterval) clearInterval(pushInterval);
    upstream?.destroy();
  });

  const server = await listen(app);
  t.after(() => close(server));

  const { port } = server.address();

  // Manually drive the request: abort after first chunk so we exercise the
  // `res.destroyed` branch on the server side.
  await new Promise((resolve, reject) => {
    const data = JSON.stringify({
      model: 'gpt-5.5',
      stream: true,
      messages: [{ role: 'user', content: 'hello' }],
    });
    const req = http.request(
      {
        method: 'POST',
        host: '127.0.0.1',
        port,
        path: '/api/openai/chat/completions',
        headers: {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(data),
          'X-App-Secret': process.env.APP_SHARED_SECRET,
          'X-Install-Id': 'a7d9673d-eba6-4cf8-a209-cc87f4f7ccc1',
          'X-Forwarded-For': '10.60.10.6',
        },
      },
      (res) => {
        res.once('data', () => {
          // Client mid-stream abort.
          req.destroy();
          resolve();
        });
        res.on('error', () => resolve());
        res.on('close', () => resolve());
      }
    );
    req.on('error', () => resolve());
    req.end(data);
    setTimeout(() => reject(new Error('client-abort test timeout')), 3000).unref();
  });

  // Critical invariant: activeStreams must NOT retain the reference.
  // /health exposes the counter so we can observe it without poking internals.
  // (2026-05-15 superreview-4 P2)`setTimeout(150)` 旧实现在慢 CI 上不一定够;
  // 改 polling 既稳又只花真正需要的 wall-clock。
  await pollHealth(server, (b) => b?.activeStreams === 0, {
    timeoutMs: 1000,
    label: 'client disconnect path must release activeStreams',
  });
});

test('chat_streamingUpstreamEndsWithoutDone_destroysClientSocket', async (t) => {
  // Distinct defense (server/index.js:422-424): upstream ends gracefully but
  // never sent `data: [DONE]`. OpenAI doing this means a truncated response;
  // server must `res.destroy(new Error('upstream ended without [DONE]'))`
  // rather than silently `res.end()` (which would also look like success on
  // the client side).
  const originalAdapter = axios.defaults.adapter;
  let upstream;

  axios.defaults.adapter = async (config) => {
    upstream = new PassThrough();
    setImmediate(() => {
      upstream.write('data: {"choices":[{"delta":{"content":"hi"}}]}\n\n');
      setImmediate(() => {
        upstream.end(); // graceful end, no [DONE]
      });
    });
    return {
      status: 200,
      statusText: 'OK',
      headers: { 'content-type': 'text/event-stream' },
      config,
      data: upstream,
      request: {},
    };
  };

  t.after(() => {
    axios.defaults.adapter = originalAdapter;
    upstream?.destroy();
  });

  const server = await listen(app);
  t.after(() => close(server));

  const { port } = server.address();
  const { body, complete } = await runStreamingChat({
    port,
    xff: '10.60.10.5',
    install: 'a7d9673d-eba6-4cf8-a209-cc87f4f7cbbc',
    secret: process.env.APP_SHARED_SECRET,
    payload: {
      model: 'gpt-5.5',
      stream: true,
      messages: [{ role: 'user', content: 'hello' }],
    },
  });

  // Invariant 1: still no [DONE] on the wire — the whole point of the defense
  // is that an "ended-without-DONE" upstream cannot masquerade as success.
  assert.equal(
    body.includes('data: [DONE]'),
    false,
    'server must not synthesize [DONE] when upstream ended without it'
  );
  // Invariant 2: response was destroyed mid-flight, not gracefully ended.
  // node's http response has `complete=true` only if the message finished
  // cleanly; a destroyed socket leaves it false.
  assert.equal(complete, false, 'response must be destroyed (complete=false), not ended cleanly');
  // Sanity: the partial frame did reach the client before the destroy.
  assert.equal(body.includes('"hi"'), true, 'expected partial frame "hi" to reach client');
});

// ---------------------------------------------------------------------------
// Group 2b — Anthropic proxy invariants
// ---------------------------------------------------------------------------

test('anthropic_sanitizeBody_enforcesAllowlistAndKnownShapes', () => {
  // 信任边界契约:model 不在 allowlist 回落默认、thinking 仅 adaptive 透传、
  // output_config 只认 effort + json_schema、system 仅 string。
  const sanitized = sanitizeAnthropicBody({
    model: 'claude-fancy-9000',
    system: 'sys prompt',
    messages: [
      { role: 'user', content: 'hi' },
      { role: 'system', content: 'sneaky' }, // Anthropic messages 无 system role → 归一 user
    ],
    max_tokens: 999999,
    thinking: { type: 'enabled', budget_tokens: 5000 }, // Opus 4.8 上会 400 → 必须丢弃
    output_config: {
      effort: 'xhigh', // 不在 [low,medium,high] → 丢弃
      format: { type: 'json_schema', schema: { type: 'object' } },
    },
  });

  assert.equal(sanitized.model, 'claude-opus-4-8');
  assert.equal(sanitized.system, 'sys prompt');
  assert.equal(sanitized.messages[1].role, 'user');
  assert.ok(sanitized.max_tokens <= 16384);
  assert.equal(sanitized.thinking, undefined);
  assert.equal(sanitized.output_config.effort, undefined);
  assert.deepEqual(sanitized.output_config.format, {
    type: 'json_schema',
    schema: { type: 'object' },
  });

  const adaptive = sanitizeAnthropicBody({
    messages: [{ role: 'user', content: 'hi' }],
    thinking: { type: 'adaptive' },
    output_config: { effort: 'medium' },
  });
  assert.deepEqual(adaptive.thinking, { type: 'adaptive' });
  assert.equal(adaptive.output_config.effort, 'medium');
});

test('anthropic_sseFrameHasMessageStop_matchesEventLineOnly', () => {
  assert.equal(sseFrameHasMessageStop('event: message_stop\ndata: {"type":"message_stop"}'), true);
  assert.equal(sseFrameHasMessageStop('event:message_stop'), true);
  // data 行里出现 message_stop 字样不算(必须是 event: 行)
  assert.equal(sseFrameHasMessageStop('data: {"text":"message_stop"}'), false);
  assert.equal(
    sseFrameHasMessageStop('event: content_block_delta\ndata: {"delta":{"text":"hi"}}'),
    false
  );
});

test('anthropic_streamingUpstreamEndsWithoutMessageStop_destroysClientSocket', async (t) => {
  // 与 OpenAI 路由 "ended without [DONE]" 同款防御:Anthropic 流正常结束但没发
  // message_stop = 半截流,必须 destroy 而不是干净 end(否则客户端把残篇当完整)。
  const originalAdapter = axios.defaults.adapter;
  let upstream;

  axios.defaults.adapter = async (config) => {
    upstream = new PassThrough();
    setImmediate(() => {
      upstream.write(
        'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}\n\n'
      );
      setImmediate(() => {
        upstream.end(); // graceful end, no message_stop
      });
    });
    return {
      status: 200,
      statusText: 'OK',
      headers: { 'content-type': 'text/event-stream' },
      config,
      data: upstream,
      request: {},
    };
  };

  t.after(() => {
    axios.defaults.adapter = originalAdapter;
    upstream?.destroy();
  });

  const server = await listen(app);
  t.after(() => close(server));

  const { port } = server.address();
  const { body, complete } = await new Promise((resolve, reject) => {
    const data = JSON.stringify({
      model: 'claude-opus-4-8',
      stream: true,
      max_tokens: 1024,
      messages: [{ role: 'user', content: 'hello' }],
    });
    const req = http.request(
      {
        method: 'POST',
        host: '127.0.0.1',
        port,
        path: '/api/anthropic/messages',
        headers: {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(data),
          'X-App-Secret': process.env.APP_SHARED_SECRET,
          'X-Install-Id': 'a7d9673d-eba6-4cf8-a209-cc87f4f7cbbd',
          'X-Forwarded-For': '10.60.10.7',
        },
      },
      (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('close', () => {
          resolve({
            body: Buffer.concat(chunks).toString('utf8'),
            complete: res.complete,
          });
        });
        res.on('error', () => {
          resolve({ body: Buffer.concat(chunks).toString('utf8'), complete: false });
        });
      }
    );
    req.on('error', () => {});
    req.end(data);
    setTimeout(() => reject(new Error('anthropic stream test timeout')), 3000).unref();
  });

  assert.equal(complete, false, 'response must be destroyed (complete=false), not ended cleanly');
  assert.equal(body.includes('"hi"'), true, 'expected partial frame to reach client');

  await pollHealth(server, (b) => b?.activeStreams === 0, {
    timeoutMs: 1000,
    label: 'anthropic ended-without-message_stop path must release activeStreams',
  });
});

// ---------------------------------------------------------------------------
// Group 3 — recordUnhandledRejection counter (round-5 D11)
// ---------------------------------------------------------------------------

test('unhandledRejection_handlerIncrementsCounterExposedViaHealth', async (t) => {
  // (round-5 D11)修复 P1#4 backlog 中 "server unhandledRejection counter 0 测覆盖" 一条。
  // Counter 走 module 级 `let unhandledRejectionCount` + 暴露在 /health body。
  // 老 production 把 handler 内嵌到 `if (require.main === module)` 内 → test
  // `require('./index')` 不挂 handler → `process.emit('unhandledRejection', ...)`
  // 完全摸不到。本次 commit 把 handler 抽成 named function `recordUnhandledRejection`
  // 导出,test 直接调,**契约**变成可单测:
  //   1. 每次调 counter +1
  //   2. /health 实时透出更新后的 count
  //   3. handler 不抛(log-only,不再 fatal shutdown)
  const server = await listen(app);
  t.after(() => close(server));

  // Counter 是 module 级累积,跨 test 不重置,只断"增量 ≥ 我们触发的次数"。
  const before = (await getJSON(server, '/health')).body?.unhandledRejectionCount ?? 0;

  assert.doesNotThrow(() => recordUnhandledRejection(new Error('test rejection A')));
  assert.doesNotThrow(() => recordUnhandledRejection(new Error('test rejection B')));

  const after = (await getJSON(server, '/health')).body?.unhandledRejectionCount ?? 0;
  assert.ok(
    after - before >= 2,
    `counter must advance by at least 2 (before=${before}, after=${after})`
  );
});
