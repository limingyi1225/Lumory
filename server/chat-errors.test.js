// Chat endpoint 错误处理 P1 行为测试。覆盖:
//   1. 上游 ECONNABORTED → 504 + 错误体含 code 字段(具体值依 NODE_ENV;test 走 fallback)
//   2. 上游 429 + Retry-After 头透传到客户端响应(NetworkRetryHelper 退避契约)
//   3. sanitizeChatBody 真实经手 axios 转发 — output 只含白名单字段,tools/temperature/top_p 等被剥
//   4. 非法 X-Install-Id 双 ID 共享同 IP 桶,121 req 触发 429(install_key 回落 ip:<req.ip>)
//
// 调用模板抄自 server/index.test.js:239 'streaming client abort'(axios mock + listen + http.request)。
// per-test X-Forwarded-For 用 10.80.X.Y 段,跟 index.test.js 的 10.10/10.50/... 不撞,避免共享
// in-memory rate-limit 桶时被前测耗光配额。

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const axios = require('axios');

process.env.OPENAI_API_KEY = process.env.OPENAI_API_KEY || 'test-openai-key';
process.env.APP_SHARED_SECRET = process.env.APP_SHARED_SECRET || 'test-app-secret';
// 高于本文件最大压力测试需要的 121 req,且高于 chat per-install 120 上限,确保
// globalIPLimiter (per-IP) 不会在测试 4 之前 fire(测试 4 自己要 chatLimiter fire)。
process.env.GLOBAL_IP_LIMIT_MAX = process.env.GLOBAL_IP_LIMIT_MAX || '999';
// 注意:NODE_ENV 在 require('./index') 时被 freeze 进 IS_PRODUCTION 常量。这里设 'test',
// 故 sanitizeUpstreamError 走 non-prod fallback ({ code: err.code || 'upstream_error', status })。
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

// 完整版 postJSON:不仅返 status,还把 headers + body 一并捞出(测试 2/3 要读 Retry-After
// 头跟解析 JSON body;index.test.js 里的 postJSON 只 resume 不 buffer body)。
function postJSONFull(server, path, body, headers = {}) {
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
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => {
          const raw = Buffer.concat(chunks).toString('utf8');
          let parsed;
          try {
            parsed = raw.length ? JSON.parse(raw) : null;
          } catch {
            parsed = raw;
          }
          resolve({ status: res.statusCode, headers: res.headers, body: parsed });
        });
      }
    );
    req.on('error', reject);
    req.end(payload);
  });
}

const VALID_UUID = 'c7d9673d-eba6-4cf8-a209-cc87f4f7cbcc';

const baseChatBody = {
  model: 'gpt-5.6-terra',
  messages: [{ role: 'user', content: 'hi' }],
};

function authHeaders(extra = {}) {
  return {
    'X-App-Secret': process.env.APP_SHARED_SECRET,
    'X-Install-Id': VALID_UUID,
    ...extra,
  };
}

test('chat_upstreamTimeout_mapsTo504_withCodeUpstreamTimeout', async (t) => {
  // P1: axios ECONNABORTED → status 473 line `(err.code === 'ECONNABORTED' ? 504 : 500)`。
  // sanitizeUpstreamError 在 NODE_ENV=test 走 non-prod 分支:返 { code: err.code, status }。
  // 故断言 status=504 + body.error.code === 'ECONNABORTED' (axios err.code 直接透出),
  // body.error.status === 504。production mode 下会换成 'upstream_timeout',我们不切 NODE_ENV
  // 避免污染其他 test 文件;这条契约由 sanitizeUpstreamError 单测(index.test.js)单独覆盖。
  const originalAdapter = axios.defaults.adapter;
  axios.defaults.adapter = async () => {
    const error = new Error('aborted');
    error.code = 'ECONNABORTED';
    throw error;
  };
  t.after(() => {
    axios.defaults.adapter = originalAdapter;
  });

  const server = await listen(app);
  t.after(() => close(server));

  const res = await postJSONFull(server, '/api/openai/chat/completions', baseChatBody, {
    ...authHeaders(),
    'X-Forwarded-For': '10.80.10.1',
  });

  assert.equal(res.status, 504, 'ECONNABORTED must map to 504');
  assert.ok(res.body && typeof res.body === 'object', 'body must be JSON object');
  assert.ok(res.body.error, 'body must contain error field');
  // non-prod sanitize:code = err.code(ECONNABORTED) + status 字段。
  assert.equal(res.body.error.code, 'ECONNABORTED');
  assert.equal(res.body.error.status, 504);
});

test('chat_upstream429WithRetryAfter_propagatesHeaderToClient', async (t) => {
  // P1: 上游 OpenAI 429 带 Retry-After 头时,proxy 必须透传给客户端,
  // 否则 NetworkRetryHelper 没法做指数退避决策。Line 477-479 显式 setHeader('Retry-After')。
  const originalAdapter = axios.defaults.adapter;
  axios.defaults.adapter = async () => {
    const error = new Error('rate limited');
    error.response = {
      status: 429,
      headers: { 'retry-after': '42' },
      data: { error: { message: 'too many requests' } },
    };
    throw error;
  };
  t.after(() => {
    axios.defaults.adapter = originalAdapter;
  });

  const server = await listen(app);
  t.after(() => close(server));

  const res = await postJSONFull(server, '/api/openai/chat/completions', baseChatBody, {
    ...authHeaders(),
    'X-Forwarded-For': '10.80.10.2',
  });

  assert.equal(res.status, 429);
  // node http header names 全 lowercase。
  assert.equal(res.headers['retry-after'], '42', 'Retry-After must propagate from upstream');
  // body.error.code 还是 sanitized:non-prod 模式无 err.code 字段(ECONNABORTED 那种 axios 自家
  // code 才有),因为 err.response.status 触发的 throw 不带 code,fallback 到 'upstream_error'。
  assert.ok(res.body?.error, 'body must include sanitized error');
});

test('chat_sanitizedBodyReachesUpstream_strippingUnsupportedFields', async (t) => {
  // P1: sanitizeChatBody 单测在 index.test.js 已覆盖纯函数,这里测**真实转发路径**
  // —— 用户可能塞 tools/temperature/top_p/frequency_penalty 等(老 OpenAI API 字段或
  // 提示注入),但上游 axios 拿到的 data 必须只含白名单字段(model/messages/stream/
  // reasoning_effort/max_completion_tokens [+ optional response_format])。
  const originalAdapter = axios.defaults.adapter;
  let capturedData;
  axios.defaults.adapter = async (config) => {
    // axios.post(url, data, opts) 序列化前 config.data 是原 object;序列化后是 JSON string。
    // 这里 data 是 object(未走 transformRequest 之前 adapter 拿到的原始对象?实际:
    // axios 在 dispatchRequest 里跑 transformRequest 把 data 序列化成 string 再交 adapter。
    // 故 capturedData 是 string,需 JSON.parse)。
    capturedData = typeof config.data === 'string' ? JSON.parse(config.data) : config.data;
    return {
      status: 200,
      statusText: 'OK',
      headers: { 'content-type': 'application/json' },
      config,
      data: { id: 'x', choices: [{ message: { content: 'ok' } }], usage: {} },
      request: {},
    };
  };
  t.after(() => {
    axios.defaults.adapter = originalAdapter;
  });

  const server = await listen(app);
  t.after(() => close(server));

  const dirtyBody = {
    model: 'gpt-5.6-terra',
    messages: [{ role: 'user', content: 'hi' }],
    stream: false,
    tools: [{ type: 'function', function: { name: 'evil' } }],
    temperature: 0.7,
    top_p: 0.9,
    frequency_penalty: 0.5,
    presence_penalty: 0.3,
    user: 'attacker-id',
    logit_bias: { 50256: -100 },
  };
  const res = await postJSONFull(server, '/api/openai/chat/completions', dirtyBody, {
    ...authHeaders(),
    'X-Forwarded-For': '10.80.10.3',
  });

  assert.equal(res.status, 200);
  assert.ok(capturedData, 'adapter must have been invoked with upstream body');

  // 白名单字段保留(model/messages 必有;stream=false 在 sanitizeChatBody 里被设为 undefined,
  // 序列化时 JSON.stringify 自动 drop;reasoning_effort/max_completion_tokens 总是会有值)。
  assert.equal(capturedData.model, 'gpt-5.6-terra');
  assert.deepEqual(capturedData.messages, [{ role: 'user', content: 'hi' }]);
  assert.equal('stream' in capturedData, false, 'stream:false → undefined → dropped from JSON');
  assert.ok('reasoning_effort' in capturedData, 'reasoning_effort always set by sanitize');
  assert.ok('max_completion_tokens' in capturedData, 'max_completion_tokens always set');

  // 黑名单字段被剥(关键安全契约):
  for (const stripped of [
    'tools',
    'temperature',
    'top_p',
    'frequency_penalty',
    'presence_penalty',
    'user',
    'logit_bias',
  ]) {
    assert.equal(stripped in capturedData, false, `upstream body must NOT contain ${stripped}`);
  }
});

test('installKey_nonUUIDInstallId_fallsBackToIPBucket', async (t) => {
  // P1: installKey 对非法 X-Install-Id(非 UUID 格式)回落 'ip:<req.ip>'。
  // 验证:同 IP + 两个不同非法 install-id 共享 chatLimiter 桶(max=120/min)。
  // 121 个 req 后(无论 install-id A 还是 B)第 121 个返 429。
  // 如果 fallback 是 per-id,A 跟 B 各 120 ok,总 240,121 不会 fire。
  //
  // chat 请求轻量(axios mock 秒返 200,no IO),120 req 局部环回连接 ~1-2s 范围。
  const originalAdapter = axios.defaults.adapter;
  axios.defaults.adapter = async (config) => ({
    status: 200,
    statusText: 'OK',
    headers: { 'content-type': 'application/json' },
    config,
    data: { id: 'x', choices: [{ message: { content: 'ok' } }], usage: {} },
    request: {},
  });
  t.after(() => {
    axios.defaults.adapter = originalAdapter;
  });

  const server = await listen(app);
  t.after(() => close(server));

  const SHARED_IP = '10.80.10.4';
  const ID_A = 'not-a-uuid-aaa';
  const ID_B = 'xyz';

  const send = (installId) =>
    postJSONFull(server, '/api/openai/chat/completions', baseChatBody, {
      'X-App-Secret': process.env.APP_SHARED_SECRET,
      'X-Install-Id': installId,
      'X-Forwarded-For': SHARED_IP,
    });

  // chat per-install max=120。前 120 应全 200(共享 IP 桶,A+B 加起来计数)。
  // 用 alternating ID 写,模拟攻击者随机换 install-id 试图绕配额。
  let lastSuccessStatus = null;
  for (let i = 0; i < 120; i += 1) {
    const id = i % 2 === 0 ? ID_A : ID_B;
    const r = await send(id);
    lastSuccessStatus = r.status;
    if (r.status !== 200) {
      // 早 fire 也 fail —— 说明 IP 共享桶已满之外的事(本测启动时桶应是空)。
      throw new Error(
        `unexpected non-200 at i=${i}: status=${r.status}, body=${JSON.stringify(r.body)}`
      );
    }
  }
  assert.equal(lastSuccessStatus, 200, 'first 120 reqs share IP bucket cleanly');

  // 第 121 个(用 ID_A 或 B 无所谓,共享桶应已满)→ 429。
  const overflow = await send(ID_A);
  assert.equal(
    overflow.status,
    429,
    `req #121 must trigger chat per-install rate-limit (shared IP bucket); got ${overflow.status}. ` +
      `如果非 429,说明非法 install-id 没回落 ip:<req.ip>(可能改成了 install:<raw> 或 per-id 桶),` +
      `攻击者可随机换 install-id 绕过 chat 120/min 配额。`
  );
});
