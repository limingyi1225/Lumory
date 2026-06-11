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
  countMessageContentChars,
  positiveNumberEnv,
  modelAllowlistEnv,
  sanitizeChatBody,
  sanitizeUpstreamError,
  sseFrameHasDone,
  normalizeInstallId,
  clientIPKey,
  upstreamStatusForError,
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

function postJSON(server, path, body, headers = {}) {
  return new Promise((resolve, reject) => {
    const payload = JSON.stringify(body);
    const { port } = server.address();
    const req = http.request(
      {
        method: 'POST',
        host: '127.0.0.1',
        port,
        path,
        headers: {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(payload),
          ...headers,
        },
      },
      (res) => {
        res.resume();
        res.on('end', () => resolve(res.statusCode));
      }
    );
    req.on('error', reject);
    req.end(payload);
  });
}

function rawPost(server, path, payload, headers = {}) {
  return new Promise((resolve, reject) => {
    const { port } = server.address();
    const req = http.request(
      {
        method: 'POST',
        host: '127.0.0.1',
        port,
        path,
        headers: {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(payload),
          ...headers,
        },
      },
      (res) => {
        let body = '';
        res.setEncoding('utf8');
        res.on('data', (chunk) => {
          body += chunk;
        });
        res.on('end', () =>
          resolve({
            status: res.statusCode,
            contentType: res.headers['content-type'],
            body,
          })
        );
      }
    );
    req.on('error', reject);
    req.end(payload);
  });
}

test('countMessageContentChars includes multimodal text parts', () => {
  const messages = [
    { role: 'user', content: 'hello' },
    {
      role: 'user',
      content: [
        { type: 'text', text: 'world' },
        { type: 'image_url', image_url: { url: 'https://example.test/image.png' } },
      ],
    },
  ];

  assert.equal(countMessageContentChars(messages), 10);
});

test('positiveNumberEnv ignores invalid numeric overrides', () => {
  process.env.TEST_POSITIVE_LIMIT = '-5';
  assert.equal(positiveNumberEnv('TEST_POSITIVE_LIMIT', 42), 42);
  process.env.TEST_POSITIVE_LIMIT = '0';
  assert.equal(positiveNumberEnv('TEST_POSITIVE_LIMIT', 42), 42);
  process.env.TEST_POSITIVE_LIMIT = '12.5';
  assert.equal(positiveNumberEnv('TEST_POSITIVE_LIMIT', 42), 42);
  process.env.TEST_POSITIVE_LIMIT = '12';
  assert.equal(positiveNumberEnv('TEST_POSITIVE_LIMIT', 42), 12);
  delete process.env.TEST_POSITIVE_LIMIT;
});

test('modelAllowlistEnv trims empty entries and preserves defaults', () => {
  process.env.TEST_MODEL_ALLOWLIST = ' gpt-5.5, ,gpt-5.4-mini ';
  assert.deepEqual(modelAllowlistEnv('TEST_MODEL_ALLOWLIST', ['fallback']), [
    'gpt-5.5',
    'gpt-5.4-mini',
  ]);
  process.env.TEST_MODEL_ALLOWLIST = ' , ';
  assert.deepEqual(modelAllowlistEnv('TEST_MODEL_ALLOWLIST', ['fallback']), ['fallback']);
  delete process.env.TEST_MODEL_ALLOWLIST;
});

test('sanitizeChatBody clamps model and strips unsupported cost controls', () => {
  const body = sanitizeChatBody({
    model: 'gpt-4-32k',
    messages: [{ role: 'user', content: 'hello' }],
    stream: true,
    max_completion_tokens: 999999,
    reasoning_effort: 'xhigh',
    tools: [{ type: 'function' }],
  });

  assert.equal(body.model, 'gpt-5.5');
  assert.equal(body.max_completion_tokens, 16384);
  assert.equal(body.reasoning_effort, 'low');
  assert.equal(body.tools, undefined);
});

test('sanitizeChatBody allows configured app models and JSON response format', () => {
  const body = sanitizeChatBody({
    model: 'gpt-5.4-mini',
    messages: [{ role: 'user', content: 'hello' }],
    response_format: { type: 'json_object' },
    reasoning_effort: 'none',
    max_completion_tokens: 256,
  });

  assert.equal(body.model, 'gpt-5.4-mini');
  assert.deepEqual(body.response_format, { type: 'json_object' });
  assert.equal(body.reasoning_effort, 'none');
  assert.equal(body.max_completion_tokens, 256);
});

test('normalizeInstallId lowercases valid UUIDs', () => {
  assert.equal(
    normalizeInstallId('A7D9673D-EBA6-4CF8-A209-CC87F4F7CBBA'),
    'a7d9673d-eba6-4cf8-a209-cc87f4f7cbba'
  );
});

test('clientIPKey collapses IPv6 host-bit rotation to /56', () => {
  const a = clientIPKey({ ip: '2001:db8:77:ab01::1' });
  const b = clientIPKey({ ip: '2001:db8:77:abff::2' });
  const c = clientIPKey({ ip: '2001:db8:77:ac00::1' });
  assert.equal(a, b);
  assert.notEqual(a, c);
});

test('clientIPKey preserves mapped IPv4 and loopback addresses', () => {
  assert.equal(clientIPKey({ ip: '::ffff:1.2.3.4' }), '1.2.3.4');
  assert.equal(clientIPKey({ ip: '::ffff:9.9.9.9' }), '9.9.9.9');
  assert.equal(clientIPKey({ ip: '::1' }), '::1');
  assert.equal(clientIPKey({ ip: '::' }), '::');
});

test('sanitizeUpstreamError has non-prod fallback code', () => {
  assert.deepEqual(sanitizeUpstreamError({}, 500), { code: 'upstream_error', status: 500 });
});

test('upstream network errors map to gateway timeout', () => {
  for (const code of ['ECONNABORTED', 'ECONNRESET', 'ETIMEDOUT', 'ENOTFOUND', 'EAI_AGAIN']) {
    assert.equal(upstreamStatusForError({ code }), 504);
  }
  assert.equal(upstreamStatusForError({ code: 'ECONNREFUSED' }), 500);
  assert.equal(upstreamStatusForError({ response: { status: 429 }, code: 'ECONNRESET' }), 429);
});

test('sseFrameHasDone ignores [DONE] inside streamed model content', () => {
  assert.equal(
    sseFrameHasDone('data: {"choices":[{"delta":{"content":"literal data: [DONE]"}}]}'),
    false
  );
  assert.equal(sseFrameHasDone('event: completion\ndata: [DONE]'), true);
  assert.equal(sseFrameHasDone('data: {"value":"[DONE]"}'), false);
});

test('missing app secret requests do not consume authenticated global quota', async (t) => {
  const server = await listen(app);
  t.after(() => close(server));

  const globalLimit = Number(process.env.GLOBAL_IP_LIMIT_MAX);
  for (let i = 0; i < globalLimit; i += 1) {
    const status = await postJSON(server, '/api/openai/embeddings', {});
    assert.equal(status, 401);
  }

  const authenticatedStatus = await postJSON(
    server,
    '/api/openai/embeddings',
    {},
    {
      'X-App-Secret': process.env.APP_SHARED_SECRET,
      'X-Install-Id': 'a7d9673d-eba6-4cf8-a209-cc87f4f7cbba',
    }
  );
  assert.equal(authenticatedStatus, 400);
});

test('invalid JSON and oversized JSON return JSON errors', async (t) => {
  const server = await listen(app);
  t.after(() => close(server));

  const invalid = await rawPost(server, '/api/openai/embeddings', '{bad json', {
    'X-App-Secret': process.env.APP_SHARED_SECRET,
    'X-Forwarded-For': '10.10.30.1',
  });
  assert.equal(invalid.status, 400);
  assert.match(invalid.contentType, /^application\/json/);
  assert.deepEqual(JSON.parse(invalid.body), { error: 'invalid_json' });

  const tooLarge = await rawPost(
    server,
    '/api/openai/embeddings',
    JSON.stringify({ input: 'x'.repeat(1024 * 1024 + 1) }),
    {
      'X-App-Secret': process.env.APP_SHARED_SECRET,
      'X-Forwarded-For': '10.10.30.2',
    }
  );
  assert.equal(tooLarge.status, 413);
  assert.match(tooLarge.contentType, /^application\/json/);
  assert.deepEqual(JSON.parse(tooLarge.body), { error: 'request_body_too_large' });
});

test('global IP limiter groups IPv6 clients by /56', async (t) => {
  const server = await listen(app);
  t.after(() => close(server));

  const statuses = [];
  for (let i = 1; i <= 4; i += 1) {
    statuses.push(
      await postJSON(
        server,
        '/api/openai/embeddings',
        {},
        {
          'X-App-Secret': process.env.APP_SHARED_SECRET,
          'X-Forwarded-For': `2001:db8:77:ab0${i}::1`,
        }
      )
    );
  }

  assert.deepEqual(statuses, [400, 400, 400, 429]);
});

test('app secret byte length mismatch returns unauthorized', async (t) => {
  const server = await listen(app);
  t.after(() => close(server));

  const sameUTF16LengthDifferentByteLength = 'é'.repeat(process.env.APP_SHARED_SECRET.length);
  const status = await postJSON(
    server,
    '/api/openai/embeddings',
    {},
    { 'X-App-Secret': sameUTF16LengthDifferentByteLength }
  );

  assert.equal(status, 401);
});

test('chat with too many messages returns 400', async (t) => {
  const server = await listen(app);
  t.after(() => close(server));

  // 65 条 messages,超过 MAX_MESSAGES_COUNT=64 上限。每条 content 极短走过 char cap,
  // 触发 messages.length 这一道关。
  // **per-test X-Forwarded-For**:`app.set('trust proxy', 'loopback')` 信任 loopback 的伪 IP 头。
  // 用专属 IP 让 globalIPLimiter(env GLOBAL_IP_LIMIT_MAX=3,跨 test 共享 in-memory)的 quota
  // 不被本测耗光,后续 streaming-abort 测仍能走到 mocked axios adapter。
  const messages = Array.from({ length: 65 }, (_, i) => ({ role: 'user', content: `m${i}` }));
  const status = await postJSON(
    server,
    '/api/openai/chat/completions',
    { messages },
    {
      'X-App-Secret': process.env.APP_SHARED_SECRET,
      'X-Install-Id': 'a7d9673d-eba6-4cf8-a209-cc87f4f7cbba',
      'X-Forwarded-For': '10.10.20.1',
    }
  );

  assert.equal(status, 400);
});

test('chat count cap fires before char cap when both exceed', async (t) => {
  // ordering invariant — count check 必须在 char check 前。如果未来 refactor 调换顺序,
  // attacker 可绕过 count cap 用 1000 条短 message 撑大上游 token 计费。
  const server = await listen(app);
  t.after(() => close(server));

  // 65 条 × 1000 chars each = 65000 chars (over MAX_MESSAGES_CHARS=32000 too)。
  // 期望:count cap 先 fire → 400 "too many messages",而不是 413 "messages too large"。
  // 同上 — X-Forwarded-For 用专属 IP 让本测不耗 globalIPLimiter quota。
  const messages = Array.from({ length: 65 }, () => ({
    role: 'user',
    content: 'a'.repeat(1000),
  }));
  const status = await postJSON(
    server,
    '/api/openai/chat/completions',
    { messages },
    {
      'X-App-Secret': process.env.APP_SHARED_SECRET,
      'X-Install-Id': 'a7d9673d-eba6-4cf8-a209-cc87f4f7cbba',
      'X-Forwarded-For': '10.10.20.2',
    }
  );

  assert.equal(status, 400, 'count cap (400) must fire before char cap (413) when both exceed');
});

test('streaming client abort cancels the upstream OpenAI request', async (t) => {
  const originalAdapter = axios.defaults.adapter;
  let capturedSignal;
  let upstream;
  let resolveAdapterCalled;
  let resolveAborted;
  const adapterCalled = new Promise((resolve) => {
    resolveAdapterCalled = resolve;
  });
  const aborted = new Promise((resolve) => {
    resolveAborted = resolve;
  });

  axios.defaults.adapter = async (config) => {
    capturedSignal = config.signal;
    upstream = new PassThrough();
    capturedSignal.addEventListener('abort', () => {
      resolveAborted();
      const error = new Error('client cancelled');
      error.code = 'ERR_CANCELED';
      upstream.destroy(error);
    });
    resolveAdapterCalled();
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

  const payload = JSON.stringify({
    model: 'gpt-5.5',
    stream: true,
    messages: [{ role: 'user', content: 'hello' }],
  });
  const { port } = server.address();
  const req = http.request(
    {
      method: 'POST',
      host: '127.0.0.1',
      port,
      path: '/api/openai/chat/completions',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(payload),
        'X-App-Secret': process.env.APP_SHARED_SECRET,
        'X-Install-Id': 'b7d9673d-eba6-4cf8-a209-cc87f4f7cbbb',
      },
    },
    (res) => {
      res.once('data', () => req.destroy());
      res.resume();
    }
  );
  req.on('error', () => {});
  req.end(payload);

  await adapterCalled;
  upstream.write('data: {"choices":[{"delta":{"content":"partial"}}]}\n\n');
  await Promise.race([
    aborted,
    new Promise((_, reject) => setTimeout(() => reject(new Error('abort timeout')), 1000)),
  ]);

  assert.equal(capturedSignal.aborted, true);
});
