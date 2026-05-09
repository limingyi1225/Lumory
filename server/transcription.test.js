// 端到端测试 /api/openai/audio/transcriptions 的信任边界 + 安全防线。
// 用 axios.defaults.adapter 注入 mock 拦上游,断言 multipart 字段 + 状态码 + 是否
// 触达上游。所有测试每条用独立 X-Forwarded-For,避开 globalIPLimiter 桶串扰。

const test = require('node:test');
const assert = require('node:assert/strict');
const axios = require('axios');

process.env.OPENAI_API_KEY = process.env.OPENAI_API_KEY || 'test-openai-key';
process.env.APP_SHARED_SECRET = process.env.APP_SHARED_SECRET || 'test-app-secret';
process.env.GLOBAL_IP_LIMIT_MAX = process.env.GLOBAL_IP_LIMIT_MAX || '50';
process.env.NODE_ENV = 'test';

const { app } = require('./index');

// 合法 install id(/^[A-F0-9-]{36}$/i)。所有转写测试共用一个 id 也行——
// per-install rate limiter 是 10/min,4 个测试远不到上限;但每测试用独立
// X-Forwarded-For 段,确保 globalIPLimiter (per-IP) 互相隔离。
const INSTALL_ID = 'a7d9673d-eba6-4cf8-a209-cc87f4f7cbba';

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

// 用 Node 18+ 原生 fetch + FormData 发请求。FormData 自动加 boundary +
// Content-Type,不要手动设 Content-Type 会丢 boundary。
async function postMultipart(server, fields, headers = {}) {
  const { port } = server.address();
  const form = new FormData();
  for (const [name, value, filename] of fields) {
    if (filename) {
      form.append(name, value, filename);
    } else {
      form.append(name, value);
    }
  }
  return fetch(`http://127.0.0.1:${port}/api/openai/audio/transcriptions`, {
    method: 'POST',
    body: form,
    headers: {
      'X-App-Secret': process.env.APP_SHARED_SECRET,
      'X-Install-Id': INSTALL_ID,
      ...headers,
    },
  });
}

function audioBlob(mime = 'audio/mp4', size = 16) {
  return new Blob([Buffer.alloc(size, 0)], { type: mime });
}

test('transcription model is server-side hardcoded ignoring client field', async (t) => {
  const originalAdapter = axios.defaults.adapter;
  let capturedModel;
  let adapterCallCount = 0;

  axios.defaults.adapter = async (config) => {
    adapterCallCount += 1;
    // axios 1.x 在 Node 下原生 FormData 透传到 adapter,可以直接 .get(...)。
    capturedModel = config.data.get('model');
    return {
      status: 200,
      statusText: 'OK',
      headers: { 'content-type': 'application/json' },
      config,
      data: { text: 'hello' },
      request: {},
    };
  };

  t.after(() => {
    axios.defaults.adapter = originalAdapter;
  });

  const server = await listen(app);
  t.after(() => close(server));

  const res = await postMultipart(
    server,
    [
      // client 试图把 model 改成更贵的"pro"型号 —— 服务端必须忽略,固定回 mini。
      ['model', 'gpt-4-transcribe-pro'],
      ['file', audioBlob('audio/mp4'), 'audio.m4a'],
    ],
    { 'X-Forwarded-For': '10.50.10.1' }
  );

  assert.equal(res.status, 200);
  const body = await res.json();
  assert.deepEqual(body, { text: 'hello' });
  assert.equal(adapterCallCount, 1, 'upstream should be called exactly once');
  assert.equal(
    capturedModel,
    'gpt-4o-mini-transcribe',
    'server must hardcode TRANSCRIPTION_MODEL and ignore client-provided model field'
  );
});

test('transcription rejects non-allowlisted MIME with 415 and does not call upstream', async (t) => {
  const originalAdapter = axios.defaults.adapter;
  let adapterCallCount = 0;

  axios.defaults.adapter = async (config) => {
    adapterCallCount += 1;
    return {
      status: 200,
      statusText: 'OK',
      headers: { 'content-type': 'application/json' },
      config,
      data: { text: 'positive control ok' },
      request: {},
    };
  };

  t.after(() => {
    axios.defaults.adapter = originalAdapter;
  });

  const server = await listen(app);
  t.after(() => close(server));

  // 1) 非白名单 MIME(audio/x-aiff)→ multer fileFilter 早断 → 415 + adapter 0 次
  const rejected = await postMultipart(
    server,
    [['file', audioBlob('audio/x-aiff'), 'audio.aiff']],
    { 'X-Forwarded-For': '10.50.20.1' }
  );

  assert.equal(rejected.status, 415, 'non-allowlisted MIME must return 415');
  const rejectedBody = await rejected.json();
  assert.equal(rejectedBody.error?.code, 'unsupported_media_type');
  assert.equal(adapterCallCount, 0, 'upstream must NOT be called for rejected MIME');

  // 2) 正向 control:白名单内的 audio/mp4 通过 + adapter 被调一次
  const allowed = await postMultipart(server, [['file', audioBlob('audio/mp4'), 'audio.m4a']], {
    'X-Forwarded-For': '10.50.20.2',
  });

  assert.equal(allowed.status, 200, 'allowlisted MIME must reach upstream');
  assert.equal(adapterCallCount, 1, 'upstream called exactly once for allowlisted MIME');
});

test('transcription drops non-ISO-639-1 language values and forwards valid ones', async (t) => {
  const originalAdapter = axios.defaults.adapter;
  const capturedLanguages = [];

  axios.defaults.adapter = async (config) => {
    // language 不存在时 .get 返 null —— 推到数组里区分 "missing" vs "present"。
    capturedLanguages.push(config.data.get('language'));
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
    axios.defaults.adapter = originalAdapter;
  });

  const server = await listen(app);
  t.after(() => close(server));

  // (a) 非 ISO-639-1 (zh-Hans 含连字符) → 应被丢弃
  const aRes = await postMultipart(
    server,
    [
      ['language', 'zh-Hans'],
      ['file', audioBlob('audio/mp4'), 'a.m4a'],
    ],
    { 'X-Forwarded-For': '10.50.30.1' }
  );
  assert.equal(aRes.status, 200);

  // (b) 合法 ISO-639-1 lowercase (en) → 应透传
  const bRes = await postMultipart(
    server,
    [
      ['language', 'en'],
      ['file', audioBlob('audio/mp4'), 'b.m4a'],
    ],
    { 'X-Forwarded-For': '10.50.30.2' }
  );
  assert.equal(bRes.status, 200);

  // (c) 大写非 lowercase (ZH) → 应被丢弃(regex 强制 lowercase)
  const cRes = await postMultipart(
    server,
    [
      ['language', 'ZH'],
      ['file', audioBlob('audio/mp4'), 'c.m4a'],
    ],
    { 'X-Forwarded-For': '10.50.30.3' }
  );
  assert.equal(cRes.status, 200);

  assert.equal(capturedLanguages.length, 3, 'three upstream calls made');
  assert.equal(capturedLanguages[0], null, 'zh-Hans must be dropped (no language field upstream)');
  assert.equal(capturedLanguages[1], 'en', 'en must be forwarded as-is');
  assert.equal(capturedLanguages[2], null, 'uppercase ZH must be dropped');
});

test('transcription rejects oversize file with 413 and code file_too_large', async (t) => {
  const originalAdapter = axios.defaults.adapter;
  let adapterCallCount = 0;

  axios.defaults.adapter = async (config) => {
    adapterCallCount += 1;
    return {
      status: 200,
      statusText: 'OK',
      headers: { 'content-type': 'application/json' },
      config,
      data: { text: 'should not reach here' },
      request: {},
    };
  };

  t.after(() => {
    axios.defaults.adapter = originalAdapter;
  });

  const server = await listen(app);
  t.after(() => close(server));

  // 26 MB 文件,超过 25 MB 限。multer LIMIT_FILE_SIZE 早断,handler 返 413。
  const oversize = audioBlob('audio/mp4', 26 * 1024 * 1024);
  const res = await postMultipart(server, [['file', oversize, 'big.m4a']], {
    'X-Forwarded-For': '10.50.40.1',
  });

  assert.equal(res.status, 413, 'oversize file must return 413');
  const body = await res.json();
  assert.equal(body.error?.code, 'file_too_large');
  assert.equal(adapterCallCount, 0, 'upstream must NOT be called for oversize upload');
});
