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
process.env.APP_SHARED_SECRET = process.env.APP_SHARED_SECRET || 'test-app-secret';
process.env.GLOBAL_IP_LIMIT_MAX = process.env.GLOBAL_IP_LIMIT_MAX || '3';
process.env.NODE_ENV = 'test';

const { app } = require('./index');

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
  const { body } = await runStreamingChat({
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

  // Give the server's error/cleanup handlers a few ticks to run after the
  // client destroy + next upstream chunk.
  await new Promise((r) => setTimeout(r, 150));

  // Critical invariant: activeStreams must NOT retain the reference.
  // /health exposes the counter so we can observe it without poking internals.
  const { status, body } = await getJSON(server, '/health');
  assert.equal(status, 200);
  assert.equal(
    body?.activeStreams,
    0,
    `activeStreams must be 0 after client disconnect, got ${body?.activeStreams}`
  );
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
