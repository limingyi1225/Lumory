const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');

process.env.OPENAI_API_KEY = process.env.OPENAI_API_KEY || 'test-openai-key';
process.env.APP_SHARED_SECRET = process.env.APP_SHARED_SECRET || 'test-app-secret';
process.env.GLOBAL_IP_LIMIT_MAX = process.env.GLOBAL_IP_LIMIT_MAX || '3';
process.env.NODE_ENV = 'test';

const {
  app,
  countMessageContentChars,
  sanitizeChatBody,
  sanitizeUpstreamError,
  normalizeInstallId,
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

test('sanitizeUpstreamError has non-prod fallback code', () => {
  assert.deepEqual(sanitizeUpstreamError({}, 500), { code: 'upstream_error', status: 500 });
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
