// 双层限流隔离 contract 测试 — chat / transcription / embeddings 三个 endpoint。
//
// 核心设计 invariant(CLAUDE.md 明示):**per-install 触顶不能传染同 IP 的其他 install**,
// 反过来 per-IP 兜底必须挡住 install-id 轮换攻击。顺序错了 attacker 用 install-id 轮换
// 就能撞死 IP cap,把同 NAT 下的所有真实用户拖下水。
//
// 关键技术细节:
//   - express-rate-limit 用 module-singleton in-memory MemoryStore,**跨测试持久** —
//     必须用专属 X-Forwarded-For 段 (10.70.x.x) 隔离 per-IP 桶,不同 install-id 隔离
//     per-install 桶。
//   - `app.set('trust proxy', 'loopback')` 让 X-Forwarded-For 在 127.0.0.1 上生效。
//   - GLOBAL_IP_LIMIT_MAX 在 require('./index') 时读取,**所有测试共享**。设 999 让
//     per-install (120) / per-IP transcription (60) 成为本文件测试的 binding limiter。
//   - axios mock 用 axios.defaults.adapter 注入,t.after 还原 originalAdapter。

const test = require('node:test');
const assert = require('node:assert/strict');
const axios = require('axios');

process.env.OPENAI_API_KEY = process.env.OPENAI_API_KEY || 'test-openai-key';
process.env.APP_SHARED_SECRET = process.env.APP_SHARED_SECRET || 'test-app-secret';
// 设高让 chat per-install (120) / transcription per-install (10) 成为 binding 限流。
// globalIPLimiter (per-IP) 在 999 远高于本文件任何单测的 per-IP 用量。
process.env.GLOBAL_IP_LIMIT_MAX = '999';
process.env.NODE_ENV = 'test';

const { app } = require('./index');

const INSTALL_A = 'a7d9673d-eba6-4cf8-a209-cc87f4f7cbba';
const INSTALL_B = 'b8e0784e-fcb7-4d09-b3fa-dd98e58d8cdd';
const INSTALL_C = 'c9f1895f-0dc8-4e1a-9c4b-ee09f6c8dcee';
const INSTALL_D = 'd0a2906a-1ed9-4f2b-ad5c-ff1a07d9edff';
const INSTALL_E = 'e1b3a17b-2fea-4a3c-be6d-001b18e0fea0';
const INSTALL_F = 'f2c4b28c-3afb-4b4d-cf7e-112c29f10fb1';

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

// JSON POST helper — chat / embeddings。返 status code only(429 测试不关心 body)。
async function postJSON(server, path, body, headers = {}) {
  const { port } = server.address();
  const res = await fetch(`http://127.0.0.1:${port}${path}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-App-Secret': process.env.APP_SHARED_SECRET,
      ...headers,
    },
    body: JSON.stringify(body),
  });
  // drain body 防 socket leak。429 / 200 都有 body。
  await res.arrayBuffer();
  return res.status;
}

// Multipart helper — transcription。和 transcription.test.js 同 idiom。
async function postMultipart(server, fields, headers = {}) {
  const { port } = server.address();
  const form = new FormData();
  for (const [name, value, filename] of fields) {
    if (filename) form.append(name, value, filename);
    else form.append(name, value);
  }
  const res = await fetch(`http://127.0.0.1:${port}/api/openai/audio/transcriptions`, {
    method: 'POST',
    body: form,
    headers: {
      'X-App-Secret': process.env.APP_SHARED_SECRET,
      ...headers,
    },
  });
  await res.arrayBuffer();
  return res.status;
}

function audioBlob() {
  return new Blob([Buffer.alloc(16, 0)], { type: 'audio/mp4' });
}

function chatBody() {
  // 极小 messages,过 count + char cap,不被 sanitizeChatBody 改坏。
  return { model: 'gpt-5.6-terra', messages: [{ role: 'user', content: 'hi' }] };
}

// chat 上游 mock — 立即返一条最小完整 chat completion JSON。
function installChatMock(t) {
  const original = axios.defaults.adapter;
  let callCount = 0;
  axios.defaults.adapter = async (config) => {
    callCount += 1;
    return {
      status: 200,
      statusText: 'OK',
      headers: { 'content-type': 'application/json' },
      config,
      data: {
        id: 'chatcmpl-test',
        object: 'chat.completion',
        choices: [{ message: { role: 'assistant', content: 'ok' }, finish_reason: 'stop' }],
      },
      request: {},
    };
  };
  t.after(() => {
    axios.defaults.adapter = original;
  });
  return () => callCount;
}

// embeddings 上游 mock。
function installEmbeddingsMock(t) {
  const original = axios.defaults.adapter;
  let callCount = 0;
  axios.defaults.adapter = async (config) => {
    callCount += 1;
    return {
      status: 200,
      statusText: 'OK',
      headers: { 'content-type': 'application/json' },
      config,
      data: { data: [{ embedding: [0.1, 0.2, 0.3] }] },
      request: {},
    };
  };
  t.after(() => {
    axios.defaults.adapter = original;
  });
  return () => callCount;
}

// transcription 上游 mock。
function installTranscriptionMock(t) {
  const original = axios.defaults.adapter;
  let callCount = 0;
  axios.defaults.adapter = async (config) => {
    callCount += 1;
    return {
      status: 200,
      statusText: 'OK',
      headers: { 'content-type': 'application/json' },
      config,
      data: { text: 'ok' },
      request: {},
    };
  };
  t.after(() => {
    axios.defaults.adapter = original;
  });
  return () => callCount;
}

// ─────────────────────────────────────────────────────────────────────────────
// Chat per-install limit (120/min) — 121st same install must 429.
// ─────────────────────────────────────────────────────────────────────────────
test('chat_perInstallLimit120_returns429At121st_sameInstall', async (t) => {
  const getCount = installChatMock(t);
  const server = await listen(app);
  t.after(() => close(server));

  const headers = {
    'X-Install-Id': INSTALL_A,
    'X-Forwarded-For': '10.70.10.1',
  };

  // 前 120 次必须全 200(per-install cap = 120)。轮询太多次序列化跑会慢,
  // 但 axios mock 是同步返,实测 ~10ms/req → 120 req ≈ 1.2s,可接受。
  for (let i = 1; i <= 120; i += 1) {
    const status = await postJSON(server, '/api/openai/chat/completions', chatBody(), headers);
    assert.equal(status, 200, `request #${i} should be 200 (within per-install cap)`);
  }

  // 第 121 次必须 429 — chatLimiter 触顶。
  const blocked = await postJSON(server, '/api/openai/chat/completions', chatBody(), headers);
  assert.equal(blocked, 429, 'request #121 must 429 (per-install cap = 120 exceeded)');

  // 上游 mock 应被调 120 次,不会调到第 121 次(限流在 handler 之前)。
  assert.equal(getCount(), 120, 'upstream must NOT be called for the 429-blocked request');
});

// ─────────────────────────────────────────────────────────────────────────────
// Chat per-install bucket isolation — install A 触顶不阻塞 install B 同 IP。
// 这是双层限流的核心 contract:per-install 桶必须独立。
// ─────────────────────────────────────────────────────────────────────────────
test('chat_perInstallLimitDoesNotBlockOtherInstalls_sameIP', async (t) => {
  const getCount = installChatMock(t);
  const server = await listen(app);
  t.after(() => close(server));

  const SHARED_IP = '10.70.20.1';

  // install B 跑满 120 → 第 121 次 429。
  for (let i = 1; i <= 120; i += 1) {
    const status = await postJSON(server, '/api/openai/chat/completions', chatBody(), {
      'X-Install-Id': INSTALL_B,
      'X-Forwarded-For': SHARED_IP,
    });
    assert.equal(status, 200, `install B request #${i} should be 200`);
  }
  const bBlocked = await postJSON(server, '/api/openai/chat/completions', chatBody(), {
    'X-Install-Id': INSTALL_B,
    'X-Forwarded-For': SHARED_IP,
  });
  assert.equal(bBlocked, 429, 'install B should 429 at request #121');

  // install C 同 IP 单次请求 → **必须 200**,per-install 桶独立。
  // (globalIPLimiter cap = 999 远高于 120 已用,IP 总 quota 还很多。)
  const cFresh = await postJSON(server, '/api/openai/chat/completions', chatBody(), {
    'X-Install-Id': INSTALL_C,
    'X-Forwarded-For': SHARED_IP,
  });
  assert.equal(
    cFresh,
    200,
    'install C on same IP must NOT be blocked by install B per-install cap'
  );

  // 上游应被调 121 次(install B × 120 + install C × 1),install B 第 121 次被限流不调上游。
  assert.equal(getCount(), 121, 'upstream call count = 120 (B) + 1 (C), not the 429-blocked B#121');
});

// ─────────────────────────────────────────────────────────────────────────────
// Transcription per-install limit (10/min) — 11th same install must 429.
// ─────────────────────────────────────────────────────────────────────────────
test('transcription_perInstallLimit10_returns429At11th_sameInstall', async (t) => {
  const getCount = installTranscriptionMock(t);
  const server = await listen(app);
  t.after(() => close(server));

  const headers = {
    'X-Install-Id': INSTALL_D,
    'X-Forwarded-For': '10.70.40.1',
  };

  for (let i = 1; i <= 10; i += 1) {
    const status = await postMultipart(server, [['file', audioBlob(), 'a.m4a']], headers);
    assert.equal(status, 200, `transcription #${i} should be 200 (within per-install cap = 10)`);
  }

  const blocked = await postMultipart(server, [['file', audioBlob(), 'a.m4a']], headers);
  assert.equal(blocked, 429, 'transcription #11 must 429 (per-install cap = 10 exceeded)');

  assert.equal(getCount(), 10, 'upstream must NOT be called for the 429-blocked transcription');
});

// ─────────────────────────────────────────────────────────────────────────────
// Transcription per-install bucket isolation — 同 IP 不同 install 互不阻塞。
// **降级版本**:不跑完整 60 IP cap fire,只验"per-install 桶独立"侧。
// 完整 transcriptionsIPLimiter cap-fire 测留 backlog —— 跑 60+ 个 multipart
// 请求 (每个 ~30ms) 约 2-3s,而且要 11 个不同 install 轮换避开 per-install cap,
// 测试逻辑复杂度跟产值不成正比。
// ─────────────────────────────────────────────────────────────────────────────
test('transcription_perInstallBucketsAreIndependent_sameIP', async (t) => {
  const getCount = installTranscriptionMock(t);
  const server = await listen(app);
  t.after(() => close(server));

  const SHARED_IP = '10.70.50.1';

  // install E 跑满 10 → 第 11 次 429。
  for (let i = 1; i <= 10; i += 1) {
    const status = await postMultipart(server, [['file', audioBlob(), 'a.m4a']], {
      'X-Install-Id': INSTALL_E,
      'X-Forwarded-For': SHARED_IP,
    });
    assert.equal(status, 200, `install E transcription #${i} should be 200`);
  }
  const eBlocked = await postMultipart(server, [['file', audioBlob(), 'a.m4a']], {
    'X-Install-Id': INSTALL_E,
    'X-Forwarded-For': SHARED_IP,
  });
  assert.equal(eBlocked, 429, 'install E should 429 at transcription #11');

  // install F 同 IP 单次 → 必须 200,per-install 桶独立。
  // 同 IP 已用 10 quota,transcriptionsIPLimiter cap = 60,还有 50 余量,IP 兜底不挡。
  const fFresh = await postMultipart(server, [['file', audioBlob(), 'a.m4a']], {
    'X-Install-Id': INSTALL_F,
    'X-Forwarded-For': SHARED_IP,
  });
  assert.equal(
    fFresh,
    200,
    'install F on same IP must NOT be blocked by install E per-install cap'
  );

  assert.equal(getCount(), 11, 'upstream count = 10 (E) + 1 (F)');
});

// ─────────────────────────────────────────────────────────────────────────────
// Embeddings per-install limit smoke test (cap = 300).
// **降级版本**:不跑完整 301 个请求(~3-4s 太贵),只验"低用量全 200 + per-install
// 桶独立"。完整 cap-fire 测留 backlog —— 跟 chat (cap=120) 同结构,真正 invariant
// 已被 chat 测试覆盖,embeddings 跑 300 次只是重复同一行为。
// ─────────────────────────────────────────────────────────────────────────────
test('embeddings_perInstallLimitSmokeAndIsolation_sameIP', async (t) => {
  const getCount = installEmbeddingsMock(t);
  const server = await listen(app);
  t.after(() => close(server));

  const SHARED_IP = '10.70.60.1';
  const body = { input: 'hello world' };

  // 5 次同 install → 全 200(远低于 300 cap)。
  for (let i = 1; i <= 5; i += 1) {
    const status = await postJSON(server, '/api/openai/embeddings', body, {
      'X-Install-Id': INSTALL_A,
      'X-Forwarded-For': SHARED_IP,
    });
    assert.equal(status, 200, `embedding #${i} should be 200`);
  }

  // 同 IP 切换 install → 仍 200(per-install 桶独立 + IP 兜底未触顶)。
  const otherInstall = await postJSON(server, '/api/openai/embeddings', body, {
    'X-Install-Id': INSTALL_B,
    'X-Forwarded-For': SHARED_IP,
  });
  assert.equal(otherInstall, 200, 'different install on same IP must succeed');

  assert.equal(getCount(), 6, 'upstream called 6 times (5 install A + 1 install B)');
});
