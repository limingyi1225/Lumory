const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '.env') });
const express = require('express');
const axios = require('axios');
const app = express();
app.use(express.json());

const OPENAI_API_KEY = process.env.OPENAI_API_KEY;
console.log('🔑 Loaded OPENAI_API_KEY:', OPENAI_API_KEY ? `${OPENAI_API_KEY.substring(0, 10)}...` : 'NOT SET');
if (!OPENAI_API_KEY) {
  console.error('❌ Missing OPENAI_API_KEY! 请在 server/.env 中设置该值');
  process.exit(1);
}
const OPENAI_BASE_URL = 'https://api.openai.com/v1';

// Health check endpoint
app.get('/health', (req, res) => {
  res.json({ status: 'ok', message: 'Backend is running' });
});

// OpenAI proxy endpoint
app.post('/api/openai/chat/completions', async (req, res) => {
  try {
    const isStreaming = req.body.stream === true;

    if (isStreaming) {
      // Handle streaming request
      console.log('🌊 处理流式请求...');
      console.log('📦 Request body:', JSON.stringify(req.body, null, 2));

      // Set headers for SSE
      res.setHeader('Content-Type', 'text/event-stream');
      res.setHeader('Cache-Control', 'no-cache');
      res.setHeader('Connection', 'keep-alive');
      res.setHeader('X-Accel-Buffering', 'no'); // Disable Nginx buffering

      const response = await axios({
        method: 'post',
        url: `${OPENAI_BASE_URL}/chat/completions`,
        data: req.body,
        headers: {
          Authorization: `Bearer ${OPENAI_API_KEY}`,
          'Content-Type': 'application/json',
          'Accept': 'text/event-stream'
        },
        responseType: 'stream'
      });

      // Pipe the stream directly to the client
      response.data.on('data', (chunk) => {
        res.write(chunk);
      });

      response.data.on('end', () => {
        res.end();
      });

      response.data.on('error', (error) => {
        console.error('Stream error:', error);
        res.end();
      });

      // Handle client disconnect
      req.on('close', () => {
        response.data.destroy();
      });

    } else {
      // Handle non-streaming request
      console.log('📄 处理非流式请求...');
      console.log('📦 Request body:', JSON.stringify(req.body, null, 2));

      const resp = await axios.post(
        `${OPENAI_BASE_URL}/chat/completions`,
        req.body,
        {
          headers: {
            Authorization: `Bearer ${OPENAI_API_KEY}`,
            'Content-Type': 'application/json'
          }
        }
      );
      res.json(resp.data);
    }
  } catch (err) {
    console.error('OpenAI Error:', err.response?.data || err.message);
    res.status(err.response?.status || 500)
      .json({ error: err.response?.data || err.message });
  }
});

const port = process.env.PORT || 3000;
app.listen(port, () => {
  console.log(`🚀 后端服务已启动，监听端口 ${port}`);
  console.log(`🔗 直连 OpenAI API: ${OPENAI_BASE_URL}`);
});
