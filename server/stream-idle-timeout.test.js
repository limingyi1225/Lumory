// Stream mid-stream idle-timeout 行为测试(megareview P2)。
//
// axios 的 `timeout` 对 responseType:'stream' 只管到响应头(TTFB)—— settle 后 isDone=true,
// socket 级 req.setTimeout 的 handler 直接 no-op,管不了 chunk 之间的空闲。服务端为流式自挂了
// idle 计时器:每收到 chunk 重置,超过 STREAM_IDLE_TIMEOUT_MS 没新数据就 destroy upstream
// → 落到 'error' handler → res.destroy → 客户端断流。
//
// 本测把 idle 设成 200ms,mock 上游连上 + 吐头 + 发一个 chunk 后**保持静默**(不再写、不 end),
// 验证服务端会:(1) 主动 destroy 上游 stream,(2) 提前关闭客户端连接(没有 [DONE])。
// 没有 idle 计时器的话连接会一直挂到 race 的 3s 超时。

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { PassThrough } = require('node:stream');

process.env.OPENAI_API_KEY = process.env.OPENAI_API_KEY || 'test-openai-key';
process.env.ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY || 'test-anthropic-key';
process.env.APP_SHARED_SECRET = process.env.APP_SHARED_SECRET || 'test-app-secret';
process.env.GLOBAL_IP_LIMIT_MAX = process.env.GLOBAL_IP_LIMIT_MAX || '999';
process.env.NODE_ENV = 'test';
// **必须在 require('./index') 之前设**:STREAM_IDLE_TIMEOUT_MS 在 require 时 freeze 进常量。
process.env.OPENAI_STREAM_IDLE_TIMEOUT_MS = '200';

const axios = require('axios');
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

test('streaming idle upstream is torn down by server-side idle timer', async (t) => {
  const originalAdapter = axios.defaults.adapter;
  let upstream;
  let upstreamClosed = false;
  let resolveAdapterCalled;
  const adapterCalled = new Promise((resolve) => {
    resolveAdapterCalled = resolve;
  });

  axios.defaults.adapter = async (config) => {
    upstream = new PassThrough();
    upstream.on('close', () => {
      upstreamClosed = true;
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

  let gotFirstChunk = false;
  let resolveClosed;
  const clientClosed = new Promise((resolve) => {
    resolveClosed = resolve;
  });

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
        'X-Install-Id': 'c1d9673d-eba6-4cf8-a209-cc87f4f7cbbb',
      },
    },
    (res) => {
      assert.equal(res.statusCode, 200);
      res.on('data', () => {
        gotFirstChunk = true;
      });
      res.on('aborted', () => resolveClosed());
      res.on('close', () => resolveClosed());
    }
  );
  req.on('error', () => {});
  req.end(payload);

  await adapterCalled;
  // 发一个有效 chunk(arm/reset idle 计时器),然后保持静默 —— 不再写、不 end、不报错。
  upstream.write('data: {"choices":[{"delta":{"content":"partial"}}]}\n\n');

  const start = Date.now();
  await Promise.race([
    clientClosed,
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error('idle timer did not tear down the stream within 3s')), 3000)
    ),
  ]);
  const elapsed = Date.now() - start;

  assert.equal(gotFirstChunk, true, '客户端应在 idle 掐断前先收到那个 chunk');
  assert.equal(upstreamClosed, true, '服务端应主动 destroy 掉静默的上游 stream');
  // 健全性下限:idle=200ms,不应是别的原因秒关。给宽松 50ms 防 CI 抖动;上限由 3s race 保证。
  assert.ok(elapsed >= 50, `teardown 应等到 idle 阈值,实测 ${elapsed}ms`);
});
